//
//  fingerprint.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/9/25.
//

#pragma once
#include <unordered_set>

enum class HashAlgorithm
{
    CRC32,
    BLAKE3
};

class fingerprint
{
public:
    // main entry point. schedules async tasks and returns immediately
    // may be started from any thread, typically main
    static int find_files(const std::unordered_set<std::string>& dir_paths,
                   const std::unordered_set<std::string>& globs) noexcept;
};


int
fingerprint::find_files(const std::unordered_set<std::string>& dir_paths,
               const std::unordered_set<std::string>& globs) noexcept
{
    // uninplemented
    return 1;
}
