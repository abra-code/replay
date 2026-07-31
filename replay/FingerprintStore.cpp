#include "FingerprintStore.h"

#include "FileHashing.h" // crc32_impl
#include "FileInfo.h"
#include "LogStream.h"
#include "PosixFileOps.h" // posix_mkdir_p

#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>

#include <dispatch/dispatch.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib> // arc4random_buf
#include <cstring>
#include <mutex>
#include <vector>

namespace fpstore
{

// ---------------------------------------------------------------------------
// On-disk format
//
//   fingerprints-<hostuuid32hex>-<algo>.bin
//   FpHeader | capacity * FpSlot | FpTrailer
//
// The magics are stored as native-endian uint64 on purpose: a store written on a
// machine of the other byte order fails the magic check and is rebuilt, rather than
// being read with every field transposed. The file is machine-local anyway.
// ---------------------------------------------------------------------------

constexpr uint64_t kHeaderMagic = 0x01535046594C5052ULL;  // "RPLYFPS\1" little-endian
constexpr uint64_t kTrailerMagic = 0x01545046594C5052ULL; // "RPLYFPT\1" little-endian
constexpr uint32_t kFormatVersion = 1;

constexpr uint32_t kAlgoCrc32c = 0;
constexpr uint32_t kAlgoBlake3 = 1;

// Where the published image records its own checksum. replay's own name, not one of the
// public.fingerprint.* names the gate and fingerprint tools memoize from - see
// mirror_checksum_xattr for why that distinction is the whole point.
inline constexpr const char *kStoreChecksumXattrName = "public.replay.store-crc32c";

struct FpHeader
{
	uint64_t magic;
	uint32_t version;
	uint32_t hashAlgo;
	uint64_t capacity;   // cross-checked against the file size, never trusted for bounds
	uint64_t count;      // advisory only
	uint64_t runCounter; // bumped on each rewrite; drives eviction
	uint8_t hostUuid[16];
	// Distinguishes two table images that happen to share a runCounter. The counter
	// restarts at 1 whenever the table is rebuilt from nothing - which is routine, since
	// a failed checksum is treated as an empty store - so it alone does not identify an
	// image. Only the journal reads this; see the batch header. Zero means "written
	// before this field existed", which no journal can name, so such a table simply
	// carries no journal until its next rewrite.
	uint64_t nonce;
};

struct FpSlot
{
	uint64_t fileKey;     // mix64(dev, inode); 0 means the slot is empty
	uint64_t statTag;     // mix64(size, mtime_ns, ctime_ns, file type)
	uint64_t contentHash; // crc32c zero-extended, or the low 64 bits of blake3
	uint32_t epoch;       // runCounter when this slot was last written
	uint32_t flags;       // reserved
};

// crc32c rather than blake3, and not because blake3 would not fit - the trailer has 4
// spare bytes, so a 64-bit digest would sit in the same 16.
//
// Neither is keyed, so neither resists tampering: anyone who can write this file can
// rewrite these 16 bytes, and blake3's preimage resistance buys nothing against someone
// who is not being asked to find a preimage. What is left is accidental corruption, and
// there the two differ less than they look. This generator (0x11EDC6F41) has (x+1) as a
// factor and a nonzero constant term, which GUARANTEES detection of every single-bit
// error, every odd number of flipped bits, and every burst up to 32 bits - the shapes bit
// rot actually takes. It also catches every 2-bit error up to 2^31-1 bits between the two
// flips, which is 256 MB, so that guarantee is total for any store of a realistic size
// even though kMaxCapacity would permit a larger one.
//
// blake3 is stronger for damage outside those classes - a scattered even number of flips,
// two separate bursts, a zeroed block - at 2^-64 against 2^-32, truncated to 64 bits as
// everything else here stores it. That margin is spent on an event that has to happen
// first, though: unlike a content-hash collision, which gets a fresh trial for every file
// on every run, a trailer collision needs the file to be corrupt before it can matter.
//
// The cost is not close. Measured on this machine, hashing warm memory: crc32c ~50 GB/s
// (a hardware instruction, folded three ways), blake3 ~1.8 GB/s. As a verify pass over a
// 32 MB store, faulting the mapping in included, that is ~2.8 ms against ~21 ms - on a
// pass that runs before any useful work on every single run. Cheap enough to be
// unconditional is the property worth keeping, because an integrity check behind a flag
// is worse than a slightly weaker one that always runs; and at 50 GB/s the pass is fast
// enough to be worth it for pre-faulting the mapping alone, which stops being true once
// the hash is slower than the memory it reads.
struct FpTrailer
{
	uint64_t magic;
	uint32_t crc32c; // over bytes [0, fileSize - sizeof(FpTrailer))
	uint32_t reserved;
};

// ---------------------------------------------------------------------------
// The journal
//
//   fingerprints-<hostuuid32hex>-<algo>.jrnl
//   FpJournalHeader | batch*        where batch = FpBatchHeader | n * FpSlot | FpBatchTrailer
//
// A separate file, so the table's format above is untouched and a reader that ignores
// the journal is still correct - only colder. Each batch carries its own checksum, so a
// tail torn by a crash costs exactly that batch, and the storeRun it names ties it to the
// table image it extends: a batch left behind by a publisher that crashed between the
// rename and clearing the journal describes a table that no longer exists, and is dropped
// rather than mixed into one it was never sized against.
// ---------------------------------------------------------------------------

constexpr uint64_t kJournalMagic = 0x014A5046594C5052ULL;  // "RPLYFPJ\1" little-endian
constexpr uint64_t kBatchMagic = 0x01425046594C5052ULL;    // "RPLYFPB\1" little-endian
constexpr uint64_t kBatchEndMagic = 0x01455046594C5052ULL; // "RPLYFPE\1" little-endian

struct FpJournalHeader
{
	uint64_t magic;
	uint32_t version;
	uint32_t hashAlgo;
	uint8_t hostUuid[16];
};

struct FpBatchHeader
{
	uint64_t magic;
	uint64_t count;      // slots that follow
	uint64_t storeRun;   // runCounter of the table image this batch extends
	uint64_t storeNonce; // and its nonce, because the counter alone can repeat
};

struct FpBatchTrailer
{
	uint64_t magic;
	uint32_t crc32c; // over [batch header, end of this batch's slots)
	uint32_t reserved;
};

// The format is on disk the moment this ships, so pin it at compile time.
static_assert(sizeof(FpHeader) == 64, "FpHeader must stay 64 bytes");
static_assert(sizeof(FpSlot) == 32, "FpSlot must stay 32 bytes: two per cache line");
static_assert(sizeof(FpTrailer) == 16, "FpTrailer must stay 16 bytes");
static_assert(alignof(FpSlot) == 8, "FpSlot fields must stay naturally aligned");
static_assert((sizeof(FpHeader) % alignof(FpSlot)) == 0, "slots must start aligned");
static_assert(sizeof(FpJournalHeader) == 32, "FpJournalHeader must stay 32 bytes");
static_assert(sizeof(FpBatchHeader) == 32, "FpBatchHeader must stay 32 bytes");
static_assert(sizeof(FpBatchTrailer) == 16, "FpBatchTrailer must stay 16 bytes");
// Together these are what lets the journal reader walk from one batch to the next and
// still hand out an aligned FpSlot pointer: the first batch starts at a multiple of
// alignof(FpSlot), and every batch is a whole number of them long.
static_assert(((sizeof(FpJournalHeader) + sizeof(FpBatchHeader)) % alignof(FpSlot)) == 0,
              "a batch's slots must start aligned");
static_assert(((sizeof(FpBatchHeader) + sizeof(FpBatchTrailer)) % alignof(FpSlot)) == 0,
              "a batch's total size must keep the next batch aligned");

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

// Power of two: record() picks its shard with a mask.
constexpr size_t kShardCount = 64;

constexpr uint64_t kMinCapacity = 1024;

// Linear probing is the right fit for an mmap'd table specifically: a six-slot probe
// run is 192 bytes and stays inside one page, so a miss costs one fault rather than six.
// Above ~0.7 the average run starts growing fast enough to leave the page.
constexpr double kMaxLoadFactor = 0.7;

// A slot survives a rewrite while it has been used within this many store-modifying
// runs. runCounter only advances when the store is actually rewritten, so a steady state
// that writes nothing ages nothing. A store shared by playlists that run at very
// different frequencies will evict the rare one; its next run is slow once and self-heals.
constexpr uint32_t kMaxIdleRuns = 32;

// The epoch field is 32 bits, so the run counter cannot exceed what it can hold.
constexpr uint64_t kMaxRunCounter = 0xFFFFFFFFULL;

// 1G slots is 32 GB. Far past anything real; the point is that a corrupt or absurd
// entry count cannot ask for an allocation that wraps or thrashes the machine.
constexpr uint64_t kMaxCapacity = 1ULL << 30;

// How much the journal is allowed to hold before a run folds it back into the table.
//
// A quarter of the table is the point past which appending has stopped being a saving:
// reading a journal that size already costs a noticeable fraction of rewriting the table,
// and every entry in it is a slot the next probe may have to check twice. At the 1024-slot
// minimum that quarter is 256, so the floor below never engages for a table this code
// writes; it only matters for a smaller one, which map_and_validate accepts because it
// checks that the capacity is a power of two rather than that it is at least kMinCapacity.
constexpr uint64_t kMinJournalEntries = 64;
constexpr uint64_t kJournalCapacityShare = 4;

// Bounds on what a corrupt journal can ask us to allocate before its checksum has been
// checked - the count field is read from the file, so it is hostile input until then.
constexpr uint64_t kMaxBatchEntries = 1ULL << 24;
constexpr uint64_t kMaxJournalBytes = 64ULL << 20;

uint64_t journal_budget(uint64_t capacity)
{
	uint64_t share = capacity / kJournalCapacityShare;
	return (share > kMinJournalEntries) ? share : kMinJournalEntries;
}

// One run's knowledge about one file, before epochs are assigned at merge time.
struct PendingRecord
{
	uint64_t fileKey;
	uint64_t statTag;
	uint64_t contentHash;
};

// splitmix64 / murmur3 finalizer. Inode numbers are near-sequential and cluster badly
// under a bare mask, and st_dev is a tiny number, so both go through this before use.
inline uint64_t mix64(uint64_t x)
{
	x ^= x >> 30;
	x *= 0xBF58476D1CE4E5B9ULL;
	x ^= x >> 27;
	x *= 0x94D049BB133111EBULL;
	x ^= x >> 31;
	return x;
}

// 0 means "no usable key": either the caller handed us the non-existent-file sentinel
// (inode 0), or the mix landed on 0, which the table reserves for an empty slot.
uint64_t file_key(const FileInfo &info)
{
	if(info.inode == 0)
		return 0;
	uint64_t key = mix64((uint64_t)(uint32_t)info.dev + 0x9E3779B97F4A7C15ULL);
	key = mix64(key ^ (uint64_t)info.inode);
	return (key == 0) ? 1 : key;
}

// The condition under which a file's bytes cannot have changed.
//
// mtime alone is not that condition: a tool that preserves timestamps, or plain
// "touch -r", restores it after a rewrite. ctime closes that, because utimes() is
// itself an inode metadata change and POSIX requires it to move ctime - there is no
// portable way to put ctime back. The xattr backend cannot use this, because setxattr
// bumps ctime itself and its records would invalidate themselves on every write.
//
// The file type is folded in as well, so an inode recycled from a symlink to a regular
// file of the same size cannot reuse the old record even if the timestamps collide.
uint64_t stat_tag(const FileInfo &info)
{
	uint64_t tag = mix64((uint64_t)info.size + 0x9E3779B97F4A7C15ULL);
	tag = mix64(tag ^ (uint64_t)info.mtime_ns);
	tag = mix64(tag ^ (uint64_t)info.ctime_ns);
	tag = mix64(tag ^ (uint64_t)(info.mode & S_IFMT));
	return tag;
}

// A validated read-only mapping of a store file, or nothing.
// Owns its descriptor and mapping unless they are handed off with release().
struct MappedStore
{
	int fd = -1;
	void *base = nullptr;
	size_t size = 0;
	uint64_t capacity = 0;
	uint64_t runCounter = 0;
	uint64_t nonce = 0;
	uint64_t count = 0;

	MappedStore() = default;
	~MappedStore() { reset(); }

	MappedStore(const MappedStore &) = delete;
	MappedStore &operator=(const MappedStore &) = delete;

	void reset()
	{
		if(base != nullptr)
		{
			munmap(base, size);
			base = nullptr;
		}
		if(fd >= 0)
		{
			close(fd);
			fd = -1;
		}
		size = 0;
		capacity = 0;
		runCounter = 0;
		nonce = 0;
		count = 0;
	}

	bool valid() const { return (base != nullptr); }

	const FpSlot *slots() const
	{
		return (const FpSlot *)((const uint8_t *)base + sizeof(FpHeader));
	}

	// Transfers ownership of the descriptor and mapping to the caller.
	void release(int &outFd, void *&outBase, size_t &outSize)
	{
		outFd = fd;
		outBase = base;
		outSize = size;
		fd = -1;
		base = nullptr;
		size = 0;
	}
};

void report(bool verbose, const char *what, const std::string &path)
{
	if(verbose)
		LogError("memo: %s: %s\n", what, path.c_str());
}

// Opens, maps and fully validates the store at path. Any failure leaves outMap empty,
// which every caller treats as "no store" - the file is never unlinked, so a transient
// read error on a network mount cannot destroy good data.
//
// The order matters. Everything is derived from the descriptor we already hold, never
// from the path a second time: a concurrent publisher's rename between a stat and an
// open would otherwise let us mix a header from one inode with slots from another.
// And the capacity used for bounds is derived from the file size, with the header's
// own value only cross-checked - sizing a mapping from a header field is the standard
// way to turn a corrupt file into an out-of-bounds read.
void map_and_validate(const std::string &path, uint32_t wantAlgo, const uint8_t *wantHost,
                      bool verbose, MappedStore &outMap)
{
	outMap.reset();

	// O_NONBLOCK is what keeps a hostile or careless name in a shared cache directory from
	// hanging the build rather than merely failing it: opening a FIFO for reading blocks
	// until a writer appears, and that happens before any fstat could reject it. On a
	// regular file the flag has no effect on the reads below.
	int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
	if(fd < 0)
	{
		// ENOENT is the normal cold start, not a diagnostic. ELOOP means someone planted
		// a symlink where the store belongs, which is worth a word under verbose.
		if(errno != ENOENT)
			report(verbose, "cannot open store", path);
		return;
	}
	outMap.fd = fd;

	struct stat st;
	if(fstat(fd, &st) != 0)
	{
		report(verbose, "cannot stat store", path);
		outMap.reset();
		return;
	}
	if(!S_ISREG(st.st_mode))
	{
		report(verbose, "store is not a regular file", path);
		outMap.reset();
		return;
	}

	const uint64_t fixedBytes = sizeof(FpHeader) + sizeof(FpTrailer);
	if((st.st_size < 0) || ((uint64_t)st.st_size < fixedBytes))
	{
		report(verbose, "store is too short", path);
		outMap.reset();
		return;
	}

	// Capacity comes from the file size, not from the header.
	uint64_t slotBytes = (uint64_t)st.st_size - fixedBytes;
	if((slotBytes % sizeof(FpSlot)) != 0)
	{
		report(verbose, "store size is not a whole number of slots", path);
		outMap.reset();
		return;
	}
	uint64_t capacity = slotBytes / sizeof(FpSlot);
	if((capacity == 0) || (capacity > kMaxCapacity) || ((capacity & (capacity - 1)) != 0))
	{
		report(verbose, "store capacity is not a usable power of two", path);
		outMap.reset();
		return;
	}

	size_t mapSize = (size_t)st.st_size;
	void *base = mmap(nullptr, mapSize, PROT_READ, MAP_PRIVATE, fd, 0);
	if(base == MAP_FAILED)
	{
		report(verbose, "cannot map store", path);
		outMap.reset();
		return;
	}
	outMap.base = base;
	outMap.size = mapSize;

	FpHeader header;
	memcpy(&header, base, sizeof(header));
	if(header.magic != kHeaderMagic)
	{
		report(verbose, "store has a foreign or corrupt header", path);
		outMap.reset();
		return;
	}
	if(header.version != kFormatVersion)
	{
		report(verbose, "store was written by a different format version", path);
		outMap.reset();
		return;
	}
	if(header.hashAlgo != wantAlgo)
	{
		report(verbose, "store holds hashes of another algorithm", path);
		outMap.reset();
		return;
	}
	if(memcmp(header.hostUuid, wantHost, 16) != 0)
	{
		// Inode numbers only mean anything on the machine that produced them. The host
		// is already in the file name, so this only fires for a store that was copied
		// or renamed onto this machine.
		report(verbose, "store belongs to another machine", path);
		outMap.reset();
		return;
	}
	if(header.capacity != capacity)
	{
		report(verbose, "store header disagrees with its size", path);
		outMap.reset();
		return;
	}

	// The checksum is what catches the failure the rest of the design cannot: a single
	// flipped bit inside a slot is structurally indistinguishable from a valid entry,
	// and it would hand back a wrong content hash for a file whose key and stat tag
	// still match - a silent wrong skip. APFS checksums metadata but not file data, so
	// this is the only thing looking. Measured at 2.8 ms for a 32 MB store against the
	// ~260 ms of getxattr the sidecar removes on a 20k-file run, so it is never optional.
	//
	// It detects accidental corruption, not tampering: there is no key, so anyone who
	// can write the store can write a matching trailer. Permissions on the cache
	// directory are the defense against a hostile writer.
	size_t bodySize = mapSize - sizeof(FpTrailer);
	FpTrailer trailer;
	memcpy(&trailer, (const uint8_t *)base + bodySize, sizeof(trailer));
	if(trailer.magic != kTrailerMagic)
	{
		report(verbose, "store trailer is missing or corrupt", path);
		outMap.reset();
		return;
	}
	if(trailer.crc32c != crc32_impl(0, (const char *)base, bodySize))
	{
		report(verbose, "store failed its integrity check, rebuilding", path);
		outMap.reset();
		return;
	}

	outMap.capacity = capacity;
	outMap.runCounter = header.runCounter;
	outMap.nonce = header.nonce;
	outMap.count = (header.count <= capacity) ? header.count : capacity;
}

// Collapses duplicate records for one file down to a single entry.
//
// Several tasks fingerprinting a shared header record it several times, so without this
// the merge would size the table from the number of (task, file) pairs rather than the
// number of files. Ties keep the last entry in sorted order, which is an arbitrary one
// of the duplicates - and that is safe: duplicates are identical unless the file changed
// mid-run, and then either {stat tag, content hash} pair is usable, because each pair
// was observed together. The next run either matches that tag (a correct hit) or does
// not (a miss).
void dedupe_shard(std::vector<PendingRecord> &records)
{
	if(records.size() < 2)
		return;

	std::sort(records.begin(), records.end(),
		[](const PendingRecord &a, const PendingRecord &b) { return a.fileKey < b.fileKey; });

	size_t out = 0;
	for(size_t i = 0; i < records.size(); ++i)
	{
		if(((i + 1) < records.size()) && (records[i + 1].fileKey == records[i].fileKey))
			continue;
		records[out++] = records[i];
	}
	records.resize(out);
}

// Probe-and-overwrite insertion into a table that is guaranteed to have room.
// Returns true when a previously empty slot was claimed, so the caller can keep count.
bool insert_slot(FpSlot *slots, uint64_t capacity, const FpSlot &value)
{
	uint64_t mask = capacity - 1;
	uint64_t index = value.fileKey & mask;
	for(uint64_t probe = 0; probe < capacity; ++probe)
	{
		FpSlot &slot = slots[index];
		if(slot.fileKey == 0)
		{
			slot = value;
			return true;
		}
		if(slot.fileKey == value.fileKey)
		{
			slot = value; // a fresher record for the same file wins
			return false;
		}
		index = (index + 1) & mask;
	}
	// Unreachable: the caller sizes the table for every entry it will insert. Dropping a
	// record if it ever happened would cost one re-hash, never a wrong answer.
	return false;
}

// The entry for fileKey in an open-addressed table, or null. Shared by the mapped table,
// the journal overlay and the merge, so all three agree on the probe rule: an empty slot
// ends the run, and because each file occupies exactly one slot, a key match is the
// answer whether or not its stat tag is the one the caller wanted.
const FpSlot *find_slot(const FpSlot *slots, uint64_t capacity, uint64_t fileKey)
{
	if((slots == nullptr) || (capacity == 0))
		return nullptr;

	uint64_t mask = capacity - 1;
	uint64_t index = fileKey & mask;
	for(uint64_t probe = 0; probe < capacity; ++probe)
	{
		const FpSlot &slot = slots[index];
		if(slot.fileKey == 0)
			return nullptr;
		if(slot.fileKey == fileKey)
			return &slot;
		index = (index + 1) & mask;
	}
	return nullptr;
}

const char *algorithm_name(uint32_t algorithmTag)
{
	return (algorithmTag == kAlgoBlake3) ? "blake3" : "crc32c";
}

// An in-memory probe table over a flat list of slots. Used for the journal, which is a
// list on disk but has to answer lookups.
struct SlotIndex
{
	std::vector<FpSlot> slots;
	uint64_t capacity = 0; // 0 when there is nothing indexed; slots is then empty
	uint64_t distinct = 0;
};

void build_index(const std::vector<FpSlot> &records, SlotIndex &out)
{
	out.slots.clear();
	out.capacity = 0;
	out.distinct = 0;
	if(records.empty())
		return;

	uint64_t target = (uint64_t)((double)records.size() / kMaxLoadFactor) + 1;
	uint64_t capacity = 64;
	while((capacity < target) && (capacity < kMaxCapacity))
		capacity <<= 1;
	if(capacity < target)
		return; // unreachable at journal sizes; an unindexed journal only costs re-hashing

	out.slots.assign((size_t)capacity, FpSlot{0, 0, 0, 0, 0});
	out.capacity = capacity;
	// File order is oldest first and insert_slot overwrites on a key match, so the last
	// record for a file - the newest - is the one that survives.
	for(const FpSlot &record : records)
	{
		if(insert_slot(out.slots.data(), capacity, record))
			++out.distinct;
	}
}

// Closes a descriptor on every exit path, including a throw out of an allocating read.
struct FdGuard
{
	int fd;
	~FdGuard()
	{
		if(fd >= 0)
			close(fd);
	}
};

// What one journal file yielded.
struct JournalContents
{
	std::vector<FpSlot> slots; // in file order, oldest batch first, so a later record wins
	// The journal on disk cannot be appended to as it stands and has to be rewritten:
	// a torn tail (everything after it would be unreachable, because the reader stops at
	// the first batch that fails), a batch belonging to a superseded table image, or a
	// file we could not make sense of at all. Never fatal - the slots recovered before
	// the problem are still good and are carried into the replacement.
	bool needsReset = false;
};

// Reads and fully validates the journal for the table image identified by storeRun.
// Like the table, any failure means "nothing usable here", never an error the run sees.
void read_journal(const std::string &path, uint32_t wantAlgo, const uint8_t *wantHost,
                  uint64_t storeRun, uint64_t storeNonce, bool verbose, JournalContents &out)
{
	out.slots.clear();
	out.needsReset = false;

	// O_NONBLOCK for the reason map_and_validate uses it: a FIFO planted at this name
	// would otherwise block the open forever, before the S_ISREG check below can reject it.
	int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
	if(fd < 0)
	{
		if(errno != ENOENT)
		{
			// Something is at that name that we cannot read - including a planted symlink,
			// which O_NOFOLLOW turns into ELOOP. Replacing it is the only way forward.
			report(verbose, "cannot open journal", path);
			out.needsReset = true;
		}
		return; // ENOENT is the normal case: no journal since the last table rewrite
	}
	FdGuard guard{fd};

	struct stat st;
	if((fstat(fd, &st) != 0) || !S_ISREG(st.st_mode) || (st.st_size < 0))
	{
		report(verbose, "cannot stat journal", path);
		out.needsReset = true;
		return;
	}
	if(st.st_size == 0)
		return; // created but not yet written to; the next append writes its header

	if((uint64_t)st.st_size > kMaxJournalBytes)
	{
		report(verbose, "journal is implausibly large, resetting", path);
		out.needsReset = true;
		return;
	}

	// read() rather than mmap. The journal is small and bounded, and it is the one file
	// in this design that is written in place: a mapping of it would have to reason about
	// another process appending to or replacing it mid-read, and a heap copy simply does
	// not have that failure mode.
	std::vector<uint8_t> raw((size_t)st.st_size);
	size_t filled = 0;
	while(filled < raw.size())
	{
		ssize_t count = read(fd, raw.data() + filled, raw.size() - filled);
		if(count < 0)
		{
			if(errno == EINTR)
				continue;
			report(verbose, "cannot read journal", path);
			out.needsReset = true;
			return;
		}
		if(count == 0)
			break; // shorter than fstat promised: it was replaced under us
		filled += (size_t)count;
	}
	raw.resize(filled);

	if(raw.size() < sizeof(FpJournalHeader))
	{
		out.needsReset = true;
		return;
	}
	FpJournalHeader header;
	memcpy(&header, raw.data(), sizeof(header));
	if((header.magic != kJournalMagic) || (header.version != kFormatVersion) ||
	   (header.hashAlgo != wantAlgo) || (memcmp(header.hostUuid, wantHost, 16) != 0))
	{
		report(verbose, "journal is foreign or corrupt, resetting", path);
		out.needsReset = true;
		return;
	}

	size_t offset = sizeof(FpJournalHeader);
	while(offset < raw.size())
	{
		uint64_t remaining = (uint64_t)(raw.size() - offset);
		if(remaining < (sizeof(FpBatchHeader) + sizeof(FpBatchTrailer)))
		{
			out.needsReset = true; // a tail too short to be a batch at all
			break;
		}

		FpBatchHeader batch;
		memcpy(&batch, raw.data() + offset, sizeof(batch));
		if((batch.magic != kBatchMagic) || (batch.count == 0) || (batch.count > kMaxBatchEntries))
		{
			out.needsReset = true;
			break;
		}

		// Bounded by kMaxBatchEntries above, so neither product can overflow, and the
		// comparison against what is actually left is what makes the count safe to trust.
		uint64_t bodyBytes = sizeof(FpBatchHeader) + (batch.count * sizeof(FpSlot));
		uint64_t batchBytes = bodyBytes + sizeof(FpBatchTrailer);
		if(batchBytes > remaining)
		{
			out.needsReset = true;
			break;
		}

		FpBatchTrailer trailer;
		memcpy(&trailer, raw.data() + offset + bodyBytes, sizeof(trailer));
		if(trailer.magic != kBatchEndMagic)
		{
			out.needsReset = true;
			break;
		}
		if(trailer.crc32c != crc32_impl(0, (const char *)(raw.data() + offset), (size_t)bodyBytes))
		{
			report(verbose, "journal batch failed its integrity check", path);
			out.needsReset = true;
			break;
		}

		// Both halves of the identity, because runCounter restarts at 1 every time the
		// table is rebuilt from nothing - which a failed checksum makes routine - so two
		// different images can and do share one. A table written before the nonce existed
		// carries 0, which no batch this code writes can name.
		if((batch.storeRun == storeRun) && (batch.storeNonce == storeNonce) && (storeNonce != 0))
		{
			// Aligned by construction: the static_asserts above make every batch start and
			// every batch length a multiple of alignof(FpSlot), and raw.data() is at least
			// that aligned because it came from the allocator.
			const FpSlot *slots = (const FpSlot *)(raw.data() + offset + sizeof(FpBatchHeader));
			out.slots.insert(out.slots.end(), slots, slots + batch.count);
		}
		else
		{
			// Structurally sound but written against a table image that has since been
			// replaced. The records are still true, but their epochs and the count they
			// were sized against belong to a generation that is gone.
			out.needsReset = true;
		}
		offset += (size_t)batchBytes;
	}
}

// A record of what was in the store file at the moment it was published: the same
// 32-byte layout the gate and fingerprint tools use, so it can be read back with the
// same tools, but under replay's own name.
//
// Deliberately NOT "public.fingerprint.crc32c". That name has a trust rule attached -
// if inode, size and mtime still match, use the recorded hash instead of reading the
// file - and it is the default in both of those tools. Bit rot moves none of those
// three, so a record under that name would answer a question about the store's current
// contents with a value from before the rot. That is the silent wrong answer the
// trailer exists to prevent, reintroduced beside the file for a different reader; and
// it would be wrong precisely when someone is looking, because the reason to point
// fingerprint at this file is to investigate corruption. Under our own name nothing
// treats it as a memo, and it stays inspectable with `xattr -p`.
//
// So: this says "at publication the bytes hashed to X", never "the bytes hash to X".
// Nothing in replay reads it back, and nothing should ever skip the trailer because of
// it. The trailer is inside the file and covers the bytes; this sits beside them.
//
// Written to the temp descriptor before the rename, so it is published atomically with
// the bytes it describes and travels with the inode rather than the name. setxattr moves
// ctime, not mtime, so the record does not invalidate itself, and the temp is created
// O_EXCL on a fresh inode so a stale record can never survive onto a new image.
//
// Always crc32c, whatever --cache-hash selected for the hashes stored INSIDE the table:
// this describes the store file's own bytes, and crc32c is what the trailer already
// computed. Hashing a megabyte again with blake3 to fill in a diagnostic is not worth
// it. And only the table gets one - the journal is appended to in place, so any record
// of its bytes would go stale on the very next append.
//
// Best effort throughout: a filesystem with no xattr support returns ENOTSUP, which is
// exactly the case the trailer-not-xattr decision was made for, and is not worth a word.
void mirror_checksum_xattr(int fd, uint32_t wholeFileCrc32c, const std::string &path, bool verbose)
{
	struct stat st;
	if(fstat(fd, &st) != 0)
		return;

	FileInfoCore record;
	memset(&record, 0, sizeof(record));
	record.inode = st.st_ino;
	record.size = st.st_size;
	record.mtime_ns = (int64_t)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec;
	record.hash.crc32c = wholeFileCrc32c;

	if(fsetxattr(fd, kStoreChecksumXattrName, &record, sizeof(record), 0, 0) != 0)
	{
		if((errno != ENOTSUP) && (errno != EPERM) && (errno != EACCES))
			report(verbose, "cannot record the store checksum in an xattr", path);
	}
}

// Appends one batch, or writes the journal from scratch when rewrite is set - the repair
// path, which carries the records that did verify into the replacement so that a torn
// tail costs only the batch it truncated.
//
// Returns false when it published nothing. The journal is then either untouched (every
// failure on the append path rolls back) or removed (the repair path, which has to clear
// the unusable file before it can replace it). Either way the caller's fallback - rewrite
// the whole table, folding in the records it still holds in memory - is correct.
bool write_journal_batch(const std::string &path, uint32_t algorithmTag, const uint8_t *hostUuid,
                         uint64_t storeRun, uint64_t storeNonce, const std::vector<FpSlot> &carried,
                         const std::vector<FpSlot> &fresh, bool rewrite, bool verbose)
{
	// Before anything is opened or removed: a batch with no records is not a thing to
	// write. The caller relies on this to tell "nothing to publish" apart from a failure.
	size_t carriedCount = rewrite ? carried.size() : 0;
	uint64_t count = (uint64_t)carriedCount + (uint64_t)fresh.size();
	if((count == 0) || (count > kMaxBatchEntries))
		return false;

	if(rewrite)
		unlink(path.c_str());

	// O_NOFOLLOW for the same reason the table uses it: a shared cache directory is an
	// advertised use case, and without it another user can plant this name as a symlink
	// and have us append to a file of their choosing. O_NONBLOCK so that a planted FIFO
	// fails the open (ENXIO) instead of blocking it until a reader turns up.
	int fd = open(path.c_str(),
		O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0644);
	if(fd < 0)
	{
		report(verbose, "cannot open journal for append", path);
		return false;
	}
	FdGuard guard{fd};

	struct stat st;
	if((fstat(fd, &st) != 0) || !S_ISREG(st.st_mode) || (st.st_size < 0))
	{
		report(verbose, "cannot stat journal for append", path);
		return false;
	}
	off_t originalSize = st.st_size;
	bool needHeader = (originalSize == 0);
	if(!needHeader && ((uint64_t)originalSize < sizeof(FpJournalHeader)))
		return false; // a stub too short to hold a header: let the caller rewrite the table

	size_t headerBytes = needHeader ? sizeof(FpJournalHeader) : 0;
	size_t bodyBytes = sizeof(FpBatchHeader) + (size_t)(count * sizeof(FpSlot));
	std::vector<uint8_t> image(headerBytes + bodyBytes + sizeof(FpBatchTrailer), 0);

	if(needHeader)
	{
		FpJournalHeader header;
		memset(&header, 0, sizeof(header));
		header.magic = kJournalMagic;
		header.version = kFormatVersion;
		header.hashAlgo = algorithmTag;
		memcpy(header.hostUuid, hostUuid, sizeof(header.hostUuid));
		memcpy(image.data(), &header, sizeof(header));
	}

	FpBatchHeader batch;
	memset(&batch, 0, sizeof(batch));
	batch.magic = kBatchMagic;
	batch.count = count;
	batch.storeRun = storeRun;
	batch.storeNonce = storeNonce;
	memcpy(image.data() + headerBytes, &batch, sizeof(batch));

	size_t slotOffset = headerBytes + sizeof(FpBatchHeader);
	if(carriedCount > 0)
		memcpy(image.data() + slotOffset, carried.data(), carriedCount * sizeof(FpSlot));
	if(!fresh.empty())
	{
		memcpy(image.data() + slotOffset + (carriedCount * sizeof(FpSlot)),
		       fresh.data(), fresh.size() * sizeof(FpSlot));
	}

	FpBatchTrailer trailer;
	memset(&trailer, 0, sizeof(trailer));
	trailer.magic = kBatchEndMagic;
	trailer.crc32c = crc32_impl(0, (const char *)(image.data() + headerBytes), bodyBytes);
	memcpy(image.data() + headerBytes + bodyBytes, &trailer, sizeof(trailer));

	const uint8_t *cursor = image.data();
	size_t remaining = image.size();
	bool written = true;
	while(remaining > 0)
	{
		ssize_t count2 = write(fd, cursor, remaining);
		if(count2 <= 0)
		{
			if((count2 < 0) && (errno == EINTR))
				continue;
			written = false;
			break;
		}
		cursor += count2;
		remaining -= (size_t)count2;
	}

	if(!written)
	{
		// A half-written batch is worse than a lost one: the reader stops at the first
		// batch that fails, so everything appended after it would be unreachable until the
		// next table rewrite. Roll back to the length we found, and if even that fails,
		// remove the journal - the table on its own is always a complete answer.
		report(verbose, "cannot append to journal", path);
		if(ftruncate(fd, originalSize) != 0)
			unlink(path.c_str());
		return false;
	}
	return true;
}

} // namespace fpstore

using namespace fpstore;

// One stripe of this run's records. Sharded rather than thread_local because GCD worker
// threads come and go mid-run, and a thread-local registry would need destructor
// plumbing to survive that. An uncontended lock is 20-40 ns against the 13 us the memo
// saves per file, and 64 stripes keep contention off the hot path.
struct alignas(64) FingerprintStore::Shard
{
	std::mutex mutex;
	std::vector<PendingRecord> records;
};

FingerprintStore::FingerprintStore(std::string cacheDir, std::string path, std::string journalPath,
                                   uint32_t algorithmTag, const uint8_t *hostUuid, bool verbose)
	: mCacheDir(std::move(cacheDir))
	, mPath(std::move(path))
	, mJournalPath(std::move(journalPath))
	, mAlgorithmTag(algorithmTag)
	, mVerbose(verbose)
	, mShards(new Shard[kShardCount])
{
	memcpy(mHostUuid, hostUuid, sizeof(mHostUuid));
}

FingerprintStore::~FingerprintStore()
{
	if(mMapBase != nullptr)
		munmap(mMapBase, mMapSize);
	if(mFd >= 0)
		close(mFd);
}

std::unique_ptr<FingerprintStore>
FingerprintStore::Open(const std::string &cacheDir, FileHashAlgorithm algorithm, bool verbose)
{
	uint32_t algorithmTag;
	if(algorithm == FileHashAlgorithm::CRC32C)
		algorithmTag = kAlgoCrc32c;
	else if(algorithm == FileHashAlgorithm::BLAKE3)
		algorithmTag = kAlgoBlake3;
	else
		return nullptr; // caller error: there is no store format for UNKNOWN or MISMATCH

	// gethostuuid can fail (it is a syscall, and a restrictive sandbox can deny it).
	// An all-zero fallback still works: it only stops distinguishing two machines that
	// both failed and both share one cache directory, and the worst case there is that
	// each rewrites the other's store.
	uint8_t hostUuid[16] = {0};
	struct timespec wait = {0, 0};
	if(gethostuuid(hostUuid, &wait) != 0)
		memset(hostUuid, 0, sizeof(hostUuid));

	char hostHex[33];
	for(size_t i = 0; i < sizeof(hostUuid); ++i)
		snprintf(hostHex + (i * 2), 3, "%02x", hostUuid[i]);

	// Everything that allocates goes inside the guard, path construction included:
	// the contract this promises is that running without a memo is always available as
	// a fallback, and throwing out of Open would break it for the one caller who cannot
	// retry - a process that is out of memory before it has started any work.
	std::unique_ptr<FingerprintStore> store;
	try
	{
		// The host scopes the file NAME, not just the header: a cache directory on a
		// shared mount then accumulates one store per machine instead of two machines
		// rewriting each other's wholesale every run. The algorithm scopes it too, so
		// switching --cache-hash leaves the store for the other algorithm intact.
		std::string stem = cacheDir;
		if(!stem.empty() && (stem.back() != '/'))
			stem += '/';
		stem += "fingerprints-";
		stem += hostHex;
		stem += '-';
		stem += algorithm_name(algorithmTag);

		store.reset(new FingerprintStore(cacheDir, stem + ".bin", stem + ".jrnl",
			algorithmTag, hostUuid, verbose));
	}
	catch(...)
	{
		return nullptr;
	}

	MappedStore mapped;
	map_and_validate(store->mPath, algorithmTag, hostUuid, verbose, mapped);
	if(mapped.valid())
	{
		uint64_t runCounter = mapped.runCounter;
		uint64_t nonce = mapped.nonce;
		store->mCapacity = mapped.capacity;
		store->mLoadedCount = (size_t)mapped.count;
		store->mSlots = mapped.slots();
		mapped.release(store->mFd, store->mMapBase, store->mMapSize);

		// The journal is only read when the table it extends is, and only for the image
		// actually mapped: without that pairing its records would be overlaid on a table
		// they were never written against. Allocating, so guarded - an unreadable journal
		// costs re-hashing, which is what every other failure in this module costs.
		try
		{
			JournalContents journal;
			read_journal(store->mJournalPath, algorithmTag, hostUuid, runCounter, nonce,
				verbose, journal);

			store->mOverlay.reset(new SlotIndex());
			build_index(journal.slots, *store->mOverlay);
			store->mOverlaySlots = store->mOverlay->slots.data();
			store->mOverlayCapacity = store->mOverlay->capacity;
			store->mJournalCount = (size_t)store->mOverlay->distinct;

			// A journal that cannot be appended to as it stands has to be rewritten, and
			// only save() can do that. Marking the store dirty is what gets us there even
			// on a run that changes nothing - otherwise a tail torn by a crash would sit
			// there permanently, hiding every batch appended after it.
			if(journal.needsReset)
				store->mDirty.store(true, std::memory_order_relaxed);
		}
		catch(...)
		{
			store->mOverlay.reset();
			store->mOverlaySlots = nullptr;
			store->mOverlayCapacity = 0;
			store->mJournalCount = 0;
		}
	}
	return store;
}

const FpSlot *
FingerprintStore::find_known(uint64_t fileKey) const
{
	// The journal holds what changed since the table was written, so it is newer wherever
	// the two disagree and has to be consulted first. It is also much smaller, so the
	// common case - a file the journal does not mention - costs one probe of a table that
	// fits in cache before falling through to the mapping.
	const FpSlot *slot = find_slot(mOverlaySlots, mOverlayCapacity, fileKey);
	if(slot != nullptr)
		return slot;
	return find_slot(mSlots, mCapacity, fileKey);
}

bool
FingerprintStore::lookup(const FileInfo &info, uint64_t &outContentHash) const
{
	uint64_t key = file_key(info);
	if(key == 0)
		return false;

	const FpSlot *slot = find_known(key);
	if(slot == nullptr)
		return false;

	// Each file occupies exactly one slot in whichever table answered, so a key match
	// that fails the stat check is a miss, not a reason to keep probing.
	if(slot->statTag != stat_tag(info))
		return false;

	outContentHash = slot->contentHash;
	mHits.fetch_add(1, std::memory_order_relaxed);
	return true;
}

bool
FingerprintStore::matches_known(uint64_t fileKey, uint64_t statTag, uint64_t contentHash) const
{
	const FpSlot *slot = find_known(fileKey);
	return (slot != nullptr) && (slot->statTag == statTag) && (slot->contentHash == contentHash);
}

void
FingerprintStore::record(const FileInfo &info, uint64_t contentHash)
{
	uint64_t key = file_key(info);
	if(key == 0)
		return;

	uint64_t tag = stat_tag(info);

	mStores.fetch_add(1, std::memory_order_relaxed);

	// One extra probe per file, skipped entirely once anything has already changed.
	// It is what makes save() free in the steady state: a run whose every record already
	// sits on disk writes nothing at all, not even a journal batch, which is the case that
	// matters most. The journal counts as "already stored" here for exactly that reason -
	// a file changed two runs ago and unchanged since must not re-append every run.
	if(!mDirty.load(std::memory_order_relaxed) && !matches_known(key, tag, contentHash))
		mDirty.store(true, std::memory_order_relaxed);

	Shard &shard = mShards[key & (kShardCount - 1)];
	try
	{
		std::lock_guard<std::mutex> guard(shard.mutex);
		shard.records.push_back(PendingRecord{key, tag, contentHash});
	}
	catch(...)
	{
		// This runs inside a taskBlock on a GCD queue, where an escaping exception is
		// std::terminate. Losing one record costs one re-hash on the next run, which is
		// what every other failure in this module costs; taking the build down for it
		// would not be. save() is guarded for the same reason.
	}
}

size_t
FingerprintStore::hit_count() const
{
	return mHits.load(std::memory_order_relaxed);
}

size_t
FingerprintStore::computed_count() const
{
	// record() is called exactly once per file looked at, hit or miss, so whatever was
	// not a hit had its hash computed. Saturating rather than wrapping, in case a caller
	// ever records without looking up.
	size_t stores = mStores.load(std::memory_order_relaxed);
	size_t hits = mHits.load(std::memory_order_relaxed);
	return (stores > hits) ? (stores - hits) : 0;
}

void
FingerprintStore::save()
{
	// Called after the whole build has already succeeded. Sorting, merging and building
	// the image all allocate, and an escaping bad_alloc here would terminate the process
	// after the work it was protecting is done. Losing the memo costs a re-hash.
	try
	{
		save_internal();
	}
	catch(...)
	{
		report(mVerbose, "could not save store", mPath);
	}
}

void
FingerprintStore::save_internal()
{
	if(!mDirty.load(std::memory_order_relaxed))
		return; // steady state: everything this run saw is already stored

	if(!posix_mkdir_p(mCacheDir))
	{
		report(mVerbose, "cannot create cache directory for store", mCacheDir);
		return;
	}

	// A dedicated lock file, and one that is never renamed or removed: the store inode
	// is replaced by the rename below, so a lock held on the store itself would stop
	// excluding anyone the moment the first writer finished. Independent of the
	// manifest's lock, so two playlists sharing a cache directory do not serialize on
	// both. O_CLOEXEC keeps the descriptor out of [execute] children, which would hold
	// the lock past our own close. O_NOFOLLOW because a shared cache directory is an
	// advertised use case, and without it another user can plant this name as a symlink
	// and have us open a file of their choosing for writing.
	std::string lockPath = mPath + ".lock";
	int lockFd = open(lockPath.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0644);
	if(lockFd < 0)
	{
		report(mVerbose, "cannot open store lock file", lockPath);
		return;
	}
	// Everything from here to the unlock allocates. Releasing by scope exit rather than
	// by code path means an escaping exception cannot leave the exclusive lock held
	// until process exit and wedge every concurrent replay on this store.
	struct LockGuard
	{
		int fd;
		~LockGuard()
		{
			flock(fd, LOCK_UN);
			close(fd);
		}
	} lockGuard{lockFd};

	int lockResult;
	while(((lockResult = flock(lockFd, LOCK_EX)) != 0) && (errno == EINTR))
		{ /* a signal interrupted the wait: keep waiting rather than writing unlocked */ }
	if(lockResult != 0)
	{
		// ENOLCK, or a filesystem that does not implement flock - realistic on the
		// network and FUSE mounts where a shared cache directory is the whole point.
		// Writing anyway would reintroduce the lost update the lock exists to prevent.
		report(mVerbose, "cannot lock store", lockPath);
		return;
	}

	// Re-read under the lock. Another process may have published since we mapped ours,
	// and merging into that is what keeps two concurrent playlists from each dropping
	// the other's entries.
	MappedStore fresh;
	map_and_validate(mPath, mAlgorithmTag, mHostUuid, mVerbose, fresh);

	// Collapse duplicates so the table is sized from the number of files, not from the
	// number of (task, file) pairs - a header included by a thousand tasks would
	// otherwise inflate the store a thousandfold. Independent per shard, so it fans out.
	// A file always lands in the same shard (the shard is chosen from its key), so a
	// per-shard dedupe is a global one.
	//
	// From here to the end, the shard vectors are read and rewritten WITHOUT their
	// mutexes. That is not an oversight and the mutexes would not fix it: the dedupe
	// reorders and shrinks each vector while the merge loops below hold references into
	// it, so a record() landing anywhere in this window is a bug no lock can absorb.
	// The precondition is the one save() documents - called once, after the scheduler
	// has drained - and taking the locks here would only make concurrent recording look
	// supported.
	Shard *shards = mShards.get();
	dispatch_apply(kShardCount, DISPATCH_APPLY_AUTO, ^(size_t i) {
		dedupe_shard(shards[i].records);
	});

	uint64_t uniqueRecords = 0;
	for(size_t i = 0; i < kShardCount; ++i)
		uniqueRecords += shards[i].records.size();

	// The journal as it stands right now, which is not necessarily the one this process
	// loaded: another run may have appended to it, or replaced the table under it, since.
	// Paired with the image we just mapped, for the same reason Open pairs them.
	JournalContents journal;
	if(fresh.valid())
	{
		read_journal(mJournalPath, mAlgorithmTag, mHostUuid, fresh.runCounter, fresh.nonce,
			mVerbose, journal);
	}

	SlotIndex published;
	build_index(journal.slots, published);

	// Everything this run saw that the table plus its journal does not already agree with.
	// On an incremental run this is a handful of files out of thousands, and it is exactly
	// what the journal exists to write instead of the whole table.
	std::vector<FpSlot> newSlots;
	for(size_t i = 0; i < kShardCount; ++i)
	{
		for(const PendingRecord &pending : shards[i].records)
		{
			const FpSlot *known = find_slot(published.slots.data(), published.capacity, pending.fileKey);
			if(known == nullptr)
			{
				known = find_slot(fresh.valid() ? fresh.slots() : nullptr, fresh.capacity,
					pending.fileKey);
			}
			if((known != nullptr) && (known->statTag == pending.statTag) &&
			   (known->contentHash == pending.contentHash))
			{
				continue;
			}
			// Provisional epoch: the append path publishes it as-is, and the rewrite path
			// below restamps every record it writes with that rewrite's own run number.
			FpSlot slot;
			slot.fileKey = pending.fileKey;
			slot.statTag = pending.statTag;
			slot.contentHash = pending.contentHash;
			slot.epoch = (uint32_t)fresh.runCounter;
			slot.flags = 0;
			newSlots.push_back(slot);
		}
	}

	// Another process may have published everything we saw between our load and this lock,
	// which turns a dirty run back into a no-op.
	if(newSlots.empty() && !journal.needsReset)
	{
		mDirty.store(false, std::memory_order_relaxed);
		return;
	}

	// Append when the journal can absorb this run's changes; rewrite the table when it
	// cannot. The rewrite is what compacts - it folds the journal back in, applies
	// eviction and resizes - so the journal never has to hold more than a bounded delta.
	//
	// Both bounds are heuristics for WHEN to compact, never for correctness: the append
	// does not touch the table, and the rewrite sizes itself from what it actually merges.
	// fresh.count being the header's advisory value is therefore harmless here.
	//
	// A table with no nonce cannot carry a journal, and this is where that is enforced.
	// It was written before the field existed, so any batch naming it would have to claim
	// a nonce of 0 - which the reader rejects, by design, because 0 identifies no image.
	// Appending anyway would write a batch nothing will ever accept: the run's changed
	// files would be re-hashed and re-appended on every subsequent run, forever, and the
	// journal could never grow enough to trigger the compaction that would fix it.
	// Falling through to a rewrite instead costs one full write and mints a nonce, after
	// which the journal works normally.
	if(fresh.valid() && (fresh.nonce != 0))
	{
		uint64_t journalTotal = (uint64_t)journal.slots.size() + (uint64_t)newSlots.size();

		// How many of those would be NEW slots in the table rather than overwrites of one
		// it already has. The distinction is the whole point: a run that rewrote a
		// thousand existing files adds nothing to the table's occupancy, and counting
		// those as new made it compact - and then GROW - for a load it was never going to
		// carry. Measured on 20000 files, the naive count compacted at 4090 journal
		// entries against a budget of 8192 and doubled the table to 2 MB for 20001 entries.
		SlotIndex pending;
		{
			std::vector<FpSlot> combined = journal.slots;
			combined.insert(combined.end(), newSlots.begin(), newSlots.end());
			build_index(combined, pending);
		}
		uint64_t trulyNew = 0;
		for(const FpSlot &slot : pending.slots)
		{
			if(slot.fileKey == 0)
				continue;
			if(find_slot(fresh.slots(), fresh.capacity, slot.fileKey) == nullptr)
				++trulyNew;
		}

		// Entries, and separately bytes: the entry budget is a fraction of the table, and
		// for an enormous table that fraction can exceed what the reader is willing to
		// read back (kMaxJournalBytes). Appending past that would produce a journal the
		// next run resets wholesale, losing the records and re-hashing every time.
		uint64_t journalBytes = sizeof(FpJournalHeader) +
			(journalTotal * sizeof(FpSlot)) + sizeof(FpBatchHeader) + sizeof(FpBatchTrailer);
		bool fitsJournal = (journalTotal <= journal_budget(fresh.capacity)) &&
			(journalBytes <= kMaxJournalBytes);
		bool fitsTable = ((double)(fresh.count + trulyNew) <=
			((double)fresh.capacity * kMaxLoadFactor));
		if(fitsJournal && fitsTable)
		{
			// Nothing to write and nothing worth carrying: the journal is simply unusable,
			// and removing it is the entire repair. Falling through to a table rewrite
			// here would publish a fresh copy of bytes that are already correct.
			if(newSlots.empty() && journal.slots.empty())
			{
				unlink(mJournalPath.c_str());
				mDirty.store(false, std::memory_order_relaxed);
				return;
			}
			if(write_journal_batch(mJournalPath, mAlgorithmTag, mHostUuid, fresh.runCounter,
					fresh.nonce, journal.slots, newSlots, journal.needsReset, mVerbose))
			{
				if(mVerbose)
				{
					LogError("memo: appended %zu records to the journal\n",
						(size_t)newSlots.size());
				}
				// The overlay this object still holds is now a run out of date. Nothing
				// reads it again - save() is called once, at the end - and rebuilding it
				// would only serve a second save that has nothing left to publish.
				mDirty.store(false, std::memory_order_relaxed);
				return;
			}
			// The append failed and rolled itself back. Fall through and rewrite instead:
			// the table is the durable half, and it can always absorb what the journal
			// could not take.
		}
	}

	uint64_t oldRun = fresh.valid() ? fresh.runCounter : 0;
	bool keepSurvivors = fresh.valid();
	if(oldRun >= kMaxRunCounter)
	{
		// Four billion store-modifying runs. Unreachable, but wrapping the 32-bit epoch
		// would make every stored slot look infinitely fresh and eviction would stop
		// working, so restart the numbering and let this run's records be the store.
		oldRun = 0;
		keepSurvivors = false;
		// Their epochs belong to the numbering being abandoned, so they would never
		// age out again.
		journal.slots.clear();
	}
	uint64_t newRun = oldRun + 1;

	uint64_t survivorCandidates = 0;
	if(keepSurvivors)
	{
		const FpSlot *oldSlots = fresh.slots();
		for(uint64_t i = 0; i < fresh.capacity; ++i)
		{
			if(oldSlots[i].fileKey == 0)
				continue;
			// Promoted to 64 bits so a slot near the top of the epoch range cannot wrap
			// and look stale. A slot claiming an epoch in the future survives too, which
			// is the conservative direction.
			if(((uint64_t)oldSlots[i].epoch + kMaxIdleRuns) >= newRun)
				++survivorCandidates;
		}
	}

	// Journal records are recent by construction - they were written against the image we
	// just mapped - so the eviction filter never actually drops one. It is applied anyway
	// so that every path into the table agrees on what "too old to keep" means.
	uint64_t journalSurvivors = 0;
	for(const FpSlot &slot : journal.slots)
	{
		if(((uint64_t)slot.epoch + kMaxIdleRuns) >= newRun)
			++journalSurvivors;
	}

	// An upper bound is fine: survivors that this run also recorded are overwritten
	// rather than added, so the real count only comes out lower.
	uint64_t needed = uniqueRecords + survivorCandidates + journalSurvivors;
	uint64_t target = (uint64_t)((double)needed / kMaxLoadFactor) + 1;
	uint64_t capacity = kMinCapacity;
	while(capacity < target)
	{
		if(capacity >= kMaxCapacity)
		{
			report(mVerbose, "too many entries to store", mPath);
			return;
		}
		capacity <<= 1;
	}

	// Built in memory and written with write(), not built into a MAP_SHARED mapping of
	// the temp file. ftruncate does not reserve blocks, so a mapping of a sparse file
	// raises SIGBUS on first touch of a page the filesystem cannot back - a crash after
	// the build already succeeded. write() returns ENOSPC instead, and at the sizes
	// involved (0.5-4 MB for a normal project, 32 MB at the extreme) the copy costs a
	// few milliseconds off the critical path.
	size_t bodySize = sizeof(FpHeader) + (size_t)(capacity * sizeof(FpSlot));
	size_t fileSize = bodySize + sizeof(FpTrailer);
	std::vector<uint8_t> image(fileSize, 0); // zero-filled: an empty slot is all zeros

	FpHeader header;
	memset(&header, 0, sizeof(header));
	header.magic = kHeaderMagic;
	header.version = kFormatVersion;
	header.hashAlgo = mAlgorithmTag;
	header.capacity = capacity;
	header.runCounter = newRun;
	// A fresh identity for a fresh image, so that a journal describing the one being
	// replaced cannot be mistaken for a journal describing this one when the counters
	// happen to agree. arc4random needs no seeding and cannot fail; forcing it non-zero
	// keeps 0 meaning "written before this field existed".
	do
	{
		arc4random_buf(&header.nonce, sizeof(header.nonce));
	}
	while(header.nonce == 0);
	memcpy(header.hostUuid, mHostUuid, sizeof(header.hostUuid));

	FpSlot *slots = (FpSlot *)(image.data() + sizeof(FpHeader));
	uint64_t inserted = 0;

	// Oldest first: table survivors, then the journal that was written on top of them,
	// then this run's records. insert_slot overwrites on a key match, so each tier
	// supersedes the one before it and a file seen this run carries the new epoch.
	if(keepSurvivors)
	{
		const FpSlot *oldSlots = fresh.slots();
		for(uint64_t i = 0; i < fresh.capacity; ++i)
		{
			if(oldSlots[i].fileKey == 0)
				continue;
			if(((uint64_t)oldSlots[i].epoch + kMaxIdleRuns) < newRun)
				continue;
			if(insert_slot(slots, capacity, oldSlots[i]))
				++inserted;
		}
	}
	for(const FpSlot &slot : journal.slots)
	{
		if(((uint64_t)slot.epoch + kMaxIdleRuns) < newRun)
			continue;
		if(insert_slot(slots, capacity, slot))
			++inserted;
	}
	for(size_t i = 0; i < kShardCount; ++i)
	{
		for(const PendingRecord &pending : shards[i].records)
		{
			FpSlot slot;
			slot.fileKey = pending.fileKey;
			slot.statTag = pending.statTag;
			slot.contentHash = pending.contentHash;
			slot.epoch = (uint32_t)newRun;
			slot.flags = 0;
			if(insert_slot(slots, capacity, slot))
				++inserted;
		}
	}

	header.count = inserted;
	memcpy(image.data(), &header, sizeof(header));

	FpTrailer trailer;
	memset(&trailer, 0, sizeof(trailer));
	trailer.magic = kTrailerMagic;
	trailer.crc32c = crc32_impl(0, (const char *)image.data(), bodySize);
	memcpy(image.data() + bodySize, &trailer, sizeof(trailer));

	// The temp name carries the pid so two processes racing on this store cannot write
	// the same temp file and hand each other a half-written image. Claimed with
	// O_EXCL|O_NOFOLLOW so a name planted by another user in a shared cache directory
	// cannot redirect the write; the unlink first clears a stale temp left behind by a
	// crashed run that happened to have this pid.
	std::string tempPath = mPath + "." + std::to_string((long)getpid()) + ".tmp";
	unlink(tempPath.c_str());
	int tempFd = open(tempPath.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
	if(tempFd < 0)
	{
		report(mVerbose, "cannot create temporary store", tempPath);
		return;
	}

	const uint8_t *cursor = image.data();
	size_t remaining = image.size();
	bool written = true;
	while(remaining > 0)
	{
		ssize_t count = write(tempFd, cursor, remaining);
		if(count <= 0)
		{
			if((count < 0) && (errno == EINTR))
				continue;
			written = false;
			break;
		}
		cursor += count;
		remaining -= (size_t)count;
	}
	if(written)
	{
		// Continue the trailer's own checksum over the trailer bytes to get one over the
		// whole file. crc32_impl complements on entry and on exit, so passing a previous
		// result back in resumes exactly where it left off.
		mirror_checksum_xattr(tempFd,
			crc32_impl(trailer.crc32c, (const char *)(image.data() + bodySize), sizeof(FpTrailer)),
			tempPath, mVerbose);
	}
	close(tempFd);

	if(!written)
	{
		report(mVerbose, "cannot write temporary store", tempPath);
		unlink(tempPath.c_str());
		return;
	}

	// Atomic against concurrent readers: they see either the old inode or the new one,
	// never a partial file, and a reader holding a mapping of the old inode keeps a
	// valid mapping. Truncating in place instead would raise SIGBUS in that reader.
	//
	// Deliberately not durable - there is no fsync, the same policy the manifest uses.
	// A store torn by a crash fails its trailer checksum on the next run and is rebuilt.
	if(rename(tempPath.c_str(), mPath.c_str()) != 0)
	{
		report(mVerbose, "cannot replace store", mPath);
		// The rename can fail in ways that leave the temp intact (ENOSPC, EROFS, the
		// store path replaced by a directory); clean up or it stays there forever.
		unlink(tempPath.c_str());
		return;
	}

	// The journal described the image that was just replaced, and everything in it has
	// been folded into the new one. Clearing it AFTER the rename is deliberate: a crash in
	// between leaves records that are still true but belong to a superseded generation,
	// and the storeRun stamped in every batch is what makes the next reader drop them
	// instead of overlaying them on a table they were never written against.
	unlink(mJournalPath.c_str());

	if(mVerbose)
		LogError("memo: rewrote the store with %zu entries\n", (size_t)inserted);

	// Published. A second save() would only rewrite the same bytes.
	mDirty.store(false, std::memory_order_relaxed);

	// lockGuard releases the flock and closes the descriptor here.
}
