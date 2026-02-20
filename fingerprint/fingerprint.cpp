//
//  fingerprint.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/8/25.
//

#include <iostream>
#include <filesystem>
#include <fstream>
#include <regex>
#include <ctime>
#include <map>

#include <CoreFoundation/CoreFoundation.h>

#include <assert.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <sys/attr.h>
#include <sys/xattr.h>

#include <fnmatch.h>
#include "glob.h"

#include "blake3.h"

#include "fingerprint.h"
#include "FileInfo.h"
#include "dispatch_queues_helper.h"
#include "json_serialization.h"
#include "CFObj.h"
#include "CFType.h"

#define FINGERPRINT_USE_GLOB_CPP 1

extern "C" uint32_t crc32_impl(uint32_t crc0, const char* buf, size_t len);

extern FileHashAlgorithm g_hash;
extern XattrMode g_xattr_mode;

extern bool g_verbose;
extern bool g_test_perf;
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

#if FINGERPRINT_USE_GLOB_CPP

struct Glob
{
    explicit Glob(const std::string& pattern, int flags) noexcept
        : glob(pattern),
          flags(flags)
    {
    }
    
    mutable glob::glob glob;
    int                flags;     // FNM_CASEFOLD | FNM_PATHNAME (if needed)
};

#else

struct Glob
{
    std::string pattern;
    int         flags;     // FNM_CASEFOLD | FNM_PATHNAME (if needed)
};

#endif // FINGERPRINT_USE_GLOB_CPP


static inline __attribute__((always_inline))
std::vector<Glob> compile_globs(const std::unordered_set<std::string>& glob_patterns) noexcept
{
    // Compile globs once — (empty vector = match-all)
    std::vector<Glob> compiled_globs;
    if (!glob_patterns.empty() && !glob_patterns.contains(""))
    {
        compiled_globs.reserve(glob_patterns.size());
        for (const auto& glob_pattern : glob_patterns)
        {
            int flags = FNM_CASEFOLD;
            if ((glob_pattern.find('/') != std::string::npos) || (glob_pattern.find("**") != std::string::npos))
                flags |= FNM_PATHNAME;
            
            compiled_globs.emplace_back(glob_pattern, flags);
        }
    }

    return compiled_globs;
}


// we always set FNM_CASEFOLD (case insensitive match) when preparing globs

static bool matches_any_glob(const char* relative_path,
                             const std::vector<Glob>& patterns) noexcept
{
    assert(relative_path != nullptr && relative_path[0] != '\0');
    assert(relative_path[strlen(relative_path) - 1] != '/');  // no trailing slash
    
#if FINGERPRINT_USE_GLOB_CPP
    std::string lowercase_path(relative_path);
    std::transform(lowercase_path.begin(), lowercase_path.end(), lowercase_path.begin(), ::tolower);
    const char* path = lowercase_path.c_str();
#else
    const char* path = relative_path;
#endif
    
    const char* basename = std::strrchr(path, '/');
    basename = (basename != nullptr) ? basename + 1 : path;

    for (const auto& g : patterns)
    {
        const char* str = (g.flags & FNM_PATHNAME) ? path
                                                  : basename;
#if FINGERPRINT_USE_GLOB_CPP
        bool is_matched = glob::glob_match(str, g.glob);
#else
        bool is_matched = (::fnmatch(g.pattern.c_str(), str, g.flags) == 0);
#endif
        if(is_matched)
            return true;
    }
    return false;
}

struct Regex
{
    std::regex re;
};

static inline __attribute__((always_inline))
std::vector<Regex> compile_regexes(const std::unordered_set<std::string>& regex_patterns) noexcept
{
    std::vector<Regex> compiled;
    if (regex_patterns.empty())
    {
        return compiled;
    }
    
    compiled.reserve(regex_patterns.size());
    for (const auto& pat : regex_patterns)
    {
        try
        {
            // ECMAScript + icase = case-insensitive
            compiled.emplace_back(Regex{ std::regex(pat, std::regex::ECMAScript | std::regex::icase) });
        }
        catch (const std::regex_error& e)
        {
            std::cerr << "Invalid regex pattern: " << pat << " (" << e.what() << ")\n";
            s_result = EXIT_FAILURE;
        }
    }
    return compiled;
}

static bool matches_any_regex(const std::string& relative_path,
                              const std::vector<Regex>& regexes) noexcept
{
    for (const auto& r : regexes)
    {
        if (std::regex_search(relative_path, r.re))
            return true;
    }
    return false;
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
        void* buffer = malloc(info.size);
        if (buffer != nullptr)
        {
            if (read(fd, buffer, info.size) == (ssize_t)info.size)
            {
                compute_buffer_hash(buffer, info.size, info);
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
                                    const std::unordered_set<std::string>& regex_patterns) noexcept
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
    
    // Resolve and normalize all paths
    for (const auto& input : paths)
    {
        std::filesystem::path p = input;
        std::filesystem::path abs_clean = p.is_absolute() ? p.lexically_normal() : (base / p).lexically_normal();
        
        // Now categorize the resolved path
        struct stat st;
        if (lstat(abs_clean.c_str(), &st) == 0)
        {
            if (S_ISDIR(st.st_mode))
            {
                // Dispatch directory traversal immediately
                std::string dir_path = abs_clean.string();
                dispatch_group_async(task_group, directory_traversal_queue, ^{
                    if (is_exiting()) { return; }
                    __unused int find_result = find_files_internal(dir_path, glob_patterns, regex_patterns);
                });
            }
            else if (S_ISLNK(st.st_mode))
            {
                // add symlink itself
                FileInfo info(st);
                files.emplace_back(abs_clean.string(), std::move(info));
                
                // resolve the entire symlink chain
                auto chain = resolve_symlink_chain(abs_clean);
                
                // Process each entry in the chain
                for (auto& [path, info] : chain)
                {
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
                            __unused int find_result = find_files_internal(dir_path, glob_patterns, regex_patterns);
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
                files.emplace_back(abs_clean.string(), std::move(info));
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
            files.emplace_back(abs_clean.string(), std::move(info));
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

// fts_read() is a solid choice for directory traversal
// for crawling with retrival of additonal file attributes
// and it does not require recursion in client code so stack depletion is not an issue
// Good discussion with source code and perf measurements is here:
// https://blog.tempel.org/2019/04/dir-read-performance.html

int
fingerprint::find_files_internal(std::string search_dir,
                                 const std::unordered_set<std::string>& glob_patterns,
                                 const std::unordered_set<std::string>& regex_patterns) noexcept
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

    dispatch_sync(get_shared_container_mutation_queue(), ^{
                s_search_bases.emplace(std::move(search_dir));
            });
    
    struct timeval time_start;
    struct timeval time_end;
    ::gettimeofday(&time_start, nullptr);

    std::vector<Glob> compiled_globs = compile_globs(glob_patterns);
    std::vector<Regex> compiled_regexes = compile_regexes(regex_patterns);
    
    // FTS_LOGICAL has an undesired behavior of:
    // 1. listing files twice:
    //    - under path with symlinked dir
    //    - under path with resolved dir symlink
    // 2. Not returning FTS_SL and FTS_SLNONE entries
    // So we use FTS_PHYSICAL and resolve the links outside of search dir scope
    
    char *paths[2] = {const_cast<char*>(search_dir.c_str()), nullptr};
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nullptr);
    if (fts == nullptr)
    {
        std::cerr << "fts_open failed for: " << search_dir << '\n';
        s_result = EXIT_FAILURE;
        return s_result;
    }

    int result = 0;
    FTSENT *ent;
    while ((ent = fts_read(fts)) != nullptr)
    {
        if (is_exiting()) { result = EXIT_FAILURE; break; }

        switch (ent->fts_info)
        {
            case FTS_D:  // pre-order directory
                break;

            case FTS_F:  // regular file
            case FTS_SL: // symbolic link
            case FTS_SLNONE: // symbolic link with non-existent target
            {
                // No glob filtering
                if (compiled_globs.empty() && compiled_regexes.empty())
                {
                    process_matched_file(ent->fts_path, ent->fts_statp);
                    break;
                }

                // Relative path starting right after the base directory
                const char* relative_path = ent->fts_path + search_dir.length();
                if (*relative_path == '/') ++relative_path;
                
                if (matches_any_glob(relative_path, compiled_globs) || matches_any_regex(relative_path, compiled_regexes))
                {
                    process_matched_file(ent->fts_path, ent->fts_statp);
                }
                
                // If it's a symlink, resolve chain
                if (ent->fts_info == FTS_SL || ent->fts_info == FTS_SLNONE)
                {
                    std::filesystem::path sym_path = ent->fts_path;
                    auto chain = resolve_symlink_chain(sym_path);
                    
                    // Process each entry in the chain
                    for (auto& [path, info] : chain)
                    {
                        // both search_dir & path are absolute at this point
                        // if the symlinked dir is outside of the scope of initial search_dir
                        // then current directory traversal is not covering it
                        if (!is_path_under_directory(search_dir, path))
                        {
                            if (info.is_directory())
                            {
                                // Found a directory in the chain - dispatch for traversal
                                if (g_verbose)
                                {
                                    std::cerr << "Symlink chain leads to directory: " << path << '\n';
                                }
                                std::string dir_path = path;  // Copy the path for capture
                                dispatch_group_async(get_all_tasks_group(), get_directory_traversal_queue(), ^{
                                    if (is_exiting()) { return; }
                                    __unused int find_result = find_files_internal(dir_path, glob_patterns, regex_patterns);
                                });
                            }
                            else
                            {
                                // Regular file, symlink, or non-existent - process if matching desired patterns
                                if (compiled_globs.empty() || matches_any_glob(path.c_str(), compiled_globs))
                                {
                                    process_matched_file_async(path, info);
                                }
                            }
                        }
                    }
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

static inline __attribute__((always_inline)) std::string get_path_for_fingerprint(const std::string& abs_path, FingerprintOptions options)
{
    if (options == FingerprintOptions::HashRelativePaths)
    {
        std::string best_rel;
        size_t best_len = 0;

        for (const auto& base : s_search_bases) {
            if (abs_path.starts_with(base) && base.size() > best_len) {
                std::string rel = abs_path.substr(base.size());
                if (!rel.empty() && rel[0] == '/') rel.erase(0, 1);
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
        return i > 0;  // a longer than b with common suffix → a > b
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

static CFMutableDictionaryRef load_tsv_as_cfdict(const std::string& path) noexcept
{
    std::ifstream infile(path);
    if (infile.fail())
    {
        std::cerr << "Error: cannot open snapshot file: " << path << "\n";
        return nullptr;
    }

    CFObj<CFMutableDictionaryRef> root_dict(CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

    CFObj<CFMutableDictionaryRef> params_dict(CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFDictionarySetValue(root_dict, CFSTR("fingerprint_params"), params_dict);
    params_dict = nullptr;

    CFObj<CFMutableArrayRef> files_arr(CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));

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

        CFObj<CFMutableDictionaryRef> file_dict(CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

        std::string path_str = line.substr(0, tab1);
        CFObj<CFStringRef> path_cf(CFStringCreateWithCString(kCFAllocatorDefault, path_str.c_str(), kCFStringEncodingUTF8));
        CFDictionarySetValue(file_dict, CFSTR("path"), path_cf);

        std::string hash_str = line.substr(tab1 + 1, tab2 - tab1 - 1);
        CFObj<CFStringRef> hash_cf(CFStringCreateWithCString(kCFAllocatorDefault, hash_str.c_str(), kCFStringEncodingUTF8));
        CFDictionarySetValue(file_dict, CFSTR("hash"), hash_cf);

        std::string size_str = line.substr(tab2 + 1, tab3 - tab2 - 1);
        int64_t size_val = std::stoll(size_str);
        CFObj<CFNumberRef> size_num(CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &size_val));
        CFDictionarySetValue(file_dict, CFSTR("size"), size_num);

        std::string inode_str = line.substr(tab3 + 1, tab4 - tab3 - 1);
        uint64_t inode_val = std::stoull(inode_str);
        CFObj<CFNumberRef> inode_num(CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &inode_val));
        CFDictionarySetValue(file_dict, CFSTR("inode"), inode_num);

        std::string mtime_str = line.substr(tab4 + 1, tab5 - tab4 - 1);
        int64_t mtime_val = std::stoll(mtime_str);
        CFObj<CFNumberRef> mtime_num(CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &mtime_val));
        CFDictionarySetValue(file_dict, CFSTR("mtime_ns"), mtime_num);

        std::string mode_str = line.substr(tab5 + 1);
        CFObj<CFStringRef> mode_cf(CFStringCreateWithCString(kCFAllocatorDefault, mode_str.c_str(), kCFStringEncodingUTF8));
        CFDictionarySetValue(file_dict, CFSTR("mode"), mode_cf);

        CFArrayAppendValue(files_arr, file_dict);
    }

    CFDictionarySetValue(root_dict, CFSTR("files"), files_arr);
    files_arr = nullptr;

    return root_dict.Detach();
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

static CFMutableDictionaryRef build_snapshot_dictionary(const SnapshotMetadata& metadata) noexcept
{
    CFObj<CFMutableDictionaryRef> root_dict(CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

    CFObj<CFMutableDictionaryRef> params_dict(CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

    {
        CFObj<CFMutableArrayRef> arr(CFArrayCreateMutable(kCFAllocatorDefault, metadata.input_paths.size(),
            &kCFTypeArrayCallBacks));
        for (const auto& p : metadata.input_paths)
        {
            CFObj<CFStringRef> cfstr(CFStringCreateWithCString(kCFAllocatorDefault, p.c_str(), kCFStringEncodingUTF8));
            CFArrayAppendValue(arr, cfstr);
        }
        CFDictionarySetValue(params_dict, CFSTR("input_paths"), arr);
    }

    {
        CFObj<CFMutableArrayRef> arr(CFArrayCreateMutable(kCFAllocatorDefault, metadata.glob_patterns.size(),
            &kCFTypeArrayCallBacks));
        for (const auto& p : metadata.glob_patterns)
        {
            CFObj<CFStringRef> cfstr(CFStringCreateWithCString(kCFAllocatorDefault, p.c_str(), kCFStringEncodingUTF8));
            CFArrayAppendValue(arr, cfstr);
        }
        CFDictionarySetValue(params_dict, CFSTR("glob_patterns"), arr);
    }

    {
        CFObj<CFMutableArrayRef> arr(CFArrayCreateMutable(kCFAllocatorDefault, metadata.regex_patterns.size(),
            &kCFTypeArrayCallBacks));
        for (const auto& p : metadata.regex_patterns)
        {
            CFObj<CFStringRef> cfstr(CFStringCreateWithCString(kCFAllocatorDefault, p.c_str(), kCFStringEncodingUTF8));
            CFArrayAppendValue(arr, cfstr);
        }
        CFDictionarySetValue(params_dict, CFSTR("regex_patterns"), arr);
    }

    CFStringRef hash_algo = (metadata.hash_algorithm == FileHashAlgorithm::CRC32C) ?
        CFSTR("crc32c") : CFSTR("blake3");
    CFDictionarySetValue(params_dict, CFSTR("hash_algorithm"), hash_algo);

    CFStringRef fp_mode = CFSTR("default");
    switch (metadata.fingerprint_mode)
    {
        case FingerprintOptions::HashAbsolutePaths: fp_mode = CFSTR("absolute"); break;
        case FingerprintOptions::HashRelativePaths: fp_mode = CFSTR("relative"); break;
        default: fp_mode = CFSTR("default"); break;
    }
    CFDictionarySetValue(params_dict, CFSTR("fingerprint_mode"), fp_mode);

    char fp_hex[32];
    std::snprintf(fp_hex, sizeof(fp_hex), "%016llx", (unsigned long long)metadata.fingerprint);
    CFObj<CFStringRef> fingerprint_str(CFStringCreateWithCString(kCFAllocatorDefault, fp_hex, kCFStringEncodingUTF8));
    CFDictionarySetValue(params_dict, CFSTR("fingerprint"), fingerprint_str);

    if (!metadata.snapshot_timestamp.empty())
    {
        CFObj<CFStringRef> timestamp(CFStringCreateWithCString(kCFAllocatorDefault, metadata.snapshot_timestamp.c_str(),
            kCFStringEncodingUTF8));
        CFDictionarySetValue(params_dict, CFSTR("snapshot_timestamp"), timestamp);
    }

    CFDictionarySetValue(root_dict, CFSTR("fingerprint_params"), params_dict);
    params_dict = nullptr;

    CFObj<CFMutableArrayRef> files_arr(CFArrayCreateMutable(kCFAllocatorDefault, s_all_matched_files.size(),
        &kCFTypeArrayCallBacks));
    for (const auto& [file_path, info] : s_all_matched_files)
    {
        if (info.is_nonexistent()) continue;

        CFObj<CFMutableDictionaryRef> file_dict(CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

        CFObj<CFStringRef> path_cfstr(CFStringCreateWithCString(kCFAllocatorDefault, file_path.c_str(), kCFStringEncodingUTF8));
        CFDictionarySetValue(file_dict, CFSTR("path"), path_cfstr);

        char hash_hex[32];
        if (g_hash == FileHashAlgorithm::CRC32C)
            std::snprintf(hash_hex, sizeof(hash_hex), "%08x", info.hash.crc32c);
        else
            std::snprintf(hash_hex, sizeof(hash_hex), "%016llx", (unsigned long long)info.hash.blake3);

        CFObj<CFStringRef> hash_cfstr(CFStringCreateWithCString(kCFAllocatorDefault, hash_hex, kCFStringEncodingUTF8));
        CFDictionarySetValue(file_dict, CFSTR("hash"), hash_cfstr);

        CFObj<CFNumberRef> inode_num(CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &info.inode));
        CFDictionarySetValue(file_dict, CFSTR("inode"), inode_num);

        CFObj<CFNumberRef> size_num(CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &info.size));
        CFDictionarySetValue(file_dict, CFSTR("size"), size_num);

        CFObj<CFNumberRef> mtime_num(CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &info.mtime_ns));
        CFDictionarySetValue(file_dict, CFSTR("mtime_ns"), mtime_num);

        char mode_hex[16];
        std::snprintf(mode_hex, sizeof(mode_hex), "%04o", info.mode & 07777);
        CFObj<CFStringRef> mode_str(CFStringCreateWithCString(kCFAllocatorDefault, mode_hex, kCFStringEncodingUTF8));
        CFDictionarySetValue(file_dict, CFSTR("mode"), mode_str);

        CFArrayAppendValue(files_arr, file_dict);
    }

    CFDictionarySetValue(root_dict, CFSTR("files"), files_arr);
    files_arr = nullptr;

    return root_dict.Detach();
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

    CFObj<CFMutableDictionaryRef> root_dict(build_snapshot_dictionary(metadata));

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
            char err_buf[256];
            if (CFStringGetCString(err_str, err_buf, sizeof(err_buf), kCFStringEncodingUTF8))
                std::cerr << err_buf;
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

    CFObj<CFMutableDictionaryRef> root_dict(build_snapshot_dictionary(metadata));

    int result = serialize_dict_to_json(root_dict, path.c_str());
    root_dict = nullptr;
    
    return result;
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
    FileHashAlgorithm hash_algorithm,
    FingerprintOptions fingerprint_mode,
    uint64_t fingerprint,
    const struct timeval& timestamp) noexcept
{
    SnapshotMetadata metadata;
    metadata.input_paths.assign(input_paths.begin(), input_paths.end());
    metadata.glob_patterns.assign(glob_patterns.begin(), glob_patterns.end());
    metadata.regex_patterns.assign(regex_patterns.begin(), regex_patterns.end());
    std::sort(metadata.input_paths.begin(), metadata.input_paths.end());
    std::sort(metadata.glob_patterns.begin(), metadata.glob_patterns.end());
    std::sort(metadata.regex_patterns.begin(), metadata.regex_patterns.end());
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

static bool sort_snapshot_files(CFMutableDictionaryRef snapshot) noexcept
{
    CFTypeRef files_arr = CFDictionaryGetValue(snapshot, CFSTR("files"));
    CFArrayRef files_array = CFType<CFArrayRef>::DynamicCast(files_arr);
    if (files_array == nullptr)
        return false;

    CFIndex count = CFArrayGetCount(files_array);
    if (count == 0)
        return true;

    CFObj<CFMutableArrayRef> sorted_arr(CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks));

    std::vector<CFDictionaryRef> files;
    files.reserve(count);
    for (CFIndex i = 0; i < count; i++)
    {
        CFTypeRef file = CFArrayGetValueAtIndex(files_array, i);
        CFDictionaryRef file_dict = CFType<CFDictionaryRef>::DynamicCast(file);
        if (file_dict != nullptr)
            files.push_back(file_dict);
    }

    std::sort(files.begin(), files.end(),
              [](CFDictionaryRef a, CFDictionaryRef b)
              {
                  CFTypeRef path_a = CFDictionaryGetValue(a, CFSTR("path"));
                  CFTypeRef path_b = CFDictionaryGetValue(b, CFSTR("path"));
                  CFStringRef path_a_str = CFType<CFStringRef>::DynamicCast(path_a);
                  CFStringRef path_b_str = CFType<CFStringRef>::DynamicCast(path_b);
                  if (path_a_str == nullptr || path_b_str == nullptr)
                      return false;
                  return CFStringCompare(path_a_str, path_b_str, 0) < 0;
              });

    for (const auto& f : files)
        CFArrayAppendValue(sorted_arr, f);

    CFDictionarySetValue(snapshot, CFSTR("files"), sorted_arr);
    return true;
}

CFMutableDictionaryRef fingerprint::load_snapshot(const std::string& path) noexcept
{
    std::filesystem::path fs_path(path);
    std::string ext = fs_path.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

    if (ext == ".tsv" || ext.empty())
    {
        CFObj<CFMutableDictionaryRef> snapshot(load_tsv_as_cfdict(path));
        if (snapshot == nullptr)
            return nullptr;
        sort_snapshot_files(snapshot);
        return snapshot.Detach();
    }

    if (ext == ".json")
    {
        CFObj<CFMutableDictionaryRef> snapshot(deserialize_json_from_file(path.c_str()));
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
            CFObj<CFStringRef> err_desc(CFErrorCopyDescription(error), kCFObjRetain);
            char err_buf[256];
            if (CFStringGetCString(err_desc, err_buf, sizeof(err_buf), kCFStringEncodingUTF8))
                std::cerr << "       " << err_buf << "\n";
        }
        return nullptr;
    }

    if (CFGetTypeID(snapshot) != CFDictionaryGetTypeID())
    {
        std::cerr << "Error: snapshot is not a dictionary: " << path << "\n";
        return nullptr;
    }

    sort_snapshot_files(snapshot);
    return snapshot.Detach();
}

static void print_cf_string(CFStringRef str, std::ostream& out)
{
    char buf[1024];
    if (CFStringGetCString(str, buf, sizeof(buf), kCFStringEncodingUTF8))
        out << buf;
    else
        out << "<unknown>";
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

static void compare_metadata(CFDictionaryRef snap1, CFDictionaryRef snap2, FileHashAlgorithm& hash_algorithm) noexcept
{
    CFStringRef key1 = CFSTR("fingerprint_params");
    CFTypeRef params1 = CFDictionaryGetValue(snap1, key1);
    CFTypeRef params2 = CFDictionaryGetValue(snap2, key1);

    CFDictionaryRef params1_dict = CFType<CFDictionaryRef>::DynamicCast(params1);
    CFDictionaryRef params2_dict = CFType<CFDictionaryRef>::DynamicCast(params2);
    if (params1_dict == nullptr || params2_dict == nullptr)
        return;

    std::cout << "Fingerprint runs:\n";

    CFStringRef timestamp_key = CFSTR("snapshot_timestamp");
    CFTypeRef ts1_raw = CFDictionaryGetValue(params1_dict, timestamp_key);
    CFTypeRef ts2_raw = CFDictionaryGetValue(params2_dict, timestamp_key);
    CFStringRef ts1 = CFType<CFStringRef>::DynamicCast(ts1_raw);
    CFStringRef ts2 = CFType<CFStringRef>::DynamicCast(ts2_raw);

    if (ts1 != nullptr && ts2 != nullptr && CFStringCompare(ts1, ts2, 0) != 0)
    {
        std::cout << "\tsnapshot time:\n\t\told: ";
        print_cf_string(ts1, std::cout);
        std::cout << "\n\t\tnew: ";
        print_cf_string(ts2, std::cout);
        std::cout << "\n";
    }

    CFStringRef fp_key = CFSTR("fingerprint");
    CFTypeRef fp1_raw = CFDictionaryGetValue(params1_dict, fp_key);
    CFTypeRef fp2_raw = CFDictionaryGetValue(params2_dict, fp_key);
    CFStringRef fp1 = CFType<CFStringRef>::DynamicCast(fp1_raw);
    CFStringRef fp2 = CFType<CFStringRef>::DynamicCast(fp2_raw);

    if (fp1 != nullptr && fp2 != nullptr && CFStringCompare(fp1, fp2, 0) != 0)
    {
        std::cout << "\tfingerprint:\n\t\told: ";
        print_cf_string(fp1, std::cout);
        std::cout << "\n\t\tnew: ";
        print_cf_string(fp2, std::cout);
        std::cout << "\n";
    }

    CFStringRef hash_key = CFSTR("hash_algorithm");
    CFTypeRef hash1_raw = CFDictionaryGetValue(params1_dict, hash_key);
    CFTypeRef hash2_raw = CFDictionaryGetValue(params2_dict, hash_key);
    CFStringRef hash1 = CFType<CFStringRef>::DynamicCast(hash1_raw);
    CFStringRef hash2 = CFType<CFStringRef>::DynamicCast(hash2_raw);

    if (hash1 != nullptr && hash2 != nullptr)
    {
        bool same_hash_algorithms = (CFStringCompare(hash1, hash2, 0) == kCFCompareEqualTo);
        if (same_hash_algorithms)
        {
            if (CFStringCompare(hash1, CFSTR("crc32c"), 0) == kCFCompareEqualTo)
            {
                hash_algorithm = FileHashAlgorithm::CRC32C;
            }
            else if (CFStringCompare(hash1, CFSTR("blake3"), 0) == kCFCompareEqualTo)
            {
                hash_algorithm = FileHashAlgorithm::BLAKE3;
            }
            else
            {
                hash_algorithm = FileHashAlgorithm::UNKNOWN;
            }
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

    CFStringRef mode_key = CFSTR("fingerprint_mode");
    CFTypeRef mode1_raw = CFDictionaryGetValue(params1_dict, mode_key);
    CFTypeRef mode2_raw = CFDictionaryGetValue(params2_dict, mode_key);
    CFStringRef mode1 = CFType<CFStringRef>::DynamicCast(mode1_raw);
    CFStringRef mode2 = CFType<CFStringRef>::DynamicCast(mode2_raw);

    if (mode1 != nullptr && mode2 != nullptr && CFStringCompare(mode1, mode2, 0) != 0)
    {
        std::cout << "\tfingerprint mode:\n\t\told: ";
        print_cf_string(mode1, std::cout);
        std::cout << "\n\t\tnew: ";
        print_cf_string(mode2, std::cout);
        std::cout << "\n";
    }

    std::cout << "\n";
}

static bool compare_files(CFDictionaryRef snap1, CFDictionaryRef snap2, FileHashAlgorithm hash_algorithm) noexcept
{
    CFTypeRef files1_arr_raw = CFDictionaryGetValue(snap1, CFSTR("files"));
    CFTypeRef files2_arr_raw = CFDictionaryGetValue(snap2, CFSTR("files"));

    CFArrayRef files1_arr = CFType<CFArrayRef>::DynamicCast(files1_arr_raw);
    CFArrayRef files2_arr = CFType<CFArrayRef>::DynamicCast(files2_arr_raw);
    if (files1_arr == nullptr || files2_arr == nullptr)
        return false;

    std::map<std::string, CFDictionaryRef> files1;
    std::map<std::string, CFDictionaryRef> files2;

    CFIndex count1 = CFArrayGetCount(files1_arr);
    for (CFIndex i = 0; i < count1; i++)
    {
        CFTypeRef file = CFArrayGetValueAtIndex(files1_arr, i);
        CFDictionaryRef file_dict = CFType<CFDictionaryRef>::DynamicCast(file);
        if (file_dict == nullptr)
            continue;
        CFTypeRef path_cf_raw = CFDictionaryGetValue(file_dict, CFSTR("path"));
        CFStringRef path_cf = CFType<CFStringRef>::DynamicCast(path_cf_raw);
        if (path_cf == nullptr)
            continue;
        char path_buf[PATH_MAX];
        if (CFStringGetCString(path_cf, path_buf, sizeof(path_buf), kCFStringEncodingUTF8))
            files1[path_buf] = file_dict;
    }

    CFIndex count2 = CFArrayGetCount(files2_arr);
    for (CFIndex i = 0; i < count2; i++)
    {
        CFTypeRef file = CFArrayGetValueAtIndex(files2_arr, i);
        CFDictionaryRef file_dict = CFType<CFDictionaryRef>::DynamicCast(file);
        if (file_dict == nullptr)
            continue;
        CFTypeRef path_cf_raw = CFDictionaryGetValue(file_dict, CFSTR("path"));
        CFStringRef path_cf = CFType<CFStringRef>::DynamicCast(path_cf_raw);
        if (path_cf == nullptr)
            continue;
        char path_buf[PATH_MAX];
        if (CFStringGetCString(path_cf, path_buf, sizeof(path_buf), kCFStringEncodingUTF8))
            files2[path_buf] = file_dict;
    }

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
            CFDictionaryRef file2 = it->second;
            bool file_modified = false;
            std::string details;

            if (hash_algorithm != FileHashAlgorithm::MISMATCH) // hashes are the same
            {
                const char* hash_name = (hash_algorithm == FileHashAlgorithm::CRC32C) ? "crc32c" : "blake3";
                CFTypeRef hash1_raw = CFDictionaryGetValue(file1, CFSTR("hash"));
                CFTypeRef hash2_raw = CFDictionaryGetValue(file2, CFSTR("hash"));
                CFStringRef hash1 = CFType<CFStringRef>::DynamicCast(hash1_raw);
                CFStringRef hash2 = CFType<CFStringRef>::DynamicCast(hash2_raw);
                if (hash1 != nullptr && hash2 != nullptr && CFStringCompare(hash1, hash2, 0) != 0)
                {
                    details += "\t";
                    details += hash_name;
                    details += " hash:\n";
                    details += "\t\told: ";
                    char hash_buf[32];
                    if (CFStringGetCString(hash1, hash_buf, sizeof(hash_buf), kCFStringEncodingUTF8))
                        details += hash_buf;
                    details += "\n";
                    details += "\t\tnew: ";
                    if (CFStringGetCString(hash2, hash_buf, sizeof(hash_buf), kCFStringEncodingUTF8))
                        details += hash_buf;
                    details += "\n";
                    file_modified = true;
                }
            }

            CFTypeRef size1_raw = CFDictionaryGetValue(file1, CFSTR("size"));
            CFTypeRef size2_raw = CFDictionaryGetValue(file2, CFSTR("size"));
            CFNumberRef size1 = CFType<CFNumberRef>::DynamicCast(size1_raw);
            CFNumberRef size2 = CFType<CFNumberRef>::DynamicCast(size2_raw);
            if (size1 != nullptr && size2 != nullptr)
            {
                int64_t size1_val, size2_val;
                CFNumberGetValue(size1, kCFNumberLongLongType, &size1_val);
                CFNumberGetValue(size2, kCFNumberLongLongType, &size2_val);
                if (size1_val != size2_val)
                {
                    details += "\tsize:\n";
                    details += "\t\told: " + std::to_string(size1_val) + "\n";
                    details += "\t\tnew: " + std::to_string(size2_val) + "\n";
                    file_modified = true;
                }
            }

            CFTypeRef mtime1_raw = CFDictionaryGetValue(file1, CFSTR("mtime_ns"));
            CFTypeRef mtime2_raw = CFDictionaryGetValue(file2, CFSTR("mtime_ns"));
            CFNumberRef mtime1 = CFType<CFNumberRef>::DynamicCast(mtime1_raw);
            CFNumberRef mtime2 = CFType<CFNumberRef>::DynamicCast(mtime2_raw);
            if (mtime1 != nullptr && mtime2 != nullptr)
            {
                int64_t mtime1_val, mtime2_val;
                CFNumberGetValue(mtime1, kCFNumberLongLongType, &mtime1_val);
                CFNumberGetValue(mtime2, kCFNumberLongLongType, &mtime2_val);
                if (mtime1_val != mtime2_val)
                {
                    details += "\tmodification time:\n";
                    details += "\t\told: " + format_mtime(mtime1_val) + "\n";
                    details += "\t\tnew: " + format_mtime(mtime2_val) + "\n";
                    file_modified = true;
                }
            }

            CFTypeRef mode1_raw = CFDictionaryGetValue(file1, CFSTR("mode"));
            CFTypeRef mode2_raw = CFDictionaryGetValue(file2, CFSTR("mode"));
            CFStringRef mode1 = CFType<CFStringRef>::DynamicCast(mode1_raw);
            CFStringRef mode2 = CFType<CFStringRef>::DynamicCast(mode2_raw);
            if (mode1 != nullptr && mode2 != nullptr && CFStringCompare(mode1, mode2, 0) != 0)
            {
                details += "\tmode:\n";
                details += "\t\told: ";
                char mode_buf[16];
                if (CFStringGetCString(mode1, mode_buf, sizeof(mode_buf), kCFStringEncodingUTF8))
                    details += mode_buf;
                details += "\n";
                details += "\t\tnew: ";
                if (CFStringGetCString(mode2, mode_buf, sizeof(mode_buf), kCFStringEncodingUTF8))
                    details += mode_buf;
                details += "\n";
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
