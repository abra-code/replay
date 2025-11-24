//
//  fingerprint.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/9/25.
//

#pragma once
#include <unordered_set>

struct GlobPattern;
enum class HashAlgorithm
{
    CRC32C,
    BLAKE3
};

class fingerprint
{
public:
    // main entry point. schedules async tasks and returns immediately
    // may be started from any thread, typically main
    static int find_files(const std::unordered_set<std::string>& dir_paths,
                   const std::unordered_set<std::string>& globs) noexcept;

    // the client should wait for all background tasks to finish
    static void wait_for_all_tasks() noexcept;

    // this can be called only after all dispatched tasks finished
    static uint64_t sort_and_compute_fingerprint() noexcept;

    // flag to stop all tasks. safe to call on any thread
    static void set_exiting() noexcept;
    
    static int get_result() noexcept;
    
private:
    // expected to be called on directory_traversal_queue
    static int find_files_internal(std::string search_dir, const std::vector<GlobPattern> &compiled_globs) noexcept;
};
