//
//  IpcPort.h
//
//  A named port for requests between dispatch and the replay server
//  On macOS it wraps CFMessagePort; on Linux,
//  and on macOS when REPLAY_IPC_BACKEND=socket (for tests), it uses a Unix domain
//  socket (common/IpcPortSocket.cpp).
//
//  Names and status numbers are CFMessagePort's, so the error numbers the tools print
//  do not change on macOS.
//

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include "CFObj.h"
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace ipc
{

enum Status : int32_t
{
	kOk = 0,
	kSendTimeout = -1,
	kReceiveTimeout = -2,
	kInvalid = -3,
	kTransportError = -4,
	kBecameInvalid = -5, // the server went away while a reply was awaited
};

// Called on the thread whose run loop the port was added to, one request at a time.
// data may be null (a request with no payload). Returns the reply, or null for none.
using Handler = std::function<CFObj<CFDataRef> (int32_t messageId, CFDataRef data)>;

class Port
{
public:
	// Null when the name is taken (by another process, or already by this one) or
	// cannot be used as a port name.
	static std::unique_ptr<Port> CreateLocal(const std::string &name, Handler handler);
	// Null when nobody serves the name, or (Unix socket) when this client cannot read the
	// server's token file.
	static std::unique_ptr<Port> CreateRemote(const std::string &name);

	virtual ~Port() = default;

	// Local ports: start receiving on the calling thread's run loop (common modes).
	virtual bool AddToCurrentRunLoop() = 0;

	// Remote ports. With replyOut null no reply is wanted and receiveTimeout is not used;
	// otherwise *replyOut gets the reply (Create rule) or null: pass &reply of an empty
	// CFObj<CFDataRef>, whose operator& gives the address of its reference.
	virtual int32_t SendRequest(int32_t messageId, CFDataRef data, double sendTimeout,
	                            double receiveTimeout, CFDataRef *replyOut) = 0;

	// Stop receiving, leave the run loop and give up the name. Safe to call again;
	// the destructor of a local port calls it.
	virtual void Invalidate() = 0;

protected:
	Port() = default;
	Port(const Port &) = delete;
	Port &operator=(const Port &) = delete;
};

} // namespace ipc
