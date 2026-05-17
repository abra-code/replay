#include <CoreFoundation/CoreFoundation.h>
#include "CFObj.h"
#include "CFType.h"
#include "yyjson.hpp"
#include "ActionStep.h"

// ---------------------------------------------------------------------------
// CF helpers
// ---------------------------------------------------------------------------

static inline CFStringRef cf_key(std::string_view sv)
{
    return CFStringCreateWithBytes(kCFAllocatorDefault,
        (const UInt8*)sv.data(), (CFIndex)sv.size(),
        kCFStringEncodingUTF8, false);
}

static std::optional<std::string> cf_string_to_std(CFTypeRef val)
{
    CFStringRef str = CFType<CFStringRef>::DynamicCast(val);
    if (str == nullptr)
        return std::nullopt;
    if (const char* ptr = CFStringGetCStringPtr(str, kCFStringEncodingUTF8))
        return std::string(ptr);
    CFIndex maxSize = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(str), kCFStringEncodingUTF8) + 1;
    std::string result(maxSize, '\0');
    if (CFStringGetCString(str, result.data(), maxSize, kCFStringEncodingUTF8)) {
        result.resize(strlen(result.c_str()));
        return result;
    }
    return std::nullopt;
}

// ---------------------------------------------------------------------------
// Special member definitions (Json::Document is complete here via yyjson.hpp)
// ---------------------------------------------------------------------------

ActionStep::ActionStep(CFDictionaryRef dict) noexcept
{
    _dict.Adopt(dict, kCFObjRetain);
}

ActionStep::ActionStep(yyjson_val* val, std::shared_ptr<Json::Document> doc) noexcept
    : _yyjson_val(val), _doc(std::move(doc))
{
}

ActionStep::~ActionStep() noexcept = default;

ActionStep::ActionStep(const ActionStep& o) noexcept
    : _dict(static_cast<CFDictionaryRef>(o._dict), kCFObjRetain),
      _yyjson_val(o._yyjson_val), _doc(o._doc)
{
}

ActionStep& ActionStep::operator=(const ActionStep& o) noexcept
{
    if (this != &o) {
        _dict = o._dict;  // releases old, retains new
        _yyjson_val = o._yyjson_val;
        _doc = o._doc;
    }
    return *this;
}

ActionStep::ActionStep(ActionStep&& o) noexcept
    : _yyjson_val(o._yyjson_val), _doc(std::move(o._doc))
{
    _dict.Swap(o._dict);  // steal without retain
    o._yyjson_val = nullptr;
}

ActionStep& ActionStep::operator=(ActionStep&& o) noexcept
{
    if (this != &o) {
        _dict.Adopt(o._dict.Detach());  // steal: releases old, adopts without retain
        _yyjson_val = o._yyjson_val;
        _doc = std::move(o._doc);
        o._yyjson_val = nullptr;
    }
    return *this;
}

// ---------------------------------------------------------------------------
// Accessors — dispatch to CF or yyjson path
// ---------------------------------------------------------------------------

std::optional<std::string> ActionStep::string_value(std::string_view key) const
{
    if (_yyjson_val != nullptr) {
        Json::Val obj{_yyjson_val};
        auto val = obj.obj_get(key);
        if (!val.valid())
            return std::nullopt;
        auto sv = val.get_str();
        if (!sv.has_value())
            return std::nullopt;
        return std::string(*sv);
    }

    if (_dict == nullptr)
        return std::nullopt;
    CFObj<CFStringRef> k(cf_key(key));
    CFTypeRef val = CFDictionaryGetValue(_dict, k);
    return cf_string_to_std(val);
}

std::optional<std::vector<std::string>> ActionStep::string_array(std::string_view key) const
{
    if (_yyjson_val != nullptr) {
        Json::Val obj{_yyjson_val};
        auto val = obj.obj_get(key);
        if (!val.valid() || !val.is_arr())
            return std::nullopt;
        std::vector<std::string> result;
        result.reserve(val.arr_size());
        Json::ArrIter iter(val);
        while (iter.has_next()) {
            auto item = iter.next();
            auto sv = item.get_str();
            if (sv.has_value())
                result.emplace_back(*sv);
        }
        return result;
    }

    if (_dict == nullptr)
        return std::nullopt;
    CFObj<CFStringRef> k(cf_key(key));
    CFArrayRef arr = CFType<CFArrayRef>::DynamicCast(CFDictionaryGetValue(_dict, k));
    if (arr == nullptr)
        return std::nullopt;
    CFIndex count = CFArrayGetCount(arr);
    std::vector<std::string> result;
    result.reserve(count);
    for (CFIndex i = 0; i < count; i++) {
        auto s = cf_string_to_std(CFArrayGetValueAtIndex(arr, i));
        if (s.has_value())
            result.emplace_back(std::move(*s));
    }
    return result;
}

bool ActionStep::bool_value(std::string_view key, bool fallback) const
{
    if (_yyjson_val != nullptr) {
        Json::Val obj{_yyjson_val};
        auto val = obj.obj_get(key);
        if (!val.valid())
            return fallback;
        auto b = val.get_bool();
        if (b.has_value())
            return *b;
        // JSON numbers as booleans (0 / non-zero)
        auto n = val.get_sint();
        if (n.has_value())
            return *n != 0;
        auto u = val.get_uint();
        if (u.has_value())
            return *u != 0;
        return fallback;
    }

    if (_dict == nullptr)
        return fallback;
    CFObj<CFStringRef> k(cf_key(key));
    CFTypeRef val = CFDictionaryGetValue(_dict, k);
    if (val == nullptr)
        return fallback;
    CFBooleanRef b = CFType<CFBooleanRef>::DynamicCast(val);
    if (b != nullptr)
        return CFBooleanGetValue(b);
    CFNumberRef num = CFType<CFNumberRef>::DynamicCast(val);
    if (num != nullptr) {
        int n = 0;
        CFNumberGetValue(num, kCFNumberIntType, &n);
        return n != 0;
    }
    return fallback;
}

int64_t ActionStep::int_value(std::string_view key, int64_t fallback) const
{
    if (_yyjson_val != nullptr) {
        Json::Val obj{_yyjson_val};
        auto val = obj.obj_get(key);
        if (!val.valid())
            return fallback;
        auto s = val.get_sint();
        if (s.has_value())
            return *s;
        auto u = val.get_uint();
        if (u.has_value())
            return (int64_t)*u;
        auto d = val.get_real();
        if (d.has_value())
            return (int64_t)*d;
        return fallback;
    }

    if (_dict == nullptr)
        return fallback;
    CFObj<CFStringRef> k(cf_key(key));
    CFNumberRef num = CFType<CFNumberRef>::DynamicCast(CFDictionaryGetValue(_dict, k));
    if (num == nullptr)
        return fallback;
    int64_t n = fallback;
    CFNumberGetValue(num, kCFNumberSInt64Type, &n);
    return n;
}

std::optional<std::vector<ActionStep>> ActionStep::step_array(std::string_view key) const
{
    if (_yyjson_val != nullptr) {
        Json::Val obj{_yyjson_val};
        auto val = obj.obj_get(key);
        if (!val.valid() || !val.is_arr())
            return std::nullopt;
        std::vector<ActionStep> result;
        result.reserve(val.arr_size());
        Json::ArrIter iter(val);
        while (iter.has_next()) {
            auto item = iter.next();
            if (item.is_obj())
                result.emplace_back(item.raw(), _doc);
        }
        return result;
    }

    if (_dict == nullptr)
        return std::nullopt;
    CFObj<CFStringRef> k(cf_key(key));
    CFArrayRef arr = CFType<CFArrayRef>::DynamicCast(CFDictionaryGetValue(_dict, k));
    if (arr == nullptr)
        return std::nullopt;
    CFIndex count = CFArrayGetCount(arr);
    std::vector<ActionStep> result;
    result.reserve(count);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef dict = CFType<CFDictionaryRef>::DynamicCast(CFArrayGetValueAtIndex(arr, i));
        if (dict != nullptr)
            result.emplace_back(dict);
    }
    return result;
}

std::optional<ActionStep> ActionStep::step_value(std::string_view key) const
{
    if (_yyjson_val != nullptr) {
        Json::Val obj{_yyjson_val};
        auto val = obj.obj_get(key);
        if (!val.valid() || !val.is_obj())
            return std::nullopt;
        return ActionStep(val.raw(), _doc);
    }

    if (_dict == nullptr)
        return std::nullopt;
    CFObj<CFStringRef> k(cf_key(key));
    CFDictionaryRef dict = CFType<CFDictionaryRef>::DynamicCast(CFDictionaryGetValue(_dict, k));
    if (dict == nullptr)
        return std::nullopt;
    return ActionStep(dict);
}
