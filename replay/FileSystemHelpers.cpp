#include "FileSystemHelpers.h"
#include "GlobOverlap.h"
#include "GlobSearch.h"
#include <dirent.h>
#include <fts.h>
#include <sys/stat.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <set>
#include <unordered_map>
#include <unordered_set>

static bool entry_is_directory(const char *parentPath, const char *name, unsigned char dtype)
{
	if (dtype == DT_DIR)
		return true;
	if (dtype == DT_REG || dtype == DT_FIFO || dtype == DT_CHR || dtype == DT_BLK || dtype == DT_SOCK)
		return false;
	// DT_LNK, DT_UNKNOWN: fall back to stat to resolve symlinks and unknown types
	std::string full = std::string(parentPath) + "/" + name;
	struct stat st;
	if (stat(full.c_str(), &st) == 0)
		return S_ISDIR(st.st_mode);
	return false;
}

bool list_directory(const char *path, std::vector<DirEntry> &out_entries)
{
	DIR *dir = opendir(path);
	if (dir == nullptr)
		return false;

	struct dirent *ent;
	while ((ent = readdir(dir)) != nullptr)
	{
		if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
			continue;
		bool isDir = entry_is_directory(path, ent->d_name, ent->d_type);
		out_entries.push_back({ent->d_name, isDir});
	}
	closedir(dir);

	std::sort(out_entries.begin(), out_entries.end(),
		[](const DirEntry &a, const DirEntry &b) { return a.name < b.name; });
	return true;
}

static int fts_name_compar(const FTSENT **a, const FTSENT **b)
{
	return strcmp((*a)->fts_name, (*b)->fts_name);
}

bool build_directory_tree(const char *path, TreeNode &out_root, int maxDepth)
{
	// Derive root display name from last path component
	std::string pathStr(path);
	size_t lastSlash = pathStr.rfind('/');
	out_root.name = (lastSlash != std::string::npos && lastSlash + 1 < pathStr.size())
	                ? pathStr.substr(lastSlash + 1)
	                : pathStr;
	out_root.isDirectory = true;

	// fts_open succeeds even for nonexistent paths; verify the root exists first.
	struct stat st;
	if (stat(path, &st) != 0)
		return false;
	if (S_ISDIR(st.st_mode) == 0)
	{
		errno = ENOTDIR;
		return false;
	}

	char *paths[2] = { const_cast<char *>(path), nullptr };
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, fts_name_compar);
	if (fts == nullptr)
		return false;

	// Index by fts_level: levelToNode[L] owns entries whose fts_level == L+1.
	// fts_level 0 = root dir, 1 = immediate children, etc.
	// We overwrite levelToNode[L] on each FTS_D at level L — safe because fts
	// is depth-first and finishes a subtree before visiting the next sibling.
	// This avoids push/pop entirely, sidestepping the question of whether
	// fts_set(FTS_SKIP) produces FTS_DP or not.
	std::vector<TreeNode *> levelToNode;

	FTSENT *ent;
	while ((ent = fts_read(fts)) != nullptr)
	{
		int lvl = ent->fts_level;

		switch (ent->fts_info)
		{
			case FTS_D:
			{
				if (lvl == 0)
				{
					// Root dir itself. maxDepth == 0: root only; maxDepth < 0: unlimited.
					if (maxDepth == 0)
					{
						fts_set(fts, ent, FTS_SKIP);
						break;
					}
					if ((int)levelToNode.size() < 1)
						levelToNode.resize(1);
					levelToNode[0] = &out_root;
				}
				else
				{
					// lvl >= 1: parent is levelToNode[lvl - 1]
					if (lvl - 1 >= (int)levelToNode.size())
						break;
					TreeNode *parent = levelToNode[lvl - 1];
					if (parent == nullptr)
						break;
					parent->children.push_back({ent->fts_name, true, {}});
					bool descend = (maxDepth < 0) || (lvl < maxDepth);
					if (descend)
					{
						if ((int)levelToNode.size() <= lvl)
							levelToNode.resize(lvl + 1);
						levelToNode[lvl] = &parent->children.back();
					}
					else
					{
						fts_set(fts, ent, FTS_SKIP);
					}
				}
				break;
			}
			case FTS_DP:
				// Nothing to do — we index by level, not a stack.
				break;

			case FTS_F:
			case FTS_SL:
			case FTS_SLNONE:
			{
				// Parent is at level lvl-1
				if (lvl - 1 >= 0 && lvl - 1 < (int)levelToNode.size())
				{
					TreeNode *parent = levelToNode[lvl - 1];
					if (parent != nullptr)
						parent->children.push_back({ent->fts_name, false, {}});
				}
				break;
			}
			case FTS_ERR:
			case FTS_DNR:
				break;

			default:
				break;
		}
	}

	fts_close(fts);
	return true;
}

// ============================================================================
// Glob expansion
// ============================================================================

std::vector<std::string> expand_glob(const std::string &pattern)
{
	std::vector<std::string> results;

	std::string base_dir = globoverlap::glob_concrete_prefix(pattern);
	std::string glob_suffix;
	if (base_dir.empty())
	{
		base_dir = ".";
		glob_suffix = pattern;
	}
	else
	{
		glob_suffix = pattern.substr(base_dir.size());
		if (!glob_suffix.empty() && glob_suffix[0] == '/')
			glob_suffix = glob_suffix.substr(1);
	}

	if (glob_suffix.empty()) {
		struct stat st;
		if (stat(pattern.c_str(), &st) == 0)
			results.push_back(pattern);
		return results;
	}

	std::string lowercase_suffix = glob_suffix;
	std::transform(lowercase_suffix.begin(), lowercase_suffix.end(),
				   lowercase_suffix.begin(), ::tolower);
	glob::glob compiled_glob(lowercase_suffix);

	char *paths[2] = { const_cast<char *>(base_dir.c_str()), nullptr };
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, nullptr);
	if (fts == nullptr)
		return results;

	FTSENT *ent;
	while ((ent = fts_read(fts)) != nullptr) {
		switch (ent->fts_info) {
			case FTS_F:
			case FTS_SL:
			case FTS_SLNONE: {
				const char *rel = ent->fts_path + base_dir.size();
				if (*rel == '/')
					++rel;

				std::string lowercase_rel(rel);
				std::transform(lowercase_rel.begin(), lowercase_rel.end(),
							   lowercase_rel.begin(), ::tolower);

				if (glob_match(lowercase_rel, compiled_glob))
					results.emplace_back(ent->fts_path);
				break;
			}
			case FTS_ERR:
			case FTS_DNR:
				break;
			default:
				break;
		}
	}

	fts_close(fts);
	return results;
}

std::vector<std::string> search_files(
	const std::vector<std::string> &patterns,
	const std::vector<std::string> &exclude_patterns,
	size_t max_results)
{
	// Group glob patterns by their concrete base directory so each directory
	// is walked at most once, regardless of how many patterns share it.
	std::unordered_map<std::string, std::unordered_set<std::string>> dir_to_globs;
	std::vector<std::string> exact_paths;

	for (const auto &pattern : patterns)
	{
		std::string base = globoverlap::glob_concrete_prefix(pattern);
		std::string suffix;
		if (base.empty())
		{
			base = ".";
			suffix = pattern;
		}
		else
		{
			suffix = pattern.substr(base.size());
			if (!suffix.empty() && suffix[0] == '/')
				suffix = suffix.substr(1);
		}

		if (suffix.empty())
		{
			// No glob metacharacters — literal path. Record for direct existence check.
			exact_paths.push_back(std::move(base));
		}
		else
		{
			dir_to_globs[std::move(base)].insert(std::move(suffix));
		}
	}

	std::unordered_set<std::string> excl_set(exclude_patterns.begin(), exclude_patterns.end());
	CompiledExcludes compiled_excl = compile_excludes(excl_set);

	std::set<std::string> seen;

	// Exact paths: existence check only, no filesystem walk needed.
	for (const auto &path : exact_paths)
	{
		if (max_results > 0 && seen.size() >= max_results)
			break;
		if (is_path_excluded(path.c_str(), compiled_excl)) continue;
		struct stat st;
		if (stat(path.c_str(), &st) == 0 && !S_ISDIR(st.st_mode))
			seen.insert(path);
	}

	// Glob patterns: one FTS walk per unique base directory.
	std::set<std::string> *seen_ptr = &seen;
	size_t max = max_results;

	for (auto &[search_dir, suffix_set] : dir_to_globs)
	{
		if (max > 0 && seen.size() >= max)
			break;

		std::vector<Glob> compiled_globs = compile_globs(suffix_set);

		FileMatchedBlock on_match = ^(const char *abs_path, struct stat *) {
			if (max > 0 && seen_ptr->size() >= max)
				return;
			seen_ptr->insert(abs_path);
		};

		walk_directory(search_dir, compiled_globs, {}, compiled_excl, on_match);
	}

	return std::vector<std::string>(seen.begin(), seen.end());
}

// Recursive helper for glob_files_in_dir. Walks dir, collects matching files into
// seen_ptr, then follows any symlinks that resolve outside root into new walk roots.
// visited_dirs prevents re-walking the same external directory via multiple symlinks.
static void
glob_walk_one(const std::string &dir,
              const std::string &root,
              const std::vector<Glob> &compiled_globs,
              const CompiledExcludes &compiled_excl,
              size_t max,
              std::set<std::string> *seen_ptr,
              std::unordered_set<std::string> &visited_dirs)
{
	std::vector<std::string> symlinks;
	FileMatchedBlock on_match = ^(const char *abs_path, struct stat *) {
		if (max == 0 || seen_ptr->size() < max)
			seen_ptr->insert(abs_path);
	};
	walk_directory(dir, compiled_globs, {}, compiled_excl, on_match, &symlinks);

	for (const auto &sym : symlinks)
	{
		char *resolved = realpath(sym.c_str(), nullptr);
		if (resolved == nullptr)
			continue;
		std::string target(resolved);
		free(resolved);

		// Symlinks pointing within root are reachable by regular traversal — skip
		bool under_root = (target.size() >= root.size() &&
		                   target.compare(0, root.size(), root) == 0 &&
		                   (target.size() == root.size() || target[root.size()] == '/'));
		if (under_root)
			continue;

		// Already visited — handles circular symlinks
		if (!visited_dirs.insert(target).second)
			continue;

		struct stat st;
		if (stat(target.c_str(), &st) != 0 || !S_ISDIR(st.st_mode))
			continue;

		glob_walk_one(target, root, compiled_globs, compiled_excl, max, seen_ptr, visited_dirs);
	}
}

std::vector<std::string> find_entries_by_name(
	const std::string &root_dir,
	const std::string &name_substr,
	const std::vector<std::string> &exclude_patterns,
	size_t max_results)
{
	std::string root = root_dir;
	while (!root.empty() && root.back() == '/')
		root.pop_back();

	std::unordered_set<std::string> excl_set(exclude_patterns.begin(), exclude_patterns.end());
	CompiledExcludes compiled_excl = compile_excludes(excl_set);

	std::vector<std::string> results;

	char *paths[2] = { const_cast<char *>(root.c_str()), nullptr };
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, fts_name_compar);
	if (fts == nullptr)
		return results;

	FTSENT *ent;
	while ((ent = fts_read(fts)) != nullptr)
	{
		switch (ent->fts_info)
		{
			case FTS_D:
			{
				if (ent->fts_level == 0)
					break; // root itself — not a result candidate
				if (is_path_excluded(ent->fts_path, compiled_excl, root.c_str()))
				{
					fts_set(fts, ent, FTS_SKIP);
					break;
				}
				if (max_results > 0 && results.size() >= max_results)
				{
					fts_set(fts, ent, FTS_SKIP);
					break;
				}
				if (strcasestr(ent->fts_name, name_substr.c_str()) != nullptr)
					results.push_back(ent->fts_path);
				break;
			}
			case FTS_F:
			case FTS_SL:
			case FTS_SLNONE:
			{
				if (max_results > 0 && results.size() >= max_results)
					break;
				if (is_path_excluded(ent->fts_path, compiled_excl, root.c_str()))
					break;
				if (strcasestr(ent->fts_name, name_substr.c_str()) != nullptr)
					results.push_back(ent->fts_path);
				break;
			}
			case FTS_ERR:
			case FTS_DNR:
				break;
			default:
				break;
		}
	}

	fts_close(fts);
	return results;
}

std::vector<std::string> glob_files_in_dir(
	const std::string &root_dir,
	const std::vector<std::string> &relative_glob_patterns,
	const std::vector<std::string> &exclude_patterns,
	size_t max_results)
{
	// Strip trailing slash for consistent prefix comparisons in glob_walk_one
	std::string root = root_dir;
	if (!root.empty() && root.back() == '/')
		root.pop_back();

	std::unordered_set<std::string> glob_set(relative_glob_patterns.begin(), relative_glob_patterns.end());
	auto compiled_globs = compile_globs(glob_set);

	std::unordered_set<std::string> excl_set(exclude_patterns.begin(), exclude_patterns.end());
	auto compiled_excl = compile_excludes(excl_set);

	std::set<std::string> seen;
	std::unordered_set<std::string> visited_dirs;
	visited_dirs.insert(root);

	glob_walk_one(root, root, compiled_globs, compiled_excl, max_results, &seen, visited_dirs);

	return std::vector<std::string>(seen.begin(), seen.end());
}
