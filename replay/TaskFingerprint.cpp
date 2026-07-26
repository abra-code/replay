#include "TaskFingerprint.h"

#include "FileSystemHelpers.h"
#include "PosixFileOps.h"
#include "GlobOverlap.h"

#include "FileHashing.h"
#include "FileInfo.h"
#include "blake3.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstring>
#include <set>
#include <unordered_set>
#include <utility>

// Globals required by FileHashing.h and by fingerprint.cpp (both declare them extern).
// Mirrors gate/main.cpp:37-40. Set from the command line before execution starts.
FileHashAlgorithm g_hash = FileHashAlgorithm::CRC32C;
XattrMode g_xattr_mode = XattrMode::On;
bool g_verbose = false;
double g_traversal_time = 0.0;

namespace
{

// Bound on symlink chain following, same spirit as the kernel's SYMLOOP_MAX.
constexpr int kMaxSymlinkHops = 32;

// Bound on collect_directory -> collect_symlink_target -> collect_directory nesting.
// visitedDirs already breaks cycles; this only keeps a pathological chain of distinct
// directories from running the thread's stack out.
constexpr int kMaxCollectDepth = 32;

struct HashedFile
{
	std::string path;
	FileInfo info;
};

// Collection state threaded through the whole rollup of one fingerprint_paths call.
struct CollectState
{
	std::vector<HashedFile> entries;

	// Directories already traversed, by (device, inode). Identity rather than spelling,
	// so a symlink pointing back at an ancestor terminates and two spellings of one
	// directory are not walked twice.
	std::set<std::pair<dev_t, ino_t>> visitedDirs;

	int depth = 0;

	// Set when any part of the tree could not be read: fts_open failed, or fts reported
	// an unreadable directory or a stat failure. Such a subtree contributes NOTHING to
	// the rollup, which is byte-for-byte what an ABSENT subtree contributes - so without
	// this flag "I could not look" and "it is gone" produce the same fingerprint, and a
	// deleted output whose parent is momentarily unreadable would hit. The whole rollup
	// degrades to nullopt instead, which can only cost an extra execution.
	bool failed = false;
};

// Appends every regular file, symlink and directory under a tree.
// Directories are recorded too (with a content-free marker, see hash_one_file) so that
// an empty directory is distinguishable from an absent one: without that, deleting an
// empty subdirectory of a declared output would leave the fingerprint unchanged and the
// producing task would be skipped forever.
// A subtree that cannot be read marks the rollup failed rather than being skipped:
// see CollectState::failed.
// followDirectoryTargets distinguishes the two ways a symlink can be reached.
// A symlink NAMED as a declared path is an explicit request: if it points at a
// directory, that whole directory is what the task declared, so it is traversed.
// A symlink DISCOVERED inside a traversal is not: following a directory target there
// would silently widen the declared world to an arbitrary tree the playlist never named.
// A single "link -> .." inside a declared directory pulls in its parent - which in a
// normal layout contains the cache directory the run is about to rewrite, so the task
// could never hit again - and "link -> /" would walk every mounted volume.
void collect_symlink_target(const std::string &linkPath, CollectState &state, bool followDirectoryTargets);

void collect_directory(const std::string &dirPath, CollectState &state)
{
	if(state.depth >= kMaxCollectDepth)
	{
		state.failed = true;
		return;
	}

	struct stat dirStat;
	if(lstat(dirPath.c_str(), &dirStat) != 0)
	{
		state.failed = true;
		return;
	}
	if(!state.visitedDirs.insert({dirStat.st_dev, dirStat.st_ino}).second)
		return; // already traversed under another name, or a symlink pointing back at an ancestor

	char *paths[2] = {const_cast<char *>(dirPath.c_str()), nullptr};
	// FTS_PHYSICAL fills fts_statp via lstat, which is exactly the metadata FileInfo needs.
	FTSPtr fts(fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, nullptr), fts_close);
	if(fts == nullptr)
	{
		state.failed = true;
		return;
	}

	// Symlinks are followed after the walk finishes, not during it: collect_symlink_target
	// can recurse into collect_directory, and starting a nested fts while this one is open
	// would multiply the descriptor pressure across a wide concurrent first wave.
	std::vector<std::string> symlinks;

	FTSENT *ent;
	while(true)
	{
		// fts_read returns NULL at the end of the traversal AND on error; only errno
		// separates them. Treating an aborted walk as a completed one would hand the
		// rollup a truncated entry list that hashes exactly like a smaller tree - the
		// wrong-skip shape this whole module exists to avoid. Clear errno each time so
		// a leftover value from the loop body cannot be mistaken for a walk failure.
		errno = 0;
		ent = fts_read(fts.get());
		if(ent == nullptr)
		{
			if(errno != 0)
				state.failed = true;
			break;
		}
		switch(ent->fts_info)
		{
			case FTS_D:
			case FTS_F:
			case FTS_SL:
			case FTS_SLNONE:
			{
				if(ent->fts_statp == nullptr)
				{
					state.failed = true;
					break;
				}
				std::string path(ent->fts_path, ent->fts_pathlen);
				if((ent->fts_info == FTS_SL) || (ent->fts_info == FTS_SLNONE))
					symlinks.push_back(path);
				state.entries.push_back({std::move(path), FileInfo(*ent->fts_statp)});
				break;
			}

			case FTS_DP:
				break; // post-order visit of a directory already recorded on the way down

			case FTS_DEFAULT:
				// fifo, socket, block/char device: has no content to hash and contributes
				// nothing, exactly as collect_concrete_path treats one named directly.
				// This is a normal tree member, NOT a read failure - degrading the rollup
				// here would make any playlist with a socket under a declared directory
				// permanently uncacheable.
			break;

			case FTS_DNR: // directory unreadable
			case FTS_NS:  // stat failed
			case FTS_ERR: // read error
			case FTS_DC:  // cycle (should not arise under FTS_PHYSICAL, but is not a clean read)
			default:
				state.failed = true;
			break;
		}
	}

	// A symlink INSIDE a declared directory must contribute its target's bytes: a task
	// that declares include/ and reads include/foo.h -> ../src/foo.h consumes src/foo.h,
	// so an edit there has to be visible. Recording only the link text made such an edit
	// a wrong skip. File targets only - see collect_symlink_target's declaration.
	++state.depth;
	for(const auto &linkPath : symlinks)
	{
		collect_symlink_target(linkPath, state, /*followDirectoryTargets=*/false);
	}
	--state.depth;
}

// Follows a symlink chain from an already-recorded link, appending every element and
// finally the target's content (traversing it when the target is a directory).
// A declared input that happens to be a symlink must reflect what the task actually
// consumed, which is the TARGET's bytes - hashing only the link text would make edits
// to the target invisible. Mirrors the engine's resolve_symlink_chain (fingerprint.cpp).
void collect_symlink_target(const std::string &linkPath, CollectState &state, bool followDirectoryTargets)
{
	std::string current = linkPath;
	std::unordered_set<std::string> visited;
	visited.insert(current);

	for(int hop = 0; hop < kMaxSymlinkHops; ++hop)
	{
		char buffer[PATH_MAX];
		ssize_t length = readlink(current.c_str(), buffer, sizeof(buffer) - 1);
		if(length <= 0)
		{
			// The caller has already established this is a symlink, so a failed readlink
			// is a read failure, not an absence - and an absence is what contributing
			// nothing would encode.
			state.failed = true;
			return;
		}
		buffer[length] = '\0';

		std::string target(buffer, (size_t)length);
		if(target.empty())
			return;
		if(target[0] != '/')
		{
			// Relative targets resolve against the link's own directory.
			auto slash = current.rfind('/');
			std::string base = (slash != std::string::npos) ? current.substr(0, slash) : std::string(".");
			target = base + "/" + target;
		}

		if(!visited.insert(target).second)
			return; // cycle

		struct stat st;
		if(lstat(target.c_str(), &st) != 0)
		{
			// ENOENT/ENOTDIR is a genuinely broken link: the target contributes nothing,
			// like any absent path. Anything else (EACCES on a parent, EIO, an unreachable
			// automount) means the target could not be looked at, and recording that as
			// absence would let an unread input compare equal to a deleted one.
			if((errno != ENOENT) && (errno != ENOTDIR))
				state.failed = true;
			return;
		}

		if(S_ISLNK(st.st_mode))
		{
			state.entries.push_back({target, FileInfo(st)});
			current = std::move(target);
			continue;
		}

		if(S_ISDIR(st.st_mode))
		{
			if(followDirectoryTargets)
				collect_directory(target, state);
			// Otherwise the link entry recorded by the caller is the whole contribution:
			// retargeting the link stays visible, and the tree behind it is left to
			// whatever declaration actually names it.
		}
		else if(S_ISREG(st.st_mode))
		{
			state.entries.push_back({target, FileInfo(st)});
		}
		return;
	}
}

// Collects one concrete (non-glob) path. Returns false when the path does not exist.
// Existing but non-regular entries (fifo, socket, device) contribute nothing.
bool collect_concrete_path(const std::string &path, CollectState &state)
{
	// Only ENOENT/ENOTDIR mean "not there". EACCES on a parent, ELOOP, EIO and
	// ENAMETOOLONG mean "could not look", and reporting those as absence would let a
	// path that exists contribute nothing - indistinguishable from a deleted one.
	struct stat st;
	if(lstat(path.c_str(), &st) != 0)
	{
		if((errno != ENOENT) && (errno != ENOTDIR))
			state.failed = true;
		return false;
	}

	if(S_ISDIR(st.st_mode))
	{
		collect_directory(path, state);
	}
	else if(S_ISLNK(st.st_mode))
	{
		// Record the link itself (so retargeting it is visible) AND what it points at.
		// Named explicitly, so a directory target IS the declared world and is traversed.
		state.entries.push_back({path, FileInfo(st)});
		collect_symlink_target(path, state, /*followDirectoryTargets=*/true);
	}
	else if(S_ISREG(st.st_mode))
	{
		state.entries.push_back({path, FileInfo(st)});
	}
	return true;
}

// Fills in info.hash for one file, honoring the xattr stat-cache mode.
// Identical policy to the engine's process_matched_file_async (fingerprint.cpp).
// Returns false when the file's content could not be read, so the caller can degrade the
// whole rollup rather than let an unreadable file contribute a 0 hash: the same file
// edited to the same size behind a persistent read failure would otherwise be invisible.
bool hash_one_file(HashedFile &entry)
{
	// A directory contributes its existence and nothing else: its content is the files
	// already collected under it, and its st_size is allocation noise, not content.
	if(entry.info.is_directory())
	{
		entry.info.size = 0;
		entry.info.hash.blake3 = 0;
		return true;
	}

	bool needsHash = true;
	bool writeXattr = false;

	if(g_xattr_mode == XattrMode::Clear)
	{
		clear_xattr_fileinfo(entry.path, entry.info);
	}
	else if(g_xattr_mode == XattrMode::On)
	{
		bool cacheHit = read_xattr_fileinfo(entry.path, entry.info);
		needsHash = !cacheHit;
		writeXattr = !cacheHit;
	}
	else if(g_xattr_mode == XattrMode::Refresh)
	{
		writeXattr = true;
	}

	bool hashed = true;
	if(needsHash)
	{
		hashed = compute_file_hash(entry.path, entry.info);
	}
	// Only memoize a hash that was really computed. Persisting the 0 left behind by a
	// failed read would make every later run hit that xattr record and reuse the 0
	// without reopening the file, until its size or mtime changes.
	if(writeXattr && hashed)
	{
		write_xattr_fileinfo(entry.path, entry.info);
	}
	return hashed;
}

void hash_update_u64_le(blake3_hasher &hasher, uint64_t value)
{
	uint8_t bytes[8];
	for(size_t i = 0; i < sizeof(bytes); ++i)
	{
		bytes[i] = (uint8_t)((value >> (8 * i)) & 0xFF);
	}
	blake3_hasher_update(&hasher, bytes, sizeof(bytes));
}

} // anonymous namespace

static std::optional<uint64_t>
fingerprint_paths_internal(const std::vector<std::string> &paths, bool requireConcreteFiles)
{
	CollectState state;
	state.entries.reserve(paths.size());

	for(const auto &path : paths)
	{
		if(path.empty())
		{
			// An input that expanded to nothing is a declaration error, not an absent file.
			if(requireConcreteFiles)
				return std::nullopt;
			continue;
		}

		// A literal path that exists always wins over glob interpretation. Filenames may
		// legitimately contain glob metacharacters (data[1].json), and treating such a
		// file as a pattern would silently match nothing AND bypass the missing-input
		// check, turning every later edit of that file into a wrong skip.
		if(collect_concrete_path(path, state))
			continue;

		if(globoverlap::is_glob_pattern(path))
		{
			// A glob matching nothing is not an error: it contributes nothing,
			// which is the same as all its matches being absent. A glob whose walk
			// FAILED is a different thing entirely and must degrade the rollup: an
			// unreadable directory shortens the match list, and a shortened list is
			// byte-for-byte what deleting those files produces. The fixed point of a
			// glob delete or move is precisely "matches nothing", so a transient
			// fts_open failure (EMFILE under a wide first wave) would otherwise
			// reproduce the stored value exactly and skip a task that must run.
			bool globFailed = false;
			std::vector<std::string> matches = expand_glob(path, &globFailed);
			if(globFailed)
			{
				state.failed = true;
				continue;
			}
			for(const auto &match : matches)
			{
				collect_concrete_path(match, state);
			}
		}
		else if(requireConcreteFiles)
		{
			return std::nullopt;
		}
	}

	// Deterministic order, and the same file reached through two declarations
	// must contribute only once.
	std::sort(state.entries.begin(), state.entries.end(),
		[](const HashedFile &a, const HashedFile &b) { return a.path < b.path; });
	auto last = std::unique(state.entries.begin(), state.entries.end(),
		[](const HashedFile &a, const HashedFile &b) { return a.path == b.path; });
	state.entries.erase(last, state.entries.end());

	for(auto &entry : state.entries)
	{
		if(!hash_one_file(entry))
			state.failed = true;
	}

	// Anything the rollup could not read makes the result unusable rather than merely
	// incomplete: an unread subtree and an absent one produce the same bytes, so a
	// partial rollup could match a stored value it does not actually describe.
	if(state.failed)
		return std::nullopt;

	blake3_hasher hasher;
	blake3_hasher_init(&hasher);

	for(const auto &entry : state.entries)
	{
		if(entry.info.is_nonexistent())
			continue;

		hash_update_u64_le(hasher, (uint64_t)entry.path.size());
		blake3_hasher_update(&hasher, entry.path.data(), entry.path.size());

		// Size and file type go in alongside the content hash. Without them a hash of 0
		// would conflate an empty file, an unreadable file and a directory, so a change
		// behind a permission failure would stay invisible forever, and replacing a
		// symlink with a regular file holding the link text would not register. Size is
		// content-derived, so byte-identical regenerated files still produce the same
		// record and downstream tasks still get the early cutoff of design 4.1.
		hash_update_u64_le(hasher, (uint64_t)entry.info.size);
		hash_update_u64_le(hasher, (uint64_t)(entry.info.mode & S_IFMT));

		if(g_hash == FileHashAlgorithm::CRC32C)
			blake3_hasher_update(&hasher, &entry.info.hash.crc32c, sizeof(entry.info.hash.crc32c));
		else
			blake3_hasher_update(&hasher, &entry.info.hash.blake3, sizeof(entry.info.hash.blake3));
	}

	uint8_t output[8] = {0};
	blake3_hasher_finalize(&hasher, output, sizeof(output));

	uint64_t result = 0;
	for(size_t i = 0; i < sizeof(output); ++i)
	{
		result |= ((uint64_t)output[i]) << (8 * i);
	}
	return result;
}

std::optional<uint64_t>
TaskFingerprint::fingerprint_paths(const std::vector<std::string> &paths, bool requireConcreteFiles)
{
	// This runs inside a taskBlock on a GCD queue, where an escaping exception would be
	// std::terminate. Glob compilation and vector growth can both throw, and a failed
	// fingerprint must never take the run down: report it as "unavailable" instead.
	try
	{
		return fingerprint_paths_internal(paths, requireConcreteFiles);
	}
	catch(...)
	{
		return std::nullopt;
	}
}

uint64_t
TaskFingerprint::combine_with_env(uint64_t fp, const std::string &envText)
{
	if(envText.empty())
		return fp;

	blake3_hasher hasher;
	blake3_hasher_init(&hasher);
	hash_update_u64_le(hasher, fp);
	blake3_hasher_update(&hasher, envText.data(), envText.size());

	uint8_t output[8] = {0};
	blake3_hasher_finalize(&hasher, output, sizeof(output));

	uint64_t combined = 0;
	for(size_t i = 0; i < sizeof(output); ++i)
	{
		combined |= ((uint64_t)output[i]) << (8 * i);
	}
	return combined;
}
