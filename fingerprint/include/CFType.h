//**************************************************************************************
// Filename:	CFType.h
//
// Copyright 2002-2004 Abracode, Inc.  All rights reserved.
//
// Description:	helper for CoreFountation types
//**************************************************************************************

#pragma once

#include <CoreFoundation/CoreFoundation.h>

template <typename T> class CFType
{
public:

// dynamic_cast<T> for CoreFoundation objects
	static T	DynamicCast(CFTypeRef inValue) noexcept
				{
					if ((inValue == nullptr) || (::CFGetTypeID(inValue) != sTypeID))
						return nullptr;
					return (T)inValue;
				}

	static CFTypeID GetTypeID() noexcept { return sTypeID; }

	static CFTypeID sTypeID;
};

template <> CFTypeID CFType<CFStringRef>::sTypeID;
template <> CFTypeID CFType<CFMutableStringRef>::sTypeID;
template <> CFTypeID CFType<CFDictionaryRef>::sTypeID;
template <> CFTypeID CFType<CFMutableDictionaryRef>::sTypeID;
template <> CFTypeID CFType<CFArrayRef>::sTypeID;
template <> CFTypeID CFType<CFMutableArrayRef>::sTypeID;
template <> CFTypeID CFType<CFNumberRef>::sTypeID;
template <> CFTypeID CFType<CFBooleanRef>::sTypeID;
template <> CFTypeID CFType<CFDataRef>::sTypeID;
template <> CFTypeID CFType<CFMutableDataRef>::sTypeID;
template <> CFTypeID CFType<CFDateRef>::sTypeID;
template <> CFTypeID CFType<CFBundleRef>::sTypeID;
template <> CFTypeID CFType<CFURLRef>::sTypeID;
template <> CFTypeID CFType<CFSetRef>::sTypeID;
template <> CFTypeID CFType<CFMutableSetRef>::sTypeID;
