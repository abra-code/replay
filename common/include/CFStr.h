//**************************************************************************************
// Filename:	CFStr.h
//
// Copyright 2002-2004 Abracode, Inc.  All rights reserved.
//
// Description:	RAII wrappers for CFStringRef / CFMutableStringRef
//**************************************************************************************

#pragma once

#include "CFObj.h"
#include "CFType.h"
#include <cstdarg>
#include <string>
#include <string_view>

// T = CFStringRef | CFMutableStringRef
template <typename T> class CFStrBase : public CFObj<T>
{
public:
	// note: reverse retain default than CFObj
	CFStrBase(T inObj, CFObjRetainType inRetainType = kCFObjRetain) noexcept
		: CFObj<T>(inObj, inRetainType)
	{
	}

	CFIndex GetLength() const noexcept
	{
		if (this->mRef != nullptr)
			return ::CFStringGetLength(this->mRef);
		return 0;
	}

	bool IsEmpty() const noexcept
	{
		return GetLength() == 0;
	}

	// Static helper for extracting from a borrowed (unowned) CFStringRef.
	// Returns empty string if str is null.
	static std::string ToString(CFStringRef str) noexcept
	{
		if (str == nullptr)
			return {};
		// Fast path: when CF can return a direct UTF-8 pointer
		if (const char *ptr = ::CFStringGetCStringPtr(str, kCFStringEncodingUTF8))
			return std::string(ptr);
		CFIndex len = ::CFStringGetLength(str);
		CFIndex byteCount = 0;
		::CFStringGetBytes(str, CFRangeMake(0, len), kCFStringEncodingUTF8,
			0, false, nullptr, 0, &byteCount);
		std::string result((size_t)byteCount, '\0');
		if (byteCount > 0)
		{
			::CFStringGetBytes(str, CFRangeMake(0, len), kCFStringEncodingUTF8,
				0, false, (UInt8 *)result.data(), byteCount, nullptr);
		}
		return result;
	}

	// Extract as std::string (UTF-8). Returns empty string if mRef is null.
	std::string ToString() const noexcept
	{
		return ToString((CFStringRef)this->mRef);
	}

	bool Equals(CFStringRef other) const noexcept
	{
		if ((this->mRef == nullptr) || (other == nullptr))
			return this->mRef == other;
		return ::CFStringCompare(this->mRef, other, 0) == kCFCompareEqualTo;
	}

	bool HasPrefix(CFStringRef prefix) const noexcept
	{
		if ((this->mRef == nullptr) || (prefix == nullptr))
			return false;
		return ::CFStringHasPrefix(this->mRef, prefix);
	}

	bool HasSuffix(CFStringRef suffix) const noexcept
	{
		if ((this->mRef == nullptr) || (suffix == nullptr))
			return false;
		return ::CFStringHasSuffix(this->mRef, suffix);
	}
};

class CFStr : public CFStrBase<CFStringRef>
{
public:
	CFStr() noexcept
		: CFStrBase<CFStringRef>(nullptr, kCFObjDontRetain)
	{
	}

	// note: reverse retain default than CFObj
	CFStr(CFStringRef inObj, CFObjRetainType inRetainType = kCFObjRetain) noexcept
		: CFStrBase<CFStringRef>(inObj, inRetainType)
	{
	}

	// Construct from UTF-8 string view
	explicit CFStr(std::string_view sv) noexcept
		: CFStrBase<CFStringRef>(
			::CFStringCreateWithBytes(kCFAllocatorDefault,
				(const UInt8 *)sv.data(), (CFIndex)sv.size(),
				kCFStringEncodingUTF8, false),
			kCFObjDontRetain)
	{
	}

	explicit CFStr(const char *s) noexcept
		: CFStrBase<CFStringRef>(
			(s != nullptr)
				? ::CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8)
				: nullptr,
			kCFObjDontRetain)
	{
	}

	// printf-style construction using a CFStringRef format (supports %@ for CFTypeRef args)
	static CFStr Format(CFStringRef fmt, ...) noexcept
	{
		va_list args;
		va_start(args, fmt);
		CFStringRef result = ::CFStringCreateWithFormatAndArguments(
			kCFAllocatorDefault, nullptr, fmt, args);
		va_end(args);
		return CFStr(result, kCFObjDontRetain);
	}

	static CFStr FormatV(CFStringRef fmt, va_list args) noexcept
	{
		CFStringRef result = ::CFStringCreateWithFormatAndArguments(
			kCFAllocatorDefault, nullptr, fmt, args);
		return CFStr(result, kCFObjDontRetain);
	}
};

class CFMutableStr : public CFStrBase<CFMutableStringRef>
{
public:
	explicit CFMutableStr(CFIndex maxLength = 0) noexcept
		: CFStrBase<CFMutableStringRef>(
			::CFStringCreateMutable(kCFAllocatorDefault, maxLength),
			kCFObjDontRetain)
	{
	}

	explicit CFMutableStr(std::string_view sv) noexcept
		: CFStrBase<CFMutableStringRef>(
			::CFStringCreateMutable(kCFAllocatorDefault, 0),
			kCFObjDontRetain)
	{
		Append(sv);
	}

	// note: reverse retain default than CFObj
	CFMutableStr(CFMutableStringRef inObj, CFObjRetainType inRetainType = kCFObjRetain) noexcept
		: CFStrBase<CFMutableStringRef>(inObj, inRetainType)
	{
	}

	void Append(std::string_view sv) noexcept
	{
		if ((this->mRef == nullptr) || sv.empty())
			return;
		CFObj<CFStringRef> tmp(::CFStringCreateWithBytes(kCFAllocatorDefault,
			(const UInt8 *)sv.data(), (CFIndex)sv.size(),
			kCFStringEncodingUTF8, false));
		if (tmp != nullptr)
			::CFStringAppend(this->mRef, tmp);
	}

	void Append(CFStringRef other) noexcept
	{
		if ((this->mRef != nullptr) && (other != nullptr))
			::CFStringAppend(this->mRef, other);
	}

	void Append(const char *s) noexcept
	{
		if (s != nullptr)
			Append(std::string_view(s));
	}

	void AppendFormat(CFStringRef fmt, ...) noexcept
	{
		if (this->mRef == nullptr)
			return;
		va_list args;
		va_start(args, fmt);
		::CFStringAppendFormatAndArguments(this->mRef, nullptr, fmt, args);
		va_end(args);
	}

	CFMutableStr& operator+=(std::string_view sv) noexcept
	{
		Append(sv);
		return *this;
	}

	CFMutableStr& operator+=(CFStringRef other) noexcept
	{
		Append(other);
		return *this;
	}

	CFMutableStr& operator+=(const char *s) noexcept
	{
		Append(s);
		return *this;
	}
};

// operator+ on CFStr — returns a fresh immutable CFStr built via a mutable scratch buffer
inline CFStr operator+(const CFStr &a, std::string_view b) noexcept
{
	CFMutableStr m;
	m.Append((CFStringRef)a);
	m.Append(b);
	return CFStr((CFStringRef)m.Detach(), kCFObjDontRetain);
}

inline CFStr operator+(const CFStr &a, CFStringRef b) noexcept
{
	CFMutableStr m;
	m.Append((CFStringRef)a);
	m.Append(b);
	return CFStr((CFStringRef)m.Detach(), kCFObjDontRetain);
}

inline CFStr operator+(const CFStr &a, const char *b) noexcept
{
	CFMutableStr m;
	m.Append((CFStringRef)a);
	m.Append(b);
	return CFStr((CFStringRef)m.Detach(), kCFObjDontRetain);
}

inline CFStr operator+(std::string_view a, const CFStr &b) noexcept
{
	CFMutableStr m;
	m.Append(a);
	m.Append((CFStringRef)b);
	return CFStr((CFStringRef)m.Detach(), kCFObjDontRetain);
}
