#pragma once
// Sidecar memoization of per-file content hashes, for the incremental execution cache.
// See private/fingerprint_store_plan.md.
//
// The xattr memoization (FileHashing.h, shared with the gate and fingerprint tools) keeps
// a file's {inode, size, mtime, hash} record in the file's own extended attributes. That
// is elegant - the record travels with the inode - but it needs the file to be writable,
// which a sandboxed build of a read-only source tree is not, and it costs a getxattr
// syscall per file (~13 us warm, against 1.4 us for the lstat that precedes it).
//
// This module keeps the same records in one mmap'd open-addressed table under the cache
// directory instead. Nothing is written to the inputs, so a read-only tree memoizes
// normally, and a probe is a couple of cache misses rather than a syscall. Measured on a
// 200k-entry table: 0.86 ms to open and map, ~0.01 us per probe.
//
// Two consequences of moving the record off the file:
//   - The key has to carry st_dev as well as st_ino, because inode numbers are only
//     unique within a device and the record no longer lives on the device.
//   - The store is machine-local (inode numbers are), while the manifest it sits beside
//     is shareable. The host UUID is in both the file name and the header, so a cache
//     directory on a shared mount just accumulates one store per machine.
//
// It also lets the validation tuple include st_ctime, which the xattr backend cannot
// afford: setxattr bumps ctime itself, so a ctime-validating xattr record would
// invalidate itself on every write. Including it closes the "touch -r restores mtime"
// wrong-skip hole, because utimes() is an inode metadata change and POSIX requires it
// to move ctime.
//
// Every entry point is thread-safe. lookup() is lock-free (it only reads the mapping);
// record() shards its writes; save() is called once, after the scheduler has drained.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "fingerprint.h" // FileHashAlgorithm, and the forward declaration of FileInfo

namespace fpstore
{
	struct FpSlot; // on-disk slot; the layout lives in FingerprintStore.cpp
}

class FingerprintStore
{
public:
	// Opens the store for one cache directory and one hash algorithm.
	//
	// Never fails because of the file: absent, unreadable, truncated, wrong magic,
	// version, algorithm or host, or a checksum mismatch all yield an empty but fully
	// usable store, which is the manifest's disposable-state policy. A store that could
	// not be read is rebuilt wholesale by the next save(); it is never unlinked, so a
	// transient read error on a network mount does not destroy good data.
	//
	// Returns nullptr only when the caller passed an algorithm that is neither CRC32C
	// nor BLAKE3, or when the object itself could not be allocated. Reasons are reported
	// once, and only under verbose.
	static std::unique_ptr<FingerprintStore> Open(const std::string &cacheDir,
	                                              FileHashAlgorithm algorithm,
	                                              bool verbose);

	~FingerprintStore();

	FingerprintStore(const FingerprintStore &) = delete;
	FingerprintStore &operator=(const FingerprintStore &) = delete;

	// Hot path, lock-free, called from every scheduler thread.
	// info must carry dev, inode, size, mtime_ns, ctime_ns and mode from a fresh lstat.
	// Returns true and fills outContentHash when a record for this inode is present AND
	// its size, mtime, ctime and file type all still match - which is exactly the
	// condition under which the file's bytes cannot have changed.
	bool lookup(const FileInfo &info, uint64_t &outContentHash) const;

	// Records what this run knows about one file. Call for EVERY file looked up, hit or
	// miss: a run that only recorded its misses would let every unchanged file's entry
	// age out and be evicted in one go, and re-hashing a whole tree at once is precisely
	// what this store exists to avoid. Recording hits keeps the epochs exact and makes
	// the merge one uniform pass.
	//
	// contentHash must be a hash that was really computed (or really memoized): storing
	// the 0 left behind by a failed read would pin the file's recorded content at 0 for
	// every later run, the same rule FileHashing.h states for the xattr backend.
	//
	// Thread-safe (sharded). Duplicate records for one file need no special handling -
	// several tasks fingerprinting a shared header produce identical records, and if the
	// file genuinely changed mid-run then either observed {stat, hash} pair is safe,
	// because both were observed together.
	void record(const FileInfo &info, uint64_t contentHash);

	// Merges this run's records with the surviving entries of the store on disk and
	// publishes the result atomically (temp + rename, never an in-place truncation).
	// A no-op when nothing this run recorded differs from what was already stored, so a
	// fully cached incremental run writes zero bytes.
	//
	// Call once, after the scheduler has drained and after any end-of-run fingerprinting
	// has finished. Never throws and never fails the run: losing the memo costs a re-hash.
	void save();

	// Entries in the store as loaded. Advisory - it is the header's own count, which is
	// never used for bounds.
	size_t loaded_entry_count() const { return mLoadedCount; }

	// Counted per lookup, not per file: a header fingerprinted by twenty tasks counts
	// twenty hits, because that is twenty file reads (or getxattr calls) not made.
	size_t hit_count() const;

	// Files whose hash this run had to compute: every record() that was not preceded by
	// a successful lookup(). Under --cache-memo-refresh, that is all of them.
	size_t computed_count() const;

	const std::string &path() const { return mPath; }

private:
	FingerprintStore(std::string cacheDir, std::string path, uint32_t algorithmTag,
	                 const uint8_t *hostUuid, bool verbose);

	// The body of save(), which only adds the exception guard around it.
	void save_internal();

	// True when the loaded mapping already holds exactly this record. Drives mDirty, so
	// that a run which changed nothing can skip the rewrite entirely.
	bool matches_loaded(uint64_t fileKey, uint64_t statTag, uint64_t contentHash) const;

	struct Shard;

	std::string mCacheDir;
	std::string mPath;
	uint32_t mAlgorithmTag = 0;
	uint8_t mHostUuid[16] = {0};
	bool mVerbose = false;

	// The loaded mapping. mSlots is null when there is no valid store on disk, which is
	// the normal cold case and not an error.
	int mFd = -1;
	void *mMapBase = nullptr;
	size_t mMapSize = 0;
	const fpstore::FpSlot *mSlots = nullptr;
	uint64_t mCapacity = 0; // derived from the file size, never taken from the header
	size_t mLoadedCount = 0;
	// Deliberately no cached run counter: save() re-reads the store under its lock and
	// takes the counter from THAT, because another process may have published since.

	std::unique_ptr<Shard[]> mShards;

	mutable std::atomic<size_t> mHits{0};
	std::atomic<size_t> mStores{0};
	std::atomic<bool> mDirty{false};
};
