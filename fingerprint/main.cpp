//
//  main.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/8/25.
//

#include <iostream>
#include <string>
#include <atomic>
#include <assert.h>
#include <sys/time.h>
#include <getopt.h>

#include "fingerprint.h"
#include "dispatch_queues_helper.h"

HashAlgorithm g_hash = HashAlgorithm::CRC32C;
bool g_use_xatrr_optimization = true;

bool g_verbose = false;
double g_traversal_time = 0.0;

static void print_usage(std::ostream& stream)
{
    stream << "\n";
    stream << "Usage: fingerprint [-g, --glob=PATTERN]... [-H, --hash=ALGO] [-X, --xattr=ON|OFF] [DIR_PATH]...\n";
    stream << "Calculate a combined checksum, aka fingerprint, of all files in specified directory/ies matching the GLOB pattern(s)\n";
    stream << "\n";
    stream << "  -g, --glob=PATTERN  Glob patterns (repeatable, unexpanded) to match files under PATHs\n";
    stream << "  -H, --hash=ALGO     Hash algorithm: crc32c (default) or blake3\n";
    stream << "  -X, --xattr=ON|OFF  Cache hashes in file extended attributes, aka xattrs (default: ON)\n";
    stream << "  -h, --help          Print this help message\n";
    stream << "  -v, --verbose       Print all status information\n";
    stream << "\n";
    stream << "DIR_PATH arguments (positional) are base directories/paths for deep iteration.\n";
    stream << "Globs apply to match/filter files discovered under each DIR_PATH.\n";
    stream << "When glob pattern is not specified, all files under provided directory/ies are fingerprinted\n";
    stream << "\n";
    stream << "With --xattr=ON the tool caches computed file checksums and saves FileInfo in \"public.fingerprint.crc32c\"\n";
    stream << "or \"public.fingerprint.blake3\" xattr for files, depending on hash choice and then reads it back on next\n";
    stream << "fingerprinting if file inode, size and modification dates are unchanged.\n";
    stream << "FileInfo is a 32 byte structure:\n";
    stream << "\t\"inode\" : 8 bytes,\n";
    stream << "\t\"size\" : 8 bytes,\n";
    stream << "\t\"mtime_ns\" : 8 bytes,\n";
    stream << "\t{ crc32c : 4 bytes, reserved: 4 bytes } or blake3 : 8 bytes\n";
    stream << "xattr caching option significantly speeds up subsequent fingerprinting after initial checksum caclulation.\n";
    stream << "Turning it off makes the tool always perform file hashing, which might be justified in a zero trust\n";
    stream << "hostile environment at the file I/O and CPU expense. In a trusted or non-critical environment without malicious suspects,\n";
    stream << "the combination of lightweight crc32c and xattr caching provides excellent performance and very low chances of collisions.\n";
    stream << "\n";
}

int main(int argc, char * argv[])
{
    static const struct option long_options[] = {
        { "glob", required_argument, nullptr, 'g' },
        { "hash", required_argument, nullptr, 'H' },
        { "xattr", required_argument, nullptr, 'X' },
        { "help", no_argument, nullptr, 'h' },
        { "verbose", no_argument, nullptr, 'v' },
        { nullptr, 0, nullptr, 0 }
    };

    std::unordered_set<std::string> globs;
    std::unordered_set<std::string> paths;
    std::string hash_type = "crc32c";
    std::string xattr = "on";

    int opt;
    while ((opt = getopt_long(argc, argv, "g:H:X:hv", long_options, nullptr)) != -1)
    {
        switch (opt)
        {
            case 'g':
            {
                globs.insert(optarg);
            }
            break;
            
            case 'H':
            {
                hash_type = optarg;
            }
            break;
                
            case 'X':
            {
                xattr = optarg;
            }
            break;
                
            case 'h':
            {
                print_usage(std::cout);
                return 0;
            }
            break;
                
            case 'v':
            {
                g_verbose = true;
            }
            break;
                
            default:
            {
                std::cerr << "Invalid param: " << opt << std::endl;
                print_usage(std::cerr);
                return EXIT_FAILURE;
            }
        }
    }

    // resolve hash_type option
    std::transform(hash_type.begin(), hash_type.end(), hash_type.begin(), ::tolower);
    if(hash_type == "crc32c")
    {
        g_hash = HashAlgorithm::CRC32C;
    }
    else if(hash_type == "blake3")
    {
        g_hash = HashAlgorithm::BLAKE3;
    }
    else
    {
        std::cerr << "Invalid --hash value: " << hash_type << std::endl;
        print_usage(std::cerr);
        return EXIT_FAILURE;
    }

    // resolve xattr option
    std::transform(xattr.begin(), xattr.end(), xattr.begin(), ::tolower);
    if (xattr == "on")
    {
        g_use_xatrr_optimization = true;
    }
    else if(xattr == "off")
    {
        g_use_xatrr_optimization = false;
    }
    else
    {
        std::cerr << "Invalid --xattr value: " << optarg << std::endl;
        print_usage(std::cerr);
        return EXIT_FAILURE;
    }

    // Collect positional dir paths
    while (optind < argc)
    {
        char real_path[PATH_MAX] = {};
        const char *search_dir = argv[optind++];
        char *dir_path = realpath(search_dir, real_path);
        if (dir_path == nullptr)
        {
            std::cerr << "Specified directory does not exist: " << real_path << '\n';
            return EXIT_FAILURE;
        }

        paths.emplace(dir_path);
    }

    if (paths.empty())
    {
        std::cerr << "No directories specified to fingerprint\n";
        print_usage(std::cerr);
        return EXIT_FAILURE;
    }
    
    // empty globs is OK, the code handles it properly by including all files
    
    int result = EXIT_SUCCESS;
    
    if(g_verbose)
    {
        std::cout << "fingerprinting directories: " << std::endl;
        for (const auto& path : paths)
        {
            std::cout << "\t" << path << std::endl;
        }
        
        std::cout << "specifed globs: " << std::endl;
        for (const auto& glob : globs)
        {
            std::cout << "\t" << glob << std::endl;
        }
        
        std::cout << "hash algorithm: " << hash_type << std::endl;
        std::cout << "xattr cache: " << xattr << std::endl;
    }
    
    struct timeval time_start;
    struct timeval time_end;
    struct timeval time_tasks_end;

    double time_delta = 0.0;
    
	::gettimeofday(&time_start, nullptr);
	
	result = fingerprint::find_files(paths, globs);
	fingerprint::wait_for_all_tasks();

	::gettimeofday(&time_tasks_end, nullptr);

	uint64_t fingerprint = fingerprint::sort_and_compute_fingerprint();
			
	::gettimeofday(&time_end, nullptr);

	std::cout << "\nFingerprint: " << fingerprint << "\n";

	result = fingerprint::get_result();

    if(g_verbose)
    {
        std::cout << "\nDirectory traversal time: " << (g_traversal_time*1000.0) << " ms\n";

        time_delta = (double)time_tasks_end.tv_sec + (double)time_tasks_end.tv_usec/(1000.0 * 1000.0) -
                     ((double)time_start.tv_sec + (double)time_start.tv_usec/(1000.0 * 1000.0));

        std::cout << "\nConcurrent tasks time: " << (time_delta*1000.0) << " ms\n";

        time_delta = (double)time_end.tv_sec + (double)time_end.tv_usec/(1000.0 * 1000.0) -
                     ((double)time_tasks_end.tv_sec + (double)time_tasks_end.tv_usec/(1000.0 * 1000.0));

        std::cout << "\nsort_and_compute_fingerprint time: " << (time_delta*1000.0) << " ms\n";

        time_delta = (double)time_end.tv_sec + (double)time_end.tv_usec/(1000.0 * 1000.0) -
                     ((double)time_start.tv_sec + (double)time_start.tv_usec/(1000.0 * 1000.0));

        std::cout << "\nTotal execution time: " << (time_delta*1000.0) << " ms\n";
    }
    
    return result;
}
