#include <CoreFoundation/CoreFoundation.h>
#include "CFObj.h"
#include "CFType.h"
#include "CFStr.h"
#include "CFArr.h"
#include "CFDict.h"
#include "yyjson.hpp"
#include "ActionStep.h"

// ---------------------------------------------------------------------------
// Special member definitions (Json::Document is complete here via yyjson.hpp)
// ---------------------------------------------------------------------------

ActionStep::ActionStep(CFDictionaryRef dict) noexcept
    : _dict(dict, kCFObjRetain)
{
}

ActionStep::ActionStep(yyjson_val* val, std::shared_ptr<Json::Document> doc) noexcept
    : _yyjson_val(val), _doc(std::move(doc))
{
}

ActionStep::~ActionStep() noexcept = default;

ActionStep::ActionStep(const ActionStep& o) noexcept
    : _dict(o._dict),
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
    CFStringRef str = nullptr;
    if (!_dict.GetValue(CFStr(key), str))
        return std::nullopt;
    return CFStr::ToString(str);
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
    CFArrayRef arrRef = nullptr;
    if (!_dict.GetValue(CFStr(key), arrRef))
        return std::nullopt;
    CFArr arr(arrRef);
    CFIndex count = arr.GetCount();
    std::vector<std::string> result;
    result.reserve(count);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef s = nullptr;
        if (arr.GetValueAtIndex(i, s))
            result.emplace_back(CFStr::ToString(s));
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
    bool b = fallback;
    if (_dict.GetValue(CFStr(key), b))
        return b;
    // Fall back to numeric → bool conversion
    int64_t n = 0;
    if (_dict.GetValue(CFStr(key), n))
        return n != 0;
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
    int64_t n = fallback;
    _dict.GetValue(CFStr(key), n);
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
    CFArrayRef arrRef = nullptr;
    if (!_dict.GetValue(CFStr(key), arrRef))
        return std::nullopt;
    CFArr arr(arrRef);
    CFIndex count = arr.GetCount();
    std::vector<ActionStep> result;
    result.reserve(count);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef dict = nullptr;
        if (arr.GetValueAtIndex(i, dict))
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
    CFDictionaryRef dict = nullptr;
    if (!_dict.GetValue(CFStr(key), dict))
        return std::nullopt;
    return ActionStep(dict);
}
