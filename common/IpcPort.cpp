//
//  IpcPort.cpp
//
//  The macOS backend of ipc::Port: CFMessagePort, unchanged in behavior from the code
//  it replaces (private/linux_phase4_ipc_design.md, section 3). On Linux there is no
//  backend yet: CreateLocal and CreateRemote return null.
//

#include "IpcPort.h"

#if defined(__APPLE__)
#include <CoreFoundation/CFMessagePort.h>
#include <utility>
#endif

namespace ipc
{

#if defined(__APPLE__)

static_assert(kSendTimeout == (int32_t)kCFMessagePortSendTimeout, "status numbers follow CFMessagePort");
static_assert(kReceiveTimeout == (int32_t)kCFMessagePortReceiveTimeout, "status numbers follow CFMessagePort");
static_assert(kInvalid == (int32_t)kCFMessagePortIsInvalid, "status numbers follow CFMessagePort");
static_assert(kTransportError == (int32_t)kCFMessagePortTransportError, "status numbers follow CFMessagePort");

namespace
{

CFObj<CFStringRef>
CreateCFName(const std::string &name)
{
	return CFObj<CFStringRef>(CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)name.data(),
	                                                  (CFIndex)name.size(), kCFStringEncodingUTF8, false));
}

class MessagePort final : public Port
{
public:
	MessagePort(bool isLocal, Handler handler)
		: mIsLocal(isLocal), mHandler(std::move(handler))
	{
	}

	~MessagePort() override
	{
		if (mIsLocal)
			Invalidate();
	}

	void Adopt(CFObj<CFMessagePortRef> &&port)
	{
		mPort = std::move(port);
	}

	bool AddToCurrentRunLoop() override
	{
		if (!mIsLocal || (mPort == nullptr) || (mRunLoopSource != nullptr))
			return false;
		mRunLoopSource.Adopt(CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, mPort, 0));
		if (mRunLoopSource == nullptr)
			return false;
		mRunLoop = CFRunLoopGetCurrent();
		CFRunLoopAddSource(mRunLoop, mRunLoopSource, kCFRunLoopCommonModes);
		return true;
	}

	int32_t SendRequest(int32_t messageId, CFDataRef data, double sendTimeout,
	                    double receiveTimeout, CFDataRef *replyOut) override
	{
		if (replyOut != nullptr)
			*replyOut = nullptr;
		if (mPort == nullptr)
			return kInvalid;
		if (replyOut == nullptr)
		{ // no reply mode: CFMessagePort does not wait for a reply
			return CFMessagePortSendRequest(mPort, messageId, data, sendTimeout, 0, nullptr, nullptr);
		}
		return CFMessagePortSendRequest(mPort, messageId, data, sendTimeout, receiveTimeout,
		                                kCFRunLoopDefaultMode, replyOut);
	}

	void Invalidate() override
	{
		if (mPort != nullptr)
			CFMessagePortInvalidate(mPort);
		if ((mRunLoopSource != nullptr) && (mRunLoop != nullptr))
		{
			CFRunLoopRemoveSource(mRunLoop, mRunLoopSource, kCFRunLoopCommonModes);
			mRunLoop = nullptr;
		}
	}

	static CFDataRef Callback(CFMessagePortRef, SInt32 messageId, CFDataRef data, void *info)
	{
		MessagePort *self = (MessagePort *)info;
		if ((self == nullptr) || !self->mHandler)
			return nullptr;
		// CFMessagePort takes the returned +1 reference and releases it.
		return self->mHandler(messageId, data).Detach();
	}

private:
	CFObj<CFMessagePortRef> mPort;
	CFObj<CFRunLoopSourceRef> mRunLoopSource;
	CFRunLoopRef mRunLoop = nullptr; // not owned: the port is used on its own thread only
	bool mIsLocal = false;
	Handler mHandler;
};

} // namespace

std::unique_ptr<Port>
Port::CreateLocal(const std::string &name, Handler handler)
{
	CFObj<CFStringRef> cfName = CreateCFName(name);
	if (cfName == nullptr)
		return nullptr;

	// The context's info must point at the object before the port exists, so the object
	// is made first and given the port afterwards.
	std::unique_ptr<MessagePort> result(new MessagePort(true, std::move(handler)));
	CFMessagePortContext context = { 0, result.get(), nullptr, nullptr, nullptr };
	Boolean shouldFreeInfo = false;
	CFObj<CFMessagePortRef> port(CFMessagePortCreateLocal(kCFAllocatorDefault, cfName, MessagePort::Callback,
	                                                      &context, &shouldFreeInfo));
	// shouldFreeInfo: CF returned an existing port of this process with another info.
	if ((port == nullptr) || shouldFreeInfo)
		return nullptr;
	result->Adopt(std::move(port));
	return result;
}

std::unique_ptr<Port>
Port::CreateRemote(const std::string &name)
{
	CFObj<CFStringRef> cfName = CreateCFName(name);
	if (cfName == nullptr)
		return nullptr;
	CFObj<CFMessagePortRef> port(CFMessagePortCreateRemote(kCFAllocatorDefault, cfName));
	if (port == nullptr)
		return nullptr;
	std::unique_ptr<MessagePort> result(new MessagePort(false, Handler()));
	result->Adopt(std::move(port));
	return result;
}

#else // no backend yet (Linux before the socket backend)

std::unique_ptr<Port>
Port::CreateLocal(const std::string &, Handler)
{
	return nullptr;
}

std::unique_ptr<Port>
Port::CreateRemote(const std::string &)
{
	return nullptr;
}

#endif

} // namespace ipc
