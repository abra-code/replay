//
//  fingerprint.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/9/25.
//

#pragma once
#include <unordered_set>
#include <vector>

struct GlobPattern;
struct FileInfo;

enum class HashAlgorithm
{
    CRC32C,
    BLAKE3
};

class fingerprint
{
public:
    // main entry point. schedules async tasks and returns immediately
    // separates directories from files and dispatches appropriately
    // may be started from any thread, typically main
    static int find_and_process_paths(const std::unordered_set<std::string>& paths,
                                      const std::unordered_set<std::string>& globs) noexcept;

    // the client should wait for all background tasks to finish
    static void wait_for_all_tasks() noexcept;

    // this can be called only after all dispatched tasks finished
    static uint64_t sort_and_compute_fingerprint() noexcept;
    
    static void list_matched_files() noexcept;
    
    // flag to stop all tasks. safe to call on any thread
    static void set_exiting() noexcept;
    
    static int get_result() noexcept;
    
private:
    // expected to be called on directory_traversal_queue
    static int find_files_internal(std::string search_dir, const std::vector<GlobPattern> &compiled_globs) noexcept;
    
    // process individual files directly (globs ignored)
    // expected to be called on directory_traversal_queue
    static void process_files_internal(const std::vector<std::pair<std::string, FileInfo>>& files) noexcept;
};
