//**************************************************************************************
// Filename:	CFType.h
//
// Copyright 2002-2004 Abracode, Inc.  All rights reserved.
//
// Description:	helper for CoreFoundation types
//**************************************************************************************

#pragma once

#include <CoreFoundation/CoreFoundation.h>

template <typename T> class CFType
{
public:

	// dynamic_cast<T> for CoreFoundation objects
	static T DynamicCast(CFTypeRef inValue) noexcept
	{
		if ((inValue == nullptr) || (::CFGetTypeID(inValue) != sTypeID))
			return nullptr;
		return (T)inValue;
	}

	// Two-arg form: leaves outValue unchanged on failure, returns false instead
	static bool DynamicCast(CFTypeRef inValue, T &outValue) noexcept
	{
		if ((inValue == nullptr) || (::CFGetTypeID(inValue) != sTypeID))
			return false;
		outValue = (T)inValue;
		return true;
	}

	static CFTypeID GetTypeID() noexcept { return sTypeID; }

	static CFTypeID sTypeID;
};

template <> inline CFTypeID CFType<CFStringRef>::sTypeID          = ::CFStringGetTypeID();
template <> inline CFTypeID CFType<CFMutableStringRef>::sTypeID   = ::CFStringGetTypeID();
template <> inline CFTypeID CFType<CFDictionaryRef>::sTypeID      = ::CFDictionaryGetTypeID();
template <> inline CFTypeID CFType<CFMutableDictionaryRef>::sTypeID = ::CFDictionaryGetTypeID();
template <> inline CFTypeID CFType<CFArrayRef>::sTypeID           = ::CFArrayGetTypeID();
template <> inline CFTypeID CFType<CFMutableArrayRef>::sTypeID    = ::CFArrayGetTypeID();
template <> inline CFTypeID CFType<CFNumberRef>::sTypeID          = ::CFNumberGetTypeID();
template <> inline CFTypeID CFType<CFBooleanRef>::sTypeID         = ::CFBooleanGetTypeID();
template <> inline CFTypeID CFType<CFDataRef>::sTypeID            = ::CFDataGetTypeID();
template <> inline CFTypeID CFType<CFMutableDataRef>::sTypeID     = ::CFDataGetTypeID();
template <> inline CFTypeID CFType<CFDateRef>::sTypeID            = ::CFDateGetTypeID();
template <> inline CFTypeID CFType<CFBundleRef>::sTypeID          = ::CFBundleGetTypeID();
template <> inline CFTypeID CFType<CFURLRef>::sTypeID             = ::CFURLGetTypeID();
template <> inline CFTypeID CFType<CFSetRef>::sTypeID             = ::CFSetGetTypeID();
template <> inline CFTypeID CFType<CFMutableSetRef>::sTypeID      = ::CFSetGetTypeID();
