#pragma once
// Per-playlist incremental execution cache: task signatures and the run manifest.
// See private/replay_caching_design.md sections 4.4 and 4.5.

#include "TaskCacheTypes.h"
#include "ReplayAction.h"

#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Rolls up a task's owned paths (outputs + exclusive + mutating inputs) into the
// world_out value. Shared by the check side and the store side so the two can never
// disagree. outputsExistenceOnly (create-directory) compares a constant marker plus
// existence and S_ISDIR instead of directory content, because other tasks legitimately
// write into that directory afterwards (design 4.6).
uint64_t compute_world_out(const std::vector<std::string> &ownedPaths, bool outputsExistenceOnly);

// Content-based cache key for one task, stable across runs and execution modes.
// blake3 over domain-tagged, length-prefixed fields; 16 lowercase hex chars.
// Paths must be passed expanded and in their original case (NOT the lowercased
// FileTree copies) so the signature stays independent of dependency analysis.
std::string compute_task_signature(const std::string &actionName,
                                   const std::vector<std::string> &inputs,
                                   const std::vector<std::string> &exclusiveInputs,
                                   const std::vector<std::string> &mutatingInputs,
                                   const std::vector<std::string> &outputs,
                                   const std::string &extras,
                                   const std::vector<std::string> &envNames,
                                   const std::string &playlistKey);

// The environment text folded into world_in: one "NAME=value\n" line per declared
// variable, global --cache-env names first and per-step names second, each group
// sorted by name (design 4.5). Names must have been validated to exist; a missing
// one contributes an empty value rather than failing here.
std::string build_cache_env_text(const std::vector<std::string> &globalNames,
                                 const std::vector<std::string> &stepNames,
                                 const std::unordered_map<std::string, std::string> &environment);

// Turns a bool action into the void block the execution engines run. When
// context->cacheSession is set and the action is cacheable, this computes the
// signature, creates the session record and returns the up-to-date-check wrapper;
// otherwise it returns a trivial adapter that just drops the bool. Shared by the
// dependency-analysis task builder and serial dispatch so both engines cache
// through identical logic. Must be called on the graph-building thread.
std::function<void()> WrapActionWithCache(std::function<bool()> action,
                                          const std::string &actionName,
                                          const std::vector<std::string> &inputs,
                                          const std::vector<std::string> &mutatingInputs,
                                          const std::vector<std::string> &exclusiveInputs,
                                          const std::vector<std::string> &outputs,
                                          const ActionCacheInfo &cacheInfo,
                                          ReplayContext *context);

// One manifest entry as loaded from disk.
struct StoredCacheEntry
{
	std::string actionName;
	std::string playlistKey;
	uint64_t worldIn = 0;
	uint64_t worldOut = 0;
	std::string timestamp;
};

// Run-scoped owner of the manifest and of every TaskCacheRecord.
// Lives for the duration of one playlist (one --playlist-key) execution.
class CacheSession
{
public:
	// playlistPath must already be resolved to an absolute path; it keys the manifest file.
	// playlistKey is empty for root-array playlists.
	CacheSession(std::string playlistPath, std::string playlistKey, ReplayContext *context);

	CacheSession(const CacheSession &) = delete;
	CacheSession &operator=(const CacheSession &) = delete;

	// Reads the manifest if present. A manifest that is absent, empty, unparseable,
	// of a different version, written with a different hash algorithm, or belonging to
	// another playlist is silently treated as empty - it is disposable state and the
	// worst case is a full re-execution, so none of those is an error.
	void load();

	// Call with false when the graph build did not see every step of the playlist
	// (--stop-on-error truncating it, for instance). Pruning is then skipped, because
	// an unseen step is not the same as a removed one.
	void set_prune_allowed(bool allowed) { mPruneAllowed = allowed; }

	// Borrowed pointer into the loaded entries, or nullptr when the task is new.
	// Valid until finalize_and_save(); the loaded map is immutable after load().
	const StoredCacheEntry *lookup(const std::string &signature) const;

	// Creates a record owned by this session. Returns a stable pointer (deque-backed).
	// Thread-safe: taskBlock construction happens on the graph-building thread today,
	// but the mutex keeps this safe if that ever changes.
	TaskCacheRecord *make_record(std::string signature,
	                             std::string actionName,
	                             std::vector<std::string> plainInputs,
	                             std::vector<std::string> ownedPaths,
	                             std::vector<std::string> concreteOutputs,
	                             std::string envText,
	                             bool outputsExistenceOnly);

	// Executes one cacheable task through the up-to-date check (design 4.6): when
	// the stored entry still matches both the consumed inputs and the owned paths,
	// the task is skipped as a hit; otherwise inner runs and its result is recorded
	// for finalize_and_save. world_in is captured here, at check time, even for new
	// tasks and under --cache-refresh, because it becomes the stored value.
	// Thread-safe: called concurrently from scheduler tasks; record must have been
	// returned by make_record on this session.
	void run_task(TaskCacheRecord *record, const std::function<bool()> &inner);

	// Call once after the scheduler has drained. Captures end-of-run world_out for
	// every task that executed successfully, carries entries forward per the outcome
	// matrix (design 4.5 step 3), prunes stale entries for this playlist key, and
	// writes the manifest atomically. Also prints the end-of-run summary line.
	void finalize_and_save();

	const std::string &manifest_path() const { return mManifestPath; }
	size_t loaded_entry_count() const { return mLoadedEntries.size(); }

private:
	bool write_manifest(const std::unordered_map<std::string, StoredCacheEntry> &entries) const;

	std::string mPlaylistPath;
	std::string mPlaylistKey;
	ReplayContext *mContext = nullptr;
	std::string mManifestPath;
	bool mPruneAllowed = true;

	std::unordered_map<std::string, StoredCacheEntry> mLoadedEntries;

	std::mutex mRecordsMutex;
	std::deque<TaskCacheRecord> mRecords; // deque: push_back keeps existing pointers stable
};
