//
//  fingerprint.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/8/25.
//

#include <iostream>
#include <filesystem>
#include <fstream>
#include <memory>
#include <regex>
#include <ctime>
#include <map>
#include <unordered_map>

#include <CoreFoundation/CoreFoundation.h>

#include <assert.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <sys/attr.h>
#include <sys/xattr.h>

#include "GlobOverlap.h"
#include "GlobSearch.h"

#include "blake3.h"

#include "fingerprint.h"
#include "FileInfo.h"
#include "dispatch_queues_helper.h"
#include "json_serialization.h"
#include "yyjson.hpp"
#include "CFObj.h"
#include "CFType.h"
#include "CFStr.h"
#include "CFArr.h"
#include "CFDict.h"

extern "C" uint32_t crc32_impl(uint32_t crc0, const char* buf, size_t len);

extern FileHashAlgorithm g_hash;
extern XattrMode g_xattr_mode;

extern bool g_verbose;
extern double g_traversal_time;

std::atomic_bool s_exiting = false;
std::atomic_int s_result = EXIT_SUCCESS;

static constexpr const char* kCrc32CXattrName = "public.fingerprint.crc32c";
static constexpr const char* kBlake3XattrName = "public.fingerprint.blake3";

// this is a shared container that must be mutated only on serial shared_container_mutation_queue
static std::vector<std::pair<std::string, FileInfo>> s_all_matched_files;

// this is a shared container for search directories that must be mutated only on serial shared_container_mutation_queue
static std::unordered_set<std::string> s_search_bases;

void
fingerprint::set_exiting() noexcept
{
    s_exiting = true;
}

static inline __attribute__((always_inline))
bool is_exiting() noexcept
{
    return s_exiting;
}

int
fingerprint::get_result() noexcept
{
    return s_result;
}

void
fingerprint::reset() noexcept
{
    s_all_matched_files.clear();
    s_search_bases.clear();
    s_exiting = false;
    s_result = EXIT_SUCCESS;
}

static bool path_exists_literal(const std::string& path) noexcept
{
    if (path.empty())
        return false;

    struct stat st{};
    return lstat(path.c_str(), &st) == 0;
}

static std::vector<std::string> split_path_components(const std::string& path) noexcept
{
    std::vector<std::string> components;
    if (path.empty()) return components;

    size_t start = 0;
    if (path[0] == '/') {
        components.emplace_back("");
        start = 1;
    }

    size_t pos;
    while ((pos = path.find('/', start)) != std::string::npos) {
        if (pos > start) {
            components.emplace_back(path.substr(start, pos - start));
        }
        start = pos + 1;
    }
    if (start < path.length()) {
        components.emplace_back(path.substr(start));
    }
    return components;
}

static inline __attribute__((always_inline))
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

static inline __attribute__((always_inline))
void compute_file_hash(const std::string &path, FileInfo &info)
{
    // Don't try to read non-existent files
    if (info.is_nonexistent())
    {
        return; // Sentinel value already set
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
        }
        else
        {
            // Failed to read symlink - leave hash as 0
            if (g_verbose)
            {
                std::cerr << "Warning: failed to read symlink: " << path << '\n';
            }
        }
        return;
    }
    
    // Regular file processing
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
        std::unique_ptr<char, decltype(&free)> buffer(
            static_cast<char*>(malloc(info.size)), free);
        if (buffer != nullptr)
        {
            if (read(fd, buffer.get(), info.size) == (ssize_t)info.size)
            {
                compute_buffer_hash(buffer.get(), info.size, info);
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
        }
    }
    // else size == 0: hash remains 0 (correct for empty file)

    close(fd);
}

// returns true if file info stored in xattr is the same as current iteration info & stores the hash in appropriate current_file_info.hash
// returns false if file info does not match or xattr cannot be read
static inline __attribute__((always_inline))
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


static inline __attribute__((always_inline))
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
    
    int xattr_result = ::setxattr(path.c_str(),
                       xattrName,
                       &info,
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
        // optional: log error, but ignore in release
        std::cerr << "setxattr failed result = " << xattr_result << " errno = " << err << " for " << path << '\n';
    }
    else if(err != 0)
    {
        std::cerr << "setxattr returned 0 but failed with errno = " << err << " for " << path << '\n';
    }
}

static inline __attribute__((always_inline))
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
        // optional: log error, but ignore in release
        std::cerr << "removexattr failed result = " << xattr_result << " errno = " << err << " for " << path << '\n';
    }
    else if(err != 0)
    {
        std::cerr << "removexattr returned 0 but failed with errno = " << err << " for " << path << '\n';
    }
}

static inline __attribute__((always_inline))
void add_to_matched_files(std::string path, FileInfo info)
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


static void process_matched_file_async(std::string path, FileInfo info) noexcept
{
    dispatch_group_t task_group = get_all_tasks_group();

    dispatch_group_async(task_group, get_cpu_gate_queue(), ^{
        dispatch_semaphore_t cpu_limit_semaphore = get_concurrency_semaphore();
        dispatch_semaphore_wait(cpu_limit_semaphore, DISPATCH_TIME_FOREVER);

        dispatch_group_async(task_group, get_file_processing_queue(), ^{
            
            FileInfo fileInfo = info;

            bool needs_hash = true;
            bool write_xattr = false;

            if (g_xattr_mode == XattrMode::Clear)
            {
                clear_xattr_fileinfo(path, fileInfo);
                // force recompute, don't write
            }
            else if (g_xattr_mode == XattrMode::On)
            {
                // Only here do we try to read and possibly skip hashing
                bool cache_hit = read_xattr_fileinfo(path, fileInfo);
                if (cache_hit)
                {
                    needs_hash = false;
                    write_xattr = false;  // nothing to do
                }
                else
                {
                    needs_hash = true;
                    write_xattr = true;   // cache miss, compute and store
                }
            }
            else if (g_xattr_mode == XattrMode::Refresh)
            {
                // Force recompute, write result back
                needs_hash = true;
                write_xattr = true;
            }
            else // Off
            {
                needs_hash = true;
                write_xattr = false;
            }

            if (needs_hash)
            {
                compute_file_hash(path, fileInfo);
            }

            if (write_xattr)
            {
                write_xattr_fileinfo(path, fileInfo);
            }
            
            add_to_matched_files(std::move(path), std::move(fileInfo));
            dispatch_semaphore_signal(cpu_limit_semaphore);
        });
    });
}

static void process_matched_file(const std::string &path, struct stat *statp) noexcept
{
    if (statp == nullptr)
    {
        std::cerr << "null stat ptr for: " << path << '\n';
        return;
    }

    FileInfo info(*statp);
    process_matched_file_async(path, std::move(info));
}

// Process pre-constructed FileInfo entries for individual files
// expected to be called on directory_traversal_queue
void
fingerprint::process_files_internal(const std::vector<std::pair<std::string, FileInfo>>& files) noexcept
{
    if (files.empty())
    {
        return;
    }
    
    for (const auto& [path, info] : files)
    {
        if (is_exiting()) { break; }
        
        process_matched_file_async(path, info);
    }
}


// Resolve symlink chain, detect cycles, return all paths with their FileInfo
// Assumes 'start' is already absolute and normalized
static std::unordered_map<std::string, FileInfo>
resolve_symlink_chain(const std::filesystem::path& start) noexcept
{
    std::unordered_map<std::string, FileInfo> result;

    std::filesystem::path current = start;

    // Skip the first path — we start resolving from its target
    while (true)
    {
        // Read the symlink target (must be a symlink at this point)
        std::error_code ec;
        std::filesystem::path target = std::filesystem::read_symlink(current, ec);
        if (ec)
        {
            if (g_verbose)
                std::cerr << "Warning: cannot read symlink target: " << current << '\n';
            break;
        }

        // Resolve next path
        std::filesystem::path next = target.is_absolute() ? target.lexically_normal() : (current.parent_path() / target).lexically_normal();
        std::string next_str = next.string();

        // Cycle detection
        if (result.contains(next_str))
        {
            if (g_verbose)
                std::cerr << "Warning: Circular symlink detected at " << next << "\n";
            break;
        }

        // lstat the *next* path in chain
        struct stat st{};
        if (lstat(next_str.c_str(), &st) != 0)
        {
            if (g_verbose)
                std::cerr << "Broken symlink in chain: " << next << " (does not exist)\n";
            FileInfo info;
            info.mark_as_nonexistent();
            result.emplace(next_str, std::move(info));
            break;
        }

        FileInfo info(st);
        result.emplace(next_str, std::move(info));

        if (!S_ISLNK(st.st_mode))
        {
            break;  // Final target reached
        }

        current = std::move(next);
    }

    return result;
}

static inline __attribute__((always_inline))
bool is_path_under_directory(const std::string& start_dir, const std::string& path) noexcept
{
    std::filesystem::path dir(start_dir);
    std::filesystem::path file(path);
    
    // Get relative path from dir to file
    auto rel = file.lexically_relative(dir);
    
    // Valid if relative path exists and doesn't escape upward
    return !rel.empty() && !rel.native().starts_with("..");
}

// Main entry point - separates directories from files
int
fingerprint::find_and_process_paths(const std::unordered_set<std::string>& paths,
                                    const std::unordered_set<std::string>& glob_patterns,
                                    const std::unordered_set<std::string>& regex_patterns,
                                    const std::unordered_set<std::string>& exclude_patterns) noexcept
{
    dispatch_queue_t directory_traversal_queue = get_directory_traversal_queue();
    dispatch_group_t task_group = get_all_tasks_group();

    // Collect files with their FileInfo for batch processing
    std::vector<std::pair<std::string, FileInfo>> files;

    // Get current directory once for all relative path resolution
    std::error_code ec;
    std::filesystem::path base = std::filesystem::current_path(ec);
    if (ec)
    {
        std::cerr << "Error: cannot get current directory: " << ec.message() << '\n';
        s_result = EXIT_FAILURE;
        return s_result;
    }

    CompiledExcludes compiled_excludes = compile_excludes(exclude_patterns);

    // Resolve and normalize all paths
    for (const auto& input : paths)
    {
        std::filesystem::path p = input;
        std::filesystem::path abs_clean = p.is_absolute() ? p.lexically_normal() : (base / p).lexically_normal();
        std::string abs_str = abs_clean.string();
        // lexically_normal can leave a trailing '/' (e.g. from "/path/." → "/path/");
        // strip it so the string matches FTS-produced paths.
        while (abs_str.size() > 1 && abs_str.back() == '/') abs_str.pop_back();

        // Use abs_str as search_dir for relative exclude pattern matching
        if (is_path_excluded(abs_str.c_str(), compiled_excludes, abs_str.c_str()))
        {
            if (g_verbose)
                std::cerr << "Skipping excluded input: " << abs_str << '\n';
            continue;
        }

        // Now categorize the resolved path
        struct stat st;
        if (lstat(abs_clean.c_str(), &st) == 0)
        {
            if (S_ISDIR(st.st_mode))
            {
                // Dispatch directory traversal immediately
                std::string dir_path = abs_str;
                dispatch_group_async(task_group, directory_traversal_queue, ^{
                    if (is_exiting()) { return; }
                    __unused int find_result = find_files_internal(dir_path, glob_patterns, regex_patterns, exclude_patterns);
                });
            }
            else if (S_ISLNK(st.st_mode))
            {
                // add symlink itself
                FileInfo info(st);
                files.emplace_back(abs_str, std::move(info));

                // resolve the entire symlink chain
                auto chain = resolve_symlink_chain(abs_clean);

                // Process each entry in the chain
                for (auto& [path, info] : chain)
                {
                    // Use abs_str (the original path) as search_dir for relative matching
                    if (is_path_excluded(path.c_str(), compiled_excludes, abs_str.c_str()))
                        continue;

                    if (info.is_directory())
                    {
                        // Found a directory in the chain - dispatch for traversal
                        if (g_verbose)
                        {
                            std::cerr << "Symlink chain leads to directory: " << path << '\n';
                        }
                        std::string dir_path = path;  // Copy the path for capture
                        dispatch_group_async(task_group, directory_traversal_queue, ^{
                            if (is_exiting()) { return; }
                            __unused int find_result = find_files_internal(dir_path, glob_patterns, regex_patterns, exclude_patterns);
                        });
                    }
                    else
                    {
                        // Regular file, symlink, or non-existent - add to files
                        files.emplace_back(path, std::move(info));
                    }
                }

                if (g_verbose && chain.size() > 1)
                {
                    std::cerr << "Resolved symlink chain of length " << chain.size()
                              << " starting at: " << abs_clean << '\n';
                }
            }
            else if (S_ISREG(st.st_mode))
            {
                // Regular file - construct FileInfo from stat structure
                FileInfo info(st);
                files.emplace_back(abs_str, std::move(info));
            }
            else
            {
                std::cerr << "Warning: skipping non-regular file/directory: " << abs_clean << '\n';
            }
        }
        else
        {
            // Path doesn't exist - create FileInfo with sentinel value
            if (g_verbose)
            {
                std::cerr << "Warning: path does not exist, treating as non-existent file: "
                          << abs_clean << '\n';
            }
            FileInfo info;
            info.mark_as_nonexistent();
            files.emplace_back(abs_str, std::move(info));
        }
    }
    
    // Dispatch all files as a single block
    if (!files.empty())
    {
        dispatch_group_async(task_group, directory_traversal_queue, ^{
            if (is_exiting()) { return; }
            process_files_internal(files);
        });
    }
    
    return s_result;
}


int
fingerprint::find_and_process_globbed_paths(const std::unordered_set<std::string>& paths,
                                             const std::unordered_set<std::string>& exclude_patterns) noexcept
{
    if (paths.empty())
        return EXIT_SUCCESS;

    std::unordered_set<std::string> plain_paths;
    std::unordered_map<std::string, std::unordered_set<std::string>> dir_to_globs;

    std::error_code ec;
    std::filesystem::path base = std::filesystem::current_path(ec);
    if (ec)
    {
        std::cerr << "Error: cannot get current directory: " << ec.message() << '\n';
        s_result = EXIT_FAILURE;
        return s_result;
    }

    for (const auto& path : paths)
    {
        if (is_exiting()) return s_result;

        if (path_exists_literal(path))
        {
            // Literal path exists: it is plain file/dir/symlink (even if name contains * ? [)
            plain_paths.insert(path);
            continue;
        }

        if (!globoverlap::contains_glob_pattern_char(path))
        {
            // No glob characters and does not exist
            std::cerr << "error: declared file does not exist: " << path << '\n';
            s_result = EXIT_FAILURE;
            return EXIT_FAILURE;
        }

        // === Glob case: split and verify the directory prefix exists ===
        if (g_verbose)
            std::cerr << "gate: treating as glob pattern: " << path << '\n';

        auto components = split_path_components(path);
        if (components.empty()) continue;

        bool is_absolute = !components.empty() && components[0].empty();
        size_t split_idx = is_absolute ? 1 : 0;

        while (split_idx < components.size())
        {
            if (globoverlap::contains_glob_pattern_char(components[split_idx]))
                break;
            ++split_idx;
        }

        if (split_idx == components.size())
        {
            plain_paths.insert(path);
            continue;
        }

        // Build literal directory prefix
        std::string dir_part;
        if (is_absolute)
        {
            dir_part = "/";
            for (size_t i = 1; i < split_idx; ++i)
            {
                dir_part += components[i];
                if (i + 1 < split_idx) dir_part += "/";
            }
        }
        else
        {
            for (size_t i = 0; i < split_idx; ++i)
            {
                dir_part += components[i];
                if (i + 1 < split_idx) dir_part += "/";
            }
        }

        if (dir_part.empty())
            dir_part = is_absolute ? "/" : ".";

        // CRITICAL: the base directory for the glob MUST exist
        if (!path_exists_literal(dir_part))
        {
            std::cerr << "error: glob base directory does not exist: " << dir_part 
                      << " (from pattern: " << path << ")\n";
            s_result = EXIT_FAILURE;
            return EXIT_FAILURE;
        }

        // Build glob part
        std::string glob_part;
        for (size_t i = split_idx; i < components.size(); ++i)
        {
            if (!glob_part.empty()) glob_part += "/";
            glob_part += components[i];
        }
        
        bool is_well_formed_pattern = globoverlap::is_glob_pattern(glob_part);
        if (!is_well_formed_pattern)
        {
            std::cerr << "error: malformed glob pattern: " << glob_part << "\n";
            s_result = EXIT_FAILURE;
            return EXIT_FAILURE;
        }
        
        std::filesystem::path p_dir(dir_part);
        std::filesystem::path abs_dir = p_dir.is_absolute()
            ? p_dir.lexically_normal()
            : (base / p_dir).lexically_normal();

        dir_to_globs[abs_dir.string()].insert(std::move(glob_part));
    }

    // Plain paths
    if (!plain_paths.empty())
    {
        __unused int plain_result = find_and_process_paths(plain_paths, {}, {}, exclude_patterns);
    }

    // Glob paths
    if (!dir_to_globs.empty())
    {
        dispatch_queue_t directory_traversal_queue = get_directory_traversal_queue();
        dispatch_group_t task_group = get_all_tasks_group();

        for (const auto& [search_dir_ref, globs_ref] : dir_to_globs)
        {
            if (is_exiting()) break;

            std::string search_dir = search_dir_ref;
            std::unordered_set<std::string> globs = globs_ref;
            std::unordered_set<std::string> excludes = exclude_patterns;

            dispatch_group_async(task_group, directory_traversal_queue, ^{
                if (is_exiting()) return;
                __unused int find_result = find_files_internal(search_dir, globs, {}, excludes);
            });
        }
    }

    return s_result;
}

// fts_read() is a solid choice for directory traversal —
// iterative, no stack-depth risk, exposes stat without a second syscall.
// https://blog.tempel.org/2019/04/dir-read-performance.html

int
fingerprint::find_files_internal(std::string search_dir,
                                 const std::unordered_set<std::string>& glob_patterns,
                                 const std::unordered_set<std::string>& regex_patterns,
                                 const std::unordered_set<std::string>& exclude_patterns) noexcept
{
    assert(search_dir.size() > 0);

    if (is_exiting())
    {
        s_result = EXIT_FAILURE;
        return s_result;
    }

    // Remove possible trailing slash – makes relative-path calculation safe
    if (!search_dir.empty() && search_dir.back() == '/')
        search_dir.pop_back();

    // Skip the entire walk if the search root itself is excluded
    CompiledExcludes compiled_excludes = compile_excludes(exclude_patterns);
    if (is_path_excluded(search_dir.c_str(), compiled_excludes, search_dir.c_str()))
    {
        if (g_verbose)
            std::cerr << "Skipping excluded search dir: " << search_dir << '\n';
        return EXIT_SUCCESS;
    }

    // emplace returns {iterator, inserted}; if not inserted the dir is already being
    // walked by another concurrent call — bail out to break cross-directory symlink cycles.
    __block bool already_visited = false;
    dispatch_sync(get_shared_container_mutation_queue(), ^{
        already_visited = !s_search_bases.emplace(search_dir).second;
    });
    if (already_visited)
        return EXIT_SUCCESS;

    struct timeval time_start;
    struct timeval time_end;
    ::gettimeofday(&time_start, nullptr);

    std::vector<Glob> compiled_globs = compile_globs(glob_patterns);
    std::vector<Regex> compiled_regexes = compile_regexes(regex_patterns);

    // FTS_XDEV: stay on the same filesystem.
    // FTS_PHYSICAL: report symlinks as FTS_SL/FTS_SLNONE so we can resolve
    //               chains that lead outside search_dir ourselves.
    FileMatchedBlock on_match = ^(const char* abs_path, struct stat* statp) {
        process_matched_file(abs_path, statp);
    };

    std::vector<std::string> symlinks;
    int result = walk_directory(search_dir, compiled_globs, compiled_regexes,
                                compiled_excludes, on_match, &symlinks, FTS_XDEV);

    if (is_exiting())
        result = EXIT_FAILURE;

    // Follow symlink chains that lead outside search_dir.
    // compiled_excludes/compiled_globs are alive here (stack-local) — no block capture needed.
    for (const auto& sym_path_str : symlinks)
    {
        if (is_exiting())
        {
            result = EXIT_FAILURE;
            break;
        }

        auto chain = resolve_symlink_chain(std::filesystem::path(sym_path_str));

        for (auto& [path, info] : chain)
        {
            if (!is_path_under_directory(search_dir, path))
            {
                if (is_path_excluded(path.c_str(), compiled_excludes, search_dir.c_str()))
                    continue;

                if (info.is_directory())
                {
                    if (g_verbose)
                        std::cerr << "Symlink chain leads to directory: " << path << '\n';
                    std::string dir_path = path;
                    std::unordered_set<std::string> excludes_copy = exclude_patterns;
                    dispatch_group_async(get_all_tasks_group(), get_directory_traversal_queue(), ^{
                        if (is_exiting())
                            return;
                        __unused int r = find_files_internal(dir_path, glob_patterns,
                                                              regex_patterns, excludes_copy);
                    });
                }
                else
                {
                    if (compiled_globs.empty() || matches_any_glob(path.c_str(), compiled_globs))
                        process_matched_file_async(path, info);
                }
            }
        }
    }

    ::gettimeofday(&time_end, nullptr);
    g_traversal_time = (double)time_end.tv_sec + (double)time_end.tv_usec/(1000.0 * 1000.0) -
                       ((double)time_start.tv_sec + (double)time_start.tv_usec/(1000.0 * 1000.0));

    if (result != 0)
        s_result = result;
    
    return result;
}


void
fingerprint::wait_for_all_tasks() noexcept
{
    dispatch_group_wait(get_all_tasks_group(), DISPATCH_TIME_FOREVER);
}

static inline __attribute__((always_inline)) std::string get_path_for_fingerprint(const std::string& abs_path, FingerprintOptions options)
{
    if (options == FingerprintOptions::HashRelativePaths)
    {
        std::string best_rel;
        size_t best_len = 0;

        for (const auto& base : s_search_bases) {
            if (abs_path.starts_with(base) && base.size() > best_len) {
                std::string rel = abs_path.substr(base.size());
                if (!rel.empty() && rel[0] == '/')
                    rel.erase(0, 1);
                best_len = base.size();
                best_rel = std::move(rel);
            }
        }
        return best_rel.empty() ? abs_path : best_rel;
    }

    return abs_path; // fallback for HashAbsolutePaths or Default (which does not use it)
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
        return i > 0;  // a longer than b with common suffix: a > b
    }
};



uint64_t
fingerprint::sort_and_compute_fingerprint(FingerprintOptions fingerprintOptions) noexcept
{
    std::sort(s_all_matched_files.begin(), s_all_matched_files.end(), [](const auto& x, const auto& y) {
        return ReversePathComparator{}(x.first, y.first);
    });

    // Uncommon situation but in case of cross-symlinks
    // in multiple directories we searched individually we may end up with duplicates
    
    // Remove duplicates - keep first occurrence of each unique path
    // After sorting, duplicates will be adjacent
    auto last = std::unique(s_all_matched_files.begin(), s_all_matched_files.end(),
                           [](const auto& a, const auto& b) {
                               return a.first == b.first;  // Compare paths
                           });
    
    // Erase the duplicate entries
    if (last != s_all_matched_files.end())
    {
        size_t duplicate_count = std::distance(last, s_all_matched_files.end());
        if (g_verbose)
        {
            std::cerr << "Removed " << duplicate_count << " duplicate path(s)\n";
        }
        s_all_matched_files.erase(last, s_all_matched_files.end());
    }

    blake3_hasher hasher;
    blake3_hasher_init(&hasher);

    for (const auto& [path, info] : s_all_matched_files)
    {
        // Skip non-existent files with sentinel hashes
        if (info.inode == 0 && info.size == 0 && info.mtime_ns == 0)
            continue;

        // Include path only if requested
        if (fingerprintOptions != FingerprintOptions::Default)
        {
            std::string path_to_hash = get_path_for_fingerprint(path, fingerprintOptions);
            blake3_hasher_update(&hasher, path_to_hash.data(), path_to_hash.size() + 1); // +1 for trailing '\0'
        }

        if (g_hash == FileHashAlgorithm::CRC32C)
            blake3_hasher_update(&hasher, &info.hash.crc32c, sizeof(info.hash.crc32c));
        else
            blake3_hasher_update(&hasher, &info.hash.blake3, sizeof(info.hash.blake3));
    }
    
    uint8_t output[8] = {0};
    blake3_hasher_finalize(&hasher, output, sizeof(output));

    return *(const uint64_t*)output;
}

void fingerprint::list_matched_files() noexcept
{
    // Sort in natural forward order
    std::sort(s_all_matched_files.begin(), s_all_matched_files.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });

    std::string out;
    out.reserve(s_all_matched_files.size() * 128); // a guestimate of max chars per line

    for (const auto& [path, info] : s_all_matched_files)
    {
        if (info.is_nonexistent()) continue;

        char line[PATH_MAX + 64];
        int len;

        if (g_hash == FileHashAlgorithm::CRC32C)
            len = std::snprintf(line, sizeof(line), "%08x\t%s\n",
                                info.hash.crc32c, path.c_str());
        else
            len = std::snprintf(line, sizeof(line), "%016llx\t%s\n",
                                (unsigned long long)info.hash.blake3, path.c_str());

        out.append(line, len);
    }

    std::fwrite(out.data(), 1, out.size(), stdout);
}

static CFMutableDict load_tsv_as_cfdict(const std::string& path) noexcept
{
    std::ifstream infile(path);
    if (infile.fail())
    {
        std::cerr << "Error: cannot open snapshot file: " << path << "\n";
        return {};
    }

    CFMutableDict root_dict;
    {
        CFMutableDict params_dict;
        root_dict.SetValue(CFSTR("fingerprint_params"), (CFMutableDictionaryRef)params_dict);
    }

    CFMutableArr files_arr;

    std::string line;
    bool first_line = true;
    while (std::getline(infile, line))
    {
        if (line.empty()) continue;

        if (first_line)
        {
            first_line = false;
            continue;
        }

        size_t tab1 = line.find('\t');
        size_t tab2 = line.find('\t', tab1 + 1);
        size_t tab3 = line.find('\t', tab2 + 1);
        size_t tab4 = line.find('\t', tab3 + 1);
        size_t tab5 = line.find('\t', tab4 + 1);

        if (tab1 == std::string::npos || tab2 == std::string::npos || tab3 == std::string::npos ||
            tab4 == std::string::npos || tab5 == std::string::npos)
            continue;

        CFMutableDict file_dict;

        file_dict.SetValue(CFSTR("path"), CFStr(line.substr(0, tab1)));
        file_dict.SetValue(CFSTR("hash"), CFStr(line.substr(tab1 + 1, tab2 - tab1 - 1)));
        file_dict.SetValue(CFSTR("size"), (int64_t)std::stoll(line.substr(tab2 + 1, tab3 - tab2 - 1)));
        file_dict.SetValue(CFSTR("inode"), (int64_t)std::stoull(line.substr(tab3 + 1, tab4 - tab3 - 1)));
        file_dict.SetValue(CFSTR("mtime_ns"), (int64_t)std::stoll(line.substr(tab4 + 1, tab5 - tab4 - 1)));
        file_dict.SetValue(CFSTR("mode"), CFStr(line.substr(tab5 + 1)));

        files_arr.AppendValue(file_dict);
    }

    root_dict.SetValue(CFSTR("files"), (CFMutableArrayRef)files_arr);

    return root_dict;
}

static void compare_metadata(CFDictionaryRef snap1, CFDictionaryRef snap2, FileHashAlgorithm& hash_algorithm) noexcept;
static bool compare_files(CFDictionaryRef snap1, CFDictionaryRef snap2, FileHashAlgorithm hash_algorithm) noexcept;

int fingerprint::compare_snapshots(const std::string& path1, const std::string& path2) noexcept
{
    CFObj<CFMutableDictionaryRef> snap1(load_snapshot(path1));
    if (snap1 == nullptr)
        return EXIT_FAILURE;

    CFObj<CFMutableDictionaryRef> snap2(load_snapshot(path2));
    if (snap2 == nullptr)
        return EXIT_FAILURE;

    FileHashAlgorithm hash_algorithm = FileHashAlgorithm::UNKNOWN;
    compare_metadata(snap1, snap2, hash_algorithm);
    bool found_diff = compare_files(snap1, snap2, hash_algorithm);

    return found_diff ? EXIT_FAILURE : EXIT_SUCCESS;
}

int fingerprint::save_snapshot_tsv(const std::string& path, const SnapshotMetadata& metadata) noexcept
{
    if (path.empty())
    {
        std::cerr << "Error: snapshot path is empty\n";
        return EXIT_FAILURE;
    }

    std::sort(s_all_matched_files.begin(), s_all_matched_files.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });

    std::string out;
    out.reserve(s_all_matched_files.size() * 128);

    const char* hash_column = (g_hash == FileHashAlgorithm::CRC32C) ? "crc32c" : "blake3";
    out += "path\t";
    out += hash_column;
    out += "\tsize\tinode\tmtime_ns\tmode\n";

    for (const auto& [file_path, info] : s_all_matched_files)
    {
        if (info.is_nonexistent()) continue;

        char line[PATH_MAX + 128];
        int len;

        char hash_hex[32];
        if (g_hash == FileHashAlgorithm::CRC32C)
            std::snprintf(hash_hex, sizeof(hash_hex), "%08x", info.hash.crc32c);
        else
            std::snprintf(hash_hex, sizeof(hash_hex), "%016llx", (unsigned long long)info.hash.blake3);

        char mode_hex[16];
        std::snprintf(mode_hex, sizeof(mode_hex), "%04o", info.mode & 07777);

        len = std::snprintf(line, sizeof(line), "%s\t%s\t%lld\t%llu\t%lld\t%s\n",
                            file_path.c_str(), hash_hex,
                            (long long)info.size, (unsigned long long)info.inode,
                            (long long)info.mtime_ns, mode_hex);

        out.append(line, len);
    }

    std::ofstream outfile(path, std::ios::out | std::ios::binary);
    if (outfile.fail())
    {
        std::cerr << "Error: cannot open snapshot file for writing: " << path << "\n";
        return EXIT_FAILURE;
    }

    outfile.write(out.data(), out.size());
    if (outfile.fail())
    {
        std::cerr << "Error: failed to write snapshot file: " << path << "\n";
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

// Build a CFMutableArr of CFStrings from a vector
static CFMutableArr cfarray_from_strings(const std::vector<std::string>& vec) noexcept
{
    CFMutableArr arr((CFIndex)vec.size());
    for (const auto& s : vec)
        arr.AppendValue(CFStr(s));
    return arr;
}

static CFMutableDict build_snapshot_dictionary(const SnapshotMetadata& metadata) noexcept
{
    CFMutableDict root_dict;
    CFMutableDict params_dict;

    params_dict.SetValue(CFSTR("input_paths"),     cfarray_from_strings(metadata.input_paths));
    params_dict.SetValue(CFSTR("glob_patterns"),   cfarray_from_strings(metadata.glob_patterns));
    params_dict.SetValue(CFSTR("regex_patterns"),  cfarray_from_strings(metadata.regex_patterns));
    params_dict.SetValue(CFSTR("exclude_patterns"), cfarray_from_strings(metadata.exclude_patterns));

    CFStringRef hash_algo = (metadata.hash_algorithm == FileHashAlgorithm::CRC32C) ?
        CFSTR("crc32c") : CFSTR("blake3");
    params_dict.SetValue(CFSTR("hash_algorithm"), hash_algo);

    CFStringRef fp_mode = CFSTR("default");
    switch (metadata.fingerprint_mode)
    {
        case FingerprintOptions::HashAbsolutePaths: fp_mode = CFSTR("absolute"); break;
        case FingerprintOptions::HashRelativePaths: fp_mode = CFSTR("relative"); break;
        default: fp_mode = CFSTR("default"); break;
    }
    params_dict.SetValue(CFSTR("fingerprint_mode"), fp_mode);

    char fp_hex[32];
    std::snprintf(fp_hex, sizeof(fp_hex), "%016llx", (unsigned long long)metadata.fingerprint);
    params_dict.SetValue(CFSTR("fingerprint"), CFStr(std::string_view(fp_hex)));

    if (!metadata.snapshot_timestamp.empty())
        params_dict.SetValue(CFSTR("snapshot_timestamp"), CFStr(metadata.snapshot_timestamp));

    root_dict.SetValue(CFSTR("fingerprint_params"), (CFMutableDictionaryRef)params_dict);

    CFMutableArr files_arr((CFIndex)s_all_matched_files.size());
    for (const auto& [file_path, info] : s_all_matched_files)
    {
        if (info.is_nonexistent()) continue;

        CFMutableDict file_dict;
        file_dict.SetValue(CFSTR("path"), CFStr(file_path));

        char hash_hex[32];
        if (g_hash == FileHashAlgorithm::CRC32C)
            std::snprintf(hash_hex, sizeof(hash_hex), "%08x", info.hash.crc32c);
        else
            std::snprintf(hash_hex, sizeof(hash_hex), "%016llx", (unsigned long long)info.hash.blake3);
        file_dict.SetValue(CFSTR("hash"), CFStr(std::string_view(hash_hex)));

        file_dict.SetValue(CFSTR("inode"),    (int64_t)info.inode);
        file_dict.SetValue(CFSTR("size"),     (int64_t)info.size);
        file_dict.SetValue(CFSTR("mtime_ns"), (int64_t)info.mtime_ns);

        char mode_hex[16];
        std::snprintf(mode_hex, sizeof(mode_hex), "%04o", info.mode & 07777);
        file_dict.SetValue(CFSTR("mode"), CFStr(std::string_view(mode_hex)));

        files_arr.AppendValue(file_dict);
    }

    root_dict.SetValue(CFSTR("files"), (CFMutableArrayRef)files_arr);

    return root_dict;
}

// Parallel JSON builder: emits the same shape as build_snapshot_dictionary,
// but directly into a yyjson MutableDoc — bypassing CFDictionary entirely.
static void build_snapshot_json(const SnapshotMetadata& metadata, Json::MutableDoc& doc) noexcept
{
    auto arr_from_strings = [&](const std::vector<std::string>& vec) {
        Json::MutableVal arr = doc.new_arr();
        for (const auto& s : vec)
            doc.arr_append(arr, doc.new_str(s));
        return arr;
    };

    Json::MutableVal root = doc.new_obj();

    Json::MutableVal params = doc.new_obj();
    doc.obj_add(params, "input_paths",      arr_from_strings(metadata.input_paths));
    doc.obj_add(params, "glob_patterns",    arr_from_strings(metadata.glob_patterns));
    doc.obj_add(params, "regex_patterns",   arr_from_strings(metadata.regex_patterns));
    doc.obj_add(params, "exclude_patterns", arr_from_strings(metadata.exclude_patterns));

    const char* hash_algo = (metadata.hash_algorithm == FileHashAlgorithm::CRC32C) ? "crc32c" : "blake3";
    doc.obj_add(params, "hash_algorithm", doc.new_str(hash_algo));

    const char* fp_mode = "default";
    switch (metadata.fingerprint_mode)
    {
        case FingerprintOptions::HashAbsolutePaths: fp_mode = "absolute"; break;
        case FingerprintOptions::HashRelativePaths: fp_mode = "relative"; break;
        default: fp_mode = "default"; break;
    }
    doc.obj_add(params, "fingerprint_mode", doc.new_str(fp_mode));

    char fp_hex[32];
    std::snprintf(fp_hex, sizeof(fp_hex), "%016llx", (unsigned long long)metadata.fingerprint);
    doc.obj_add(params, "fingerprint", doc.new_str(fp_hex));

    if (!metadata.snapshot_timestamp.empty())
        doc.obj_add(params, "snapshot_timestamp", doc.new_str(metadata.snapshot_timestamp));

    doc.obj_add(root, "fingerprint_params", params);

    Json::MutableVal files_arr = doc.new_arr();
    for (const auto& [file_path, info] : s_all_matched_files)
    {
        if (info.is_nonexistent()) continue;

        Json::MutableVal file_obj = doc.new_obj();
        doc.obj_add(file_obj, "path", doc.new_str(file_path));

        char hash_hex[32];
        if (g_hash == FileHashAlgorithm::CRC32C)
            std::snprintf(hash_hex, sizeof(hash_hex), "%08x", info.hash.crc32c);
        else
            std::snprintf(hash_hex, sizeof(hash_hex), "%016llx", (unsigned long long)info.hash.blake3);
        doc.obj_add(file_obj, "hash", doc.new_str(hash_hex));

        doc.obj_add(file_obj, "inode",    doc.new_sint((int64_t)info.inode));
        doc.obj_add(file_obj, "size",     doc.new_sint((int64_t)info.size));
        doc.obj_add(file_obj, "mtime_ns", doc.new_sint((int64_t)info.mtime_ns));

        char mode_oct[16];
        std::snprintf(mode_oct, sizeof(mode_oct), "%04o", info.mode & 07777);
        doc.obj_add(file_obj, "mode", doc.new_str(mode_oct));

        doc.arr_append(files_arr, file_obj);
    }
    doc.obj_add(root, "files", files_arr);

    doc.set_root(root);
}

int fingerprint::save_snapshot_plist(const std::string& path, const SnapshotMetadata& metadata) noexcept
{
    if (path.empty())
    {
        std::cerr << "Error: snapshot path is empty\n";
        return EXIT_FAILURE;
    }

    std::sort(s_all_matched_files.begin(), s_all_matched_files.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });

    CFMutableDict root_dict = build_snapshot_dictionary(metadata);

    CFErrorRef error = nullptr;
    CFObj<CFDataRef> plist_data(CFPropertyListCreateData(kCFAllocatorDefault, root_dict,
        kCFPropertyListBinaryFormat_v1_0, 0, &error));
    root_dict = nullptr;
    
    if (plist_data == nullptr)
    {
        std::cerr << "Error: failed to serialize plist: ";
        if (error != nullptr)
        {
            CFObj<CFStringRef> err_str(CFErrorCopyDescription(error));
            std::cerr << CFStr::ToString(err_str);
        }
        std::cerr << "\n";
        return EXIT_FAILURE;
    }

    std::ofstream outfile(path, std::ios::out | std::ios::binary);
    if (outfile.fail())
    {
        std::cerr << "Error: cannot open snapshot file for writing: " << path << "\n";
        return EXIT_FAILURE;
    }

    outfile.write(reinterpret_cast<const char*>(CFDataGetBytePtr(plist_data)), CFDataGetLength(plist_data));
    if (outfile.fail())
    {
        std::cerr << "Error: failed to write snapshot file: " << path << "\n";
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

int fingerprint::save_snapshot_json(const std::string& path, const SnapshotMetadata& metadata) noexcept
{
    if (path.empty())
    {
        std::cerr << "Error: snapshot path is empty\n";
        return EXIT_FAILURE;
    }

    std::sort(s_all_matched_files.begin(), s_all_matched_files.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });

    Json::MutableDoc doc;
    build_snapshot_json(metadata, doc);

    return write_json_doc_to_file(doc, path.c_str());
}

int fingerprint::save_snapshot(const std::string& path, const SnapshotMetadata& metadata) noexcept
{
    std::filesystem::path snap(path);
    std::string ext = snap.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

    if (ext.empty() || ext == ".tsv")
    {
        return save_snapshot_tsv(path, metadata);
    }
    else if (ext == ".json")
    {
        return save_snapshot_json(path, metadata);
    }
    else if (ext == ".plist")
    {
        return save_snapshot_plist(path, metadata);
    }
    else
    {
        std::cerr << "Error: unsupported snapshot format: " << ext << "\n";
        std::cerr << "       Supported formats: .tsv, .json, .plist (or no extension)\n";
        return EXIT_FAILURE;
    }
}

SnapshotMetadata fingerprint::create_snapshot_metadata(
    const std::unordered_set<std::string>& input_paths,
    const std::unordered_set<std::string>& glob_patterns,
    const std::unordered_set<std::string>& regex_patterns,
    const std::unordered_set<std::string>& exclude_patterns,
    FileHashAlgorithm hash_algorithm,
    FingerprintOptions fingerprint_mode,
    uint64_t fingerprint,
    const struct timeval& timestamp) noexcept
{
    SnapshotMetadata metadata;
    metadata.input_paths.assign(input_paths.begin(), input_paths.end());
    metadata.glob_patterns.assign(glob_patterns.begin(), glob_patterns.end());
    metadata.regex_patterns.assign(regex_patterns.begin(), regex_patterns.end());
    metadata.exclude_patterns.assign(exclude_patterns.begin(), exclude_patterns.end());
    std::sort(metadata.input_paths.begin(), metadata.input_paths.end());
    std::sort(metadata.glob_patterns.begin(), metadata.glob_patterns.end());
    std::sort(metadata.regex_patterns.begin(), metadata.regex_patterns.end());
    std::sort(metadata.exclude_patterns.begin(), metadata.exclude_patterns.end());
    metadata.hash_algorithm = hash_algorithm;
    metadata.fingerprint_mode = fingerprint_mode;
    metadata.fingerprint = fingerprint;
    
    struct tm tm_buf;
    localtime_r(&timestamp.tv_sec, &tm_buf);
    char timestamp_buf[64];
    size_t len = std::strftime(timestamp_buf, sizeof(timestamp_buf), "%Y-%m-%d %H:%M:%S", &tm_buf);
    len += std::snprintf(timestamp_buf + len, sizeof(timestamp_buf) - len, ".%06ld", (long)timestamp.tv_usec);
    (void)len;
    metadata.snapshot_timestamp = timestamp_buf;
    
    return metadata;
}

static bool sort_snapshot_files(CFMutableDictionaryRef snapshotRef) noexcept
{
    CFMutableDict snapshot(snapshotRef);
    CFArrayRef files_array_ref = nullptr;
    if (!snapshot.GetValue(CFSTR("files"), files_array_ref))
        return false;

    CFArr files_array(files_array_ref);
    CFIndex count = files_array.GetCount();
    if (count == 0)
        return true;

    std::vector<CFDictionaryRef> files;
    files.reserve(count);
    for (CFIndex i = 0; i < count; i++)
    {
        CFDictionaryRef file_dict = nullptr;
        if (files_array.GetValueAtIndex(i, file_dict))
            files.push_back(file_dict);
    }

    std::sort(files.begin(), files.end(),
              [](CFDictionaryRef a, CFDictionaryRef b)
              {
                  CFDict da(a), db(b);
                  CFStringRef path_a_str = nullptr;
                  CFStringRef path_b_str = nullptr;
                  if (!da.GetValue(CFSTR("path"), path_a_str)
                      || !db.GetValue(CFSTR("path"), path_b_str))
                      return false;
                  return CFStringCompare(path_a_str, path_b_str, 0) < 0;
              });

    CFMutableArr sorted_arr(count);
    for (CFDictionaryRef f : files)
        sorted_arr.AppendValue(f);

    snapshot.SetValue(CFSTR("files"), (CFMutableArrayRef)sorted_arr);
    return true;
}

CFMutableDictionaryRef fingerprint::load_snapshot(const std::string& path) noexcept
{
    std::filesystem::path fs_path(path);
    std::string ext = fs_path.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

    if (ext == ".tsv" || ext.empty())
    {
        CFMutableDict snapshot = load_tsv_as_cfdict(path);
        if (snapshot == nullptr)
            return nullptr;
        sort_snapshot_files(snapshot);
        return snapshot.Detach();
    }

    if (ext == ".json")
    {
        CFMutableDict snapshot = load_json_file_as_cfdict(path.c_str());
        if (snapshot == nullptr)
            return nullptr;
        sort_snapshot_files(snapshot);
        return snapshot.Detach();
    }

    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (file.fail())
    {
        std::cerr << "Error: cannot open snapshot file: " << path << "\n";
        return nullptr;
    }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    std::vector<char> buffer(size);
    if (!file.read(buffer.data(), size))
    {
        std::cerr << "Error: failed to read snapshot file: " << path << "\n";
        return nullptr;
    }

    CFObj<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, (const UInt8*)buffer.data(), size));
    if (data == nullptr)
    {
        std::cerr << "Error: failed to create CFData from file: " << path << "\n";
        return nullptr;
    }

    CFErrorRef error_raw = nullptr;
    CFPropertyListFormat format;
    CFObj<CFMutableDictionaryRef> snapshot((CFMutableDictionaryRef)CFPropertyListCreateWithData(
        kCFAllocatorDefault, data, kCFPropertyListMutableContainers, &format, &error_raw), kCFObjRetain);
    data = nullptr;

    if (snapshot == nullptr)
    {
        CFObj<CFErrorRef> error(error_raw);
        std::cerr << "Error: failed to parse snapshot file: " << path << "\n";
        if (error != nullptr)
        {
            CFObj<CFStringRef> err_desc(CFErrorCopyDescription(error));
            std::cerr << "       " << CFStr::ToString(err_desc) << "\n";
        }
        return nullptr;
    }

    if (CFType<CFMutableDictionaryRef>::DynamicCast(snapshot) == nullptr)
    {
        std::cerr << "Error: snapshot is not a dictionary: " << path << "\n";
        return nullptr;
    }

    sort_snapshot_files(snapshot);
    return snapshot.Detach();
}

static void print_cf_string(CFStringRef str, std::ostream& out)
{
    if (str == nullptr)
        out << "<unknown>";
    else
        out << CFStr::ToString(str);
}

static std::string format_mtime(int64_t mtime_ns) noexcept
{
    if (mtime_ns == 0)
        return "<unknown>";

    time_t epoch_sec = mtime_ns / 1000000000;
    struct tm* tm_info = localtime(&epoch_sec);
    if (tm_info == nullptr)
        return "<invalid>";

    char buffer[64];
    strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", tm_info);

    int64_t remainder = mtime_ns % 1000000000;
    char full_buffer[80];
    snprintf(full_buffer, sizeof(full_buffer), "%s.%09lld", buffer, (long long)remainder);
    return full_buffer;
}

static void compare_metadata(CFDictionaryRef snap1Ref, CFDictionaryRef snap2Ref, FileHashAlgorithm& hash_algorithm) noexcept
{
    CFDict snap1(snap1Ref), snap2(snap2Ref);
    CFDictionaryRef params1_ref = nullptr;
    CFDictionaryRef params2_ref = nullptr;
    if (!snap1.GetValue(CFSTR("fingerprint_params"), params1_ref)
        || !snap2.GetValue(CFSTR("fingerprint_params"), params2_ref))
        return;
    CFDict params1(params1_ref), params2(params2_ref);

    std::cout << "Fingerprint runs:\n";

    CFStringRef ts1 = nullptr, ts2 = nullptr;
    params1.GetValue(CFSTR("snapshot_timestamp"), ts1);
    params2.GetValue(CFSTR("snapshot_timestamp"), ts2);
    if ((ts1 != nullptr) && (ts2 != nullptr) && (CFStringCompare(ts1, ts2, 0) != 0))
    {
        std::cout << "\tsnapshot time:\n\t\told: ";
        print_cf_string(ts1, std::cout);
        std::cout << "\n\t\tnew: ";
        print_cf_string(ts2, std::cout);
        std::cout << "\n";
    }

    CFStringRef fp1 = nullptr, fp2 = nullptr;
    params1.GetValue(CFSTR("fingerprint"), fp1);
    params2.GetValue(CFSTR("fingerprint"), fp2);
    if ((fp1 != nullptr) && (fp2 != nullptr) && (CFStringCompare(fp1, fp2, 0) != 0))
    {
        std::cout << "\tfingerprint:\n\t\told: ";
        print_cf_string(fp1, std::cout);
        std::cout << "\n\t\tnew: ";
        print_cf_string(fp2, std::cout);
        std::cout << "\n";
    }

    CFStringRef hash1 = nullptr, hash2 = nullptr;
    params1.GetValue(CFSTR("hash_algorithm"), hash1);
    params2.GetValue(CFSTR("hash_algorithm"), hash2);
    if ((hash1 != nullptr) && (hash2 != nullptr))
    {
        bool same_hash_algorithms = (CFStringCompare(hash1, hash2, 0) == kCFCompareEqualTo);
        if (same_hash_algorithms)
        {
            if (CFStringCompare(hash1, CFSTR("crc32c"), 0) == kCFCompareEqualTo)
                hash_algorithm = FileHashAlgorithm::CRC32C;
            else if (CFStringCompare(hash1, CFSTR("blake3"), 0) == kCFCompareEqualTo)
                hash_algorithm = FileHashAlgorithm::BLAKE3;
            else
                hash_algorithm = FileHashAlgorithm::UNKNOWN;
        }
        else
        {
            hash_algorithm = FileHashAlgorithm::MISMATCH; // marker for non-matching hashes
            std::cout << "\thash algorithm:\n\t\told: ";
            print_cf_string(hash1, std::cout);
            std::cout << "\n\t\tnew: ";
            print_cf_string(hash2, std::cout);
            std::cout << "\n";
        }
    }

    CFStringRef mode1 = nullptr, mode2 = nullptr;
    params1.GetValue(CFSTR("fingerprint_mode"), mode1);
    params2.GetValue(CFSTR("fingerprint_mode"), mode2);
    if ((mode1 != nullptr) && (mode2 != nullptr) && (CFStringCompare(mode1, mode2, 0) != 0))
    {
        std::cout << "\tfingerprint mode:\n\t\told: ";
        print_cf_string(mode1, std::cout);
        std::cout << "\n\t\tnew: ";
        print_cf_string(mode2, std::cout);
        std::cout << "\n";
    }

    std::cout << "\n";
}

static bool compare_files(CFDictionaryRef snap1Ref, CFDictionaryRef snap2Ref, FileHashAlgorithm hash_algorithm) noexcept
{
    CFDict snap1(snap1Ref), snap2(snap2Ref);
    CFArrayRef files1_arr_ref = nullptr;
    CFArrayRef files2_arr_ref = nullptr;
    if (!snap1.GetValue(CFSTR("files"), files1_arr_ref)
        || !snap2.GetValue(CFSTR("files"), files2_arr_ref))
        return false;

    auto index_files = [](CFArrayRef arrRef, std::map<std::string, CFDictionaryRef>& out)
    {
        CFArr arr(arrRef);
        CFIndex count = arr.GetCount();
        for (CFIndex i = 0; i < count; i++)
        {
            CFDictionaryRef file_dict = nullptr;
            if (!arr.GetValueAtIndex(i, file_dict))
                continue;
            CFDict dict(file_dict);
            CFStringRef path_cf = nullptr;
            if (!dict.GetValue(CFSTR("path"), path_cf))
                continue;
            out[CFStr::ToString(path_cf)] = file_dict;
        }
    };

    std::map<std::string, CFDictionaryRef> files1;
    std::map<std::string, CFDictionaryRef> files2;
    index_files(files1_arr_ref, files1);
    index_files(files2_arr_ref, files2);

    if (hash_algorithm == FileHashAlgorithm::MISMATCH)
    {
        std::cout << "WARNING: Hash algorithms differ between snapshots.\n";
        std::cout << "File content hashes are not comparable - ignoring hash differences.\n";
        std::cout << "Only reporting additions, removals, size, and modification date changes.\n\n";
    }

    bool found_diff = false;

    for (const auto& [path, file1] : files1)
    {
        auto it = files2.find(path);
        if (it == files2.end())
        {
            std::cout << path << "\n";
            std::cout << "\tremoved\n\n";
            found_diff = true;
        }
        else
        {
            CFDict file1Dict(file1);
            CFDict file2Dict(it->second);
            bool file_modified = false;
            std::string details;

            if (hash_algorithm != FileHashAlgorithm::MISMATCH) // hashes are the same
            {
                const char* hash_name = (hash_algorithm == FileHashAlgorithm::CRC32C) ? "crc32c" : "blake3";
                CFStringRef hash1 = nullptr, hash2 = nullptr;
                file1Dict.GetValue(CFSTR("hash"), hash1);
                file2Dict.GetValue(CFSTR("hash"), hash2);
                if ((hash1 != nullptr) && (hash2 != nullptr) && (CFStringCompare(hash1, hash2, 0) != 0))
                {
                    details += "\t";
                    details += hash_name;
                    details += " hash:\n";
                    details += "\t\told: " + CFStr::ToString(hash1) + "\n";
                    details += "\t\tnew: " + CFStr::ToString(hash2) + "\n";
                    file_modified = true;
                }
            }

            int64_t size1_val = 0, size2_val = 0;
            bool have_size1 = file1Dict.GetValue(CFSTR("size"), size1_val);
            bool have_size2 = file2Dict.GetValue(CFSTR("size"), size2_val);
            if (have_size1 && have_size2 && (size1_val != size2_val))
            {
                details += "\tsize:\n";
                details += "\t\told: " + std::to_string(size1_val) + "\n";
                details += "\t\tnew: " + std::to_string(size2_val) + "\n";
                file_modified = true;
            }

            int64_t mtime1_val = 0, mtime2_val = 0;
            bool have_mtime1 = file1Dict.GetValue(CFSTR("mtime_ns"), mtime1_val);
            bool have_mtime2 = file2Dict.GetValue(CFSTR("mtime_ns"), mtime2_val);
            if (have_mtime1 && have_mtime2 && (mtime1_val != mtime2_val))
            {
                details += "\tmodification time:\n";
                details += "\t\told: " + format_mtime(mtime1_val) + "\n";
                details += "\t\tnew: " + format_mtime(mtime2_val) + "\n";
                file_modified = true;
            }

            CFStringRef mode1 = nullptr, mode2 = nullptr;
            file1Dict.GetValue(CFSTR("mode"), mode1);
            file2Dict.GetValue(CFSTR("mode"), mode2);
            if ((mode1 != nullptr) && (mode2 != nullptr) && (CFStringCompare(mode1, mode2, 0) != 0))
            {
                details += "\tmode:\n";
                details += "\t\told: " + CFStr::ToString(mode1) + "\n";
                details += "\t\tnew: " + CFStr::ToString(mode2) + "\n";
                file_modified = true;
            }

            if (file_modified)
            {
                std::cout << path << "\n";
                std::cout << details << "\n";
                found_diff = true;
            }
        }
    }

    for (const auto& [path, file2] : files2)
    {
        if (files1.find(path) == files1.end())
        {
            std::cout << path << "\n";
            std::cout << "\tadded\n\n";
            found_diff = true;
        }
    }

    if (!found_diff)
    {
        std::cout << "File contents are identical\n";
    }

    return found_diff;
}
