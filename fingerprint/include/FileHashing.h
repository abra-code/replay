//
//  FileHashing.h
//  fingerprint
//
//  Stateless per-file hashing and xattr memoization helpers.
//
//  These were originally private to fingerprint.cpp. They keep no state of
//  their own beyond the process-wide configuration globals (g_hash, g_verbose)
//  and are safe to call concurrently from any thread, so they are shared with
//  replay's synchronous TaskFingerprint module (see private/replay_caching_design.md 4.8).
//  Keeping a single implementation guarantees that replay, gate and fingerprint
//  agree on the "public.fingerprint.*" xattr format.
//

#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>

#include "blake3.h"
#include "fingerprint.h"
#include "FileInfo.h"

extern "C" uint32_t crc32_impl(uint32_t crc0, const char* buf, size_t len);

// Defined by each tool that links this code (replay: TaskFingerprint.cpp,
// gate/fingerprint: their main.cpp).
extern FileHashAlgorithm g_hash;
extern bool g_verbose;

inline constexpr const char* kCrc32CXattrName = "public.fingerprint.crc32c";
inline constexpr const char* kBlake3XattrName = "public.fingerprint.blake3";

// The xattr hash memoization is an optimization: failing to write it is never fatal,
// it only costs a re-hash next time. Permission failures are routine and must stay
// silent - a read-only source tree, a sandbox denying writes to inputs, a filesystem
// without xattr support, or (in replay, where many tasks fingerprint a shared header
// at once) another thread restoring the file's mode inside our chmod window. Anything
// else is unexpected and reported only under -v.
inline __attribute__((always_inline))
void report_xattr_failure(const char* operation, int result, int err, const std::string& path) noexcept
{
    // ENOATTR: removing an xattr that was never written - the normal case for the
    // fingerprint tool's --xattr clear. (replay never selects XattrMode::Clear.)
    if ((err == EACCES) || (err == EPERM) || (err == ENOTSUP) || (err == EROFS) || (err == ENOATTR))
        return;
    if (!g_verbose)
        return;

    std::string message = std::string("Warning: ") + operation + " failed result = " + std::to_string(result)
                        + " errno = " + std::to_string(err) + " for " + path + "\n";
    std::cerr << message;
}

inline __attribute__((always_inline))
void compute_buffer_hash(const void *buffer, size_t size, FileInfo &fileInfo)
{
    if (g_hash == FileHashAlgorithm::CRC32C)
    {
        fileInfo.hash.crc32c = crc32_impl(0, (const char*)buffer, size);
    }
    else
    {
        blake3_hasher hasher;
        blake3_hasher_init(&hasher);
        blake3_hasher_update(&hasher, (const void *)buffer, size);
        blake3_hasher_finalize(&hasher, (uint8_t*)&fileInfo.hash.blake3, 8);
    }
}

// Returns true when info.hash was actually computed over the file's bytes, false when
// the content could not be read (open/read/mmap/readlink failure) and the hash is
// therefore still the 0 it was initialized to. Callers MUST NOT persist a false result
// into the xattr stat-cache: a stored {inode, size, mtime, hash = 0} record keeps
// hitting on every later run, so one transient EMFILE or permission failure would pin
// the file's recorded content hash at 0 until its size or mtime changes.
inline __attribute__((always_inline))
bool compute_file_hash(const std::string &path, FileInfo &info)
{
    // Don't try to read non-existent files
    if (info.is_nonexistent())
    {
        return false; // Sentinel value already set
    }

    // For symlinks, read the symlink data itself, not the target
    if (info.is_symlink())
    {
        char target[PATH_MAX];
        ssize_t len = readlink(path.c_str(), target, sizeof(target) - 1);

        if (len > 0)
        {
            target[len] = '\0';
            compute_buffer_hash(target, len, info);
            return true;
        }

        // Failed to read symlink - leave hash as 0
        if (g_verbose)
        {
            std::cerr << "Warning: failed to read symlink: " << path << '\n';
        }
        return false;
    }

    // Regular file processing
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0)
    {
        // TODO: log error
        return false;
    }

    // 16 MB is the mmap threshold - TODO: experiment with different thresholds
    const size_t MMAP_THRESHOLD = 16 * 1024 * 1024;

    bool hashed = false;
    if ((info.size < MMAP_THRESHOLD) && (info.size > 0))
    {
        std::unique_ptr<char, decltype(&free)> buffer(
            static_cast<char*>(malloc(info.size)), free);
        if (buffer != nullptr)
        {
            if (read(fd, buffer.get(), info.size) == (ssize_t)info.size)
            {
                compute_buffer_hash(buffer.get(), info.size, info);
                hashed = true;
            }
        }
    }
    else if (info.size >= MMAP_THRESHOLD)
    {
        // Large files: mmap + madvise
        void* map = mmap(nullptr, info.size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map != MAP_FAILED)
        {
            madvise(map, info.size, MADV_SEQUENTIAL);
            compute_buffer_hash(map, info.size, info);
            munmap(map, info.size);
            hashed = true;
        }
    }
    else
    {
        hashed = true; // size == 0: hash remains 0, which is correct for an empty file
    }

    close(fd);
    return hashed;
}

// returns true if file info stored in xattr is the same as current iteration info & stores the hash in appropriate current_file_info.hash
// returns false if file info does not match or xattr cannot be read
inline __attribute__((always_inline))
bool read_xattr_fileinfo(const std::string& path, FileInfoCore& current_file_info) noexcept
{
    FileInfoCore cached_file_info {};
    const char* xattr_name = (g_hash == FileHashAlgorithm::CRC32C) ? kCrc32CXattrName : kBlake3XattrName;
    ssize_t attr_size = getxattr(path.c_str(), xattr_name, &cached_file_info, sizeof(FileInfoCore), 0, XATTR_NOFOLLOW);

    if (attr_size != sizeof(FileInfoCore))
    {
        return false; // no xattr or wrong size, we need to recompute the hash
    }

    bool is_file_info_unchanged = (cached_file_info.inode == current_file_info.inode) &&
                                  (cached_file_info.size == current_file_info.size) &&
                                  (cached_file_info.mtime_ns == current_file_info.mtime_ns);

    if (is_file_info_unchanged)
    { // we read the cached hash if the file info is unchanged
        if(g_hash == FileHashAlgorithm::CRC32C)
        {
            current_file_info.hash.crc32c = cached_file_info.hash.crc32c;
        }
        else if(g_hash == FileHashAlgorithm::BLAKE3)
        {
            current_file_info.hash.blake3 = cached_file_info.hash.blake3;
        }
    }

    return is_file_info_unchanged;
}


inline __attribute__((always_inline))
void write_xattr_fileinfo(const std::string& path, const FileInfo& info) noexcept
{
    bool forced_writable = false;
    if ((info.mode & S_IWUSR) == 0) // if the file is not user-writable
    {
        int mode_change_status = lchmod(path.c_str(), info.mode | S_IWUSR); // temporarily set to writable
        //int mode_change_status = set_file_mode_flags(path, info.mode | S_IWUSR);
        forced_writable = (mode_change_status == 0);
    }

    errno = 0; //clear any potentially lingering errors from previous operation

    const char* xattrName = (g_hash == FileHashAlgorithm::CRC32C) ? kCrc32CXattrName : kBlake3XattrName;

    // Address the base subobject explicitly rather than relying on it sitting at offset 0
    // of the derived object: FileInfo has data members in both the base and the derived
    // class, so it is not standard-layout and that offset is an assumption rather than a
    // guarantee. Same codegen, and it stops the assumption from growing more load-bearing
    // as runtime-only fields are added.
    int xattr_result = ::setxattr(path.c_str(),
                       xattrName,
                       &static_cast<const FileInfoCore &>(info),
                       sizeof(FileInfoCore), //only the core part of the FileInfo is persisted
                       0,              // position (ignored)
                       XATTR_NOFOLLOW); // or 0 to not follow symlinks

    int err = errno;

    if (forced_writable)
    {
        lchmod(path.c_str(), info.mode); // restore original permissions
    }

    if (xattr_result != 0)
    {
        report_xattr_failure("setxattr", xattr_result, err, path);
    }
}

inline __attribute__((always_inline))
void clear_xattr_fileinfo(const std::string& path, const FileInfo& info) noexcept
{
    bool forced_writable = false;
    if ((info.mode & S_IWUSR) == 0) // if the file is not user-writable
    {
        int mode_change_status = lchmod(path.c_str(), info.mode | S_IWUSR); // temporarily set to writable
        forced_writable = (mode_change_status == 0);
    }

    errno = 0; //clear any potentially lingering errors from previous operation
    const char* xattr_name = (g_hash == FileHashAlgorithm::CRC32C) ? kCrc32CXattrName : kBlake3XattrName;
    int xattr_result = ::removexattr(path.c_str(), xattr_name, XATTR_NOFOLLOW);

    int err = errno;

    if (forced_writable)
    {
        lchmod(path.c_str(), info.mode); // restore original permissions
    }

    if (xattr_result != 0)
    {
        report_xattr_failure("removexattr", xattr_result, err, path);
    }
}
