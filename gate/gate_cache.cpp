//
//  gate_cache.cpp
//  gate
//
//  Per-task cache files with flock concurrency control.
//  Each task gets its own file: <cache_dir>/<signature>.<format>
//  Supports binary plist (default) and JSON formats.
//

#include "gate_cache.h"

#include <iostream>
#include <fstream>
#include <algorithm>
#include <cstdio>
#include <sys/file.h>
#include <sys/stat.h>

#include <CoreFoundation/CoreFoundation.h>
#include "../fingerprint/json_serialization.h"
#include "../fingerprint/CFObj.h"
#include "path_helpers.h"

#include "blake3.h"

extern bool g_verbose;

// Helper to create CFString from std::string
static CFStringRef create_cfstring(const std::string& s)
{
    return CFStringCreateWithBytes(kCFAllocatorDefault,
                                  (const UInt8*)s.data(), s.size(),
                                  kCFStringEncodingUTF8, false);
}

// Helper to extract std::string from CFString
static std::string cfstring_to_string(CFStringRef cf)
{
    if (!cf) return {};
    const char* ptr = CFStringGetCStringPtr(cf, kCFStringEncodingUTF8);
    if (ptr) return std::string(ptr);

    CFIndex len = CFStringGetLength(cf);
    CFIndex bufSize = 0;
    CFStringGetBytes(cf, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, nullptr, 0, &bufSize);
    std::string result(bufSize, '\0');
    CFStringGetBytes(cf, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false,
                     (UInt8*)result.data(), bufSize, nullptr);
    return result;
}

// Helper to extract uint64 from hex CFString
static uint64_t cfstring_to_hex64(CFStringRef cf)
{
    std::string s = cfstring_to_string(cf);
    return strtoull(s.c_str(), nullptr, 16);
}

// Helper to create hex CFString from uint64
static CFStringRef hex64_to_cfstring(uint64_t val)
{
    char buf[17];
    snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)val);
    return CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
}

// Helper to create CFArray of CFStrings from vector
static CFArrayRef create_cfarray(const std::vector<std::string>& vec)
{
    CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, vec.size(), &kCFTypeArrayCallBacks);
    for (const auto& s : vec)
    {
        CFObj<CFStringRef> cf(create_cfstring(s));
        CFArrayAppendValue(arr, (CFStringRef)cf);
    }
    return arr;
}

// Helper to extract vector of strings from CFArray
static std::vector<std::string> cfarray_to_vector(CFArrayRef arr)
{
    std::vector<std::string> result;
    if (!arr) return result;
    CFIndex count = CFArrayGetCount(arr);
    result.reserve(count);
    for (CFIndex i = 0; i < count; ++i)
    {
        CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(arr, i);
        result.push_back(cfstring_to_string(s));
    }
    return result;
}


std::string compute_task_signature(const std::vector<std::string>& inputs,
                                   const std::vector<std::string>& outputs,
                                   const std::string& command,
                                   const std::string& hash_algorithm,
                                   const std::vector<std::string>& signature_keys)
{
    // Sort copies of paths for deterministic signature
    std::vector<std::string> sorted_inputs = inputs;
    std::vector<std::string> sorted_outputs = outputs;
    std::sort(sorted_inputs.begin(), sorted_inputs.end());
    std::sort(sorted_outputs.begin(), sorted_outputs.end());

    blake3_hasher hasher;
    blake3_hasher_init(&hasher);

    if (g_verbose)
    {
        std::cerr << "gate: task signature includes:\n";
        std::cerr << "\tcommand: " << command << '\n';
        std::cerr << "\t" << inputs.size() << " input(s)\n";
        std::cerr << "\t" << outputs.size() << " output(s)\n";
        std::cerr << "\thash algorithm: " << hash_algorithm << '\n';
        if (signature_keys.size() > 0)
        {
            std::cerr << "\tsignature keys:";
            for (const auto& sig : signature_keys)
             std::cerr << " " << sig;
            std::cerr << "\n";
        }
    }

    for (const auto& p : sorted_inputs)
        blake3_hasher_update(&hasher, p.data(), p.size() + 1); // include null

    blake3_hasher_update(&hasher, "\x01", 1); // separator

    for (const auto& p : sorted_outputs)
        blake3_hasher_update(&hasher, p.data(), p.size() + 1);

    blake3_hasher_update(&hasher, "\x02", 1); // separator

    blake3_hasher_update(&hasher, command.data(), command.size());

    blake3_hasher_update(&hasher, "\x03", 1); // separator

    blake3_hasher_update(&hasher, hash_algorithm.data(), hash_algorithm.size());

    // Signature keys are hashed in order (not sorted — order may be meaningful)
    for (const auto& key : signature_keys)
    {
        blake3_hasher_update(&hasher, "\x04", 1); // separator per key
        blake3_hasher_update(&hasher, key.data(), key.size());
    }

    // auto-detect Xcode key env vars for build configuration
    // and automatically use them for task signature to distingush as different tasks
    const char* xcode_var = getenv("CONFIGURATION");
    if (xcode_var != nullptr)
    {
        blake3_hasher_update(&hasher, "\x05", 1); // separator per key
        blake3_hasher_update(&hasher, xcode_var, strlen(xcode_var));
        std::cerr << "\tCONFIGURATION=" << xcode_var << '\n';
    }
    
    xcode_var = getenv("EFFECTIVE_PLATFORM_NAME");
    if (xcode_var != nullptr)
    {
        blake3_hasher_update(&hasher, "\x05", 1); // separator per key
        blake3_hasher_update(&hasher, xcode_var, strlen(xcode_var));
        std::cerr << "\tEFFECTIVE_PLATFORM_NAME=" << xcode_var << '\n';
    }

    xcode_var = getenv("ARCHS");
    if (xcode_var != nullptr)
    {
        blake3_hasher_update(&hasher, "\x05", 1); // separator per key
        blake3_hasher_update(&hasher, xcode_var, strlen(xcode_var));
        std::cerr << "\tARCHS=" << xcode_var << '\n';
    }
   
    uint64_t key = 0;
    blake3_hasher_finalize(&hasher, (uint8_t*)&key, sizeof(key));

    char hex[17];
    snprintf(hex, sizeof(hex), "%016llx", (unsigned long long)key);

    if (g_verbose)
    {
        std::cerr << "gate: task signature: " << hex << '\n';
    }

    return std::string(hex);
}


static std::string cache_file_path(const std::string& cache_dir,
                                   const std::string& signature,
                                   CacheFormat format)
{
    const char* ext = (format == CacheFormat::Json) ? "json" : "plist";
    return cache_dir + "/" + signature + "." + ext;
}

// Serialize a CFDictionary to a file in the given format.
// Returns 0 on success.
static int serialize_cache(CFDictionaryRef dict, const std::string& path, CacheFormat format)
{
    if (format == CacheFormat::Json)
        return serialize_dict_to_json(dict, path.c_str());

    // Binary plist
    CFErrorRef error = nullptr;
    CFObj<CFDataRef> data(CFPropertyListCreateData(kCFAllocatorDefault, dict,
        kCFPropertyListBinaryFormat_v1_0, 0, &error));
    if (data == nullptr)
    {
        std::cerr << "error: failed to serialize plist";
        if (error != nullptr)
        {
            CFObj<CFErrorRef> err_guard(error);
            CFObj<CFStringRef> desc(CFErrorCopyDescription(error));
            char buf[256];
            if (CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8))
                std::cerr << ": " << buf;
        }
        std::cerr << '\n';
        return 1;
    }

    std::ofstream out(path, std::ios::out | std::ios::binary);
    if (out.fail())
    {
        std::cerr << "error: cannot open cache file for writing: " << path << '\n';
        return 1;
    }

    out.write(reinterpret_cast<const char*>(CFDataGetBytePtr(data)), CFDataGetLength(data));
    return out.fail() ? 1 : 0;
}

// Deserialize a CFMutableDictionary from a file in the given format.
// Returns nullptr on failure.
static CFMutableDictionaryRef deserialize_cache(const std::string& path, CacheFormat format)
{
    if (format == CacheFormat::Json)
        return deserialize_json_from_file(path.c_str());

    // Binary plist
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (file.fail())
        return nullptr;

    std::streamsize size = file.tellg();
    if (size <= 0)
        return nullptr;

    file.seekg(0, std::ios::beg);
    std::vector<char> buffer(size);
    if (!file.read(buffer.data(), size))
        return nullptr;

    CFObj<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, (const UInt8*)buffer.data(), size));
    if (data == nullptr)
        return nullptr;

    CFErrorRef error = nullptr;
    CFPropertyListFormat plist_format;
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFPropertyListCreateWithData(
        kCFAllocatorDefault, data, kCFPropertyListMutableContainers, &plist_format, &error);

    if (dict == nullptr)
    {
        if (error != nullptr)
            CFRelease(error);
        return nullptr;
    }

    return dict;
}


bool cache_lookup(const std::string& cache_dir,
                  CacheFormat format,
                  const std::string& signature,
                  CacheEntry& out_entry)
{
    std::string path = cache_file_path(cache_dir, signature, format);

    // Try to open and lock for reading
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;

    flock(fd, LOCK_SH);

    CFMutableDictionaryRef dict = deserialize_cache(path, format);
    flock(fd, LOCK_UN);
    close(fd);

    if (!dict) return false;
    CFObj<CFMutableDictionaryRef> dict_guard(dict);

    // Extract fields directly from the flat dictionary
    CFObj<CFStringRef> k_command(create_cfstring("command"));
    CFObj<CFStringRef> k_inputs(create_cfstring("inputs"));
    CFObj<CFStringRef> k_outputs(create_cfstring("outputs"));
    CFObj<CFStringRef> k_input_fingerprint(create_cfstring("input_fingerprint"));
    CFObj<CFStringRef> k_output_fingerprint(create_cfstring("output_fingerprint"));
    CFObj<CFStringRef> k_hash_algo(create_cfstring("hash_algorithm"));
    CFObj<CFStringRef> k_timestamp(create_cfstring("timestamp"));

    out_entry.command = cfstring_to_string((CFStringRef)CFDictionaryGetValue(dict, k_command.Get()));
    out_entry.inputs = cfarray_to_vector((CFArrayRef)CFDictionaryGetValue(dict, k_inputs.Get()));
    out_entry.outputs = cfarray_to_vector((CFArrayRef)CFDictionaryGetValue(dict, k_outputs.Get()));
    out_entry.input_fingerprint = cfstring_to_hex64((CFStringRef)CFDictionaryGetValue(dict, k_input_fingerprint.Get()));
    out_entry.output_fingerprint = cfstring_to_hex64((CFStringRef)CFDictionaryGetValue(dict, k_output_fingerprint.Get()));
    out_entry.hash_algorithm = cfstring_to_string((CFStringRef)CFDictionaryGetValue(dict, k_hash_algo.Get()));
    out_entry.timestamp = cfstring_to_string((CFStringRef)CFDictionaryGetValue(dict, k_timestamp.Get()));

    return true;
}


bool cache_store(const std::string& cache_dir,
                 CacheFormat format,
                 const std::string& signature,
                 const CacheEntry& entry)
{
    // Ensure cache directory exists
    mkdir(cache_dir.c_str(), 0755);

    std::string path = cache_file_path(cache_dir, signature, format);

    // Open/create and lock exclusively
    int fd = open(path.c_str(), O_RDWR | O_CREAT, 0644);
    if (fd < 0)
    {
        std::cerr << "error: cannot open cache file: " << path << '\n';
        return false;
    }
    flock(fd, LOCK_EX);

    // Build the flat entry dictionary
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 8,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFObj<CFMutableDictionaryRef> dict_guard(dict);

    int version_val = 1;
    CFObj<CFNumberRef> version(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &version_val));
    CFObj<CFStringRef> k_version(create_cfstring("version"));
    CFDictionarySetValue(dict, k_version.Get(), version.Get());

    CFObj<CFStringRef> k_command(create_cfstring("command"));
    CFObj<CFStringRef> v_command(create_cfstring(entry.command));
    CFDictionarySetValue(dict, k_command.Get(), v_command.Get());

    CFObj<CFStringRef> k_inputs(create_cfstring("inputs"));
    CFObj<CFArrayRef> v_inputs(create_cfarray(entry.inputs));
    CFDictionarySetValue(dict, k_inputs.Get(), v_inputs.Get());

    CFObj<CFStringRef> k_outputs(create_cfstring("outputs"));
    CFObj<CFArrayRef> v_outputs(create_cfarray(entry.outputs));
    CFDictionarySetValue(dict, k_outputs.Get(), v_outputs.Get());

    CFObj<CFStringRef> k_input_fingerprint(create_cfstring("input_fingerprint"));
    CFObj<CFStringRef> v_input_fingerprint(hex64_to_cfstring(entry.input_fingerprint));
    CFDictionarySetValue(dict, k_input_fingerprint.Get(), v_input_fingerprint.Get());

    CFObj<CFStringRef> k_output_fingerprint(create_cfstring("output_fingerprint"));
    CFObj<CFStringRef> v_output_fingerprint(hex64_to_cfstring(entry.output_fingerprint));
    CFDictionarySetValue(dict, k_output_fingerprint.Get(), v_output_fingerprint.Get());

    CFObj<CFStringRef> k_hash_algo(create_cfstring("hash_algorithm"));
    CFObj<CFStringRef> v_hash_algo(create_cfstring(entry.hash_algorithm));
    CFDictionarySetValue(dict, k_hash_algo.Get(), v_hash_algo.Get());

    CFObj<CFStringRef> k_timestamp(create_cfstring("timestamp"));
    CFObj<CFStringRef> v_timestamp(create_cfstring(entry.timestamp));
    CFDictionarySetValue(dict, k_timestamp.Get(), v_timestamp.Get());

    // Atomic write: serialize to temp file, then rename
    std::string tmp_path = path + ".tmp";
    int result = serialize_cache(dict, tmp_path, format);
    if (result == 0)
    {
        rename(tmp_path.c_str(), path.c_str());
        if (g_verbose)
        {
            std::string absolute_path = resolve_path(path);
            std::cerr << "gate: task cache stored in: " << absolute_path << '\n';
            std::cerr << "\tnew input fingerprint:  " << std::hex << entry.input_fingerprint << '\n'
                      << "\tnew output fingerprint: " << entry.output_fingerprint << std::dec << '\n';
        }
    }
    else
    {
        std::cerr << "error: failed to write cache\n";
    }

    flock(fd, LOCK_UN);
    close(fd);

    return (result == 0);
}
