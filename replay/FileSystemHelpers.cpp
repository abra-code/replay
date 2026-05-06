#include "FileSystemHelpers.h"
#include <dirent.h>
#include <fts.h>
#include <sys/stat.h>
#include <algorithm>
#include <cstring>

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
	if (!dir)
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
	if (!S_ISDIR(st.st_mode))
	{ errno = ENOTDIR; return false; }

	char *paths[2] = { const_cast<char *>(path), nullptr };
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, fts_name_compar);
	if (!fts)
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
					// Root dir itself
					if (maxDepth <= 0) { fts_set(fts, ent, FTS_SKIP); break; }
					if ((int)levelToNode.size() < 1) levelToNode.resize(1);
					levelToNode[0] = &out_root;
				}
				else
				{
					// lvl >= 1: parent is levelToNode[lvl - 1]
					if (lvl - 1 >= (int)levelToNode.size()) break;
					TreeNode *parent = levelToNode[lvl - 1];
					if (!parent) break;
					parent->children.push_back({ent->fts_name, true, {}});
					if (lvl < maxDepth)
					{
						if ((int)levelToNode.size() <= lvl) levelToNode.resize(lvl + 1);
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
					if (parent) parent->children.push_back({ent->fts_name, false, {}});
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
