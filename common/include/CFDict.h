//**************************************************************************************
// Filename:	CFDict.h
//
// Copyright 2002-2004 Abracode, Inc.  All rights reserved.
//
// Description:	RAII wrappers for CFDictionaryRef / CFMutableDictionaryRef
//**************************************************************************************

#pragma once

#include "CFObj.h"
#include "CFType.h"

// T = CFDictionaryRef | CFMutableDictionaryRef
template <typename T> class CFDictBase : public CFObj<T>
{
public:
	CFDictBase() noexcept
		: CFObj<T>()
	{
	}

	// note: reverse retain default than CFObj
	CFDictBase(T inObj, CFObjRetainType inRetainType = kCFObjRetain) noexcept
		: CFObj<T>(inObj, inRetainType)
	{
	}

	// Returns false without modifying outValue if key absent or wrong type
	template <typename CFT>
	bool GetValue(CFStringRef inKey, CFT &outValue) const noexcept
	{
		if (this->mRef != nullptr)
		{
			CFTypeRef resultRef = nullptr;
			if (::CFDictionaryGetValueIfPresent(this->mRef, inKey, &resultRef))
				return CFType<CFT>::DynamicCast(resultRef, outValue);
		}
		return false;
	}

	bool GetValue(CFStringRef inKey, CFIndex &outValue) const noexcept
	{
		CFNumberRef num = nullptr;
		if (GetValue(inKey, num))
			return ::CFNumberGetValue(num, kCFNumberCFIndexType, &outValue);
		return false;
	}

	bool GetValue(CFStringRef inKey, int64_t &outValue) const noexcept
	{
		CFNumberRef num = nullptr;
		if (GetValue(inKey, num))
			return ::CFNumberGetValue(num, kCFNumberSInt64Type, &outValue);
		return false;
	}

	bool GetValue(CFStringRef inKey, double &outValue) const noexcept
	{
		CFNumberRef num = nullptr;
		if (GetValue(inKey, num))
			return ::CFNumberGetValue(num, kCFNumberDoubleType, &outValue);
		return false;
	}

	bool GetValue(CFStringRef inKey, bool &outValue) const noexcept
	{
		CFBooleanRef b = nullptr;
		if (GetValue(inKey, b))
		{
			outValue = ::CFBooleanGetValue(b);
			return true;
		}
		return false;
	}

	// Returns nullptr if key absent
	CFTypeRef operator[](CFStringRef inKey) const noexcept
	{
		if (this->mRef == nullptr)
			return nullptr;
		return ::CFDictionaryGetValue(this->mRef, inKey);
	}
};

typedef CFDictBase<CFDictionaryRef> CFDict;

class CFMutableDict : public CFDictBase<CFMutableDictionaryRef>
{
public:
	CFMutableDict() noexcept
		: CFDictBase<CFMutableDictionaryRef>(
			::CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
				&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks),
			kCFObjDontRetain)
	{
	}

	// note: reverse retain default than CFObj
	CFMutableDict(CFMutableDictionaryRef inObj, CFObjRetainType inRetainType = kCFObjRetain) noexcept
		: CFDictBase<CFMutableDictionaryRef>(inObj, inRetainType)
	{
	}

	void SetValue(CFStringRef inKey, CFTypeRef inValue) noexcept
	{
		if (inValue != nullptr)
			::CFDictionarySetValue(mRef, inKey, inValue);
		else
			::CFDictionaryRemoveValue(mRef, inKey);
	}

	void SetValue(CFStringRef inKey, CFStringRef inValue) noexcept
	{
		if (inValue != nullptr)
			::CFDictionarySetValue(mRef, inKey, inValue);
		else
			::CFDictionaryRemoveValue(mRef, inKey);
	}

	void SetValue(CFStringRef inKey, CFIndex inValue) noexcept
	{
		CFObj<CFNumberRef> num(::CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &inValue));
		::CFDictionarySetValue(mRef, inKey, (CFNumberRef)num);
	}

	void SetValue(CFStringRef inKey, int64_t inValue) noexcept
	{
		CFObj<CFNumberRef> num(::CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &inValue));
		::CFDictionarySetValue(mRef, inKey, (CFNumberRef)num);
	}

	void SetValue(CFStringRef inKey, double inValue) noexcept
	{
		CFObj<CFNumberRef> num(::CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &inValue));
		::CFDictionarySetValue(mRef, inKey, (CFNumberRef)num);
	}

	void SetValue(CFStringRef inKey, bool inValue) noexcept
	{
		::CFDictionarySetValue(mRef, inKey, inValue ? kCFBooleanTrue : kCFBooleanFalse);
	}

	void RemoveValue(CFStringRef inKey) noexcept
	{
		::CFDictionaryRemoveValue(mRef, inKey);
	}
};
