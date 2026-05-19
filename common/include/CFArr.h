//**************************************************************************************
// Filename:	CFArr.h
//
// Copyright 2002-2004 Abracode, Inc.  All rights reserved.
//
// Description:	RAII wrappers for CFArrayRef / CFMutableArrayRef
//**************************************************************************************

#pragma once

#include "CFObj.h"
#include "CFType.h"

// T = CFArrayRef | CFMutableArrayRef
template <typename T> class CFArrayBase : public CFObj<T>
{
public:
	CFArrayBase() noexcept
		: CFObj<T>()
	{
	}

	// note: reverse retain default than CFObj
	CFArrayBase(T inObj, CFObjRetainType inRetainType = kCFObjRetain) noexcept
		: CFObj<T>(inObj, inRetainType)
	{
	}

	CFIndex GetCount() const noexcept
	{
		if (this->mRef != nullptr)
			return ::CFArrayGetCount(this->mRef);
		return 0;
	}

	template <typename CFT>
	bool GetValueAtIndex(CFIndex idx, CFT &outValue) const noexcept
	{
		if (this->mRef != nullptr)
		{
			CFTypeRef resultRef = ::CFArrayGetValueAtIndex(this->mRef, idx);
			return CFType<CFT>::DynamicCast(resultRef, outValue);
		}
		return false;
	}

	CFTypeRef GetValueAtIndex(CFIndex idx) const noexcept
	{
		if (this->mRef != nullptr)
			return ::CFArrayGetValueAtIndex(this->mRef, idx);
		return nullptr;
	}

	CFTypeRef operator[](CFIndex idx) const noexcept
	{
		if (this->mRef == nullptr || idx < 0 || idx >= ::CFArrayGetCount(this->mRef))
			return nullptr;
		return ::CFArrayGetValueAtIndex(this->mRef, idx);
	}
};

typedef CFArrayBase<CFArrayRef> CFArr;

class CFMutableArr : public CFArrayBase<CFMutableArrayRef>
{
public:
	explicit CFMutableArr(CFIndex maxCount = 0) noexcept
		: CFArrayBase<CFMutableArrayRef>(::CFArrayCreateMutable(kCFAllocatorDefault, maxCount, &kCFTypeArrayCallBacks))
	{
	}

	// note: reverse retain default than CFObj
	CFMutableArr(CFMutableArrayRef inObj, CFObjRetainType inRetainType = kCFObjRetain) noexcept
		: CFArrayBase<CFMutableArrayRef>(inObj, inRetainType)
	{
	}

	// Accepts any raw CF ref (CFStringRef, CFArrayRef, CFDictionaryRef, ...)
	// and any wrapper that exposes operator CFTypeRef() (CFStr, CFMutableStr,
	// CFArr, CFMutableArr, CFMutableDict, ...) via implicit user-defined conversion.
	void AppendValue(CFTypeRef inValue) noexcept
	{
		::CFArrayAppendValue(mRef, inValue);
	}

	void InsertValueAtIndex(CFIndex idx, CFTypeRef inValue) noexcept
	{
		::CFArrayInsertValueAtIndex(mRef, idx, inValue);
	}

	void SetValueAtIndex(CFIndex idx, CFTypeRef inValue) noexcept
	{
		::CFArraySetValueAtIndex(mRef, idx, inValue);
	}

	void RemoveValueAtIndex(CFIndex idx) noexcept
	{
		::CFArrayRemoveValueAtIndex(mRef, idx);
	}

	void RemoveAllValues() noexcept
	{
		::CFArrayRemoveAllValues(mRef);
	}
};
