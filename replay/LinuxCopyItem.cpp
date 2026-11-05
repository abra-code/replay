//
//  LinuxCopyItem.cpp
//
//  Linux only. The copier behind the clone action and behind move across file systems,
//  standing in for macOS copyfile(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC |
//  COPYFILE_RECURSIVE) (PosixFileOps.h). It follows what copyfile does with those flags,
//  checked on macOS 27:
//  - a destination that is an existing folder receives the item inside it, under the
//    source's name (like cp -R); any other existing destination is EEXIST;
//  - a missing parent folder is ENOENT;
//  - symlinks are copied as symlinks, dangling ones included;
//  - regular files keep their mode, owner where permitted, access and modification times,
//    and extended attributes; data is cloned where the file system can (FICLONE on btrfs,
//    XFS, bcachefs), otherwise copied in the kernel (copy_file_range), otherwise read and
//    written;
//  - folders keep their mode, owner where permitted, and extended attributes, but not
//    their times; hard links inside a tree become separate files;
//  - FIFOs, sockets and devices are ENOTSUP;
//  - a trailing slash on the source asks for a folder: a symlink to a folder is followed,
//    a file is ENOTDIR, and an existing destination is EEXIST (no copying into it); a
//    trailing slash on a missing destination with a file source is ENOENT;
//  - the first error stops the copy and leaves what was copied so far.
//  Deliberate differences: a folder's mode is applied after its contents are copied, so a
//  read-only folder copies (copyfile applies it first and fails with EACCES); copying a
//  folder into itself is EINVAL up front (copyfile recurses until ENAMETOOLONG);
//  set-user-ID and set-group-ID bits are dropped when the owner cannot be copied; a file
//  copied onto a symlink to itself is EEXIST (copyfile succeeds without doing anything).
//

#if defined(__linux__)

#include "PosixFileOps.h"

#include <fcntl.h>
#include <fts.h>
#include <linux/fs.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace
{

// Keeps errno across cleanup calls (close, unlink, fts_close) that may change it.
class ErrnoKeeper
{
public:
	ErrnoKeeper() : mErrno(errno) {}
	~ErrnoKeeper() { errno = mErrno; }
private:
	int mErrno;
};

bool is_ignored_xattr_error(int err)
{
	// The destination file system may not take extended attributes at all (ENOTSUP), and
	// names outside the user namespace (security.*, system.*) may need privileges this
	// process does not have. copyfile skips what it cannot copy in the same way.
	return (err == ENOTSUP) || (err == EPERM) || (err == EACCES);
}

// Reads the list of extended attribute names. fd >= 0 reads from the open file, otherwise
// from path without following a symlink. Returns false with errno set on a real error; an
// unsupported file system yields an empty list.
bool list_xattrs(int fd, const char *path, std::vector<char> &names)
{
	names.clear();
	for(int attempt = 0; attempt < 4; ++attempt)
	{
		ssize_t size = (fd >= 0) ? flistxattr(fd, nullptr, 0) : llistxattr(path, nullptr, 0);
		if(size < 0)
			return is_ignored_xattr_error(errno);
		if(size == 0)
			return true;
		names.resize((size_t)size);
		size = (fd >= 0) ? flistxattr(fd, names.data(), names.size())
		                 : llistxattr(path, names.data(), names.size());
		if(size >= 0)
		{
			names.resize((size_t)size);
			return true;
		}
		if(errno != ERANGE) // ERANGE: the list grew between the two calls; ask again
			return is_ignored_xattr_error(errno);
	}
	errno = ERANGE;
	return false;
}

// Copies every extended attribute it can from one file to another. Either both fds are
// valid, or both paths are used without following symlinks.
bool copy_xattrs(int srcFd, const char *srcPath, int dstFd, const char *dstPath)
{
	std::vector<char> names;
	if(!list_xattrs(srcFd, srcPath, names))
		return false;

	std::vector<char> value;
	size_t offset = 0;
	while(offset < names.size())
	{
		const char *name = names.data() + offset;
		size_t nameLength = strnlen(name, names.size() - offset);
		offset += nameLength + 1;
		if(nameLength == 0)
			continue;

		ssize_t size = -1;
		for(int attempt = 0; attempt < 4; ++attempt)
		{
			size = (srcFd >= 0) ? fgetxattr(srcFd, name, nullptr, 0) : lgetxattr(srcPath, name, nullptr, 0);
			if(size < 0)
				break;
			value.resize((size_t)size);
			size = (srcFd >= 0) ? fgetxattr(srcFd, name, value.data(), value.size())
			                    : lgetxattr(srcPath, name, value.data(), value.size());
			if((size >= 0) || (errno != ERANGE))
				break;
		}
		if(size < 0)
		{
			if((errno == ENODATA) || is_ignored_xattr_error(errno)) // removed meanwhile, or not readable by us
				continue;
			return false;
		}

		int rc = (dstFd >= 0) ? fsetxattr(dstFd, name, value.data(), (size_t)size, 0)
		                      : lsetxattr(dstPath, name, value.data(), (size_t)size, 0);
		if((rc != 0) && !is_ignored_xattr_error(errno))
			return false;
	}
	return true;
}

// The mode to give a copy. When the owner could not be copied (an unprivileged user copying
// someone else's file), the set-user-ID and set-group-ID bits are dropped, as GNU cp does:
// otherwise a copy of a set-user-ID program would run as whoever made the copy.
mode_t copied_mode(const struct stat &st, bool ownerCopied)
{
	mode_t mode = st.st_mode & 07777;
	if(!ownerCopied)
		mode &= (mode_t)~(S_ISUID | S_ISGID);
	return mode;
}

bool write_all(int fd, const char *buffer, size_t length)
{
	while(length > 0)
	{
		ssize_t written = write(fd, buffer, length);
		if(written < 0)
		{
			if(errno == EINTR)
				continue;
			return false;
		}
		buffer += written;
		length -= (size_t)written;
	}
	return true;
}

bool copy_data_read_write(int srcFd, int dstFd)
{
	std::vector<char> buffer(256 * 1024);
	while(true)
	{
		ssize_t count = read(srcFd, buffer.data(), buffer.size());
		if(count < 0)
		{
			if(errno == EINTR)
				continue;
			return false;
		}
		if(count == 0)
			return true;
		if(!write_all(dstFd, buffer.data(), (size_t)count))
			return false;
	}
}

bool copy_data(int srcFd, int dstFd)
{
	// A clone shares the blocks until either side is written: instant, and no extra space.
	if(ioctl(dstFd, FICLONE, srcFd) == 0)
		return true;

	// copy_file_range copies inside the kernel, and NFS and SMB do it on the server.
	bool copiedAny = false;
	while(true)
	{
		ssize_t count = copy_file_range(srcFd, nullptr, dstFd, nullptr, 1 << 30, 0);
		if(count > 0)
		{
			copiedAny = true;
			continue;
		}
		if(count == 0)
		{
			// End of file. Some kernels (5.3 to 5.11) return 0 at once instead of an error
			// when they cannot do it, for example for files in /proc and /sys, which report
			// a size of 0 but have contents. So 0 at once is never trusted: the read and
			// write below find the end at once for a file that is really empty.
			if(copiedAny)
				return true;
			break;
		}
		if(errno == EINTR)
			continue;
		if(copiedAny)
			return false;
		// Not available for this pair of files (EXDEV across file system types before Linux
		// 5.3 and again from 5.12, EINVAL, EOPNOTSUPP, ENOSYS, or EBADF on some special
		// files): fall back to plain reads and writes.
		if((errno != EXDEV) && (errno != EINVAL) && (errno != EOPNOTSUPP) && (errno != ENOSYS) &&
		   (errno != EBADF) && (errno != ENOTSUP))
			return false;
		break;
	}

	// Nothing was copied, so both offsets are still at 0.
	return copy_data_read_write(srcFd, dstFd);
}

// Copies one regular file. The destination must not exist. On failure the partly written
// destination is removed.
bool copy_regular_file(const char *src, const char *dst)
{
	// O_NONBLOCK: if the path was replaced by a FIFO since it was checked, the open returns
	// instead of waiting for a writer, and the type check below rejects it. It changes
	// nothing for a regular file.
	int srcFd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
	if(srcFd < 0)
		return false;

	struct stat st;
	if(fstat(srcFd, &st) != 0)
	{
		ErrnoKeeper keep;
		close(srcFd);
		return false;
	}
	if(!S_ISREG(st.st_mode))
	{
		close(srcFd);
		errno = ENOTSUP;
		return false;
	}

	// Created owner-only, and given its final mode last, so it is never readable by others
	// before it holds the source's permissions, and a read-only source still gets its
	// extended attributes and times written.
	int dstFd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR);
	if(dstFd < 0)
	{
		ErrnoKeeper keep;
		close(srcFd);
		return false;
	}

	bool ok = copy_data(srcFd, dstFd) && copy_xattrs(srcFd, nullptr, dstFd, nullptr);
	if(ok)
	{
		// Owner first: changing it can clear the set-user-ID and set-group-ID bits, which
		// the mode then restores. Not permitted for an unprivileged user unless nothing
		// changes, so a failure is not an error, as with copyfile.
		bool ownerCopied = (fchown(dstFd, st.st_uid, st.st_gid) == 0);
		ok = (fchmod(dstFd, copied_mode(st, ownerCopied)) == 0);
	}
	if(ok)
	{
		struct timespec times[2] = {st.st_atim, st.st_mtim};
		ok = (futimens(dstFd, times) == 0);
	}

	{
		ErrnoKeeper keep;
		close(srcFd);
	}
	if(close(dstFd) != 0) // a delayed write error (NFS, a full disk) surfaces here
		ok = false;

	if(!ok)
	{
		ErrnoKeeper keep;
		unlink(dst);
	}
	return ok;
}

bool copy_symlink(const char *src, const char *dst, const struct stat &st)
{
	// st_size is the target's length on most file systems, but 0 on some (procfs), so
	// grow the buffer until the target fits.
	size_t capacity = ((st.st_size > 0) ? (size_t)st.st_size : PATH_MAX) + 1;
	std::string target;
	while(true)
	{
		target.resize(capacity);
		ssize_t length = readlink(src, &target[0], capacity);
		if(length < 0)
			return false;
		if((size_t)length < capacity)
		{
			target.resize((size_t)length);
			break;
		}
		capacity *= 2;
	}

	if(symlink(target.c_str(), dst) != 0)
		return false;

	// Best effort, like copyfile: Linux keeps no user extended attributes on symlinks.
	(void)lchown(dst, st.st_uid, st.st_gid);
	struct timespec times[2] = {st.st_atim, st.st_mtim};
	(void)utimensat(AT_FDCWD, dst, times, AT_SYMLINK_NOFOLLOW);
	return true;
}

// Mode, owner and extended attributes of a folder whose contents are already copied.
bool finish_directory(const char *src, const char *dst, const struct stat &st)
{
	if(!copy_xattrs(-1, src, -1, dst))
		return false;
	bool ownerCopied = (lchown(dst, st.st_uid, st.st_gid) == 0);
	return chmod(dst, copied_mode(st, ownerCopied)) == 0;
}

// root is the source folder as fts should open it; the first rootLength characters of every
// path fts returns are replaced by dst.
bool copy_tree(const std::string &root, size_t rootLength, const std::string &dst)
{
	char *roots[2] = {const_cast<char *>(root.c_str()), nullptr};
	FTS *fts = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, nullptr);
	if(fts == nullptr)
		return false;

	bool ok = true;
	while(ok)
	{
		// fts_read returns NULL both at the end and on an error; only an error sets errno.
		errno = 0;
		FTSENT *entry = fts_read(fts);
		if(entry == nullptr)
		{
			ok = (errno == 0);
			break;
		}

		// fts_path starts with the root exactly as it was passed in.
		std::string target = dst + std::string(entry->fts_path + rootLength);
		switch(entry->fts_info)
		{
			case FTS_D:
				// Owner-only and writable while the contents go in; finish_directory applies
				// the real mode on the way out (FTS_DP).
				ok = (mkdir(target.c_str(), S_IRWXU) == 0);
				break;

			case FTS_DP:
				ok = finish_directory(entry->fts_accpath, target.c_str(), *entry->fts_statp);
				break;

			case FTS_F:
				ok = copy_regular_file(entry->fts_accpath, target.c_str());
				break;

			case FTS_SL:
			case FTS_SLNONE:
				ok = copy_symlink(entry->fts_accpath, target.c_str(), *entry->fts_statp);
				break;

			case FTS_DNR: // a folder that cannot be read
			case FTS_ERR:
			case FTS_NS:  // no stat information
				errno = (entry->fts_errno != 0) ? entry->fts_errno : EIO;
				ok = false;
				break;

			case FTS_DEFAULT: // FIFO, socket, device
				errno = ENOTSUP;
				ok = false;
				break;

			case FTS_DC: // a folder that contains itself (possible through bind mounts)
				errno = ELOOP;
				ok = false;
				break;

			default: // FTS_DOT is not returned without FTS_SEEDOT
				break;
		}
	}

	ErrnoKeeper keep;
	fts_close(fts);
	return ok;
}

std::string strip_trailing_slashes(const std::string &path)
{
	std::string result = path;
	while((result.size() > 1) && (result.back() == '/'))
		result.pop_back();
	return result;
}

std::string last_component(const std::string &path)
{
	size_t slash = path.rfind('/');
	return (slash == std::string::npos) ? path : path.substr(slash + 1);
}

// True when dst would be created inside the folder src (or be src itself).
bool is_inside(const std::string &src, const std::string &dst)
{
	char *srcReal = realpath(src.c_str(), nullptr);
	if(srcReal == nullptr)
		return false;
	std::string parent = posix_parent_dir(dst);
	if(dst.find('/') == std::string::npos)
		parent = ".";
	char *parentReal = realpath(parent.c_str(), nullptr);
	bool inside = false;
	if(parentReal != nullptr)
	{
		std::string root(srcReal);
		std::string candidate(parentReal);
		inside = (candidate == root) || ((root == "/") ? true : (candidate.compare(0, root.size() + 1, root + "/") == 0));
		free(parentReal);
	}
	free(srcReal);
	return inside;
}

} // namespace

int linux_copy_item(const std::string &srcPath, const std::string &dstPath)
{
	std::string src = strip_trailing_slashes(srcPath);
	std::string dst = strip_trailing_slashes(dstPath);
	bool srcSlash = (src.size() < srcPath.size());
	bool dstSlash = (dst.size() < dstPath.size());

	// A trailing slash on the source asks for a folder, and the kernel resolves it that way,
	// as copyfile does: a symlink to a folder is followed (the folder is copied), and a file
	// or a symlink to one is ENOTDIR.
	struct stat srcStat;
	if(lstat((srcSlash ? (src + "/") : src).c_str(), &srcStat) != 0)
		return -1;

	// An existing folder as the destination receives the item inside it, as copyfile and
	// cp -R do. A symlink to a folder is followed for this, as copyfile follows it. With a
	// trailing slash on the source copyfile does not do this (the destination exists: EEXIST).
	struct stat dstStat;
	bool dstExists = (stat(dst.c_str(), &dstStat) == 0);
	if(dstSlash && !dstExists && !S_ISDIR(srcStat.st_mode))
	{
		// "newname/" names a folder; copyfile does not create a file or symlink there.
		errno = ENOENT;
		return -1;
	}
	if(!srcSlash && dstExists && S_ISDIR(dstStat.st_mode))
	{
		std::string name = last_component(src);
		if(name.empty() || (name == ".") || (name == "..") || (name == "/"))
		{
			errno = EEXIST;
			return -1;
		}
		dst += "/";
		dst += name;
	}

	if(S_ISDIR(srcStat.st_mode))
	{
		if(is_inside(src, dst))
		{
			errno = EINVAL;
			return -1;
		}
		// With the slash kept, fts follows a source that is a symlink to a folder.
		return copy_tree(srcSlash ? (src + "/") : src, src.size(), dst) ? 0 : -1;
	}
	if(S_ISREG(srcStat.st_mode))
		return copy_regular_file(src.c_str(), dst.c_str()) ? 0 : -1;
	if(S_ISLNK(srcStat.st_mode))
		return copy_symlink(src.c_str(), dst.c_str(), srcStat) ? 0 : -1;

	errno = ENOTSUP; // FIFO, socket, device: copyfile does not copy them either
	return -1;
}

#endif // __linux__
