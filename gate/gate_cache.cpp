//
//  gate_cache.cpp
//  gate
//
//  Per-task cache files, each replaced whole by renaming a temp file over it.
//  Each task gets its own file: <cache_dir>/<signature>.<format>
//  Supports binary plist (default) and JSON formats.
//

#include "gate_cache.h"

#include <iostream>
#include <fstream>
#include <algorithm>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include <CoreFoundation/CoreFoundation.h>
#include "json_serialization.h"
#include "yyjson.hpp"
#include "CFObj.h"
#include "CFStr.h"
#include "CFArr.h"
#include "CFDict.h"
#include "FileHelpers.h"

#include "blake3.h"

extern bool g_verbose;

// Build a CFMutableArr of CFStrings from a vector
static CFMutableArr cfarray_from_vector(const std::vector<std::string>& vec)
{
    CFMutableArr arr((CFIndex)vec.size());
    for (const auto& s : vec)
        arr.AppendValue(CFStr(s));
    return arr;
}

// Extract vector of strings from a CFArrayRef (borrowed)
static std::vector<std::string> cfarray_to_vector(CFArrayRef arrRef)
{
    std::vector<std::string> result;
    if (arrRef == nullptr)
        return result;
    CFArr arr(arrRef);
    CFIndex count = arr.GetCount();
    result.reserve(count);
    for (CFIndex i = 0; i < count; ++i)
    {
        CFStringRef s = nullptr;
        if (arr.GetValueAtIndex(i, s))
            result.push_back(CFStr::ToString(s));
    }
    return result;
}

// Extract uint64 from hex CFString
static uint64_t cfstring_to_hex64(CFStringRef cf)
{
    std::string s = CFStr::ToString(cf);
    return strtoull(s.c_str(), nullptr, 16);
}

// Build a CFStr containing a 16-char hex representation of a uint64
static CFStr hex64_to_cfstr(uint64_t val)
{
    char buf[17];
    snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)val);
    return CFStr(std::string_view(buf));
}


std::string compute_task_signature(const std::vector<std::string>& inputs,
                                   const std::vector<std::string>& outputs,
                                   const std::vector<std::string>& exclude_inputs,
                                   const std::string& command,
                                   const std::string& hash_algorithm,
                                   const std::vector<std::string>& signature_keys)
{
    // Sort copies of paths for deterministic signature
    std::vector<std::string> sorted_inputs = inputs;
    std::vector<std::string> sorted_outputs = outputs;
    std::vector<std::string> sorted_excludes = exclude_inputs;
    std::sort(sorted_inputs.begin(), sorted_inputs.end());
    std::sort(sorted_outputs.begin(), sorted_outputs.end());
    std::sort(sorted_excludes.begin(), sorted_excludes.end());

    blake3_hasher hasher;
    blake3_hasher_init(&hasher);

    if (g_verbose)
    {
        std::cerr << "gate: task signature includes:\n";
        std::cerr << "\tcommand: " << command << '\n';
        std::cerr << "\t" << inputs.size() << " input(s)\n";
        std::cerr << "\t" << outputs.size() << " output(s)\n";
        std::cerr << "\t" << exclude_inputs.size() << " exclude(s)\n";
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

    blake3_hasher_update(&hasher, "\x06", 1); // separator before excludes

    for (const auto& p : sorted_excludes)
        blake3_hasher_update(&hasher, p.data(), p.size() + 1);

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

// Build the cache entry JSON directly via yyjson — parallel to the CFDict
// builder in cache_store_plist. Keeps the JSON path off CFDictionary entirely.
static void build_cache_json(const CacheEntry& entry, Json::MutableDoc& doc)
{
    auto arr_from_vec = [&](const std::vector<std::string>& vec) {
        Json::MutableVal arr = doc.new_arr();
        for (const auto& s : vec)
            doc.arr_append(arr, doc.new_str(s));
        return arr;
    };

    auto hex64 = [](uint64_t val) {
        char buf[17];
        snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)val);
        return std::string(buf);
    };

    Json::MutableVal root = doc.new_obj();
    doc.obj_add(root, "version",            doc.new_sint(1));
    doc.obj_add(root, "command",            doc.new_str(entry.command));
    doc.obj_add(root, "inputs",             arr_from_vec(entry.inputs));
    doc.obj_add(root, "outputs",            arr_from_vec(entry.outputs));
    doc.obj_add(root, "exclude_inputs",     arr_from_vec(entry.exclude_inputs));
    doc.obj_add(root, "input_fingerprint",  doc.new_str(hex64(entry.input_fingerprint)));
    doc.obj_add(root, "output_fingerprint", doc.new_str(hex64(entry.output_fingerprint)));
    doc.obj_add(root, "hash_algorithm",     doc.new_str(entry.hash_algorithm));
    doc.obj_add(root, "timestamp",          doc.new_str(entry.timestamp));
    doc.set_root(root);
}

// Populate a CFMutableDict with the cache entry fields (for binary-plist serialization).
static void populate_cache_cfdict(const CacheEntry& entry, CFMutableDict& dict)
{
    dict.SetValue(CFSTR("version"), (int64_t)1);
    dict.SetValue(CFSTR("command"), CFStr(entry.command));
    dict.SetValue(CFSTR("inputs"), cfarray_from_vector(entry.inputs));
    dict.SetValue(CFSTR("outputs"), cfarray_from_vector(entry.outputs));
    dict.SetValue(CFSTR("exclude_inputs"), cfarray_from_vector(entry.exclude_inputs));
    dict.SetValue(CFSTR("input_fingerprint"), hex64_to_cfstr(entry.input_fingerprint));
    dict.SetValue(CFSTR("output_fingerprint"), hex64_to_cfstr(entry.output_fingerprint));
    dict.SetValue(CFSTR("hash_algorithm"), CFStr(entry.hash_algorithm));
    dict.SetValue(CFSTR("timestamp"), CFStr(entry.timestamp));
}

// Serialize a CFDictionary to binary plist bytes. Returns false on failure.
static bool serialize_dict_to_plist(CFDictionaryRef dict, std::string& out_bytes)
{
    CFObj<CFErrorRef> error;
    CFObj<CFDataRef> data(CFPropertyListCreateData(kCFAllocatorDefault, dict,
        kCFPropertyListBinaryFormat_v1_0, 0, &error));
    if (data == nullptr)
    {
        std::cerr << "error: failed to serialize plist";
        if (error != nullptr)
        {
            CFObj<CFStringRef> desc(CFErrorCopyDescription(error));
            std::cerr << ": " << CFStr::ToString(desc);
        }
        std::cerr << '\n';
        return false;
    }

    out_bytes.assign(reinterpret_cast<const char*>(CFDataGetBytePtr(data)), (size_t)CFDataGetLength(data));
    return true;
}

// Load a binary plist into a CFMutableDictionary. Returns empty CFMutableDict on failure.
static CFMutableDict load_plist_as_cfdict(const std::string& path)
{
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (file.fail())
        return {};

    std::streamsize size = file.tellg();
    if (size <= 0)
        return {};

    file.seekg(0, std::ios::beg);
    std::vector<char> buffer(size);
    if (!file.read(buffer.data(), size))
        return {};

    CFObj<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, (const UInt8*)buffer.data(), size));
    if (data == nullptr)
        return {};

    CFObj<CFErrorRef> error;
    CFPropertyListFormat plist_format;
    CFObj<CFPropertyListRef> plist(CFPropertyListCreateWithData(
        kCFAllocatorDefault, data, kCFPropertyListMutableContainers, &plist_format, &error));

    // A damaged or planted entry whose root is not a dictionary must not be used as one:
    // CFDictionary calls on an array or a string abort the process.
    if (plist == nullptr || CFGetTypeID(plist) != CFDictionaryGetTypeID())
        return {};

    return CFMutableDict((CFMutableDictionaryRef)(CFPropertyListRef)plist, kCFObjRetain);
}


bool cache_lookup(const std::string& cache_dir,
                  CacheFormat format,
                  const std::string& signature,
                  CacheEntry& out_entry)
{
    // A cache folder that belongs to another user could hold entries that user wrote,
    // and an entry decides whether the command runs: it is not used. A missing folder
    // is the common first run and not worth a message.
    struct stat dir_info;
    if (stat(cache_dir.c_str(), &dir_info) != 0)
        return false;
    if (dir_info.st_uid != geteuid())
    {
        std::cerr << "warning: cache folder " << cache_dir
                  << " belongs to another user; its entries are not used\n";
        return false;
    }

    std::string path = cache_file_path(cache_dir, signature, format);

    // No entry yet is the common case and not worth a message. No lock is needed:
    // cache_store replaces an entry by renaming a complete file over it, so a reader
    // sees the old entry or the new one, never part of one. Only a regular file of this
    // user counts: a link, or a file another user put in a folder they can write, does not.
    struct stat entry_info;
    if (lstat(path.c_str(), &entry_info) != 0)
        return false;
    if (!S_ISREG(entry_info.st_mode) || entry_info.st_uid != geteuid())
    {
        if (g_verbose)
            std::cerr << "gate: cache entry " << path << " is not a regular file of this user; not used\n";
        return false;
    }

    CFMutableDict dict = (format == CacheFormat::Json)
        ? load_json_file_as_cfdict(path.c_str())
        : load_plist_as_cfdict(path);

    // The loaders return an empty dictionary for a file they could not read or parse.
    if (dict == nullptr || CFDictionaryGetCount(dict) == 0)
        return false;

    // Extract fields directly from the flat dictionary
    CFStringRef command_str = nullptr;
    if (dict.GetValue(CFSTR("command"), command_str))
        out_entry.command = CFStr::ToString(command_str);

    CFArrayRef inputs_arr = nullptr;
    if (dict.GetValue(CFSTR("inputs"), inputs_arr))
        out_entry.inputs = cfarray_to_vector(inputs_arr);

    CFArrayRef outputs_arr = nullptr;
    if (dict.GetValue(CFSTR("outputs"), outputs_arr))
        out_entry.outputs = cfarray_to_vector(outputs_arr);

    CFArrayRef excludes_arr = nullptr;
    if (dict.GetValue(CFSTR("exclude_inputs"), excludes_arr))
        out_entry.exclude_inputs = cfarray_to_vector(excludes_arr);

    CFStringRef input_fp = nullptr;
    if (dict.GetValue(CFSTR("input_fingerprint"), input_fp))
        out_entry.input_fingerprint = cfstring_to_hex64(input_fp);

    CFStringRef output_fp = nullptr;
    if (dict.GetValue(CFSTR("output_fingerprint"), output_fp))
        out_entry.output_fingerprint = cfstring_to_hex64(output_fp);

    CFStringRef hash_algo = nullptr;
    if (dict.GetValue(CFSTR("hash_algorithm"), hash_algo))
        out_entry.hash_algorithm = CFStr::ToString(hash_algo);

    CFStringRef timestamp = nullptr;
    if (dict.GetValue(CFSTR("timestamp"), timestamp))
        out_entry.timestamp = CFStr::ToString(timestamp);

    return true;
}


bool cache_store(const std::string& cache_dir,
                 CacheFormat format,
                 const std::string& signature,
                 const CacheEntry& entry)
{
    // Create the cache folder if it is missing; a failure other than "already there",
    // or something in its place that is not a folder, ends the store with a message.
    if (mkdir(cache_dir.c_str(), 0755) != 0 && errno != EEXIST)
    {
        std::cerr << "error: cannot create cache folder " << cache_dir << ": " << strerror(errno) << '\n';
        return false;
    }
    struct stat dir_info;
    if (stat(cache_dir.c_str(), &dir_info) != 0 || !S_ISDIR(dir_info.st_mode))
    {
        std::cerr << "error: cache folder is not a folder: " << cache_dir << '\n';
        return false;
    }
    if (dir_info.st_uid != geteuid())
    {
        std::cerr << "error: cache folder " << cache_dir << " belongs to another user; the entry is not written\n";
        return false;
    }

    // Serialize first, so a failure here leaves nothing behind in the cache folder.
    // JSON path bypasses CFDictionary entirely (parallel yyjson builder).
    std::string bytes;
    if (format == CacheFormat::Json)
    {
        Json::MutableDoc doc;
        build_cache_json(entry, doc);
        bytes = doc.to_string(YYJSON_WRITE_PRETTY);
        if (bytes.empty())
        {
            std::cerr << "error: failed to serialize cache entry as JSON\n";
            return false;
        }
    }
    else
    {
        CFMutableDict dict;
        populate_cache_cfdict(entry, dict);
        if (!serialize_dict_to_plist(dict, bytes))
            return false;
    }

    // Atomic write: a temp file of this process's own, then rename over the entry.
    // The process id in the name keeps two runs of the same task from writing one temp
    // file; the last rename wins, and either entry is complete. O_EXCL|O_NOFOLLOW
    // refuses anything already at that name, a link planted by anyone else who can
    // write the cache folder included; the unlink first clears a temp left by a crashed run that
    // had the same process id. Entries are readable by this user only: they hold the
    // full command line, which can carry a token or a password.
    std::string path = cache_file_path(cache_dir, signature, format);
    std::string tmp_path = path + "." + std::to_string((long)getpid()) + ".tmp";
    unlink(tmp_path.c_str());
    int fd = open(tmp_path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0)
    {
        std::cerr << "error: cannot create cache file " << tmp_path << ": " << strerror(errno) << '\n';
        return false;
    }

    bool written = file_helpers::write_all(fd, bytes.data(), bytes.size());
    int write_errno = errno;
    if (close(fd) != 0 && written)
    {
        written = false;
        write_errno = errno;
    }
    if (!written)
    {
        std::cerr << "error: cannot write cache file " << tmp_path << ": " << strerror(write_errno) << '\n';
        unlink(tmp_path.c_str());
        return false;
    }

    if (rename(tmp_path.c_str(), path.c_str()) != 0)
    {
        std::cerr << "error: cannot replace cache file " << path << ": " << strerror(errno) << '\n';
        unlink(tmp_path.c_str());
        return false;
    }

    if (g_verbose)
    {
        std::string absolute_path = file_helpers::resolve_path(path);
        std::cerr << "gate: task cache stored in: " << absolute_path << '\n';
        std::cerr << "\tnew input fingerprint:  " << std::hex << entry.input_fingerprint << '\n'
                  << "\tnew output fingerprint: " << entry.output_fingerprint << std::dec << '\n';
    }

    return true;
}
