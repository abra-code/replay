//
//  fingerprint.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/8/25.
//

#include <iostream>
#include <assert.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <sys/xattr.h>
#include <fnmatch.h>

#include "blake3.h"

#include "fingerprint.h"
#include "FileInfo.h"
#include "dispatch_queues_helper.h"

extern "C" uint32_t crc32_impl(uint32_t crc0, const char* buf, size_t len);

extern bool g_use_xatrr_optimization;
extern HashAlgorithm g_hash;

extern bool g_test_perf;
extern double g_traversal_time;

std::atomic_bool s_exiting = false;
std::atomic_int s_result = EXIT_SUCCESS;

static constexpr const char* kCrc32CXattrName = "public.fingerprint.crc32c";
static constexpr const char* kBlake3XattrName = "public.fingerprint.blake3";

// this is a shared container that must be mutated only on serial shared_container_mutation_queue
static std::vector<std::pair<std::string, FileInfo>> s_all_matched_files;

void
fingerprint::set_exiting() noexcept
{
    s_exiting = true;
}

static inline bool
is_exiting() noexcept
{
    return s_exiting;
}

int
fingerprint::get_result() noexcept
{
    return s_result;
}


struct GlobPattern
{
    std::string pattern;   // already lower-cased
    int         flags;     // FNM_CASEFOLD | FNM_PATHNAME (if needed)
};

static inline bool matches_any_glob(const char* relative_path,
                                    const std::vector<GlobPattern>& patterns) noexcept
{
    std::string relative_path_lower = relative_path;
    std::transform(relative_path_lower.begin(), relative_path_lower.end(),
                   relative_path_lower.begin(), ::tolower);

    // at this point both glob patters and relative path are lowercase
    for (const auto& g : patterns)
    {
        if (fnmatch(g.pattern.c_str(), relative_path_lower.c_str(), g.flags) == 0)
            return true;
    }
    return false;
}

int
fingerprint::find_files(const std::unordered_set<std::string>& paths,
                        const std::unordered_set<std::string>& globs) noexcept
{
    // Pre-compile globs once — (empty vector = match-all)
    std::vector<GlobPattern> compiled_globs;
    if (!globs.empty() && !globs.contains(""))
    {
        compiled_globs.reserve(globs.size());
        for (const auto& g : globs)
        {
            int flags = FNM_CASEFOLD;
            if (g.find('/') != std::string::npos)
                flags |= FNM_PATHNAME;
            compiled_globs.push_back({g, flags});
        }
    }

    dispatch_queue_t directory_traversal_queue = get_directory_traversal_queue();
    dispatch_group_t task_group = get_all_tasks_group();

    // Multiple independent directory traversal with fts_read() calls (different roots) are safe,
    // cheap (metadata cached), and faster overall — especially on SSDs or multiple volumes.
    // No risk of overwhelming the filesystem.
    
    for (const auto& path : paths)
    {
        dispatch_group_async(task_group, directory_traversal_queue, ^{
            if (is_exiting()) { return; }
            __unused int find_result = find_files_internal(path, compiled_globs);
        });
    }
    return s_result;
}


static inline void compute_buffer_checksum(const void *buffer, size_t size, FileInfo &fileInfo)
{
    if (g_hash == HashAlgorithm::CRC32C)
    {
        fileInfo.checksum.crc32c = crc32_impl(0, (const char*)buffer, size);
    }
    else
    {
        blake3_hasher hasher;
        blake3_hasher_init(&hasher);
        blake3_hasher_update(&hasher, (const void *)buffer, size);
        blake3_hasher_finalize(&hasher, (uint8_t*)&fileInfo.checksum.blake3, 8);
    }
}

static inline void compute_file_checksum(const std::string &path, FileInfo &info)
{
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0)
    {
        // TODO: log error
        return;
    }

    // 16 MB is the mmap threshold - TODO: experiment with different thresholds
    const size_t MMAP_THRESHOLD = 16 * 1024 * 1024;
    
    if ((info.size < MMAP_THRESHOLD) && (info.size > 0))
    {
        void* buffer = malloc(info.size);
        if (buffer != nullptr)
        {
            if (read(fd, buffer, info.size) == (ssize_t)info.size)
            {
                compute_buffer_checksum(buffer, info.size, info);
            }
            free(buffer);
        }
    }
    else if (info.size >= MMAP_THRESHOLD)
    {
        // Large files: mmap + madvise
        void* map = mmap(nullptr, info.size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map != MAP_FAILED)
        {
            madvise(map, info.size, MADV_SEQUENTIAL);
            compute_buffer_checksum(map, info.size, info);
            munmap(map, info.size);
        }
    }
    // else size == 0: checksum remains 0 (correct for empty file)

    close(fd);

//    std::cout << '\t' << path << "\t CRC32: " << fileInfo.crc32 << '\n';
}


static inline void write_fileinfo_xattr(const std::string& path, const FileInfo& info) noexcept
{
    errno = 0; //clear any potetnially lingering errors from previous operation
    
    const char* xattrName = (g_hash == HashAlgorithm::CRC32C) ? kCrc32CXattrName : kBlake3XattrName;
    
    int ret = ::setxattr(path.c_str(),
                       xattrName,
                       &info,
                       sizeof(info),
                       0,              // position (ignored)
                       XATTR_NOFOLLOW); // or 0 to not follow symlinks
    
    if (ret != 0)
    {
        // optional: log error, but ignore in release
        int err = errno;
        std::cerr << "setxattr failed ret = " << ret << " errno = " << err << " for " << path << '\n';
    }
    else
    {
        int err = errno;
        if(err != 0)
        {
            std::cerr << "setxattr returned 0 but failed with errno = " << err << " for " << path << '\n';
        }
    }
}

static inline bool file_changed(const std::string& path, const FileInfo& current) noexcept
{
    FileInfo cached{};
    const char* xattrName = (g_hash == HashAlgorithm::CRC32C) ? kCrc32CXattrName : kBlake3XattrName;
    ssize_t ret = getxattr(path.c_str(), xattrName, &cached, sizeof(cached), 0, XATTR_NOFOLLOW);

    if (ret != sizeof(cached))
    {
        return true;                      // no xattr or wrong size, we need to recompute
    }

    return cached.inode    != current.inode ||
           cached.size     != current.size ||
           cached.mtime_ns != current.mtime_ns;
}

static inline void add_file_path_and_info(std::string path, FileInfo info)
{
    dispatch_queue_t shared_container_mutation_queue = get_shared_container_mutation_queue();
    dispatch_group_t task_group = get_all_tasks_group();
    
    // shared_container_mutation_queue is a serial queue, allowing only one task at a time
    dispatch_group_async(task_group, shared_container_mutation_queue, ^{
        if (is_exiting()) { return; }

        try
        {
            s_all_matched_files.emplace_back(std::move(path), std::move(info));
        }
        catch (const std::exception& e)
        {
            std::cerr << "operation failed with exception:" << e.what() << '\n';
            s_result = EXIT_FAILURE;
        }
    });

}

// ─────────────────────────────────────────────────────────────────────────────
//  Core per-file processing
// ─────────────────────────────────────────────────────────────────────────────
static void process_regular_file(FTSENT* ent) noexcept
{
    if (ent == nullptr || ent->fts_statp == nullptr)
    {
        // Should never happen with FTS_LOGICAL | FTS_NOCHDIR and no FTS_NOSTAT
        std::cerr << "fts error on: " << ent->fts_path << " ent=" << ent << " ent->fts_statp = " << ent->fts_statp << '\n';
        return;
    }

    FileInfo info(*ent);
    std::string path = ent->fts_path;

    dispatch_group_t task_group = get_all_tasks_group();

    dispatch_group_async(task_group, get_cpu_gate_queue(), ^{
        dispatch_semaphore_t cpu_limit_semaphore = get_concurrency_semaphore();
        dispatch_semaphore_wait(cpu_limit_semaphore, DISPATCH_TIME_FOREVER);

        dispatch_group_async(task_group, get_file_processing_queue(), ^{
            FileInfo fileInfo = info;

            const bool needs_hash = !g_use_xatrr_optimization ||
                                    file_changed(path, fileInfo);

            if (needs_hash)
            {
                compute_file_checksum(path, fileInfo);
                if (g_use_xatrr_optimization)
                {
                    write_fileinfo_xattr(path, fileInfo);
                }
            }

            add_file_path_and_info(std::move(path), std::move(fileInfo));
            dispatch_semaphore_signal(cpu_limit_semaphore);
        });
    });
}


// fts_read() is a solid choice for directory traversal
// for crawling with retrival of additonal file attributes
// and it does not require recursion in client code so stack depletion is not an issue
// Good discussion with source code and perf measurements is here:
// https://blog.tempel.org/2019/04/dir-read-performance.html

int
fingerprint::find_files_internal(std::string search_dir,
                                 const std::vector<GlobPattern> &compiled_globs) noexcept
{
    assert(search_dir.size() > 0);
    
    if (is_exiting()) {
        s_result = EXIT_FAILURE;
        return s_result;
    }

    // Remove possible trailing slash – makes relative-path calculation safe
    if (!search_dir.empty() && search_dir.back() == '/')
        search_dir.pop_back();

    struct timeval time_start;
    struct timeval time_end;
    ::gettimeofday(&time_start, nullptr);

    char *paths[2] = {const_cast<char*>(search_dir.c_str()), nullptr};
    FTS *fts = fts_open(paths, FTS_LOGICAL | FTS_NOCHDIR, nullptr);
    if (!fts) {
        std::cerr << "fts_open failed for: " << search_dir << '\n';
        s_result = EXIT_FAILURE;
        return s_result;
    }

    int result = 0;
    FTSENT *ent;
    while ((ent = fts_read(fts)) != nullptr) {
        if (is_exiting()) { result = EXIT_FAILURE; break; }

        switch (ent->fts_info) {
            case FTS_D:  // pre-order directory
                break;

            case FTS_F:  // regular file
            {
                // No glob filtering
                if (compiled_globs.empty())
                {
                    process_regular_file(ent);
                    break;
                }

                // Relative path starting right after the base directory
                const char* relative_path = ent->fts_path + search_dir.length();
                if (*relative_path == '/') ++relative_path;

                if (matches_any_glob(relative_path, compiled_globs))
                {
                    process_regular_file(ent);
                }
            }
            break;

            case FTS_ERR:
            case FTS_DNR:
                std::cerr << "fts error on: " << ent->fts_path << " errno=" << ent->fts_errno << '\n';
                result = ent->fts_errno ? ent->fts_errno : EXIT_FAILURE;
                break;

            default:
                break;
        }
    }

    fts_close(fts);
    
    ::gettimeofday(&time_end, nullptr);
    g_traversal_time = (double)time_end.tv_sec + (double)time_end.tv_usec/(1000.0 * 1000.0) -
                       ((double)time_start.tv_sec + (double)time_start.tv_usec/(1000.0 * 1000.0));

    if (result != 0) { s_result = result; }
    
    return result;
}


void
fingerprint::wait_for_all_tasks() noexcept
{
    dispatch_group_wait(get_all_tasks_group(), DISPATCH_TIME_FOREVER);
}

// file paths usually are more diverse at the end than the beginning
// esitmate is 40-60% less comparison work needed if we sort with reverse comparator

struct ReversePathComparator
{
    bool operator()(const std::string& a, const std::string& b) const
    {
        size_t i = a.size();
        size_t j = b.size();

        while (i > 0 && j > 0)
        {
            if (a[--i] != b[--j])
            {
                return a[i] < b[j];
            }
        }
        return i > 0;  // a longer than b with common suffix → a > b
    }
};



uint64_t
fingerprint::sort_and_compute_fingerprint() noexcept
{
    std::sort(s_all_matched_files.begin(), s_all_matched_files.end(), [](const auto& x, const auto& y) {
        return ReversePathComparator{}(x.first, y.first);
    });

    blake3_hasher hasher;
    blake3_hasher_init(&hasher);

    if (g_hash == HashAlgorithm::CRC32C)
    {
        for (const auto& [path, info] : s_all_matched_files)
        {
            blake3_hasher_update(&hasher, &info.checksum.crc32c, sizeof(info.checksum.crc32c));
        }
    }
    else
    {
        for (const auto& [path, info] : s_all_matched_files)
        {
            blake3_hasher_update(&hasher, &info.checksum.blake3, sizeof(info.checksum.blake3));
        }
    }

    uint8_t output[8] = {0};
    blake3_hasher_finalize(&hasher, output, sizeof(output));

    return *(const uint64_t*)output;  // 64-bit fingerprint
}
