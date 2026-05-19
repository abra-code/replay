//
//  json_serialization.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 2/17/26.
//

#include "json_serialization.h"

#include <cstdio>
#include <cstdlib>

#include "yyjson.hpp"
#include "CFObj.h"
#include "CFStr.h"
#include "CFArr.h"
#include "CFDict.h"

// Convert a parsed yyjson value into a CoreFoundation object.
// Returns a +1-retained CF object the caller owns. Returns nullptr on failure.
// All containers are created mutable so callers (compare_snapshots, cache_lookup)
// can resort / mutate them in place — matching the prior NSJSONReadingMutableContainers
// behavior.
static CFTypeRef yyjson_to_cf(Json::Val v) noexcept
{
    if (!v.valid())
        return nullptr;

    if (v.is_str())
    {
        auto sv = v.get_str();
        if (!sv)
            return nullptr;
        return CFStr(*sv).Detach();
    }
    if (v.is_sint())
    {
        int64_t n = *v.get_sint();
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &n);
    }
    if (v.is_uint())
    {
        // CFNumber has no unsigned type; squeeze into SInt64.
        // All numeric fields we round-trip fit in 63 bits.
        int64_t n = (int64_t)*v.get_uint();
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &n);
    }
    if (v.is_real())
    {
        double d = *v.get_real();
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &d);
    }
    if (v.is_bool())
    {
        CFBooleanRef b = *v.get_bool() ? kCFBooleanTrue : kCFBooleanFalse;
        CFRetain(b);
        return b;
    }
    if (v.is_null())
    {
        CFRetain(kCFNull);
        return kCFNull;
    }
    if (v.is_arr())
    {
        CFMutableArr arr((CFIndex)v.arr_size());
        Json::ArrIter it(v);
        while (it.has_next())
        {
            CFObj<CFTypeRef> cf(yyjson_to_cf(it.next()));
            if (cf != nullptr)
                arr.AppendValue(cf);
        }
        return arr.Detach();
    }
    if (v.is_obj())
    {
        CFMutableDict dict;
        Json::ObjIter it(v);
        while (it.has_next())
        {
            Json::Val key = it.next_key();
            auto ksv = key.get_str();
            if (!ksv)
                continue;
            CFStr cf_key(*ksv);
            if (cf_key == nullptr)
                continue;
            CFObj<CFTypeRef> cf_val(yyjson_to_cf(Json::ObjIter::val(key)));
            if (cf_val != nullptr)
                dict.SetValue(cf_key, (CFTypeRef)cf_val);
        }
        return dict.Detach();
    }

    return nullptr;
}

int write_json_doc_to_file(const Json::MutableDoc& doc, const char* path)
{
    yyjson_write_err err{};
    bool ok = yyjson_mut_write_file(path, doc.raw_doc(),
                                    YYJSON_WRITE_PRETTY, nullptr, &err);
    if (!ok)
    {
        std::fprintf(stderr, "Error: failed to write JSON file %s: %s\n",
                     path, (err.msg != nullptr) ? err.msg : "unknown error");
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}

CFMutableDictionaryRef load_json_file_as_cfdict(const char* path)
{
    yyjson_read_err err{};
    Json::Document doc = Json::parse_file(path, YYJSON_READ_NOFLAG, &err);
    if (!doc)
    {
        std::fprintf(stderr, "Error: failed to parse JSON file %s: %s\n",
                     path, (err.msg != nullptr) ? err.msg : "unknown error");
        return nullptr;
    }

    Json::Val root = doc.root();
    if (!root.is_obj())
    {
        std::fprintf(stderr, "Error: JSON root is not an object: %s\n", path);
        return nullptr;
    }

    return (CFMutableDictionaryRef)yyjson_to_cf(root);
}
