#pragma once
// POSIX file operation helpers used by action implementation files.
// Include only in action .mm / .cpp files — not in public headers.

#include <copyfile.h>
#include <fts.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <climits>
#include <cstring>
#include <string>

// Returns the parent directory component of path (everything before the last '/').
// Returns "/" when there is no slash or the only slash is the leading one.
static inline std::string posix_parent_dir(const std::string &path)
{
	auto pos = path.rfind('/');
	if(pos == std::string::npos || pos == 0)
		return "/";
	return path.substr(0, pos);
}

// Returns true if the path exists without following symlinks (lstat semantics).
static inline bool posix_path_exists(const char *path)
{
	struct stat st;
	return lstat(path, &st) == 0;
}

// Returns true if the path exists, following symlinks (access F_OK semantics).
// Used to validate symlink targets — a broken symlink returns false.
static inline bool posix_path_exists_following_symlinks(const char *path)
{
	return access(path, F_OK) == 0;
}

// Creates path and all missing intermediate directories (like mkdir -p).
// Treats EEXIST on any component as success.
// Returns true when the final directory exists after the call.
static inline bool posix_mkdir_p(const char *path)
{
	char tmp[PATH_MAX];
	strlcpy(tmp, path, sizeof(tmp));
	size_t len = strlen(tmp);
	if(len > 0 && tmp[len - 1] == '/')
	{
		tmp[len - 1] = '\0';
	}
	for(char *p = tmp + 1; *p != '\0'; ++p)
	{
		if(*p == '/')
		{
			*p = '\0';
			if(mkdir(tmp, 0777) != 0 && errno != EEXIST)
			{
				return false;
			}
			*p = '/';
		}
	}
	return mkdir(tmp, 0777) == 0 || errno == EEXIST;
}

// Recursively removes a file or directory tree.
// Returns true on success. Returns true (idempotent) if path does not exist.
static inline bool posix_remove_recursive(const char *path)
{
	struct stat st;
	if(lstat(path, &st) != 0)
	{
		return errno == ENOENT;
	}
	if(!S_ISDIR(st.st_mode))
	{
		return unlink(path) == 0;
	}

	char *paths[2] = {(char *)path, nullptr};
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_XDEV, nullptr);
	if(fts == nullptr)
	{
		return false;
	}
	bool ok = true;
	FTSENT *ent;
	while((ent = fts_read(fts)) != nullptr)
	{
		switch(ent->fts_info)
		{
			case FTS_DP:
				if(rmdir(ent->fts_accpath) != 0)
				{
					ok = false;
				}
				break;
			case FTS_F:
			case FTS_SL:
			case FTS_SLNONE:
			case FTS_DEFAULT:
				if(unlink(ent->fts_accpath) != 0)
				{
					ok = false;
				}
				break;
			case FTS_ERR:
			case FTS_NS:
				ok = false;
				break;
			default:
				break;
		}
	}
	fts_close(fts);
	return ok;
}

// Clones src to dst using copyfile(3) with APFS clone-on-write when on the same volume.
// Falls back to a full data copy across volumes. COPYFILE_RECURSIVE handles directory trees.
// Returns 0 on success, -1 on failure (errno set).
static inline int posix_clone_item(const char *src, const char *dst)
{
	return copyfile(src, dst, nullptr,
	                COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_RECURSIVE);
}

// Moves src to dst. Uses rename(2) for same-volume moves; falls back to clone+delete on EXDEV.
// Returns true on success.
static inline bool posix_move_item(const char *src, const char *dst)
{
	if(rename(src, dst) == 0)
	{
		return true;
	}
	if(errno != EXDEV)
	{
		return false;
	}
	if(posix_clone_item(src, dst) != 0)
	{
		return false;
	}
	return posix_remove_recursive(src);
}
