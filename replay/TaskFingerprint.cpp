#include "TaskFingerprint.h"

#include "FileSystemHelpers.h"
#include "PosixFileOps.h"
#include "GlobOverlap.h"

#include "FileHashing.h"
#include "FileInfo.h"
#include "blake3.h"

#include <algorithm>
#include <climits>
#include <cstring>
#include <unordered_set>

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

struct HashedFile
{
	std::string path;
	FileInfo info;
};

// Appends every regular file, symlink and directory under a tree.
// Directories are recorded too (with a content-free marker, see hash_one_file) so that
// an empty directory is distinguishable from an absent one: without that, deleting an
// empty subdirectory of a declared output would leave the fingerprint unchanged and the
// producing task would be skipped forever.
// Unreadable subdirectories are skipped; traversal failures are not fatal.
void collect_directory(const std::string &dirPath, std::vector<HashedFile> &out)
{
	char *paths[2] = {const_cast<char *>(dirPath.c_str()), nullptr};
	// FTS_PHYSICAL fills fts_statp via lstat, which is exactly the metadata FileInfo needs.
	FTSPtr fts(fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, nullptr), fts_close);
	if(fts == nullptr)
		return;

	FTSENT *ent;
	while((ent = fts_read(fts.get())) != nullptr)
	{
		switch(ent->fts_info)
		{
			case FTS_D:
			case FTS_F:
			case FTS_SL:
			case FTS_SLNONE:
			{
				if(ent->fts_statp == nullptr)
					break;
				out.push_back({std::string(ent->fts_path, ent->fts_pathlen), FileInfo(*ent->fts_statp)});
				break;
			}
			default:
				break;
		}
	}
}

// Follows a symlink chain from an already-recorded link, appending every element and
// finally the target's content (traversing it when the target is a directory).
// A declared input that happens to be a symlink must reflect what the task actually
// consumed, which is the TARGET's bytes - hashing only the link text would make edits
// to the target invisible. Mirrors the engine's resolve_symlink_chain (fingerprint.cpp).
void collect_symlink_target(const std::string &linkPath, std::vector<HashedFile> &out)
{
	std::string current = linkPath;
	std::unordered_set<std::string> visited;
	visited.insert(current);

	for(int hop = 0; hop < kMaxSymlinkHops; ++hop)
	{
		char buffer[PATH_MAX];
		ssize_t length = readlink(current.c_str(), buffer, sizeof(buffer) - 1);
		if(length <= 0)
			return;
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
			return; // broken link: the target contributes nothing, like any absent path

		if(S_ISLNK(st.st_mode))
		{
			out.push_back({target, FileInfo(st)});
			current = std::move(target);
			continue;
		}

		if(S_ISDIR(st.st_mode))
			collect_directory(target, out);
		else if(S_ISREG(st.st_mode))
			out.push_back({target, FileInfo(st)});
		return;
	}
}

// Collects one concrete (non-glob) path. Returns false when the path does not exist.
// Existing but non-regular entries (fifo, socket, device) contribute nothing.
bool collect_concrete_path(const std::string &path, std::vector<HashedFile> &out)
{
	struct stat st;
	if(lstat(path.c_str(), &st) != 0)
		return false;

	if(S_ISDIR(st.st_mode))
	{
		collect_directory(path, out);
	}
	else if(S_ISLNK(st.st_mode))
	{
		// Record the link itself (so retargeting it is visible) AND what it points at.
		out.push_back({path, FileInfo(st)});
		collect_symlink_target(path, out);
	}
	else if(S_ISREG(st.st_mode))
	{
		out.push_back({path, FileInfo(st)});
	}
	return true;
}

// Fills in info.hash for one file, honoring the xattr stat-cache mode.
// Identical policy to the engine's process_matched_file_async (fingerprint.cpp).
void hash_one_file(HashedFile &entry)
{
	// A directory contributes its existence and nothing else: its content is the files
	// already collected under it, and its st_size is allocation noise, not content.
	if(entry.info.is_directory())
	{
		entry.info.size = 0;
		entry.info.hash.blake3 = 0;
		return;
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

	if(needsHash)
	{
		compute_file_hash(entry.path, entry.info);
	}
	if(writeXattr)
	{
		write_xattr_fileinfo(entry.path, entry.info);
	}
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
	std::vector<HashedFile> entries;
	entries.reserve(paths.size());

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
		if(collect_concrete_path(path, entries))
			continue;

		if(globoverlap::is_glob_pattern(path))
		{
			// A glob matching nothing is not an error: it contributes nothing,
			// which is the same as all its matches being absent.
			for(const auto &match : expand_glob(path))
			{
				collect_concrete_path(match, entries);
			}
		}
		else if(requireConcreteFiles)
		{
			return std::nullopt;
		}
	}

	// Deterministic order, and the same file reached through two declarations
	// must contribute only once.
	std::sort(entries.begin(), entries.end(),
		[](const HashedFile &a, const HashedFile &b) { return a.path < b.path; });
	auto last = std::unique(entries.begin(), entries.end(),
		[](const HashedFile &a, const HashedFile &b) { return a.path == b.path; });
	entries.erase(last, entries.end());

	for(auto &entry : entries)
	{
		hash_one_file(entry);
	}

	blake3_hasher hasher;
	blake3_hasher_init(&hasher);

	for(const auto &entry : entries)
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
