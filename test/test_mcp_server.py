#!/usr/bin/env python3
"""
test_mcp_server.py — end-to-end tests for replay --mcp-server

Usage:  python3 test_mcp_server.py [/path/to/replay]
Exit:   0 = all tests passed, 1 = one or more failures
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_DIR   = SCRIPT_DIR.parent

DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

# ---------------------------------------------------------------------------
# Minimal test harness
# ---------------------------------------------------------------------------

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
        msg += f"\n        {reason}"
    print(msg)

def check(name: str, condition: bool, reason: str = "") -> bool:
    if condition:
        ok(name)
        return True
    fail(name, reason)
    return False

# ---------------------------------------------------------------------------
# MCP server driver
# ---------------------------------------------------------------------------

def run_mcp(messages: list[dict], allow_write: list[str] = (), *,
            extra_args: list[str] = (), sequential: bool = False) -> dict:
    """Run replay --mcp-server with the given JSON-RPC messages.

    allow_write: directories passed as --allow-write (implies --sandbox).
    extra_args:  additional flags such as ["--allow-read", path].
    sequential:  if True, send each message and wait for response before sending next.

    Returns dict: id -> response object.
    """
    allow_write_flags: list[str] = []
    for d in allow_write:
        allow_write_flags += ["--allow-write", d]
    cmd = [str(REPLAY), *allow_write_flags, *extra_args, "--mcp-server"]

    responses: dict = {}

    # Launch a single process for the entire test lifetime
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,  # Handles encoding/decoding automatically
        bufsize=1   # Line-buffered for interactive communication
    )

    try:

        if sequential:
            # Send one, wait for response (if expected), then repeat
            for m in messages:
                proc.stdin.write(json.dumps(m) + "\n")
                proc.stdin.flush()
                
                # JSON-RPC standard: Notifications do NOT have an 'id' and get no reply
                if "id" not in m:
                    continue
                    
                # Only block and read if the message expects a response
                line = proc.stdout.readline()
                # If line is empty, the server process died or closed the stream
                if not line:
                    # Capture any stderr diagnostics before raising
                    stderr_err = proc.stderr.read() if proc.stderr else "No stderr captured."
                    return_code = proc.poll()
                    raise RuntimeError(
                        f"MCP server disconnected unexpectedly while waiting for a response to request ID {m.get('id')}.\n"
                        f"Server Exit Code: {return_code}\n"
                        f"Server Stderr Output:\n{stderr_err}"
                    )
                
                if line:
                    r = json.loads(line.strip())
                    responses[r.get("id")] = r
        else:
            # Pipeline all messages immediately to the server
            for m in messages:
                proc.stdin.write(json.dumps(m) + "\n")
            proc.stdin.flush()
            
            # Close stdin so the server knows no more inputs are coming
            proc.stdin.close()
            
            # Read all responses until the stream reaches EOF
            for line in proc.stdout:
                if line.strip():
                    r = json.loads(line.strip())
                    responses[r.get("id")] = r

    finally:
        # Prevent resource leaks by ensuring clean termination
        if proc.stdin and not proc.stdin.closed:
            proc.stdin.close()
        proc.terminate()
        proc.wait(timeout=5)

    return responses

def text_of(resp: dict) -> str:
    """Extract content[0].text from a tools/call result response."""
    return resp.get("result", {}).get("content", [{}])[0].get("text", "")

def is_error(resp: dict, code: int | None = None) -> bool:
    if "error" not in resp:
        return False
    if code is not None:
        return resp["error"]["code"] == code
    return True

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

def test_handshake_isolated(tmpdir: str) -> None:
    print("\n=== ISOLATION STEP 1: INITIALIZE ===")
    r1 = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}}}
    ], [tmpdir], sequential=False)
    print(f"Step 1 Response: {r1}")

    print("\n=== ISOLATION STEP 2: NOTIFICATION ===")
    # Note: Running this alone won't generate an output, but verifies no crash
    r2 = run_mcp([
        {"jsonrpc": "2.0", "method": "initialized"}
    ], [tmpdir], sequential=False)
    print(f"Step 2 Response (Should be empty dict): {r2}")

    print("\n=== ISOLATION STEP 3: PING ===")
    r3 = run_mcp([
        {"jsonrpc": "2.0", "id": 2, "method": "ping"}
    ], [tmpdir], sequential=False)
    print(f"Step 3 Response: {r3}")

def test_handshake(tmpdir: str) -> None:
    print("=== MCP: initialize / initialized / ping ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}}},
        {"jsonrpc": "2.0", "method": "initialized"},   # notification — no response
        {"jsonrpc": "2.0", "id": 2, "method": "ping"},
    ], [tmpdir], sequential=True)

    check("initialize returns protocolVersion",
          by_id[1].get("result", {}).get("protocolVersion") == "2024-11-05")
    check("initialize returns serverInfo.name == replay-mcp",
          by_id[1].get("result", {}).get("serverInfo", {}).get("name") == "replay-mcp")
    check("initialized notification produces no response",
          len(by_id) == 2,
          f"expected 2 responses, got {len(by_id)}")
    check("ping returns empty result",
          "result" in by_id[2] and "error" not in by_id[2])


def test_tools_list(tmpdir: str) -> None:
    print("=== MCP: tools/list ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    ], [tmpdir])

    tools = {t["name"] for t in by_id[1].get("result", {}).get("tools", [])}
    required = {
        "read_file", "read_multiple_files", "write_file", "edit_file",
        "create_directory", "list_directory", "directory_tree", "move_file",
        "delete_file", "search_files", "get_file_info",
        "list_allowed_directories", "glob_search",
    }
    missing = required - tools
    check("tools/list includes all required tools",
          not missing, f"missing: {missing}")


def test_write_read(tmpdir: str) -> None:
    print("=== MCP: write_file + read_file ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{tmpdir}/hello.txt",
                                  "content": "Hello, MCP!\nLine 2\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "read_file",
                    "arguments": {"path": f"{tmpdir}/hello.txt"}}},
    ], [tmpdir], sequential=True)

    check("write_file succeeds",
          "Successfully wrote" in text_of(by_id[1]))
    check("read_file returns correct content",
          "Hello, MCP!" in text_of(by_id[2]) and "Line 2" in text_of(by_id[2]))


def test_edit_literal(tmpdir: str) -> None:
    print("=== MCP: edit_file (literal, unlimited) ===")

    path = f"{tmpdir}/edit_lit.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path, "content": "foo bar\nfoo qux\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": path,
                                  "edits": [{"oldText": "foo", "newText": "FOO",
                                             "limit": 0}]}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[3])
    check("literal replace all occurrences",
          "FOO bar" in text and "FOO qux" in text and "foo" not in text,
          f"got: {text!r}")


def test_edit_regex(tmpdir: str) -> None:
    print("=== MCP: edit_file (regex + backreferences) ===")

    path = f"{tmpdir}/edit_re.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path,
                                  "content": "v1_alpha\nv2_beta\nv3_gamma\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": path,
                                  "edits": [{"oldText": "v([0-9]+)_([a-z]+)",
                                             "newText": "version-\\1(\\2)",
                                             "regex": True, "limit": 0}]}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[3])
    check("regex + backreferences",
          "version-1(alpha)" in text and "version-2(beta)" in text
          and "version-3(gamma)" in text,
          f"got: {text!r}")


def test_edit_case_insensitive(tmpdir: str) -> None:
    print("=== MCP: edit_file (case-insensitive) ===")

    path = f"{tmpdir}/edit_ci.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path,
                                  "content": "TODO: fix\ntodo: also\nToDo: and this\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": path,
                                  "edits": [{"oldText": "todo", "newText": "DONE",
                                             "caseInsensitive": True, "limit": 0}]}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[3])
    import re
    remaining = re.findall(r"[Tt][Oo][Dd][Oo]", text)
    check("case-insensitive replace all",
          not remaining and text.count("DONE") == 3,
          f"remaining todos: {remaining!r}, text: {text!r}")


def test_edit_dryrun(tmpdir: str) -> None:
    print("=== MCP: edit_file (dry-run) ===")

    path = f"{tmpdir}/edit_dr.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path, "content": "original content\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": path,
                                  "edits": [{"oldText": "original",
                                             "newText": "replaced"}],
                                  "dryRun": True}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    check("dry-run returns plan header",
          "Dry-run" in text_of(by_id[2]))
    check("dry-run does not modify file",
          "original content" in text_of(by_id[3]))


def test_create_directory(tmpdir: str) -> None:
    print("=== MCP: create_directory (deeply nested) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "create_directory",
                    "arguments": {"path": f"{tmpdir}/deep/nested/dir"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "get_file_info",
                    "arguments": {"path": f"{tmpdir}/deep/nested/dir"}}},
    ], [tmpdir], sequential=True)

    check("create_directory succeeds",
          "Created" in text_of(by_id[1]))
    check("get_file_info confirms directory",
          "type: directory" in text_of(by_id[2]))


def test_list_directory(tmpdir: str) -> None:
    print("=== MCP: list_directory ===")

    d = f"{tmpdir}/listdir"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/a.txt", "content": "a"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/b.txt", "content": "b"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "create_directory",
                    "arguments": {"path": f"{d}/subdir"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "list_directory", "arguments": {"path": d}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[4])
    check("list_directory: files present",
          "[FILE] a.txt" in text and "[FILE] b.txt" in text, f"got: {text!r}")
    check("list_directory: subdir present",
          "[DIR]  subdir" in text, f"got: {text!r}")


def test_directory_tree(tmpdir: str) -> None:
    print("=== MCP: directory_tree ===")

    d = f"{tmpdir}/tree"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/a.txt", "content": "a"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/sub/b.txt", "content": "b"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "directory_tree", "arguments": {"path": d}}},
    ], [tmpdir], sequential=True)

    tree = json.loads(text_of(by_id[3]))
    names = {c["name"] for c in tree.get("children", [])}
    check("directory_tree: root is directory",
          tree.get("type") == "directory")
    check("directory_tree: top-level file present",
          "a.txt" in names, f"got: {names}")
    check("directory_tree: subdirectory present",
          "sub" in names, f"got: {names}")
    sub = next((c for c in tree["children"] if c["name"] == "sub"), None)
    check("directory_tree: nested file present",
          sub is not None and any(c["name"] == "b.txt"
                                  for c in sub.get("children", [])))


def test_move_file(tmpdir: str) -> None:
    print("=== MCP: move_file ===")

    src = f"{tmpdir}/move_src.txt"
    dst = f"{tmpdir}/move_dst.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": src, "content": "moved content"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "move_file",
                    "arguments": {"source": src, "destination": dst}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": dst}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": src}}},
    ], [tmpdir], sequential=True)

    check("move_file: destination readable",
          "moved content" in text_of(by_id[3]))
    check("move_file: source no longer exists",
          is_error(by_id[4]))


def test_delete_file(tmpdir: str) -> None:
    print("=== MCP: delete_file ===")

    path = f"{tmpdir}/del_test.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path, "content": "to be deleted"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "delete_file", "arguments": {"path": path}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    check("delete_file succeeds",
          "Deleted" in text_of(by_id[2]))
    check("delete_file: file no longer accessible",
          is_error(by_id[3]))


def test_search_files(tmpdir: str) -> None:
    print("=== MCP: search_files ===")

    d = f"{tmpdir}/search"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/foo.swift", "content": "swift"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/bar.cpp", "content": "cpp"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/sub/baz.swift", "content": "s2"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "search_files",
                    "arguments": {"path": d, "pattern": "**/*.swift"}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[4])
    check("search_files: matches swift files",
          "foo.swift" in text and "baz.swift" in text, f"got: {text!r}")
    check("search_files: excludes cpp files",
          "bar.cpp" not in text, f"got: {text!r}")


def test_get_file_info(tmpdir: str) -> None:
    print("=== MCP: get_file_info ===")

    path = f"{tmpdir}/info_test.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path, "content": "12345"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "get_file_info", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[2])
    check("get_file_info: type=file", "type: file" in text, text)
    check("get_file_info: size=5",    "size: 5" in text,    text)
    check("get_file_info: modified timestamp present", "modified:" in text, text)
    check("get_file_info: permissions present",        "permissions:" in text, text)


def test_read_multiple_files(tmpdir: str) -> None:
    print("=== MCP: read_multiple_files ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{tmpdir}/multi_a.txt",
                                  "content": "content A"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{tmpdir}/multi_b.txt",
                                  "content": "content B"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_multiple_files",
                    "arguments": {"paths": [
                        f"{tmpdir}/multi_a.txt",
                        f"{tmpdir}/multi_b.txt",
                        f"{tmpdir}/nonexistent.txt",
                    ]}}},
    ], [tmpdir], sequential=True)

    items = by_id[3].get("result", {}).get("content", [])
    check("read_multiple_files: 3 content items",
          len(items) == 3, f"got {len(items)}")
    check("read_multiple_files: file A content",
          "content A" in items[0]["text"])
    check("read_multiple_files: file B content",
          "content B" in items[1]["text"])
    check("read_multiple_files: inline error for missing file",
          "error" in items[2]["text"].lower())


def test_glob_search(tmpdir: str) -> None:
    print("=== MCP: glob_search ===")

    d = f"{tmpdir}/glob"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/src/main.cpp", "content": ""}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/src/util.cpp", "content": ""}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/include/util.h", "content": ""}}},
        # Multi-pattern (array)
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "glob_search",
                    "arguments": {"path": d,
                                  "patterns": ["**/*.cpp", "**/*.h"]}}},
        # Single pattern string
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
         "params": {"name": "glob_search",
                    "arguments": {"path": d, "pattern": "src/*.cpp"}}},
    ], [tmpdir], sequential=True)

    text4 = text_of(by_id[4])
    check("glob_search multi-pattern: cpp files present",
          "main.cpp" in text4 and "util.cpp" in text4, text4)
    check("glob_search multi-pattern: header present",
          "util.h" in text4, text4)

    text5 = text_of(by_id[5])
    check("glob_search single pattern: cpp files present",
          "main.cpp" in text5 and "util.cpp" in text5, text5)
    check("glob_search single pattern: header excluded",
          "util.h" not in text5, text5)


def test_list_allowed_directories(tmpdir: str) -> None:
    print("=== MCP: list_allowed_directories ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "list_allowed_directories", "arguments": {}}},
    ], [tmpdir])

    text = text_of(by_id[1])
    check("list_allowed_directories: shows allowed dir",
          tmpdir.split("/")[-1] in text or "read-write" in text, text)


def test_path_validation(tmpdir: str) -> None:
    print("=== MCP: path validation ===")

    by_id = run_mcp([
        # Read outside allowed dir
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "read_file",
                    "arguments": {"path": "/etc/passwd"}}},
        # Write outside allowed dir
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": "/tmp/mcp_evil.txt",
                                  "content": "evil"}}},
    ], [tmpdir])

    check("read outside allowed dir, expected error: -32001",
          is_error(by_id[1], -32001),
          str(by_id[1]))
    check("write outside allowed dir, expected error: -32001",
          is_error(by_id[2], -32001),
          str(by_id[2]))


def test_readonly_dir(tmpdir: str) -> None:
    print("=== MCP: read-only allowed dir (--allow-read) ===")

    ro_dir = os.path.join(tmpdir, "ro_area")
    os.makedirs(ro_dir, exist_ok=True)
    ro_file = os.path.join(ro_dir, "file.txt")
    with open(ro_file, "w") as f:
        f.write("read-only content")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "read_file",
                    "arguments": {"path": ro_file}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": os.path.join(ro_dir, "new.txt"),
                                  "content": "should fail"}}},
    ], [], extra_args=["--allow-read", ro_dir])

    check("--allow-read: read succeeds",
          "read-only content" in text_of(by_id[1]))
    check("--allow-read: write rejected with -32001",
          is_error(by_id[2], -32001), str(by_id[2]))


def test_protocol_errors(tmpdir: str) -> None:
    print("=== MCP: protocol errors ===")

    by_id = run_mcp([
        # Unknown method with id, expected error: -32601
        {"jsonrpc": "2.0", "id": 1, "method": "nonexistent/method", "params": {}},
        # String id preserved
        {"jsonrpc": "2.0", "id": "myid", "method": "ping"},
        # Null id preserved
        {"jsonrpc": "2.0", "id": None, "method": "ping"},
    ], [tmpdir])

    check("unknown method, expected error: -32601",
          is_error(by_id[1], -32601), str(by_id[1]))
    check("string id preserved",
          by_id["myid"].get("id") == "myid", str(by_id["myid"]))
    check("null id preserved",
          by_id[None].get("id") is None, str(by_id[None]))


def test_parse_error(tmpdir: str) -> None:
    print("=== MCP: parse error (invalid JSON) ===")

    cmd = [str(REPLAY), "--mcp-server"]
    result = subprocess.run(
        cmd,
        input=b"this is not json\n",
        capture_output=True,
        timeout=10,
    )
    resps = [json.loads(line) for line in result.stdout.decode().splitlines() if line.strip()]
    check("invalid JSON, expected error: -32700",
          len(resps) == 1 and is_error(resps[0], -32700),
          str(resps))


def test_initialized_notification_no_response(tmpdir: str) -> None:
    print("=== MCP: initialized notification has no response ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "method": "initialized"},
    ], [tmpdir])

    check("initialized notification produces no response",
          len(by_id) == 0, f"got {len(by_id)} responses")


def test_concurrent_requests(tmpdir: str) -> None:
    print("=== MCP: concurrent requests (N writes + reads) ===")

    n = 10
    messages = []
    for i in range(n):
        messages.append({
            "jsonrpc": "2.0", "id": i + 1,
            "method": "tools/call",
            "params": {"name": "write_file",
                       "arguments": {"path": f"{tmpdir}/concurrent_{i}.txt",
                                     "content": f"content-{i}"}},
        })
    for i in range(n):
        messages.append({
            "jsonrpc": "2.0", "id": n + i + 1,
            "method": "tools/call",
            "params": {"name": "read_file",
                       "arguments": {"path": f"{tmpdir}/concurrent_{i}.txt"}},
        })

    by_id = run_mcp(messages, [tmpdir])

    check(f"concurrent: all {2*n} responses received",
          len(by_id) == 2 * n, f"got {len(by_id)}")
    all_writes_ok = all("Successfully wrote" in text_of(by_id[i + 1]) for i in range(n))
    check("concurrent: all writes succeeded", all_writes_ok)
    all_reads_ok = all(f"content-{i}" in text_of(by_id[n + i + 1]) for i in range(n))
    check("concurrent: all reads returned correct content", all_reads_ok)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    if not REPLAY.exists():
        print(f"error: replay binary not found at {REPLAY}", file=sys.stderr)
        return 1

    print(f"\nreplay: {REPLAY}")
    print("=" * 50)

    with tempfile.TemporaryDirectory(prefix="replay_mcp_test_") as tmpdir:
        test_handshake_isolated(tmpdir)
        test_handshake(tmpdir)
        test_tools_list(tmpdir)
        test_write_read(tmpdir)
        test_edit_literal(tmpdir)
        test_edit_regex(tmpdir)
        test_edit_case_insensitive(tmpdir)
        test_edit_dryrun(tmpdir)
        test_create_directory(tmpdir)
        test_list_directory(tmpdir)
        test_directory_tree(tmpdir)
        test_move_file(tmpdir)
        test_delete_file(tmpdir)
        test_search_files(tmpdir)
        test_get_file_info(tmpdir)
        test_read_multiple_files(tmpdir)
        test_glob_search(tmpdir)
        test_list_allowed_directories(tmpdir)
        test_path_validation(tmpdir)
        test_readonly_dir(tmpdir)
        test_protocol_errors(tmpdir)
        test_parse_error(tmpdir)
        test_initialized_notification_no_response(tmpdir)
        test_concurrent_requests(tmpdir)

    print()
    print("=" * 50)
    print(f"  Passed: {_pass}   Failed: {_fail}")
    print("=" * 50)

    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
