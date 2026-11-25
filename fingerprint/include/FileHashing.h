//
//  FileHashing.h
//  fingerprint
//
//  Stateless per-file hashing and fingerprint xattr helpers.
//
//  These were originally private to fingerprint.cpp. They keep no state of
//  their own beyond the process-wide configuration globals (g_hash, g_verbose)
//  and are safe to call concurrently from any thread, so they are shared with
//  replay's synchronous TaskFingerprint module.
//  Keeping a single implementation guarantees that replay, gate and fingerprint
//  agree on the "public.fingerprint.*" xattr format.
//

#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include "Platform.h"
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "blake3.h"
#include "fingerprint.h"
#include "FileInfo.h"

extern "C" uint32_t crc32_impl(uint32_t crc0, const char* buf, size_t len);

// Defined by each tool that links this code (replay: TaskFingerprint.cpp,
// gate/fingerprint: their main.cpp).
extern FileHashAlgorithm g_hash;
extern bool g_verbose;

inline constexpr const char* kCrc32CXattrName = REPLAY_XATTR_PREFIX "public.fingerprint.crc32c";
inline constexpr const char* kBlake3XattrName = REPLAY_XATTR_PREFIX "public.fingerprint.blake3";

// The fingerprint xattr is an optimization: failing to write it is never fatal,
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
    if ((err == EACCES) || (err == EPERM) || (err == ENOTSUP) || (err == EROFS) || (err == kPlatformErrNoAttr))
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

// A stored hash (the fingerprint xattr, or replay's hash store) is trusted while the
// file's recorded times and size match. File times move in steps, and a file rewritten at
// the same size within the step of its last change keeps the same times, so a hash read
// in that step and stored would be handed back for the new content. A hash is therefore
// stored only when the file's last change is old enough to be in an earlier step than
// any change after the read; a newer file is hashed again next time and stored then. A
// change time in the future never qualifies. How old is old enough depends on the file
// system (platform_file_time_step):
//   Fine    APFS, stamped from the precise clock: 1 ms.
//   Tick    Linux ext4 and tmpfs, stamped from the coarse clock: two of its steps (8 ms
//           at 250 Hz, 20 ms at 100 Hz), measured against that same clock: every later
//           stamp is at least its reading at the read, however far it lags the precise
//           clock. Since Linux 6.13 a time read after the change is precise, ahead of
//           the coarse clock; it is stored once that clock is two steps past it, and the
//           kernel stamps any change after such a read later than it. ext2/3/4
//           with small inodes keep whole seconds; a change time with no fraction of a
//           second is taken for that and gets the Coarse age.
//   Coarse anything else (HFS+ 1 s, FAT 2 s, network and FUSE file systems): 2 s.
inline constexpr int64_t kMinAgeToStoreHashFineNs = 1000000LL;
inline constexpr int64_t kMinAgeToStoreHashCoarseNs = 2000000000LL;

// The clock file times are stamped from. Take it before reading the content whose hash
// may be stored.
inline int64_t file_clock_ns() noexcept
{
    return platform_file_clock_ns();
}

// The time step of the file system holding path, looked up once per device.
inline PlatformTimeStep file_time_step(const std::string& path, const FileInfo& info) noexcept
{
    // Never destroyed: a worker thread may still be hashing while exit() runs the
    // destructors of statics.
    static std::mutex& steps_mutex = *new std::mutex;
    static std::unordered_map<dev_t, PlatformTimeStep>& steps = *new std::unordered_map<dev_t, PlatformTimeStep>;
    try
    {
        {
            std::lock_guard<std::mutex> guard(steps_mutex);
            auto found = steps.find(info.dev);
            if (found != steps.end())
                return found->second;
        }
        // statfs follows a symbolic link, and its target can be on another file system
        // than the link, whose device keys this cache. The directory holding the link is
        // on the link's own.
        std::string where = path;
        if (info.is_symlink())
        {
            size_t slash = path.find_last_of('/');
            if (slash == std::string::npos)
                where = ".";
            else
                where = path.substr(0, (slash == 0) ? 1 : slash);
        }
        PlatformTimeStep step = platform_file_time_step(where.c_str());
        std::lock_guard<std::mutex> guard(steps_mutex);
        steps.emplace(info.dev, step);
        return step;
    }
    catch (...)
    {
        return PlatformTimeStep::Coarse;
    }
}

// A shorter age in milliseconds from REPLAY_HASH_STORE_TEST_MIN_AGE_MS, at most 2000, or
// -1 when it is not set: the test suites that check the hash store's format set 0, so
// that the files a run has just written are stored by that run; those that check the
// rule itself can set 2000 for the Coarse age on every file system. The age it sets is
// measured against the precise clock at the decision (may_store_hash), not the file
// clock at the read: the suites write their files moments before a run, and since
// Linux 6.13 those files carry precise times ahead of the coarse clock. It therefore
// gives up the guarantee for a file rewritten during the read; tests only.
inline int64_t test_min_age_to_store_hash_ns() noexcept
{
    static const int64_t min_age_ns = []() noexcept -> int64_t {
        const char* text = getenv("REPLAY_HASH_STORE_TEST_MIN_AGE_MS");
        if (text != nullptr)
        {
            char* end = nullptr;
            long long ms = strtoll(text, &end, 10);
            if ((end != text) && (*end == '\0') && (ms >= 0) && (ms <= kMinAgeToStoreHashCoarseNs / 1000000LL))
                return (int64_t)(ms * 1000000LL);
        }
        return -1;
    }();
    return min_age_ns;
}

// changed_ns: the file time the store validates that moves on every change - mtime for
// the fingerprint xattr, the later of mtime and ctime for replay's hash store, which also
// tells apart a rewrite that puts the old mtime back. read_start_ns: file_clock_ns()
// taken before the content was read.
inline bool may_store_hash(const std::string& path, const FileInfo& info, int64_t changed_ns,
                           int64_t read_start_ns) noexcept
{
    int64_t min_age = test_min_age_to_store_hash_ns();
    if (min_age >= 0)
        read_start_ns = platform_precise_clock_ns(); // the test override's clock, see above

    int64_t age = 0;
    if (__builtin_sub_overflow(read_start_ns, changed_ns, &age) || (age < 0))
        return false;

    if (min_age < 0)
    {
        switch (file_time_step(path, info))
        {
            case PlatformTimeStep::Fine:
                min_age = kMinAgeToStoreHashFineNs;
                break;
            case PlatformTimeStep::Tick:
                min_age = ((changed_ns % 1000000000LL) != 0) ? (2 * platform_file_clock_step_ns())
                                                              : kMinAgeToStoreHashCoarseNs;
                break;
            case PlatformTimeStep::Coarse:
                min_age = kMinAgeToStoreHashCoarseNs;
                break;
        }
    }
    return age >= min_age;
}

// returns true if file info stored in xattr is the same as current iteration info & stores the hash in appropriate current_file_info.hash
// returns false if file info does not match or xattr cannot be read
inline __attribute__((always_inline))
bool read_xattr_fileinfo(const std::string& path, FileInfoCore& current_file_info) noexcept
{
    FileInfoCore cached_file_info {};
    const char* xattr_name = (g_hash == FileHashAlgorithm::CRC32C) ? kCrc32CXattrName : kBlake3XattrName;
    ssize_t attr_size = platform_get_xattr_nofollow(path.c_str(), xattr_name, &cached_file_info, sizeof(FileInfoCore));

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


// The fingerprint xattr is written or removed, and its file's mode briefly changed for
// that, only on files of the user running the tool. Another user's file (reached through
// a shared folder, or every file when running as root) keeps its attributes and its
// mode; its hash is still read
// from an existing xattr and otherwise computed every time.
inline __attribute__((always_inline))
bool may_change_file_xattr(const FileInfo& info) noexcept
{
    return info.uid == geteuid();
}

inline __attribute__((always_inline))
void write_xattr_fileinfo(const std::string& path, const FileInfo& info) noexcept
{
    if (!may_change_file_xattr(info))
        return;

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
    int xattr_result = platform_set_xattr_nofollow(path.c_str(),
                       xattrName,
                       &static_cast<const FileInfoCore &>(info),
                       sizeof(FileInfoCore)); //only the core part of the FileInfo is persisted

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
    if (!may_change_file_xattr(info))
        return;

    bool forced_writable = false;
    if ((info.mode & S_IWUSR) == 0) // if the file is not user-writable
    {
        int mode_change_status = lchmod(path.c_str(), info.mode | S_IWUSR); // temporarily set to writable
        forced_writable = (mode_change_status == 0);
    }

    errno = 0; //clear any potentially lingering errors from previous operation
    const char* xattr_name = (g_hash == FileHashAlgorithm::CRC32C) ? kCrc32CXattrName : kBlake3XattrName;
    int xattr_result = platform_remove_xattr_nofollow(path.c_str(), xattr_name);

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
