//
//  main.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/8/25.
//

#include <iostream>
#include <fstream>
#include <string>
#include <atomic>
#include <assert.h>
#include <sys/time.h>
#include <getopt.h>

#include "fingerprint.h"
#include "dispatch_queues_helper.h"
#include "env_var_expand.h"

#define STRINGIFY(x) #x
#define STRINGIFY_VALUE(x) STRINGIFY(x)

FileHashAlgorithm g_hash = FileHashAlgorithm::CRC32C;
XattrMode g_xattr_mode = XattrMode::On;

bool g_verbose = false;
double g_traversal_time = 0.0;

static void print_usage(std::ostream& stream)
{
    stream << "\n";
    stream << "Usage: fingerprint [-g, --glob=PATTERN]... [OPTIONS]... [PATH]...\n";
    stream << "Calculate a combined hash, aka fingerprint, of all files in specified path(s) matching the GLOB pattern(s)\n";
    stream << "OPTIONS:\n";
    stream << "  -g, --glob=PATTERN  Glob patterns (repeatable, unexpanded) to match files under directories\n";
    stream << "  -H, --hash=ALGO     File content hash algorithm: crc32c (default) or blake3\n";
    stream << "  -F, --fingerprint-mode=MODE  Options to include paths in final fingerprint:\n";
    stream << "        default  : only file content hashes (rename-insensitive) - default if not specified\n";
    stream << "        absolute : include full absolute paths (detects moves/renames)\n";
    stream << "        relative : use relative paths when under searched dirs (recommended)\n";
    stream << "  -X, --xattr=MODE    Control extended attribute (xattr) hash caching:\n";
    stream << "        on      : use cache if valid, update if changed - default\n";
    stream << "        off     : disable xattr caching\n";
    stream << "        refresh : force recompute and update xattrs\n";
    stream << "        clear   : disable caching and delete existing xattrs\n";
    stream << "  -I, --inputs=FILE   Read input paths from FILE (one path per line, repeatable)\n";
    stream << "                      Supports Xcode .xcfilelist with ${VAR}/$(VAR) and plain lists.\n";
    stream << "  -l, --list          List matched files with their hashes\n";
    stream << "  -h, --help          Print this help message\n";
    stream << "  -v, --verbose       Print all status information\n";
    stream << "\n";
    stream << "PATH arguments (positional) can be:\n";
    stream << "  - Directories for recursive traversal\n";
    stream << "  - Individual files to fingerprint directly\n";
    stream << "  - Symlinks (entire symlink chains are followed and fingerprinted)\n";
    stream << "  - Non-existent paths (treated as files with sentinel hash value)\n";
    stream << "\n";
    stream << "Paths can be absolute or relative. Relative paths are resolved against the current directory.\n";
    stream << "Glob patterns apply only to files discovered during directory traversal, not to directly specified files.\n";
    stream << "When no glob pattern is specified, all files under provided directories are fingerprinted.\n";
    stream << "\n";
    stream << "With --xattr=ON the tool caches computed file hashes and saves FileInfo in \"public.fingerprint.crc32c\"\n";
    stream << "or \"public.fingerprint.blake3\" xattr for files, depending on hash choice and then reads it back on next\n";
    stream << "fingerprinting if file inode, size and modification dates are unchanged.\n";
    stream << "FileInfo is a 32 byte structure:\n";
    stream << "\t\"inode\" : 8 bytes,\n";
    stream << "\t\"size\" : 8 bytes,\n";
    stream << "\t\"mtime_ns\" : 8 bytes,\n";
    stream << "\t{ crc32c : 4 bytes, reserved: 4 bytes } or blake3 : 8 bytes\n";
    stream << "xattr caching option significantly speeds up subsequent fingerprinting after initial hash calculation.\n";
    stream << "Turning it off makes the tool always perform file hashing, which might be justified in a zero trust\n";
    stream << "hostile environment at the file I/O and CPU expense. In a trusted or non-critical environment without malicious suspects,\n";
    stream << "the combination of lightweight crc32c and xattr caching provides excellent performance and very low chances of collisions.\n";
    stream << "\n";
}

int main(int argc, char * argv[])
{
    static const struct option long_options[] = {
        { "glob", required_argument,  nullptr, 'g' },
        { "hash", required_argument,  nullptr, 'H' },
        { "fingerprint-mode",required_argument, nullptr, 'F' },
        { "xattr", required_argument, nullptr, 'X' },
        { "inputs", required_argument, nullptr, 'I' },
        { "list",  no_argument,       nullptr, 'l' },
        { "help", no_argument,        nullptr, 'h' },
        { "version", no_argument,     nullptr, 'V' },
        { "verbose", no_argument,     nullptr, 'v' },
        { nullptr, 0,                 nullptr, 0 }
    };

    std::unordered_set<std::string> globs;
    std::unordered_set<std::string> paths;
    std::string hash_type = "crc32c";
    std::string xattr = "on";
    bool list_files = false;
    FingerprintOptions fingerprint_mode = FingerprintOptions::Default;

    int opt;
    while ((opt = getopt_long(argc, argv, "g:H:F:X:I:lhVv", long_options, nullptr)) != -1)
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

            case 'F':
            {
                std::string mode = optarg;
                std::transform(mode.begin(), mode.end(), mode.begin(), ::tolower);
                if (mode == "default")
                    fingerprint_mode = FingerprintOptions::Default;
                else if (mode == "absolute")
                    fingerprint_mode = FingerprintOptions::HashAbsolutePaths;
                else if (mode == "relative")
                    fingerprint_mode = FingerprintOptions::HashRelativePaths;
                else
                {
                    std::cerr << "Error: invalid --fingerprint-mode: " << optarg << "\n";
                    std::cerr << "       Valid values: default, absolute, relative\n";
                    return EXIT_FAILURE;
                }
            }
            break;
            
            case 'X':
            {
                xattr = optarg;
            }
            break;

            case 'I':
            {
                auto input_paths = read_input_file_list(optarg);
                if (input_paths.empty() && std::ifstream(optarg).fail())
                {
                    std::cerr << "Error: cannot open inputs file: " << optarg << '\n';
                    return EXIT_FAILURE;
                }
                
                for (auto& path : input_paths)
                {
                    paths.emplace(std::move(path));
                }
            }
            break;
                
            case 'l':
            {
                list_files = true;
            }
            break;
                
            case 'h':
            {
                print_usage(std::cout);
                return 0;
            }
            break;
                
            case 'V':
            {
                printf("fingerprint %s\n", STRINGIFY_VALUE(REPLAY_VERSION));
                return EXIT_SUCCESS;
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
        g_hash = FileHashAlgorithm::CRC32C;
    }
    else if(hash_type == "blake3")
    {
        g_hash = FileHashAlgorithm::BLAKE3;
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
        g_xattr_mode = XattrMode::On;
    else if (xattr == "off")
        g_xattr_mode = XattrMode::Off;
    else if (xattr == "refresh")
        g_xattr_mode = XattrMode::Refresh;
    else if (xattr == "clear")
        g_xattr_mode = XattrMode::Clear;
    else
    {
        std::cerr << "Error: invalid --xattr value: " << optarg << "\n";
        std::cerr << "       Valid values: on, off, refresh, clear\n";
        return EXIT_FAILURE;
    }

    // Collect positional dir paths
    while (optind < argc)
    {
        const char *search_path = argv[optind++];
        paths.emplace(search_path);
    }
    
    if (paths.empty())
    {
        std::cerr << "No paths specified to fingerprint\n";
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
	
    result = fingerprint::find_and_process_paths(paths, globs);
	fingerprint::wait_for_all_tasks();

	::gettimeofday(&time_tasks_end, nullptr);

	uint64_t fingerprint = fingerprint::sort_and_compute_fingerprint(fingerprint_mode);
    result = fingerprint::get_result();

	::gettimeofday(&time_end, nullptr);

    if (list_files)
    {
        std::cout << std::endl << "Matched files (" << hash_type << " hash & path):" << std::endl;
        fingerprint::list_matched_files();
        std::cout << std::endl;
    }
    
    printf("\nFingerprint: %016llx\n\n", (unsigned long long)fingerprint);

    if (g_verbose)
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
