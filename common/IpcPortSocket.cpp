//
//  IpcPortSocket.cpp
//
//  The Unix domain socket backend of ipc::Port.
//  Used on Linux, and on macOS when REPLAY_IPC_BACKEND=socket (tests).
//
//  One stream connection per request: the client connects, sends one frame, reads the
//  reply frame when it wants one, and closes. The server accepts on its run loop
//  (a CFSocket), serves one connection at a time and calls the handler on the run loop
//  thread, as CFMessagePort does.
//
//  Frame (little-endian): magic "RPLC" (request) or "RPLY" (reply), version (2 bytes, 1),
//  flags (2 bytes: bit 0 reply wanted, bit 1 payload present), message id or status
//  (4 bytes, signed), payload length (4 bytes, at most 16 MiB), payload.
//
//  Token: before its request frame a client sends the 32 bytes of <socket>.token, a file
//  of random bytes the server writes (mode 0600) before it listens. The server drops a
//  connection whose first 32 bytes differ. Connecting needs only the socket, which a
//  sandboxed command can reach whenever Unix sockets are not limited (playlists and gate
//  by default); reading the token needs read access to the socket folder, which
//  the sandbox does not give. So a sandboxed step cannot have a server, which runs
//  unsandboxed, run actions for it.
//

#include "IpcPort.h"
#include "IpcPortInternal.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

namespace ipc
{
namespace detail
{
namespace
{

constexpr uint32_t kMaxPayload = 16u * 1024u * 1024u;
constexpr uint16_t kFrameVersion = 1;
constexpr uint16_t kFlagReplyWanted = 1u << 0;
constexpr uint16_t kFlagHasPayload = 1u << 1;
constexpr size_t kHeaderSize = 16;
constexpr char kRequestMagic[4] = { 'R', 'P', 'L', 'C' };
constexpr char kReplyMagic[4] = { 'R', 'P', 'L', 'Y' };

// How long the server waits for a connected peer's request, and for its reply to be
// taken. REPLAY_IPC_TEST_RECEIVE_TIMEOUT shortens the first, for tests only.
constexpr double kServerReceiveTimeout = 10;
constexpr double kServerSendTimeout = 10;
// How long CreateRemote waits for the connection that checks a server is there.
constexpr double kProbeTimeout = 2;

constexpr size_t kTokenSize = 32;
using Token = std::array<uint8_t, kTokenSize>;

enum class Io
{
	kOk,
	kTimeout,
	kClosed,    // the peer closed or reset the connection
	kBadFrame,  // wrong magic or version, or a payload over the limit
	kError,
};

// ---------------------------------------------------------------- time and descriptors

double
Now()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

double
DeadlineAfter(double seconds)
{
	if (!(seconds > 0)) // also NaN
		seconds = 0;
	if (seconds > 86400.0 * 365)
		seconds = 86400.0 * 365;
	return Now() + seconds;
}

int
RemainingMilliseconds(double deadline)
{
	double remaining = deadline - Now();
	if (remaining <= 0)
		return 0;
	double ms = std::ceil(remaining * 1000);
	return (ms > (double)INT_MAX) ? INT_MAX : (int)ms;
}

#if !defined(__linux__)
bool
SetCloseOnExecAndNonBlocking(int fd)
{
	int fdFlags = fcntl(fd, F_GETFD);
	if ((fdFlags < 0) || (fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC) != 0))
		return false;
	int statusFlags = fcntl(fd, F_GETFL);
	if ((statusFlags < 0) || (fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) != 0))
		return false;
#if defined(__APPLE__)
	int on = 1;
	(void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
	return true;
}
#endif

int
NewStreamSocket()
{
#if defined(__linux__)
	// Both flags at once: the server spawns children on other threads, and one spawned
	// between socket() and fcntl() would inherit the descriptor. macOS has no such flags.
	return socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
#else
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	if (!SetCloseOnExecAndNonBlocking(fd))
	{
		close(fd);
		return -1;
	}
	return fd;
#endif
}

bool
PeerIsSameUser(int fd)
{
#if defined(__linux__)
	struct ucred cred;
	socklen_t len = sizeof(cred);
	if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0)
		return false;
	return cred.uid == getuid();
#else
	uid_t uid = 0;
	gid_t gid = 0;
	if (getpeereid(fd, &uid, &gid) != 0)
		return false;
	return uid == getuid();
#endif
}

// ---------------------------------------------------------------- reading and writing

Io
WaitFor(int fd, short events, double deadline)
{
	for (;;)
	{
		struct pollfd p = { fd, events, 0 };
		int n = poll(&p, 1, RemainingMilliseconds(deadline));
		if (n > 0)
			return Io::kOk; // also POLLHUP and POLLERR: the next read or write reports them
		if (n == 0)
			return Io::kTimeout;
		if (errno != EINTR)
			return Io::kError;
	}
}

Io
WriteAll(int fd, const uint8_t *bytes, size_t size, double deadline)
{
	while (size > 0)
	{
#if defined(MSG_NOSIGNAL)
		ssize_t n = send(fd, bytes, size, MSG_NOSIGNAL);
#else
		ssize_t n = send(fd, bytes, size, 0); // SO_NOSIGPIPE is set on the socket
#endif
		if (n > 0)
		{
			bytes += n;
			size -= (size_t)n;
			continue;
		}
		if ((n < 0) && (errno == EINTR))
			continue;
		if ((n < 0) && ((errno == EAGAIN) || (errno == EWOULDBLOCK)))
		{
			Io waited = WaitFor(fd, POLLOUT, deadline);
			if (waited != Io::kOk)
				return waited;
			continue;
		}
		if ((n < 0) && ((errno == EPIPE) || (errno == ECONNRESET)))
			return Io::kClosed;
		return Io::kError;
	}
	return Io::kOk;
}

Io
ReadAll(int fd, uint8_t *bytes, size_t size, double deadline)
{
	while (size > 0)
	{
		ssize_t n = recv(fd, bytes, size, 0);
		if (n > 0)
		{
			bytes += n;
			size -= (size_t)n;
			continue;
		}
		if (n == 0)
			return Io::kClosed;
		if (errno == EINTR)
			continue;
		if ((errno == EAGAIN) || (errno == EWOULDBLOCK))
		{
			Io waited = WaitFor(fd, POLLIN, deadline);
			if (waited != Io::kOk)
				return waited;
			continue;
		}
		if (errno == ECONNRESET)
			return Io::kClosed;
		return Io::kError;
	}
	return Io::kOk;
}

void
PutU16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)(v & 0xff);
	p[1] = (uint8_t)(v >> 8);
}

void
PutU32(uint8_t *p, uint32_t v)
{
	for (int i = 0; i < 4; i++)
		p[i] = (uint8_t)((v >> (8 * i)) & 0xff);
}

uint16_t
GetU16(const uint8_t *p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

uint32_t
GetU32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

Io
WriteFrame(int fd, const char magic[4], uint16_t flags, int32_t idOrStatus, CFDataRef data, double deadline)
{
	size_t length = 0;
	if (data != nullptr)
	{
		flags |= kFlagHasPayload;
		length = (size_t)CFDataGetLength(data);
		if (length > kMaxPayload)
			return Io::kBadFrame;
	}
	uint8_t header[kHeaderSize];
	memcpy(header, magic, 4);
	PutU16(header + 4, kFrameVersion);
	PutU16(header + 6, flags);
	PutU32(header + 8, (uint32_t)idOrStatus);
	PutU32(header + 12, (uint32_t)length);
	Io written = WriteAll(fd, header, sizeof(header), deadline);
	if ((written != Io::kOk) || (length == 0))
		return written;
	return WriteAll(fd, CFDataGetBytePtr(data), length, deadline);
}

// dataOut gets the payload, or null when the frame has none.
Io
ReadFrame(int fd, const char magic[4], double deadline, uint16_t *flagsOut, int32_t *idOrStatusOut, CFObj<CFDataRef> &dataOut)
{
	dataOut.Release();
	uint8_t header[kHeaderSize];
	Io read = ReadAll(fd, header, sizeof(header), deadline);
	if (read != Io::kOk)
		return read;
	if ((memcmp(header, magic, 4) != 0) || (GetU16(header + 4) != kFrameVersion))
		return Io::kBadFrame;
	uint16_t flags = GetU16(header + 6);
	int32_t idOrStatus = (int32_t)GetU32(header + 8);
	uint32_t length = GetU32(header + 12);
	if ((length > kMaxPayload) || ((length > 0) && ((flags & kFlagHasPayload) == 0)))
		return Io::kBadFrame;

	if ((flags & kFlagHasPayload) != 0)
	{
		CFObj<CFMutableDataRef> data(CFDataCreateMutable(kCFAllocatorDefault, (CFIndex)length));
		if (data == nullptr)
			return Io::kError;
		CFDataSetLength(data, (CFIndex)length);
		if (length > 0)
		{
			read = ReadAll(fd, CFDataGetMutableBytePtr(data), length, deadline);
			if (read != Io::kOk)
				return read;
		}
		dataOut.Adopt(data.Detach());
	}
	*flagsOut = flags;
	*idOrStatusOut = idOrStatus;
	return Io::kOk;
}

// ---------------------------------------------------------------- the folder and names

std::string
TrimTrailingSlashes(std::string path)
{
	while ((path.size() > 1) && (path.back() == '/'))
		path.pop_back();
	return path;
}

bool
IsOwnedFolder(const std::string &path, bool requirePrivate)
{
	struct stat st;
	if (lstat(path.c_str(), &st) != 0)
		return false;
	if (!S_ISDIR(st.st_mode) || (st.st_uid != getuid()))
		return false;
	return !requirePrivate || ((st.st_mode & 0777) == 0700);
}

// The folder that holds the sockets: $XDG_RUNTIME_DIR/replay on Linux when that variable
// names a folder of this user, $TMPDIR/replay on macOS (TMPDIR is per user there),
// otherwise /tmp/replay-<uid>.
std::string
SocketFolder()
{
#if defined(__APPLE__)
	const char *base = getenv("TMPDIR");
#else
	const char *base = getenv("XDG_RUNTIME_DIR");
#endif
	if ((base != nullptr) && (base[0] == '/'))
	{
		std::string folder = TrimTrailingSlashes(base);
		if (IsOwnedFolder(folder, false))
			return folder + "/replay";
	}
	return "/tmp/replay-" + std::to_string((unsigned long)getuid());
}

// Creates the folder when missing. Refuses one that is a link, belongs to another user,
// or is open to others: anyone who can write there could stand in for a server.
bool
EnsureSocketFolder(const std::string &folder, bool create)
{
	if (create && (mkdir(folder.c_str(), 0700) != 0) && (errno != EEXIST))
	{
		fprintf(stderr, "error: cannot create the folder for replay's ports, %s: %s\n", folder.c_str(), strerror(errno));
		return false;
	}
	struct stat st;
	if (lstat(folder.c_str(), &st) != 0)
	{
		if (create || (errno != ENOENT))
			fprintf(stderr, "error: cannot use the folder for replay's ports, %s: %s\n", folder.c_str(), strerror(errno));
		return false;
	}
	if (!IsOwnedFolder(folder, true))
	{
		fprintf(stderr, "error: %s must be a folder (not a link) that belongs to you with mode 0700; "
		        "remove it or run chmod 700 on it\n", folder.c_str());
		return false;
	}
	return true;
}

bool
IsPlainNameCharacter(char c)
{
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9'))
	    || (c == '.') || (c == '-') || (c == '_');
}

uint64_t
Fnv1a64(const std::string &text)
{
	uint64_t hash = 14695981039346656037ULL;
	for (unsigned char c : text)
	{
		hash ^= c;
		hash *= 1099511628211ULL;
	}
	return hash;
}

// <folder>/<name>.sock, or, for a name that does not fit sockaddr_un or has characters
// other than letters, digits, ".", "-" and "_", <folder>/<start of name>-<64-bit hash>.sock
// with the other characters shown as "_". Empty when even that does not fit.
std::string
SocketPath(const std::string &folder, const std::string &name)
{
	const size_t limit = sizeof(((struct sockaddr_un *)nullptr)->sun_path) - 1; // room for the NUL
	const std::string suffix = ".sock";

	bool plain = !name.empty() && (name[0] != '.');
	for (char c : name)
		plain = plain && IsPlainNameCharacter(c);
	if (plain && (folder.size() + 1 + name.size() + suffix.size() <= limit))
		return folder + "/" + name + suffix;

	char hash[17];
	snprintf(hash, sizeof(hash), "%016llx", (unsigned long long)Fnv1a64(name));
	size_t fixed = folder.size() + 1 + 1 + 16 + suffix.size(); // "/", "-", hash, suffix
	if (fixed >= limit)
		return std::string();
	size_t prefixLength = std::min<size_t>(40, limit - fixed);
	std::string prefix;
	for (size_t i = 0; (i < name.size()) && (prefix.size() < prefixLength); i++)
		prefix += IsPlainNameCharacter(name[i]) ? name[i] : '_';
	if (!prefix.empty() && (prefix[0] == '.'))
		prefix[0] = '_';
	return folder + "/" + prefix + "-" + hash + suffix;
}

bool
FillAddress(const std::string &path, struct sockaddr_un *address)
{
	memset(address, 0, sizeof(*address));
	address->sun_family = AF_UNIX;
	if (path.empty() || (path.size() >= sizeof(address->sun_path)))
		return false;
	memcpy(address->sun_path, path.c_str(), path.size() + 1);
	return true;
}

// ---------------------------------------------------------------- the token

std::string
TokenPath(const std::string &socketPath)
{
	return socketPath + ".token";
}

// Writes a new token to path, replacing an old server's file. The caller holds the
// name's lock, so no other server writes it meanwhile. *deviceOut and *inodeOut identify
// the file, so that Invalidate removes only its own.
bool
WriteToken(const std::string &path, Token *tokenOut, dev_t *deviceOut, ino_t *inodeOut)
{
	if (getentropy(tokenOut->data(), tokenOut->size()) != 0)
	{
		fprintf(stderr, "error: cannot get random bytes for %s: %s\n", path.c_str(), strerror(errno));
		return false;
	}
	if ((unlink(path.c_str()) != 0) && (errno != ENOENT))
	{
		fprintf(stderr, "error: cannot remove the old %s: %s\n", path.c_str(), strerror(errno));
		return false;
	}
	// O_EXCL after the unlink: a new file, never one planted in its place or a link.
	int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd < 0)
	{
		fprintf(stderr, "error: cannot create %s: %s\n", path.c_str(), strerror(errno));
		return false;
	}
	size_t done = 0;
	while (done < tokenOut->size())
	{
		ssize_t n = write(fd, tokenOut->data() + done, tokenOut->size() - done);
		if ((n < 0) && (errno == EINTR))
			continue;
		if (n <= 0)
		{
			fprintf(stderr, "error: cannot write %s: %s\n", path.c_str(), (n < 0) ? strerror(errno) : "nothing written");
			close(fd);
			unlink(path.c_str());
			return false;
		}
		done += (size_t)n;
	}
	struct stat st;
	bool identified = (fstat(fd, &st) == 0);
	if (identified)
	{
		*deviceOut = st.st_dev;
		*inodeOut = st.st_ino;
	}
	// Closed at once: an open descriptor would show up in /proc/<pid>/fd.
	if ((close(fd) != 0) || !identified)
	{
		fprintf(stderr, "error: cannot write %s: %s\n", path.c_str(), strerror(errno));
		unlink(path.c_str());
		return false;
	}
	return true;
}

// Reads a server's token. Refuses a file that is not a plain file of this user, closed to
// others, of exactly the token's size. On false, errno says why (EINVAL for a wrong file).
bool
ReadToken(const std::string &path, Token *tokenOut)
{
	// O_NONBLOCK: a pipe planted in its place cannot hold the client (fstat refuses it next).
	int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
	if (fd < 0)
		return false;
	struct stat st;
	if ((fstat(fd, &st) != 0) || !S_ISREG(st.st_mode) || (st.st_uid != getuid())
	    || ((st.st_mode & 077) != 0) || (st.st_size != (off_t)tokenOut->size()))
	{
		close(fd);
		errno = EINVAL;
		return false;
	}
	size_t done = 0;
	while (done < tokenOut->size())
	{
		ssize_t n = read(fd, tokenOut->data() + done, tokenOut->size() - done);
		if ((n < 0) && (errno == EINTR))
			continue;
		if (n <= 0)
		{
			int error = (n < 0) ? errno : EINVAL;
			close(fd);
			errno = error;
			return false;
		}
		done += (size_t)n;
	}
	close(fd);
	return true;
}

// Compares in time that does not depend on where the first difference is.
bool
SameToken(const Token &a, const uint8_t *b)
{
	uint8_t difference = 0;
	for (size_t i = 0; i < a.size(); i++)
		difference |= (uint8_t)(a[i] ^ b[i]);
	return difference == 0;
}

enum class Connect
{
	kOk,
	kNobody,  // no socket file, or nobody listens on it
	kTimeout, // the server's queue stayed full
	kError,
};

// Connects a new socket to path. *fdOut is the connected socket on kOk.
Connect
ConnectTo(const std::string &path, double deadline, int *fdOut)
{
	*fdOut = -1;
	struct sockaddr_un address;
	if (!FillAddress(path, &address))
		return Connect::kError;

	for (;;)
	{
		int fd = NewStreamSocket();
		if (fd < 0)
			return Connect::kError;
		int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
		if (result == 0)
		{
			*fdOut = fd;
			return Connect::kOk;
		}
		int error = errno;
		if (error == EINPROGRESS)
		{
			Io waited = WaitFor(fd, POLLOUT, deadline);
			int soError = 0;
			socklen_t len = sizeof(soError);
			if ((waited == Io::kOk) && (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0) && (soError == 0))
			{
				*fdOut = fd;
				return Connect::kOk;
			}
			close(fd);
			if (waited == Io::kTimeout)
				return Connect::kTimeout;
			error = soError;
		}
		else
		{
			close(fd);
		}

		if ((error == ENOENT) || (error == ECONNREFUSED) || (error == ENOTDIR))
			return Connect::kNobody;
		if ((error == EAGAIN) || (error == EWOULDBLOCK) || (error == EINTR))
		{
			// Linux: the server's accept queue is full. Try again until the deadline.
			if (RemainingMilliseconds(deadline) == 0)
				return Connect::kTimeout;
			usleep(10000);
			continue;
		}
		return Connect::kError;
	}
}

// ---------------------------------------------------------------- the ports

class SocketLocalPort final : public Port
{
public:
	// Takes ownership of both descriptors; lockFd holds the name's lock until Invalidate.
	// token is the content of the token file identified by tokenDevice and tokenInode.
	SocketLocalPort(int listenFd, int lockFd, std::string path, dev_t device, ino_t inode,
	                const Token &token, dev_t tokenDevice, ino_t tokenInode, Handler handler)
		: mListenFd(listenFd), mLockFd(lockFd), mPath(std::move(path)), mDevice(device), mInode(inode),
		  mToken(token), mTokenDevice(tokenDevice), mTokenInode(tokenInode), mHandler(std::move(handler))
	{
		const char *timeout = getenv("REPLAY_IPC_TEST_RECEIVE_TIMEOUT");
		if (timeout != nullptr)
		{
			char *end = nullptr;
			double value = strtod(timeout, &end);
			if ((end != timeout) && (*end == '\0') && (value > 0) && (value <= kServerReceiveTimeout))
				mReceiveTimeout = value;
		}
	}

	~SocketLocalPort() override
	{
		Invalidate();
	}

	bool AddToCurrentRunLoop() override
	{
		if ((mListenFd < 0) || (mSocket != nullptr))
			return false;
		CFSocketContext context = { 0, this, nullptr, nullptr, nullptr };
		mSocket.Adopt(CFSocketCreateWithNative(kCFAllocatorDefault, mListenFd, kCFSocketReadCallBack, AcceptCallback, &context));
		if (mSocket == nullptr)
			return false;
		// The descriptor is closed by Invalidate, after the socket file is removed.
		CFSocketSetSocketFlags(mSocket, CFSocketGetSocketFlags(mSocket) & ~(CFOptionFlags)kCFSocketCloseOnInvalidate);
		mSource.Adopt(CFSocketCreateRunLoopSource(kCFAllocatorDefault, mSocket, 0));
		if (mSource == nullptr)
			return false;
		mRunLoop = CFRunLoopGetCurrent();
		CFRunLoopAddSource(mRunLoop, mSource, kCFRunLoopCommonModes);
		return true;
	}

	int32_t SendRequest(int32_t, CFDataRef, double, double, CFDataRef *replyOut) override
	{
		if (replyOut != nullptr)
			*replyOut = nullptr;
		return kInvalid; // a local port receives only
	}

	void Invalidate() override
	{
		if ((mSource != nullptr) && (mRunLoop != nullptr))
			CFRunLoopRemoveSource(mRunLoop, mSource, kCFRunLoopCommonModes);
		mRunLoop = nullptr;
		mSource.Release();
		if (mSocket != nullptr)
			CFSocketInvalidate(mSocket);
		mSocket.Release();
		if (mListenFd >= 0)
		{
			// Remove the socket file only while it is still this server's: after a stale
			// server's file was replaced, the name belongs to the new server.
			struct stat st;
			if ((lstat(mPath.c_str(), &st) == 0) && (st.st_dev == mDevice) && (st.st_ino == mInode))
				unlink(mPath.c_str());
			close(mListenFd);
			mListenFd = -1;
			// The token file likewise, before the lock is given up.
			std::string tokenPath = TokenPath(mPath);
			if ((lstat(tokenPath.c_str(), &st) == 0) && (st.st_dev == mTokenDevice) && (st.st_ino == mTokenInode))
				unlink(tokenPath.c_str());
		}
		if (mLockFd >= 0)
		{ // gives up the name: the next server may take it
			close(mLockFd);
			mLockFd = -1;
		}
	}

private:
	static void AcceptCallback(CFSocketRef, CFSocketCallBackType, CFDataRef, const void *, void *info)
	{
		SocketLocalPort *self = (SocketLocalPort *)info;
		if ((self != nullptr) && (self->mListenFd >= 0))
			self->AcceptOne();
	}

	void AcceptOne()
	{
#if defined(__linux__)
		int fd = accept4(mListenFd, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK); // see NewStreamSocket
		bool ready = (fd >= 0);
#else
		int fd = accept(mListenFd, nullptr, nullptr);
		bool ready = (fd >= 0) && SetCloseOnExecAndNonBlocking(fd);
#endif
		if (fd < 0)
			return; // EAGAIN after a peer gave up, or EINTR: the callback comes again if needed
		if (!ready || !PeerIsSameUser(fd))
		{
			close(fd);
			return;
		}
		Serve(fd);
		close(fd);
	}

	void Serve(int fd)
	{
		double deadline = DeadlineAfter(mReceiveTimeout);
		// The token first: a peer that could not read the token file (a sandboxed command)
		// is dropped before its frame is read.
		uint8_t token[kTokenSize];
		if ((ReadAll(fd, token, sizeof(token), deadline) != Io::kOk) || !SameToken(mToken, token))
			return; // dropped without a reply: a probe, a peer that gave up, or a wrong token

		uint16_t flags = 0;
		int32_t messageId = 0;
		CFObj<CFDataRef> request;
		Io read = ReadFrame(fd, kRequestMagic, deadline, &flags, &messageId, request);
		if (read != Io::kOk)
			return; // dropped without a reply: a peer that gave up, or a bad frame

		CFObj<CFDataRef> reply;
		if (mHandler)
			reply = mHandler(messageId, request);
		request.Release();
		if ((flags & kFlagReplyWanted) != 0)
			(void)WriteFrame(fd, kReplyMagic, 0, kOk, reply, DeadlineAfter(kServerSendTimeout));
	}

	int mListenFd = -1;
	int mLockFd = -1;
	std::string mPath;
	dev_t mDevice = 0;
	ino_t mInode = 0;
	Token mToken;
	dev_t mTokenDevice = 0;
	ino_t mTokenInode = 0;
	Handler mHandler;
	double mReceiveTimeout = kServerReceiveTimeout;
	CFObj<CFSocketRef> mSocket;
	CFObj<CFRunLoopSourceRef> mSource;
	CFRunLoopRef mRunLoop = nullptr; // not retained: the port is used on its own thread only
};

class SocketRemotePort final : public Port
{
public:
	explicit SocketRemotePort(std::string path)
		: mPath(std::move(path))
	{
	}

	bool AddToCurrentRunLoop() override
	{
		return false; // a remote port sends only
	}

	int32_t SendRequest(int32_t messageId, CFDataRef data, double sendTimeout,
	                    double receiveTimeout, CFDataRef *replyOut) override
	{
		if (replyOut != nullptr)
			*replyOut = nullptr;
		if (mPath.empty())
			return kInvalid;

		// Read for every request: a server started again under the name has a new token.
		Token token;
		if (!ReadToken(TokenPath(mPath), &token))
			return (errno == ENOENT) ? kInvalid : kTransportError;

		int fd = -1;
		double sendDeadline = DeadlineAfter(sendTimeout);
		Connect connected = ConnectTo(mPath, sendDeadline, &fd);
		if (connected == Connect::kNobody)
			return kInvalid;
		if (connected == Connect::kTimeout)
			return kSendTimeout;
		if (connected != Connect::kOk)
			return kTransportError;
		if (!PeerIsSameUser(fd))
		{
			close(fd);
			return kTransportError;
		}

		uint16_t flags = (replyOut != nullptr) ? kFlagReplyWanted : 0;
		Io written = WriteAll(fd, token.data(), token.size(), sendDeadline);
		if (written == Io::kOk)
			written = WriteFrame(fd, kRequestMagic, flags, messageId, data, sendDeadline);
		if (written != Io::kOk)
		{
			close(fd);
			if (written == Io::kTimeout)
				return kSendTimeout;
			return (written == Io::kClosed) ? kInvalid : kTransportError;
		}
		if (replyOut == nullptr)
		{
			close(fd);
			return kOk;
		}

		uint16_t replyFlags = 0;
		int32_t status = 0;
		CFObj<CFDataRef> reply;
		Io read = ReadFrame(fd, kReplyMagic, DeadlineAfter(receiveTimeout), &replyFlags, &status, reply);
		close(fd);
		if (read == Io::kTimeout)
			return kReceiveTimeout;
		if (read == Io::kClosed)
			return kBecameInvalid; // the server went away, or dropped the request
		if (read != Io::kOk)
			return kTransportError;
		if (status != kOk)
			return status;
		*replyOut = reply.Detach(); // Create rule: the caller owns it
		return kOk;
	}

	void Invalidate() override
	{
		mPath.clear();
	}

private:
	std::string mPath;
};

} // namespace

std::unique_ptr<Port>
CreateSocketLocal(const std::string &name, Handler handler)
{
	std::string folder = SocketFolder();
	if (!EnsureSocketFolder(folder, true))
		return nullptr;
	std::string path = SocketPath(folder, name);
	struct sockaddr_un address;
	if (!FillAddress(path, &address))
	{
		fprintf(stderr, "error: the folder for replay's ports, %s, is too long for a socket path\n", folder.c_str());
		return nullptr;
	}

	// The server holds an exclusive lock on <socket>.lock for as long as it serves the name,
	// so a lock that cannot be taken means the name is taken. A server that died released
	// its lock with its descriptors, and its socket file is stale. A connect probe cannot
	// tell this apart: a live server with a full accept queue refuses connections on macOS.
	std::string lockPath = path + ".lock";
	int lockFd = open(lockPath.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (lockFd < 0)
	{
		fprintf(stderr, "error: cannot open %s: %s\n", lockPath.c_str(), strerror(errno));
		return nullptr;
	}
	int locked;
	do
		locked = flock(lockFd, LOCK_EX | LOCK_NB);
	while ((locked != 0) && (errno == EINTR));
	if (locked != 0)
	{
		if (errno != EWOULDBLOCK)
			fprintf(stderr, "error: cannot lock %s: %s\n", lockPath.c_str(), strerror(errno));
		close(lockFd); // EWOULDBLOCK: another server holds the name
		return nullptr;
	}

	if ((unlink(path.c_str()) != 0) && (errno != ENOENT))
	{
		fprintf(stderr, "error: cannot remove the stale socket %s: %s\n", path.c_str(), strerror(errno));
		close(lockFd);
		return nullptr;
	}
	// The token exists before the socket does, so a client that finds the socket finds it.
	std::string tokenPath = TokenPath(path);
	Token token;
	dev_t tokenDevice = 0;
	ino_t tokenInode = 0;
	if (!WriteToken(tokenPath, &token, &tokenDevice, &tokenInode))
	{
		close(lockFd);
		return nullptr;
	}
	int listenFd = NewStreamSocket();
	if (listenFd < 0)
	{
		fprintf(stderr, "error: cannot create a socket: %s\n", strerror(errno));
		unlink(tokenPath.c_str());
		close(lockFd);
		return nullptr;
	}
	struct stat st;
	if ((bind(listenFd, (struct sockaddr *)&address, sizeof(address)) != 0)
	    || (listen(listenFd, 128) != 0)
	    || (lstat(path.c_str(), &st) != 0))
	{
		fprintf(stderr, "error: cannot listen on %s: %s\n", path.c_str(), strerror(errno));
		close(listenFd);
		unlink(tokenPath.c_str());
		close(lockFd);
		return nullptr;
	}
	return std::unique_ptr<Port>(new SocketLocalPort(listenFd, lockFd, path, st.st_dev, st.st_ino,
	                                                 token, tokenDevice, tokenInode, std::move(handler)));
}

std::unique_ptr<Port>
CreateSocketRemote(const std::string &name)
{
	std::string folder = SocketFolder();
	if (!EnsureSocketFolder(folder, false))
		return nullptr;
	std::string path = SocketPath(folder, name);
	int fd = -1;
	Connect probe = ConnectTo(path, DeadlineAfter(kProbeTimeout), &fd);
	if (probe != Connect::kOk)
		return nullptr;
	bool sameUser = PeerIsSameUser(fd);
	close(fd);
	if (!sameUser)
		return nullptr;
	// Say why when the token cannot be read: the server is there, but this client may not
	// talk to it. Under the sandbox the read is refused unless the socket folder is granted.
	std::string tokenPath = TokenPath(path);
	Token token;
	if (!ReadToken(tokenPath, &token))
	{
		int error = errno;
		// Once per process: dispatch takes a null port for "no server", tries to start one
		// and asks again for a few seconds, which would print this each time.
		static std::atomic<bool> told(false);
		if (!told.exchange(true))
		{
			if (error == ENOENT)
				fprintf(stderr, "error: %s is missing: the server for this name may come from an older replay, "
				        "or be stopping; if it keeps running, stop it and start it again\n", tokenPath.c_str());
			else
				fprintf(stderr, "error: cannot read %s, which a client needs to talk to the server: %s%s\n",
				        tokenPath.c_str(), (error == EINVAL) ? "not a private file of yours of the right size" : strerror(error),
				        ((error == EACCES) || (error == EPERM)) ? " (a sandboxed command cannot use the servers)" : "");
		}
		return nullptr;
	}
	return std::unique_ptr<Port>(new SocketRemotePort(path));
}

} // namespace detail
} // namespace ipc
