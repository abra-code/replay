#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// Thin adaptor over a step dictionary.
// Phase 5a: backed by CFDictionaryRef (plist or toll-free-bridged NSDictionary).
// Phase 5b: adds yyjson backing for JSON; callers are unchanged.
class ActionStep {
public:
	ActionStep() = default;

	explicit ActionStep(CFDictionaryRef dict) noexcept : _dict(dict) { if(_dict != nullptr) CFRetain(_dict); }

	~ActionStep() noexcept { if(_dict != nullptr) CFRelease(_dict); }

	ActionStep(const ActionStep& o) noexcept : _dict(o._dict) { if(_dict != nullptr) CFRetain(_dict); }
	ActionStep& operator=(const ActionStep& o) noexcept {
		if(this != &o) {
			if(_dict != nullptr) CFRelease(_dict);
			_dict = o._dict;
			if(_dict != nullptr) CFRetain(_dict);
		}
		return *this;
	}
	ActionStep(ActionStep&& o) noexcept : _dict(o._dict) { o._dict = nullptr; }
	ActionStep& operator=(ActionStep&& o) noexcept {
		if(this != &o) {
			if(_dict != nullptr) CFRelease(_dict);
			_dict = o._dict;
			o._dict = nullptr;
		}
		return *this;
	}

	std::optional<std::string>              string_value(std::string_view key) const;
	std::optional<std::vector<std::string>> string_array(std::string_view key) const;
	bool                                    bool_value(std::string_view key, bool fallback = false) const;
	int64_t                                 int_value(std::string_view key, int64_t fallback = 0) const;
	std::optional<std::vector<ActionStep>>  step_array(std::string_view key) const;

	bool empty() const noexcept { return _dict == nullptr; }

private:
	CFDictionaryRef _dict = nullptr;
};
