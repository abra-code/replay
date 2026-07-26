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

struct FpHeader
{
	uint64_t magic;
	uint32_t version;
	uint32_t hashAlgo;
	uint64_t capacity;   // cross-checked against the file size, never trusted for bounds
	uint64_t count;      // advisory only
	uint64_t runCounter; // bumped on each rewrite; drives eviction
	uint8_t hostUuid[16];
	uint8_t reserved[8];
};

struct FpSlot
{
	uint64_t fileKey;     // mix64(dev, inode); 0 means the slot is empty
	uint64_t statTag;     // mix64(size, mtime_ns, ctime_ns, file type)
	uint64_t contentHash; // crc32c zero-extended, or the low 64 bits of blake3
	uint32_t epoch;       // runCounter when this slot was last written
	uint32_t flags;       // reserved
};

struct FpTrailer
{
	uint64_t magic;
	uint32_t crc32c; // over bytes [0, fileSize - sizeof(FpTrailer))
	uint32_t reserved;
};

// The format is on disk the moment this ships, so pin it at compile time.
static_assert(sizeof(FpHeader) == 64, "FpHeader must stay 64 bytes");
static_assert(sizeof(FpSlot) == 32, "FpSlot must stay 32 bytes: two per cache line");
static_assert(sizeof(FpTrailer) == 16, "FpTrailer must stay 16 bytes");
static_assert(alignof(FpSlot) == 8, "FpSlot fields must stay naturally aligned");
static_assert((sizeof(FpHeader) % alignof(FpSlot)) == 0, "slots must start aligned");

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

	int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
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

const char *algorithm_name(uint32_t algorithmTag)
{
	return (algorithmTag == kAlgoBlake3) ? "blake3" : "crc32c";
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

FingerprintStore::FingerprintStore(std::string cacheDir, std::string path, uint32_t algorithmTag,
                                   const uint8_t *hostUuid, bool verbose)
	: mCacheDir(std::move(cacheDir))
	, mPath(std::move(path))
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
		std::string path = cacheDir;
		if(!path.empty() && (path.back() != '/'))
			path += '/';
		path += "fingerprints-";
		path += hostHex;
		path += '-';
		path += algorithm_name(algorithmTag);
		path += ".bin";

		store.reset(new FingerprintStore(cacheDir, std::move(path), algorithmTag, hostUuid, verbose));
	}
	catch(...)
	{
		return nullptr;
	}

	MappedStore mapped;
	map_and_validate(store->mPath, algorithmTag, hostUuid, verbose, mapped);
	if(mapped.valid())
	{
		store->mCapacity = mapped.capacity;
		store->mLoadedCount = (size_t)mapped.count;
		store->mSlots = mapped.slots();
		mapped.release(store->mFd, store->mMapBase, store->mMapSize);
	}
	return store;
}

bool
FingerprintStore::lookup(const FileInfo &info, uint64_t &outContentHash) const
{
	if(mSlots == nullptr)
		return false;

	uint64_t key = file_key(info);
	if(key == 0)
		return false;

	uint64_t tag = stat_tag(info);
	uint64_t mask = mCapacity - 1;
	uint64_t index = key & mask;
	for(uint64_t probe = 0; probe < mCapacity; ++probe)
	{
		const FpSlot &slot = mSlots[index];
		if(slot.fileKey == 0)
			return false; // an empty slot ends the probe run: the file is not stored
		if(slot.fileKey == key)
		{
			// Each file occupies exactly one slot (the merge overwrites rather than
			// appends), so a key match that fails the stat check is a miss, not a
			// reason to keep probing.
			if(slot.statTag != tag)
				return false;
			outContentHash = slot.contentHash;
			mHits.fetch_add(1, std::memory_order_relaxed);
			return true;
		}
		index = (index + 1) & mask;
	}
	return false;
}

bool
FingerprintStore::matches_loaded(uint64_t fileKey, uint64_t statTag, uint64_t contentHash) const
{
	if(mSlots == nullptr)
		return false;

	uint64_t mask = mCapacity - 1;
	uint64_t index = fileKey & mask;
	for(uint64_t probe = 0; probe < mCapacity; ++probe)
	{
		const FpSlot &slot = mSlots[index];
		if(slot.fileKey == 0)
			return false;
		if(slot.fileKey == fileKey)
			return (slot.statTag == statTag) && (slot.contentHash == contentHash);
		index = (index + 1) & mask;
	}
	return false;
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
	// It is what makes save() free in the steady state: a run whose every record
	// already sits in the store writes nothing at all, which is the case that matters
	// most - an incremental build that touched two files must not rewrite 32 MB.
	if(!mDirty.load(std::memory_order_relaxed) && !matches_loaded(key, tag, contentHash))
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

	uint64_t oldRun = fresh.valid() ? fresh.runCounter : 0;
	bool keepSurvivors = fresh.valid();
	if(oldRun >= kMaxRunCounter)
	{
		// Four billion store-modifying runs. Unreachable, but wrapping the 32-bit epoch
		// would make every stored slot look infinitely fresh and eviction would stop
		// working, so restart the numbering and let this run's records be the store.
		oldRun = 0;
		keepSurvivors = false;
	}
	uint64_t newRun = oldRun + 1;

	// Collapse duplicates so the table is sized from the number of files, not from the
	// number of (task, file) pairs - a header included by a thousand tasks would
	// otherwise inflate the store a thousandfold. Independent per shard, so it fans out.
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

	// An upper bound is fine: survivors that this run also recorded are overwritten
	// rather than added, so the real count only comes out lower.
	uint64_t needed = uniqueRecords + survivorCandidates;
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
	memcpy(header.hostUuid, mHostUuid, sizeof(header.hostUuid));

	FpSlot *slots = (FpSlot *)(image.data() + sizeof(FpHeader));
	uint64_t inserted = 0;

	// Survivors first, this run's records second, so a file seen this run overwrites its
	// older entry and carries the new epoch.
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

	// Published. A second save() would only rewrite the same bytes.
	mDirty.store(false, std::memory_order_relaxed);

	// lockGuard releases the flock and closes the descriptor here.
}
