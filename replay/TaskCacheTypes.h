#pragma once
// Value types shared between the action layer (ReplayAction.h) and the cache
// module (TaskCache.h). Kept in their own header so ReplayAction.h does not have
// to include TaskCache.h, which needs ReplayContext and would close the cycle.

#include <atomic>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "fingerprint.h" // FileHashAlgorithm, XattrMode

enum class CacheFormat
{
	Json,
	Plist
};

// Where per-file content hashes are memoized between runs (--cache-memo).
// Both backends answer the same question - "have this file's bytes changed since the
// last run?" - but they trust different things, because one of them writes to the file
// it is memoizing and the other does not. See FingerprintStore.h.
enum class CacheMemo
{
	Sidecar, // a compact index in the cache directory; works on a read-only tree
	Xattr,   // the file's own public.fingerprint.* attribute, shared with gate/fingerprint
	Off      // no memoization: every declared file is re-read on every run
};

enum class CacheOutcome
{
	NotSeen,    // never dispatched (cycle, or short-circuited before the wrapper ran)
	Hit,        // up to date, skipped
	ExecutedOK, // ran and reported success
	Failed      // ran and reported failure
};

// Cache identity material contributed by one HandleActionStep branch.
// Default-constructed (cacheable == false) means "never cache this action".
struct ActionCacheInfo
{
	std::string extras;                 // action-specific identity beyond the path vectors
	bool cacheable = false;
	bool outputsExistenceOnly = false;  // create-directory: check existence + S_ISDIR, not content
	std::vector<std::string> envNames;  // per-step "env" names folded into the input fingerprint
};

// One cacheable task, owned by the run's CacheSession.
// Only the owning task writes checkedWorldIn and outcome, and only while it runs;
// finalize reads them after the scheduler has drained, so no lock is needed.
struct TaskCacheRecord
{
	std::string signature;
	std::string actionName;
	std::string playlistKey;
	std::vector<std::string> plainInputs;    // world_in material: inputs, concrete and glob
	std::vector<std::string> ownedPaths;     // world_out material: outputs + exclusive + mutating
	std::vector<std::string> concreteOutputs; // non-glob outputs, for the fast existence pass
	std::string envText;                     // NAME=value lines folded into world_in
	bool outputsExistenceOnly = false;

	// The FINAL world_in value, captured at CHECK time: the plain-input rollup with
	// envText ALREADY folded in via TaskFingerprint::combine_with_env. finalize stores
	// it verbatim, so the check side and the store side must fold exactly once, here.
	// nullopt means a declared concrete input was missing at check time; in that case
	// no entry is stored at all, because a value recomputed at end of run would describe
	// state the task never consumed and could produce a wrong skip (design 4.1).
	std::optional<uint64_t> checkedWorldIn;

	std::atomic<CacheOutcome> outcome{CacheOutcome::NotSeen};
};

// "crc32c" / "blake3" - the spelling persisted in the manifest and accepted by --cache-hash.
const char *CacheHashAlgorithmName(FileHashAlgorithm algorithm);
