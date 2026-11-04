//
//  CFMessagePortStub.cpp
//
//  Phase 1 stub (Linux only). Swift's libFoundation.so declares CFMessagePort in its
//  headers but does not export it, so these fail closed: no port can be created or
//  reached, and dispatch and replay --start-server report that the server is not
//  running. Phase 4 replaces CFMessagePort with a port class (Unix socket on Linux).
//

#if defined(__linux__)

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFMessagePort.h>

CFMessagePortRef CFMessagePortCreateLocal(CFAllocatorRef, CFStringRef, CFMessagePortCallBack,
                                          CFMessagePortContext *, Boolean *shouldFreeInfo)
{
	if(shouldFreeInfo != nullptr)
		*shouldFreeInfo = false;
	return nullptr;
}

CFMessagePortRef CFMessagePortCreateRemote(CFAllocatorRef, CFStringRef)
{
	return nullptr;
}

CFRunLoopSourceRef CFMessagePortCreateRunLoopSource(CFAllocatorRef, CFMessagePortRef, CFIndex)
{
	return nullptr;
}

void CFMessagePortInvalidate(CFMessagePortRef)
{
}

SInt32 CFMessagePortSendRequest(CFMessagePortRef, SInt32, CFDataRef, CFTimeInterval, CFTimeInterval,
                                CFStringRef, CFDataRef *)
{
	return kCFMessagePortIsInvalid;
}

#endif
