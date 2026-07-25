#pragma once
// Synchronous, GCD-free fingerprinting of a task's declared paths.
//
// The fingerprint tool's engine (fingerprint/fingerprint.cpp) keeps static
// containers and drives its own GCD queues, so it cannot be called from replay's
// concurrently executing tasks: the wrapper runs on the scheduler's concurrent
// queue and the engine blocks in dispatch_group_wait waiting for workers from the
// same pool, which starves and eventually deadlocks under a wide first wave.
//
// This module therefore does all the work in-thread: path expansion, directory
// traversal, per-file hashing and the rollup. It shares only the stateless
// per-file pieces with the engine (FileHashing.h), so the "public.fingerprint.*"
// xattr stat-cache stays compatible with gate and fingerprint.
// All entry points are thread-safe and reentrant.

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "fingerprint.h" // FileHashAlgorithm, XattrMode

// Configuration globals required by FileHashing.h and fingerprint.cpp.
// Defined in TaskFingerprint.cpp; set once from the command line before the
// scheduler starts, read-only afterwards.
extern FileHashAlgorithm g_hash;
extern XattrMode g_xattr_mode;
extern bool g_verbose;
extern double g_traversal_time;

class TaskFingerprint
{
public:
	// Rolls the given paths up into a single 64-bit fingerprint.
	// Accepted path forms: concrete files, symlinks (both the link itself and its
	// resolved target contribute, so retargeting a link and editing its target are
	// each visible), directories (recursive, including empty ones), and glob patterns
	// such as dir/**/*.c (expanded here, matching nothing is not an error).
	// A literal path that exists is always treated as concrete, even when its name
	// contains glob metacharacters.
	// Paths that do not exist contribute nothing to the rollup, exactly as if
	// they had not been listed - that is what makes the move/delete fixed points
	// work. Presence still flips the fingerprint because a present file does contribute.
	// An empty FILE is recorded normally (size 0, hash 0) and stays distinct from an
	// absent one, which contributes nothing at all.
	// requireConcreteFiles: when true, a non-glob path that does not exist - or an empty
	// path string, which is an input that expanded to nothing - yields nullopt so the
	// caller can report "missing input" instead of a bogus fingerprint.
	// Returns nullopt when any part of the declared world could not be READ (unreadable
	// directory, stat or open failure, symlink nesting past the depth bound), regardless
	// of requireConcreteFiles: an unread subtree contributes exactly what an absent one
	// contributes, so a partial rollup could match a stored value it does not describe.
	// Never throws and never fails the run.
	static std::optional<uint64_t> fingerprint_paths(const std::vector<std::string> &paths, bool requireConcreteFiles);

	// Folds declared environment text into a file fingerprint.
	// Returns fp unchanged when envText is empty. Mirrors gate's combine_with_env.
	static uint64_t combine_with_env(uint64_t fp, const std::string &envText);
};
