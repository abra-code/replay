#include <CoreFoundation/CoreFoundation.h>
#include "ActionStep.h"

static inline CFStringRef cf_key(std::string_view sv) {
	return CFStringCreateWithBytes(kCFAllocatorDefault,
		(const UInt8*)sv.data(), (CFIndex)sv.size(),
		kCFStringEncodingUTF8, false);
}

static std::optional<std::string> cf_string_to_std(CFTypeRef val) {
	if(val == nullptr || CFGetTypeID(val) != CFStringGetTypeID())
		return std::nullopt;
	CFStringRef str = (CFStringRef)val;
	if(const char* ptr = CFStringGetCStringPtr(str, kCFStringEncodingUTF8))
		return std::string(ptr);
	CFIndex maxSize = CFStringGetMaximumSizeForEncoding(
		CFStringGetLength(str), kCFStringEncodingUTF8) + 1;
	std::string result(maxSize, '\0');
	if(CFStringGetCString(str, result.data(), maxSize, kCFStringEncodingUTF8)) {
		result.resize(strlen(result.c_str()));
		return result;
	}
	return std::nullopt;
}

std::optional<std::string> ActionStep::string_value(std::string_view key) const {
	if(_dict == nullptr) return std::nullopt;
	CFStringRef k = cf_key(key);
	CFTypeRef val = CFDictionaryGetValue(_dict, k);
	CFRelease(k);
	return cf_string_to_std(val);
}

std::optional<std::vector<std::string>> ActionStep::string_array(std::string_view key) const {
	if(_dict == nullptr) return std::nullopt;
	CFStringRef k = cf_key(key);
	CFTypeRef val = CFDictionaryGetValue(_dict, k);
	CFRelease(k);
	if(val == nullptr || CFGetTypeID(val) != CFArrayGetTypeID()) return std::nullopt;
	CFArrayRef arr = (CFArrayRef)val;
	CFIndex count = CFArrayGetCount(arr);
	std::vector<std::string> result;
	result.reserve(count);
	for(CFIndex i = 0; i < count; i++) {
		auto s = cf_string_to_std(CFArrayGetValueAtIndex(arr, i));
		if(s.has_value()) result.emplace_back(std::move(*s));
	}
	return result;
}

bool ActionStep::bool_value(std::string_view key, bool fallback) const {
	if(_dict == nullptr) return fallback;
	CFStringRef k = cf_key(key);
	CFTypeRef val = CFDictionaryGetValue(_dict, k);
	CFRelease(k);
	if(val == nullptr) return fallback;
	if(CFGetTypeID(val) == CFBooleanGetTypeID())
		return CFBooleanGetValue((CFBooleanRef)val);
	if(CFGetTypeID(val) == CFNumberGetTypeID()) {
		int n = 0;
		CFNumberGetValue((CFNumberRef)val, kCFNumberIntType, &n);
		return n != 0;
	}
	return fallback;
}

int64_t ActionStep::int_value(std::string_view key, int64_t fallback) const {
	if(_dict == nullptr) return fallback;
	CFStringRef k = cf_key(key);
	CFTypeRef val = CFDictionaryGetValue(_dict, k);
	CFRelease(k);
	if(val == nullptr || CFGetTypeID(val) != CFNumberGetTypeID()) return fallback;
	int64_t n = fallback;
	CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &n);
	return n;
}

std::optional<std::vector<ActionStep>> ActionStep::step_array(std::string_view key) const {
	if(_dict == nullptr) return std::nullopt;
	CFStringRef k = cf_key(key);
	CFTypeRef val = CFDictionaryGetValue(_dict, k);
	CFRelease(k);
	if(val == nullptr || CFGetTypeID(val) != CFArrayGetTypeID()) return std::nullopt;
	CFArrayRef arr = (CFArrayRef)val;
	CFIndex count = CFArrayGetCount(arr);
	std::vector<ActionStep> result;
	result.reserve(count);
	for(CFIndex i = 0; i < count; i++) {
		CFTypeRef item = CFArrayGetValueAtIndex(arr, i);
		if(CFGetTypeID(item) == CFDictionaryGetTypeID())
			result.emplace_back((CFDictionaryRef)item);
	}
	return result;
}
