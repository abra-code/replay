//**************************************************************************************
// Filename:	CFType.cp
// Copyright 2002-2004 Abracode, Inc.  All rights reserved.
//
// Description:	helper for CoreFountation types
//**************************************************************************************

#include "CFType.h"

// most common CF types that are used in property lists:

template <> CFTypeID CFType<CFStringRef>::sTypeID		= ::CFStringGetTypeID();
template <> CFTypeID CFType<CFMutableStringRef>::sTypeID = ::CFStringGetTypeID();
template <> CFTypeID CFType<CFDictionaryRef>::sTypeID	= ::CFDictionaryGetTypeID();
template <> CFTypeID CFType<CFMutableDictionaryRef>::sTypeID = ::CFDictionaryGetTypeID();
template <> CFTypeID CFType<CFArrayRef>::sTypeID		= ::CFArrayGetTypeID();
template <> CFTypeID CFType<CFMutableArrayRef>::sTypeID = ::CFArrayGetTypeID();
template <> CFTypeID CFType<CFNumberRef>::sTypeID		= ::CFNumberGetTypeID();
template <> CFTypeID CFType<CFBooleanRef>::sTypeID		= ::CFBooleanGetTypeID();
template <> CFTypeID CFType<CFDataRef>::sTypeID		= ::CFDataGetTypeID();
template <> CFTypeID CFType<CFMutableDataRef>::sTypeID	= ::CFDataGetTypeID();
template <> CFTypeID CFType<CFDateRef>::sTypeID		= ::CFDateGetTypeID();
template <> CFTypeID CFType<CFBundleRef>::sTypeID		= ::CFBundleGetTypeID();
template <> CFTypeID CFType<CFURLRef>::sTypeID			= ::CFURLGetTypeID();
template <> CFTypeID CFType<CFSetRef>::sTypeID         = ::CFSetGetTypeID();
template <> CFTypeID CFType<CFMutableSetRef>::sTypeID  = ::CFSetGetTypeID();
