#include <getopt.h>
#include <iostream>
#include <string>

#include "fingerprint.h"

HashAlgorithm g_hash = HashAlgorithm::BLAKE3;
bool g_use_xatrr_optimization = true;

static void print_usage(std::ostream& stream)
{
    stream << "\n";
	stream << "Usage: fingerprint [-g, --glob=PATTERN]... [-H, --hash=ALGO] [-X, --xattr=ON|OFF] [PATH]...\n";
    stream << "Calculate a combined checksum, aka a fingerprint, of all files in specified directory/ies matching the GLOB pattern(s)\n";
    stream << "\n";
    stream << "  -g, --glob=PATTERN  Glob patterns (repeatable, unexpanded) to match files under PATHs\n";
	stream << "  -H, --hash=ALGO     Hash algorithm: crc32c (default) or blake3\n";
	stream << "  -X, --xattr=ON|OFF  Cache file hashes in xattrs (default: on)\n";
	stream << "  -h, --help          Print this help message\n";
	stream << "\n";
    stream << "PATH arguments (positional) are base directories/paths for deep iteration.\n";
    stream << "Globs apply to match/filter files discovered under each PATH.\n";
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
    stream << "Turning it off makes the tool always perform file hashing, which might be justified in a zero trust \n";
    stream << "hostile environment at the file I/O and CPU expense. In a trusted or non-critical environment without malicious suspects,\n";
    stream << "the combination of lightweight crc32c and xattr caching provides excellent performance and very low chances of collisions.\n";
}

int main(int argc, char * argv[])
{
	static const struct option long_options[] = {
		{ "glob", required_argument, nullptr, 'g' },
		{ "hash", required_argument, nullptr, 'H' },
		{ "xattr", required_argument, nullptr, 'X' },
		{ "help", no_argument, nullptr, 'h' },
		{ nullptr, 0, nullptr, 0 }
	};

    std::unordered_set<std::string> globs;
    std::unordered_set<std::string> paths;
    std::string hash_type = "crc32c";
    std::string xattr = "on";

	int opt;
	while ((opt = getopt_long(argc, argv, "g:H:X:h", long_options, nullptr)) != -1) {
		switch (opt) {
			case 'g':
                globs.insert(optarg);
				break;
			case 'H': {
                hash_type = optarg;
				break;
            }
			case 'X': {
                xattr = optarg;
				break;
            }
			case 'h':
				print_usage(std::cout);
				return 0;
			default:
				print_usage(std::cerr);
				return 1;
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
        return 1;
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
        return 1;
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
        print_usage(std::cerr);
        return 1;
        
        // don't like the idea of defaulting to current directory if no paths provided
//        char* rp = realpath(".", nullptr);
//        if (rp != nullptr)
//        {
//            paths.emplace(rp);
//            free(rp);
//        } else {
//            paths.emplace(".");
//        }
    }

    // empty globs is OK, the code handles it properly by including all files
    
    int result = EXIT_SUCCESS;
    
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
    
    result = fingerprint::find_files(paths, globs);
    
	return result;
}
