//
//  IpcPort.cpp
//
//  ipc::Port's factories and its macOS backend, CFMessagePort, unchanged in behavior
//  from the code it replaced. Linux uses
//  the Unix domain socket backend (IpcPortSocket.cpp); macOS uses it too when
//  REPLAY_IPC_BACKEND=socket, so the test suites can run it on a Mac.
//

#include "IpcPort.h"
#include "IpcPortInternal.h"

#include <utility>

#if defined(__APPLE__)
#include <CoreFoundation/CFMessagePort.h>
#include <cstdlib>
#include <cstring>
#endif

namespace ipc
{

#if defined(__APPLE__)

static_assert(kSendTimeout == (int32_t)kCFMessagePortSendTimeout, "status numbers follow CFMessagePort");
static_assert(kReceiveTimeout == (int32_t)kCFMessagePortReceiveTimeout, "status numbers follow CFMessagePort");
static_assert(kInvalid == (int32_t)kCFMessagePortIsInvalid, "status numbers follow CFMessagePort");
static_assert(kTransportError == (int32_t)kCFMessagePortTransportError, "status numbers follow CFMessagePort");
static_assert(kBecameInvalid == (int32_t)kCFMessagePortBecameInvalidError, "status numbers follow CFMessagePort");

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

std::unique_ptr<Port>
CreateMessagePortLocal(const std::string &name, Handler handler)
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
CreateMessagePortRemote(const std::string &name)
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

bool
UseSocketBackend()
{
	const char *backend = getenv("REPLAY_IPC_BACKEND");
	return (backend != nullptr) && (strcmp(backend, "socket") == 0);
}

} // namespace

#endif // __APPLE__

std::unique_ptr<Port>
Port::CreateLocal(const std::string &name, Handler handler)
{
#if defined(__APPLE__)
	if (!UseSocketBackend())
		return CreateMessagePortLocal(name, std::move(handler));
#endif
	return detail::CreateSocketLocal(name, std::move(handler));
}

std::unique_ptr<Port>
Port::CreateRemote(const std::string &name)
{
#if defined(__APPLE__)
	if (!UseSocketBackend())
		return CreateMessagePortRemote(name);
#endif
	return detail::CreateSocketRemote(name);
}

} // namespace ipc
