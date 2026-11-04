//
//  Platform.h
//
//  The few operating system calls whose names or signatures differ between macOS and
//  Linux, behind one inline API. Everything else replay uses is plain POSIX.
//

#pragma once

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <climits>
#include <string>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

// Extended attribute names. Linux only accepts names in a namespace, and "user." is the
// one an unprivileged process may write, so the macOS name is kept after the prefix.
#if defined(__APPLE__)
#define REPLAY_XATTR_PREFIX ""
#else
#define REPLAY_XATTR_PREFIX "user."
#endif

// "No such attribute": macOS ENOATTR, Linux ENODATA.
#if defined(__APPLE__)
inline constexpr int kPlatformErrNoAttr = ENOATTR;
#else
inline constexpr int kPlatformErrNoAttr = ENODATA;
#endif

// Extended attribute calls that never follow a symlink at the end of the path.
inline ssize_t platform_get_xattr_nofollow(const char *path, const char *name, void *value, size_t size) noexcept
{
#if defined(__APPLE__)
	return ::getxattr(path, name, value, size, 0, XATTR_NOFOLLOW);
#else
	return ::lgetxattr(path, name, value, size);
#endif
}

inline int platform_set_xattr_nofollow(const char *path, const char *name, const void *value, size_t size) noexcept
{
#if defined(__APPLE__)
	return ::setxattr(path, name, value, size, 0, XATTR_NOFOLLOW);
#else
	return ::lsetxattr(path, name, value, size, 0);
#endif
}

inline int platform_remove_xattr_nofollow(const char *path, const char *name) noexcept
{
#if defined(__APPLE__)
	return ::removexattr(path, name, XATTR_NOFOLLOW);
#else
	return ::lremovexattr(path, name);
#endif
}

inline int platform_fset_xattr(int fd, const char *name, const void *value, size_t size) noexcept
{
#if defined(__APPLE__)
	return ::fsetxattr(fd, name, value, size, 0, 0);
#else
	return ::fsetxattr(fd, name, value, size, 0);
#endif
}

// stat times. macOS has st_mtimespec and st_ctimespec, Linux st_mtim and st_ctim.
inline const struct timespec &platform_stat_mtime(const struct stat &st) noexcept
{
#if defined(__APPLE__)
	return st.st_mtimespec;
#else
	return st.st_mtim;
#endif
}

inline const struct timespec &platform_stat_ctime(const struct stat &st) noexcept
{
#if defined(__APPLE__)
	return st.st_ctimespec;
#else
	return st.st_ctim;
#endif
}

inline int64_t platform_timespec_ns(const struct timespec &ts) noexcept
{
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// Creation time in seconds, or 0 when the file system does not record one.
// Linux keeps it only in statx, so a struct stat cannot carry it; the path is needed.
inline time_t platform_birth_time(const char *path, const struct stat &st) noexcept
{
#if defined(__APPLE__)
	(void)path;
	return st.st_birthtimespec.tv_sec;
#else
	(void)st;
	struct statx stx;
	if(::statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, STATX_BTIME, &stx) != 0)
		return 0;
	if((stx.stx_mask & STATX_BTIME) == 0)
		return 0;
	return (time_t)stx.stx_btime.tv_sec;
#endif
}

// Absolute path of the running executable, or an empty string. Not noexcept: it allocates.
inline std::string platform_executable_path()
{
	char path[PATH_MAX] = {0};
#if defined(__APPLE__)
	uint32_t size = sizeof(path);
	if(_NSGetExecutablePath(path, &size) != 0)
		return std::string();
	return std::string(path);
#else
	ssize_t length = ::readlink("/proc/self/exe", path, sizeof(path) - 1);
	if((length <= 0) || ((size_t)length >= sizeof(path) - 1)) // a full buffer may be truncated
		return std::string();
	path[length] = '\0';
	return std::string(path);
#endif
}

// A 16-byte id of this machine. Returns false and zeroes it when there is none.
// Linux: /etc/machine-id, 32 hex digits; an empty file (not yet initialized) is "none".
inline bool platform_host_uuid(uint8_t uuid[16]) noexcept
{
	memset(uuid, 0, 16);
#if defined(__APPLE__)
	struct timespec wait = {0, 0};
	if(::gethostuuid(uuid, &wait) != 0)
	{
		memset(uuid, 0, 16);
		return false;
	}
	return true;
#else
	FILE *file = ::fopen("/etc/machine-id", "re");
	if(file == nullptr)
		return false;
	char hex[33] = {0};
	size_t count = ::fread(hex, 1, 32, file);
	::fclose(file);
	if(count != 32)
		return false;
	for(size_t i = 0; i < 16; ++i)
	{
		unsigned value = 0;
		for(size_t j = 0; j < 2; ++j)
		{
			char c = hex[(i * 2) + j];
			unsigned digit;
			if((c >= '0') && (c <= '9'))
				digit = (unsigned)(c - '0');
			else if((c >= 'a') && (c <= 'f'))
				digit = (unsigned)(c - 'a' + 10);
			else if((c >= 'A') && (c <= 'F'))
				digit = (unsigned)(c - 'A' + 10);
			else
			{
				memset(uuid, 0, 16);
				return false;
			}
			value = (value << 4) | digit;
		}
		uuid[i] = (uint8_t)value;
	}
	return true;
#endif
}
