#!/usr/bin/env python3
"""
test_ipc_socket.py - the Unix domain socket backend of replay's IPC (common/IpcPortSocket.cpp),
talked to directly through its socket.

Runs on Linux, where the socket backend is the only one, and on macOS, where it is selected
with REPLAY_IPC_BACKEND=socket. Each case gets its own socket folder: XDG_RUNTIME_DIR (Linux)
or TMPDIR (macOS) is set to a new private folder, so the servers land in <that>/replay/.

Scenarios:
  1. a request round-trips: StartServer gets a reply with the server's process id
  2. a wrong magic, a wrong version, a length over 16 MiB: the connection is closed, the server keeps serving
  3. a peer that closes mid-frame: the server keeps serving
  4. a peer that connects and sends nothing holds the server only until the receive timeout
     (shortened to 1 s with REPLAY_IPC_TEST_RECEIVE_TIMEOUT)
  5. a 1 MiB action round-trips and runs
  6. a stale socket from a killed server: a new server starts
  7. two servers started at once for the same batch: exactly one runs
  8. a socket folder with the wrong mode, or a link, is refused
  9. dispatch wait returns when the server is killed with SIGKILL (the process exit watch)
 10. as root only: another user cannot reach the socket
 11. the token: a private 32 byte file; a request without it, or with a wrong one, is dropped
 12. a sandboxed playlist step cannot have the server run an action (it cannot read the token)

Usage: python3 test_ipc_socket.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import atexit
import os
import plistlib
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"

IS_LINUX = sys.platform.startswith("linux")

# The frame of common/IpcPortSocket.cpp: magic, version, flags, id or status, length.
HEADER = struct.Struct("<4sHHiI")
FLAG_REPLY_WANTED = 1 << 0
FLAG_HAS_PAYLOAD = 1 << 1
MAX_PAYLOAD = 16 * 1024 * 1024

MSG_START_SERVER = 1
MSG_QUEUE_ACTION_DICTIONARY = 2
MSG_QUEUE_ACTION_LINE = 3
MSG_FINISH_AND_WAIT = 4

_pass = 0
_fail = 0


def ok(name: str) -> None:
    global _pass
    _pass += 1
    print(f"  PASS: {name}")


def fail(name: str, reason: str = "") -> None:
    global _fail
    _fail += 1
    msg = f"  FAIL: {name}"
    if reason:
        msg += f"\n        {reason[:300]}"
    print(msg)


def check(name: str, condition: bool, reason: str = "") -> bool:
    if condition:
        ok(name)
        return True
    fail(name, reason)
    return False


class Folder:
    """A private base folder standing in for XDG_RUNTIME_DIR (Linux) or TMPDIR (macOS)."""

    def __init__(self):
        self.base = Path(tempfile.mkdtemp(prefix="ipc"))
        atexit.register(shutil.rmtree, self.base, True)
        os.chmod(self.base, 0o700)
        self.sockets = self.base / "replay"

    def env(self, **extra) -> dict:
        env = dict(os.environ)
        env.pop("REPLAY_IPC_TEST_RECEIVE_TIMEOUT", None)
        if IS_LINUX:
            env["XDG_RUNTIME_DIR"] = str(self.base)
        else:
            env["TMPDIR"] = str(self.base) + "/"
            env["REPLAY_IPC_BACKEND"] = "socket"
        env.update(extra)
        return env

    def socket_path(self, batch: str) -> Path:
        return self.sockets / f"group.replay-port.{batch}.sock"


def start_server(replay: Path, folder: Folder, batch: str, **extra_env) -> subprocess.Popen:
    return subprocess.Popen([str(replay), "--start-server", batch],
                            env=folder.env(**extra_env), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def wait_for_socket(path: Path, server: subprocess.Popen, seconds: float = 5) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists():
            return True
        if server.poll() is not None:
            return False
        time.sleep(0.02)
    return False


def recv_exact(sock: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        try:
            chunk = sock.recv(size - len(data))
        except ConnectionResetError:
            return data  # closed with bytes still unread: Linux resets instead
        if not chunk:
            return data
        data += chunk
    return data


def token_path(path: Path) -> Path:
    return path.parent / (path.name + ".token")


def read_token(path: Path) -> bytes:
    """The server's token, which a client sends before its frame; b"" when unreadable."""
    try:
        return token_path(path).read_bytes()
    except OSError:
        return b""


def request(path: Path, message_id: int, payload, want_reply: bool, timeout: float = 10,
            token: bytes = None):
    """Sends the token and one request frame; returns (status, payload) of the reply, or
    None when the server closed the connection without one, or () when no reply was
    wanted. token: what to send in place of the server's token."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(str(path))
        flags = FLAG_REPLY_WANTED if want_reply else 0
        body = b""
        if payload is not None:
            flags |= FLAG_HAS_PAYLOAD
            body = payload
        sent_token = read_token(path) if token is None else token
        sock.sendall(sent_token + HEADER.pack(b"RPLC", 1, flags, message_id, len(body)) + body)
        if not want_reply:
            return ()
        header = recv_exact(sock, HEADER.size)
        if len(header) < HEADER.size:
            return None
        magic, version, reply_flags, status, length = HEADER.unpack(header)
        if magic != b"RPLY" or version != 1:
            return None
        reply = recv_exact(sock, length) if reply_flags & FLAG_HAS_PAYLOAD else None
        return (status, reply)


def ping(path: Path, timeout: float = 10):
    """The server's process id from a StartServer request, or None."""
    try:
        reply = request(path, MSG_START_SERVER, None, True, timeout)
    except OSError:
        return None
    if not reply or reply[0] != 0 or reply[1] is None:
        return None
    return plistlib.loads(reply[1]).get("pid")


def wait_for_answer(path: Path, server: subprocess.Popen, seconds: float = 10):
    """Pings until the server answers, exits, or the time is up; returns the process id or None."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        pid = ping(path, timeout=2)
        if pid is not None or server.poll() is not None:
            return pid
        time.sleep(0.05)
    return None


def send_raw_then_read(path: Path, data: bytes, close_early: bool = False) -> bytes:
    """Sends the token, then raw bytes; returns what the server sends back before it
    closes (b"" expected)."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect(str(path))
        sock.sendall(read_token(path) + data)
        if close_early:
            return b""
        try:
            return sock.recv(64)
        except ConnectionResetError:
            return b""  # closed with bytes still unread: the kernel resets instead
        except socket.timeout:
            return b"(no close within 5 s)"


def finish(server: subprocess.Popen, path: Path, timeout: float = 15):
    """Asks the server to finish; returns its (stdout, stderr)."""
    try:
        request(path, MSG_FINISH_AND_WAIT, plistlib.dumps({}, fmt=plistlib.FMT_BINARY), True)
    except OSError:
        pass
    try:
        out, err = server.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        server.kill()
        out, err = server.communicate()
    return out.decode(errors="replace"), err.decode(errors="replace")


def stop(server: subprocess.Popen) -> None:
    if server.poll() is None:
        server.kill()
    server.communicate()


# ----------------------------------------------------------------------------------- tests

def test_round_trip(replay: Path) -> None:
    print("\n=== 1. a request round-trips ===")
    folder = Folder()
    path = folder.socket_path("ipct1")
    server = start_server(replay, folder, "ipct1")
    if not check("the server creates its socket", wait_for_socket(path, server),
                 server.stderr.read().decode(errors="replace") if server.poll() is not None else ""):
        stop(server)
        return
    mode = os.stat(folder.sockets).st_mode & 0o777
    check("the socket folder has mode 0700", mode == 0o700, oct(mode))
    pid = ping(path)
    check("StartServer gets the server's process id", pid == server.pid, f"got {pid}, server {server.pid}")
    out, err = finish(server, path)
    check("the server exits after FinishAndWait", server.returncode == 0, err)
    check("the server removes its socket", not path.exists())
    check("the server removes its token", not token_path(path).exists())


def test_bad_frames(replay: Path) -> None:
    print("\n=== 2. bad frames ===")
    folder = Folder()
    path = folder.socket_path("ipct2")
    server = start_server(replay, folder, "ipct2")
    if not wait_for_socket(path, server):
        fail("the server creates its socket")
        stop(server)
        return
    cases = [
        ("a wrong magic", HEADER.pack(b"XXXX", 1, FLAG_REPLY_WANTED, MSG_START_SERVER, 0)),
        ("a reply magic sent as a request", HEADER.pack(b"RPLY", 1, FLAG_REPLY_WANTED, MSG_START_SERVER, 0)),
        ("a wrong version", HEADER.pack(b"RPLC", 2, FLAG_REPLY_WANTED, MSG_START_SERVER, 0)),
        ("a length over 16 MiB", HEADER.pack(b"RPLC", 1, FLAG_REPLY_WANTED | FLAG_HAS_PAYLOAD,
                                             MSG_QUEUE_ACTION_LINE, MAX_PAYLOAD + 1)),
        ("a length without the payload flag", HEADER.pack(b"RPLC", 1, FLAG_REPLY_WANTED, MSG_START_SERVER, 4) + b"abcd"),
    ]
    for name, data in cases:
        got = send_raw_then_read(path, data)
        check(f"{name}: closed without a reply", got == b"", repr(got))
        check(f"{name}: the server keeps serving", ping(path) == server.pid)

    print("\n=== 3. a peer that closes mid-frame ===")
    send_raw_then_read(path, b"RPLC\x01\x00", close_early=True)
    check("a header cut short: the server keeps serving", ping(path) == server.pid)
    send_raw_then_read(path, HEADER.pack(b"RPLC", 1, FLAG_HAS_PAYLOAD, MSG_QUEUE_ACTION_LINE, 100) + b"[echo]", close_early=True)
    check("a payload cut short: the server keeps serving", ping(path) == server.pid)
    finish(server, path)


def test_silent_peer(replay: Path) -> None:
    print("\n=== 4. a peer that sends nothing ===")
    folder = Folder()
    path = folder.socket_path("ipct4")
    server = start_server(replay, folder, "ipct4", REPLAY_IPC_TEST_RECEIVE_TIMEOUT="1")
    if not wait_for_socket(path, server):
        fail("the server creates its socket")
        stop(server)
        return
    silent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    silent.connect(str(path))
    time.sleep(0.1)  # the server accepts the silent peer first
    started = time.monotonic()
    pid = ping(path, timeout=10)
    elapsed = time.monotonic() - started
    silent.close()
    check("the next request is served", pid == server.pid)
    check("after the 1 s receive timeout, not before and not much after", 0.7 <= elapsed <= 4,
          f"took {elapsed:.2f} s")
    finish(server, path)


def test_large_action(replay: Path) -> None:
    print("\n=== 5. a 1 MiB action ===")
    folder = Folder()
    path = folder.socket_path("ipct5")
    server = start_server(replay, folder, "ipct5")
    if not wait_for_socket(path, server):
        fail("the server creates its socket")
        stop(server)
        return
    text = "ipc-large-" + ("x" * (1024 * 1024)) + "-end"
    action = plistlib.dumps({"action": "echo", "text": text}, fmt=plistlib.FMT_BINARY)
    reply = request(path, MSG_QUEUE_ACTION_DICTIONARY, action, True)
    check("the action is accepted", reply is not None and reply[0] == 0, repr(reply)[:200])
    line = b"[echo]\tipc-line-action\n"
    check("a line action is sent with no reply wanted", request(path, MSG_QUEUE_ACTION_LINE, line, False) == ())
    out, err = finish(server, path)
    check("the 1 MiB text is echoed whole", text in out, f"output is {len(out)} characters; stderr: {err[:200]}")
    check("the line action ran", "ipc-line-action" in out, out[-200:])


def test_stale_socket(replay: Path) -> None:
    print("\n=== 6. a stale socket ===")
    folder = Folder()
    path = folder.socket_path("ipct6")
    first = start_server(replay, folder, "ipct6")
    if not wait_for_socket(path, first):
        fail("the first server creates its socket")
        stop(first)
        return
    first.send_signal(signal.SIGKILL)
    first.communicate()
    check("the killed server leaves its socket behind", path.exists())
    second = start_server(replay, folder, "ipct6")
    pid = wait_for_answer(path, second)
    check("a new server takes the name", pid == second.pid, f"got {pid}, new server {second.pid}")
    finish(second, path)


def test_two_servers(replay: Path) -> None:
    print("\n=== 7. two servers at once ===")
    folder = Folder()
    path = folder.socket_path("ipct7")
    servers = [start_server(replay, folder, "ipct7") for _ in range(2)]
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and all(s.poll() is None for s in servers):
        time.sleep(0.05)
    time.sleep(0.2)  # in case the second one also exits
    running = [s for s in servers if s.poll() is None]
    exited = [s for s in servers if s.poll() is not None]
    check("exactly one server runs", len(running) == 1, f"{len(running)} running")
    if exited:
        err = exited[0].communicate()[1].decode(errors="replace")
        check("the other reports the name taken", exited[0].returncode != 0
              and "could not create a local message port" in err, err[:200])
    if running:
        check("the one running answers", ping(path) == running[0].pid)
        finish(running[0], path)
    for s in exited:
        stop(s)


def test_folder_checks(replay: Path) -> None:
    print("\n=== 8. the folder checks ===")
    folder = Folder()
    folder.sockets.mkdir(mode=0o755)
    os.chmod(folder.sockets, 0o755)
    server = start_server(replay, folder, "ipct8")
    try:
        _, err = server.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        _, err = server.communicate()
    err = err.decode(errors="replace")
    check("a folder open to others is refused", server.returncode != 0 and "mode 0700" in err, err[:200])

    folder = Folder()
    target = folder.base / "elsewhere"
    target.mkdir(mode=0o700)
    os.symlink(target, folder.sockets)
    server = start_server(replay, folder, "ipct8")
    try:
        _, err = server.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        _, err = server.communicate()
    err = err.decode(errors="replace")
    check("a link in place of the folder is refused", server.returncode != 0 and "not a link" in err, err[:200])


def test_dispatch_wait_on_kill(replay: Path) -> None:
    print("\n=== 9. dispatch wait when the server is killed ===")
    dispatch = replay.parent / "dispatch"
    if not dispatch.exists():
        fail("dispatch next to replay", str(dispatch))
        return
    folder = Folder()
    path = folder.socket_path("ipct9")
    server = start_server(replay, folder, "ipct9")
    if not wait_for_socket(path, server):
        fail("the server creates its socket")
        stop(server)
        return
    queued = subprocess.run([str(dispatch), "ipct9", "execute", "/bin/sleep", "8"],
                            env=folder.env(), capture_output=True, text=True, timeout=15)
    check("dispatch queues a long action", queued.returncode == 0, queued.stderr)
    waiter = subprocess.Popen([str(dispatch), "ipct9", "wait"], env=folder.env(),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(1.0)
    check("dispatch wait is waiting", waiter.poll() is None)
    killed_at = time.monotonic()
    server.send_signal(signal.SIGKILL)
    server.communicate()
    try:
        waiter.communicate(timeout=6)
        elapsed = time.monotonic() - killed_at
        check("dispatch wait returns soon after the kill", elapsed < 3, f"took {elapsed:.2f} s")
    except subprocess.TimeoutExpired:
        waiter.kill()
        waiter.communicate()
        fail("dispatch wait returns soon after the kill", "still waiting after 6 s")


def test_other_user(replay: Path) -> None:
    print("\n=== 10. another user ===")
    if os.geteuid() != 0:
        print("  skipped: needs root to run a client as another user")
        return
    folder = Folder()
    path = folder.socket_path("ipct10")
    server = start_server(replay, folder, "ipct10")
    if not wait_for_socket(path, server):
        fail("the server creates its socket")
        stop(server)
        return
    probe = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--connect-probe", str(path)],
                           user=65534, group=65534, capture_output=True, text=True, timeout=15)
    check("a client of another user cannot connect", probe.stdout.strip() == "refused",
          probe.stdout + probe.stderr)
    finish(server, path)


def test_token(replay: Path) -> None:
    print("\n=== 11. the token ===")
    folder = Folder()
    path = folder.socket_path("ipct11")
    # Without the token the server takes the frame's 16 bytes as half a token and waits
    # for the rest until its receive timeout, shortened to 1 s.
    server = start_server(replay, folder, "ipct11", REPLAY_IPC_TEST_RECEIVE_TIMEOUT="1")
    if not wait_for_socket(path, server):
        fail("the server creates its socket")
        stop(server)
        return
    st = os.lstat(token_path(path))
    check("the token is a plain file with mode 0600", (st.st_mode & 0o777) == 0o600 and (st.st_mode & 0o170000) == 0o100000,
          oct(st.st_mode))
    token = read_token(path)
    check("the token has 32 bytes", len(token) == 32, repr(len(token)))
    check("no token: closed without a reply", request(path, MSG_START_SERVER, None, True, timeout=5, token=b"") is None)
    check("no token: the server keeps serving", ping(path) == server.pid)
    wrong = bytes([token[0] ^ 1]) + token[1:]
    check("a wrong token: closed without a reply", request(path, MSG_START_SERVER, None, True, timeout=5, token=wrong) is None)
    check("a wrong token: the server keeps serving", ping(path) == server.pid)
    finish(server, path)

    second = start_server(replay, folder, "ipct11")
    if wait_for_answer(path, second) is None:
        fail("a second server under the name answers")
        stop(second)
        return
    check("a server started again under the name has a new token", read_token(path) not in (b"", token))
    finish(second, path)


def test_sandboxed_step(replay: Path) -> None:
    print("\n=== 12. a sandboxed playlist step ===")
    dispatch = replay.parent / "dispatch"
    if not dispatch.exists():
        fail("dispatch next to replay", str(dispatch))
        return
    folder = Folder()
    path = folder.socket_path("ipct12")
    server = start_server(replay, folder, "ipct12")
    if not wait_for_socket(path, server):
        fail("the server creates its socket")
        stop(server)
        return
    work = Path(tempfile.mkdtemp(prefix="ipcw"))
    atexit.register(shutil.rmtree, work, True)
    # Control: the same step unsandboxed reaches the server.
    line = f"[execute]\t{dispatch}\tipct12\techo\tFROM-PLAIN-STEP\n"
    subprocess.run([str(replay)], input=line, env=folder.env(), capture_output=True, text=True, timeout=30)
    line = f"[execute]\t{dispatch}\tipct12\techo\tFROM-SANDBOXED-STEP\n"
    boxed = subprocess.run([str(replay), "--allow-write", str(work)], input=line, env=folder.env(),
                           capture_output=True, text=True, timeout=30)
    out, err = finish(server, path)
    check("control: an unsandboxed step has the server run an action", "FROM-PLAIN-STEP" in out, out[-300:] + err[-300:])
    check("a sandboxed step cannot have the server run an action", "FROM-SANDBOXED-STEP" not in out, out[-300:])
    check("the step says the token cannot be read", ".token" in boxed.stderr + boxed.stdout,
          (boxed.stdout + boxed.stderr)[-400:])


def connect_probe(path: str) -> int:
    """Run as another user by test 10: prints whether connecting works."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(path)
        print("connected")
    except OSError:
        print("refused")
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--connect-probe":
        return connect_probe(sys.argv[2])

    replay = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY
    if not replay.exists():
        print(f"error: replay not found at {replay}")
        return 1
    print(f"replay = {replay}")
    print("backend: Unix domain socket" + ("" if IS_LINUX else " (REPLAY_IPC_BACKEND=socket)"))

    test_round_trip(replay)
    test_bad_frames(replay)
    test_silent_peer(replay)
    test_large_action(replay)
    test_stale_socket(replay)
    test_two_servers(replay)
    test_folder_checks(replay)
    test_dispatch_wait_on_kill(replay)
    test_other_user(replay)
    test_token(replay)
    test_sandboxed_step(replay)

    print(f"\nPassed: {_pass}  Failed: {_fail}")
    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
