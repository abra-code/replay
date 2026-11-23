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
// Returns the CF object, or null on failure.
// All containers are created mutable so callers (compare_snapshots, cache_lookup)
// can resort / mutate them in place — matching the prior NSJSONReadingMutableContainers
// behavior.
// Containers nested deeper than this fail the conversion: it recurses once per level
// (the parser does not), so a cache or snapshot file with very deep nesting would
// otherwise overflow the stack. The files these tools write nest three levels.
static constexpr int kMaxJsonNesting = 256;

static CFObj<CFTypeRef> yyjson_to_cf(Json::Val v, int depth, bool &too_deep) noexcept
{
    if (!v.valid())
        return CFObj<CFTypeRef>();
    if (depth > kMaxJsonNesting)
    {
        too_deep = true;
        return CFObj<CFTypeRef>();
    }

    if (v.is_str())
    {
        auto sv = v.get_str();
        if (!sv)
            return CFObj<CFTypeRef>();
        return CFObj<CFTypeRef>(CFStr(*sv).Detach());
    }
    if (v.is_sint())
    {
        int64_t n = *v.get_sint();
        return CFObj<CFTypeRef>(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &n));
    }
    if (v.is_uint())
    {
        // CFNumber has no unsigned type; squeeze into SInt64.
        // All numeric fields we round-trip fit in 63 bits.
        int64_t n = (int64_t)*v.get_uint();
        return CFObj<CFTypeRef>(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &n));
    }
    if (v.is_real())
    {
        double d = *v.get_real();
        return CFObj<CFTypeRef>(CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &d));
    }
    if (v.is_bool())
    {
        CFBooleanRef b = *v.get_bool() ? kCFBooleanTrue : kCFBooleanFalse;
        return CFObj<CFTypeRef>(b, kCFObjRetain);
    }
    if (v.is_null())
    {
        return CFObj<CFTypeRef>(kCFNull, kCFObjRetain);
    }
    if (v.is_arr())
    {
        CFMutableArr arr((CFIndex)v.arr_size());
        Json::ArrIter it(v);
        while (it.has_next())
        {
            CFObj<CFTypeRef> cf(yyjson_to_cf(it.next(), depth + 1, too_deep));
            if (too_deep)
                return CFObj<CFTypeRef>();
            if (cf != nullptr)
                arr.AppendValue(cf);
        }
        return CFObj<CFTypeRef>(arr.Detach());
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
            CFObj<CFTypeRef> cf_val(yyjson_to_cf(Json::ObjIter::val(key), depth + 1, too_deep));
            if (too_deep)
                return CFObj<CFTypeRef>();
            if (cf_val != nullptr)
                dict.SetValue(cf_key, (CFTypeRef)cf_val);
        }
        return CFObj<CFTypeRef>(dict.Detach());
    }

    return CFObj<CFTypeRef>();
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

CFMutableDict load_json_file_as_cfdict(const char* path, bool quiet)
{
    yyjson_read_err err{};
    Json::Document doc = Json::parse_file(path, YYJSON_READ_NOFLAG, &err);
    if (!doc)
    {
        if (!quiet)
        {
            std::fprintf(stderr, "Error: failed to parse JSON file %s: %s\n",
                         path, (err.msg != nullptr) ? err.msg : "unknown error");
        }
        return {};
    }

    Json::Val root = doc.root();
    if (!root.is_obj())
    {
        if (!quiet)
            std::fprintf(stderr, "Error: JSON root is not an object: %s\n", path);
        return {};
    }

    bool too_deep = false;
    CFObj<CFTypeRef> converted(yyjson_to_cf(root, 0, too_deep));
    if (too_deep)
    {
        if (!quiet)
            std::fprintf(stderr, "Error: JSON nested too deeply: %s\n", path);
        return {};
    }
    return CFMutableDict((CFMutableDictionaryRef)converted.Detach(), kCFObjDontRetain);
}
