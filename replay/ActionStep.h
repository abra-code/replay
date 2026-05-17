#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include "CFObj.h"
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// Forward declarations to avoid pulling full yyjson headers into every translation unit.
// Callers that construct a yyjson-backed ActionStep must include yyjson.hpp themselves.
struct yyjson_val;
namespace Json { class Document; }

// Thin adaptor over a step dictionary, abstracting dual implementation
// - backed by CFDictionaryRef (plist/toll-free-bridged NSDictionary).
// - backed by yyjson_val* (JSON)

class ActionStep {
public:
    ActionStep() = default;

    // plist backing: retains dict for its lifetime.
    explicit ActionStep(CFDictionaryRef dict) noexcept;

    // yyjson backing: val must point to a JSON object node; doc keeps the
    // parsed document alive via shared ownership.
    explicit ActionStep(yyjson_val* val, std::shared_ptr<Json::Document> doc) noexcept;

    // Special members are defined in ActionStep.cpp so that Json::Document is
    // a complete type at the definition site (yyjson.hpp is included there).
    ~ActionStep() noexcept;
    ActionStep(const ActionStep&) noexcept;
    ActionStep& operator=(const ActionStep&) noexcept;
    ActionStep(ActionStep&&) noexcept;
    ActionStep& operator=(ActionStep&&) noexcept;

    std::optional<std::string>              string_value(std::string_view key) const;
    std::optional<std::vector<std::string>> string_array(std::string_view key) const;
    bool                                    bool_value(std::string_view key, bool fallback = false) const;
    int64_t                                 int_value(std::string_view key, int64_t fallback = 0) const;
    // Returns a vector of ActionStep wrappers when the key holds an array of dicts.
    std::optional<std::vector<ActionStep>>  step_array(std::string_view key) const;
    // Returns a single ActionStep wrapper when the key holds a dict value.
    std::optional<ActionStep>               step_value(std::string_view key) const;

    bool empty() const noexcept { return _dict == nullptr && _yyjson_val == nullptr; }

private:
    CFObj<CFDictionaryRef> _dict;
    yyjson_val* _yyjson_val = nullptr;
    std::shared_ptr<Json::Document> _doc; // non-null only for yyjson-backed instances
};
