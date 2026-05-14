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

def is_command_error(resp: dict) -> bool:
    """Return True when a tools/call result has isError=true (command failed, not MCP error)."""
    return resp.get("result", {}).get("isError", False) is True

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
    check("initialize returns capabilities.tools",
          "tools" in by_id[1].get("result", {}).get("capabilities", {}),
          str(by_id[1].get("result", {}).get("capabilities")))
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
        "read_file", "read_multiple_files", "write_file", "edit_file", "edit_files",
        "create_directory", "list_directory", "directory_tree", "move_file",
        "delete_file", "search_files", "get_file_info",
        "list_allowed_directories", "glob_search", "execute_command",
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
    print("=== MCP: concurrent requests (N writes then N reads) ===")

    n = 10
    write_msgs = [
        {"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{tmpdir}/concurrent_{i}.txt",
                                  "content": f"content-{i}"}}}
        for i in range(n)
    ]
    read_msgs = [
        {"jsonrpc": "2.0", "id": n + i + 1, "method": "tools/call",
         "params": {"name": "read_file",
                    "arguments": {"path": f"{tmpdir}/concurrent_{i}.txt"}}}
        for i in range(n)
    ]

    # Two separate batches guarantee all writes complete before reads start.
    write_by_id = run_mcp(write_msgs, [tmpdir])
    read_by_id  = run_mcp(read_msgs,  [tmpdir])

    check(f"concurrent writes: all {n} responses received",
          len(write_by_id) == n, f"got {len(write_by_id)}")
    all_writes_ok = all("Successfully wrote" in text_of(write_by_id[i + 1]) for i in range(n))
    check("concurrent writes: all succeeded", all_writes_ok)

    check(f"concurrent reads: all {n} responses received",
          len(read_by_id) == n, f"got {len(read_by_id)}")
    all_reads_ok = all(f"content-{i}" in text_of(read_by_id[n + i + 1]) for i in range(n))
    check("concurrent reads: all returned correct content", all_reads_ok)


def test_tools_list_schema(tmpdir: str) -> None:
    print("=== MCP: tools/list inputSchema validation ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    ], [tmpdir])

    tools = by_id[1].get("result", {}).get("tools", [])
    # These tools declare at least one required param in their schema.
    tools_with_required = {
        "read_file", "read_multiple_files", "write_file", "edit_file", "edit_files",
        "create_directory", "list_directory", "directory_tree", "move_file",
        "delete_file", "search_files", "get_file_info", "glob_search", "execute_command",
    }
    for tool in tools:
        name = tool.get("name", "?")
        schema = tool.get("inputSchema", {})
        check(f"tool {name}: inputSchema.type == object",
              schema.get("type") == "object", str(schema))
        check(f"tool {name}: inputSchema.properties present",
              isinstance(schema.get("properties"), dict), str(schema))
        if name in tools_with_required:
            check(f"tool {name}: inputSchema.required is non-empty list",
                  isinstance(schema.get("required"), list) and len(schema["required"]) > 0,
                  str(schema.get("required")))


def test_edit_default_limit(tmpdir: str) -> None:
    print("=== MCP: edit_file (default limit=1, replaces first occurrence only) ===")

    path = f"{tmpdir}/edit_lim1.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path, "content": "foo bar\nfoo qux\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": path,
                                  "edits": [{"oldText": "foo", "newText": "FOO"}]}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[3])
    check("default limit=1: edit succeeds",
          "error" not in by_id[2], str(by_id[2]))
    check("default limit=1: first occurrence replaced",
          "FOO bar" in text, f"got: {text!r}")
    check("default limit=1: second occurrence untouched",
          "foo qux" in text, f"got: {text!r}")


def test_edit_no_match_error(tmpdir: str) -> None:
    print("=== MCP: edit_file (no match with default limit=1 → -32603) ===")

    path = f"{tmpdir}/edit_nomatch.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path, "content": "hello world\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": path,
                                  "edits": [{"oldText": "nonexistent_text"}]}}},
    ], [tmpdir], sequential=True)

    check("no-match with default limit=1 → -32603",
          is_error(by_id[2], -32603), str(by_id[2]))


def test_edit_invalid_regex(tmpdir: str) -> None:
    print("=== MCP: edit_file (invalid regex → -32603) ===")

    path = f"{tmpdir}/edit_badre.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": path, "content": "some content\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": path,
                                  "edits": [{"oldText": "[unclosed_bracket",
                                             "newText": "x",
                                             "regex": True}]}}},
    ], [tmpdir], sequential=True)

    check("invalid regex → -32603",
          is_error(by_id[2], -32603), str(by_id[2]))


def test_read_file_not_found(tmpdir: str) -> None:
    print("=== MCP: read_file (file not found → -32002) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "read_file",
                    "arguments": {"path": f"{tmpdir}/does_not_exist.txt"}}},
    ], [tmpdir])

    check("read_file nonexistent file → -32002",
          is_error(by_id[1], -32002), str(by_id[1]))


def test_read_binary_file(tmpdir: str) -> None:
    print("=== MCP: read_file (binary file → blob) ===")

    path = os.path.join(tmpdir, "binary.bin")
    with open(path, "wb") as f:
        f.write(bytes(range(256)))  # 256-byte binary with null bytes → not valid UTF-8 text

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir])

    items = by_id[1].get("result", {}).get("content", [{}])
    check("binary file: content[0].type == blob",
          items[0].get("type") == "blob", str(items[0]))
    check("binary file: non-empty base64 data field",
          len(items[0].get("data", "")) > 0, str(items[0]))
    check("binary file: mimeType field present",
          "mimeType" in items[0], str(items[0]))


def test_directory_tree_depth(tmpdir: str) -> None:
    print("=== MCP: directory_tree (depth param) ===")

    d = f"{tmpdir}/depth_tree"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/a/b/c.txt", "content": "deep"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "directory_tree",
                    "arguments": {"path": d, "depth": 0}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "directory_tree",
                    "arguments": {"path": d, "depth": 1}}},
    ], [tmpdir], sequential=True)

    tree0 = json.loads(text_of(by_id[2]))
    check("depth=0: root is directory", tree0.get("type") == "directory")
    check("depth=0: no children",
          tree0.get("children") == [], f"got: {tree0.get('children')}")

    tree1 = json.loads(text_of(by_id[3]))
    check("depth=1: immediate child 'a' present",
          any(c["name"] == "a" for c in tree1.get("children", [])),
          f"got: {tree1.get('children')}")
    a_node = next((c for c in tree1.get("children", []) if c["name"] == "a"), None)
    check("depth=1: 'a' has no children (depth limit reached)",
          a_node is not None and a_node.get("children") == [],
          f"a_node: {a_node}")


def test_delete_directory(tmpdir: str) -> None:
    print("=== MCP: delete_file (recursive directory delete) ===")

    d = f"{tmpdir}/del_dir"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/a.txt", "content": "a"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/sub/b.txt", "content": "b"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "delete_file", "arguments": {"path": d}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "get_file_info", "arguments": {"path": d}}},
    ], [tmpdir], sequential=True)

    check("delete directory: succeeds",
          "Deleted" in text_of(by_id[3]), str(by_id[3]))
    check("delete directory: dir no longer accessible",
          is_error(by_id[4]), str(by_id[4]))


def test_glob_search_exclude_patterns(tmpdir: str) -> None:
    print("=== MCP: glob_search / search_files (excludePatterns) ===")

    d = f"{tmpdir}/excl"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/src/main.cpp", "content": ""}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/vendor/lib.cpp", "content": ""}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "glob_search",
                    "arguments": {"path": d,
                                  "patterns": ["**/*.cpp"],
                                  "excludePatterns": ["vendor/**"]}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "search_files",
                    "arguments": {"path": d,
                                  "pattern": "**/*.cpp",
                                  "excludePatterns": ["vendor/**"]}}},
    ], [tmpdir], sequential=True)

    text3 = text_of(by_id[3])
    check("glob_search excludePatterns: src/main.cpp included",
          "main.cpp" in text3, text3)
    check("glob_search excludePatterns: vendor/lib.cpp excluded",
          "lib.cpp" not in text3, text3)

    text4 = text_of(by_id[4])
    check("search_files excludePatterns: src/main.cpp included",
          "main.cpp" in text4, text4)
    check("search_files excludePatterns: vendor/lib.cpp excluded",
          "lib.cpp" not in text4, text4)


def test_glob_search_brace(tmpdir: str) -> None:
    print("=== MCP: glob_search (brace alternation {cpp,h}) ===")

    d = f"{tmpdir}/brace"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/src/main.cpp", "content": ""}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/include/util.h", "content": ""}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/README.txt", "content": ""}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "glob_search",
                    "arguments": {"path": d, "pattern": "**/*.{cpp,h}"}}},
    ], [tmpdir], sequential=True)

    text = text_of(by_id[4])
    check("brace alternation: .cpp file matched",
          "main.cpp" in text, text)
    check("brace alternation: .h file matched",
          "util.h" in text, text)
    check("brace alternation: .txt file excluded",
          "README.txt" not in text, text)


def test_edit_files_literal(tmpdir: str) -> None:
    print("=== MCP: edit_files (two literal paths) ===")

    a = f"{tmpdir}/ef_lit_a.txt"
    b = f"{tmpdir}/ef_lit_b.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file", "arguments": {"path": a, "content": "hello world\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file", "arguments": {"path": b, "content": "hello again\n"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "edit_files",
                    "arguments": {"paths": [a, b],
                                  "edits": [{"oldText": "hello", "newText": "goodbye",
                                             "limit": 0}]}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": a}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": b}}},
    ], [tmpdir], sequential=True)

    content = by_id[3].get("result", {}).get("content", [])
    check("edit_files literal: two content items returned",
          len(content) == 2, f"got {len(content)} items: {content}")
    check("edit_files literal: first file success",
          "Successfully edited" in content[0].get("text", ""), str(content[0]))
    check("edit_files literal: second file success",
          "Successfully edited" in content[1].get("text", ""), str(content[1]))
    check("edit_files literal: file a modified",
          "goodbye world" in text_of(by_id[4]), text_of(by_id[4]))
    check("edit_files literal: file b modified",
          "goodbye again" in text_of(by_id[5]), text_of(by_id[5]))


def test_edit_files_glob(tmpdir: str) -> None:
    print("=== MCP: edit_files (glob pattern expands to multiple files) ===")

    d = f"{tmpdir}/ef_glob"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/one.txt", "content": "version 1\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/two.txt", "content": "version 2\n"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/three.txt", "content": "version 3\n"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "edit_files",
                    "arguments": {"paths": [f"{d}/*.txt"],
                                  "edits": [{"oldText": "version", "newText": "release",
                                             "limit": 0}]}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": f"{d}/one.txt"}}},
    ], [tmpdir], sequential=True)

    content = by_id[4].get("result", {}).get("content", [])
    check("edit_files glob: three files matched",
          len(content) == 3, f"got {len(content)} items")
    all_ok = all("Successfully edited" in item.get("text", "") for item in content)
    check("edit_files glob: all files succeeded", all_ok, str(content))
    check("edit_files glob: file content updated",
          "release 1" in text_of(by_id[5]), text_of(by_id[5]))


def test_edit_files_mixed(tmpdir: str) -> None:
    print("=== MCP: edit_files (literal path + glob mixed) ===")

    d = f"{tmpdir}/ef_mixed"
    lit = f"{tmpdir}/ef_mixed_lit.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": lit, "content": "file alpha\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/a.txt", "content": "file bravo\n"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{d}/b.txt", "content": "file charlie\n"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "edit_files",
                    "arguments": {"paths": [lit, f"{d}/*.txt"],
                                  "edits": [{"oldText": "file", "newText": "FILE",
                                             "limit": 0}]}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": lit}}},
    ], [tmpdir], sequential=True)

    content = by_id[4].get("result", {}).get("content", [])
    check("edit_files mixed: three results (1 literal + 2 from glob)",
          len(content) == 3, f"got {len(content)} items")
    all_ok = all("Successfully edited" in item.get("text", "") for item in content)
    check("edit_files mixed: all files succeeded", all_ok, str(content))
    check("edit_files mixed: literal file modified",
          "FILE alpha" in text_of(by_id[5]), text_of(by_id[5]))


def test_edit_files_no_glob_match(tmpdir: str) -> None:
    print("=== MCP: edit_files (glob matches no files → -32002) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "edit_files",
                    "arguments": {"paths": [f"{tmpdir}/no_such_dir/*.txt"],
                                  "edits": [{"oldText": "foo", "newText": "bar"}]}}},
    ], [tmpdir])

    check("edit_files no glob match → -32002",
          is_error(by_id[1], -32002), str(by_id[1]))


def test_edit_files_dryrun(tmpdir: str) -> None:
    print("=== MCP: edit_files (dryRun — per-file plans, no writes) ===")

    a = f"{tmpdir}/ef_dry_a.txt"
    b = f"{tmpdir}/ef_dry_b.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": a, "content": "original A\n"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": b, "content": "original B\n"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "edit_files",
                    "arguments": {"paths": [a, b],
                                  "edits": [{"oldText": "original", "newText": "modified"}],
                                  "dryRun": True}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": a}}},
    ], [tmpdir], sequential=True)

    content = by_id[3].get("result", {}).get("content", [])
    check("edit_files dryRun: two content items",
          len(content) == 2, f"got {len(content)} items")
    check("edit_files dryRun: first item is dry-run plan",
          "Dry-run" in content[0].get("text", ""), str(content[0]))
    check("edit_files dryRun: second item is dry-run plan",
          "Dry-run" in content[1].get("text", ""), str(content[1]))
    check("edit_files dryRun: file not modified",
          "original A" in text_of(by_id[4]), text_of(by_id[4]))


def test_execute_simple(tmpdir: str) -> None:
    print("=== MCP: execute_command (simple echo) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command",
                    "arguments": {"command": "echo 'hello mcp'",
                                  "workingDirectory": tmpdir}}},
    ], [tmpdir])

    text = text_of(by_id[1])
    check("execute_command simple: stdout contains output", "hello mcp" in text, text)
    check("execute_command simple: exit code 0 in text", "[exit code: 0]" in text, text)
    check("execute_command simple: isError absent",
          not is_command_error(by_id[1]), str(by_id[1]))


def test_execute_working_dir(tmpdir: str) -> None:
    print("=== MCP: execute_command (workingDirectory → pwd) ===")

    canonical = os.path.realpath(tmpdir)
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command",
                    "arguments": {"command": "pwd",
                                  "workingDirectory": tmpdir}}},
    ], [tmpdir])

    text = text_of(by_id[1])
    check("execute_command workingDirectory: pwd output contains canonical path",
          canonical in text, f"expected {canonical!r} in {text!r}")


def test_execute_exit_nonzero(tmpdir: str) -> None:
    print("=== MCP: execute_command (non-zero exit → isError) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command",
                    "arguments": {"command": "exit 42",
                                  "workingDirectory": tmpdir}}},
    ], [tmpdir])

    text = text_of(by_id[1])
    check("execute_command exit 42: isError true", is_command_error(by_id[1]), str(by_id[1]))
    check("execute_command exit 42: exit code in text", "[exit code: 42]" in text, text)


def test_execute_stderr(tmpdir: str) -> None:
    print("=== MCP: execute_command (stdout + stderr → two content items) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command",
                    "arguments": {"command": "echo 'out_line'; echo 'err_line' >&2",
                                  "workingDirectory": tmpdir}}},
    ], [tmpdir])

    content = by_id[1].get("result", {}).get("content", [])
    check("execute_command stderr: two content items",
          len(content) == 2, f"got {len(content)}: {content}")
    check("execute_command stderr: first item contains stdout",
          "out_line" in content[0].get("text", ""), str(content[0]))
    check("execute_command stderr: second item has [stderr] prefix",
          content[1].get("text", "").startswith("[stderr]"), str(content[1]))
    check("execute_command stderr: stderr content present",
          "err_line" in content[1].get("text", ""), str(content[1]))


def test_execute_timeout(tmpdir: str) -> None:
    print("=== MCP: execute_command (timeout kills command) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command",
                    "arguments": {"command": "sleep 100",
                                  "workingDirectory": tmpdir,
                                  "timeout": 1}}},
    ], [tmpdir])

    text = text_of(by_id[1])
    check("execute_command timeout: isError true", is_command_error(by_id[1]), str(by_id[1]))
    check("execute_command timeout: timeout notice in output",
          "timed out" in text.lower(), text)


def test_execute_workdir_invalid(tmpdir: str) -> None:
    print("=== MCP: execute_command (workingDirectory outside allowed → -32001) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command",
                    "arguments": {"command": "echo hi", "workingDirectory": "/etc"}}},
    ], [tmpdir])

    check("execute_command invalid workdir → -32001",
          is_error(by_id[1], -32001), str(by_id[1]))


def test_execute_missing_command(tmpdir: str) -> None:
    print("=== MCP: execute_command (missing command → -32602) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command", "arguments": {}}},
    ], [tmpdir])

    check("execute_command missing command → -32602",
          is_error(by_id[1], -32602), str(by_id[1]))


def test_execute_file_write(tmpdir: str) -> None:
    print("=== MCP: execute_command (shell writes file, read_file verifies) ===")

    path = f"{tmpdir}/shell_created.txt"
    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "execute_command",
                    "arguments": {"command": f"printf 'from shell\\n' > {path}",
                                  "workingDirectory": tmpdir}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": path}}},
    ], [tmpdir], sequential=True)

    check("execute_command file write: exit 0",
          "[exit code: 0]" in text_of(by_id[1]), text_of(by_id[1]))
    check("execute_command file write: read_file sees shell output",
          "from shell" in text_of(by_id[2]), text_of(by_id[2]))


def test_missing_required_params(tmpdir: str) -> None:
    print("=== MCP: missing required params (-32602) ===")

    by_id = run_mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": "read_file", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "write_file",
                    "arguments": {"path": f"{tmpdir}/x.txt"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "edit_file",
                    "arguments": {"path": f"{tmpdir}/x.txt"}}},
    ], [tmpdir])

    check("read_file missing path → -32602",
          is_error(by_id[1], -32602), str(by_id[1]))
    check("write_file missing content → -32602",
          is_error(by_id[2], -32602), str(by_id[2]))
    check("edit_file missing edits → -32602",
          is_error(by_id[3], -32602), str(by_id[3]))


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
        test_tools_list_schema(tmpdir)
        test_write_read(tmpdir)
        test_edit_literal(tmpdir)
        test_edit_regex(tmpdir)
        test_edit_case_insensitive(tmpdir)
        test_edit_dryrun(tmpdir)
        test_edit_default_limit(tmpdir)
        test_edit_no_match_error(tmpdir)
        test_edit_invalid_regex(tmpdir)
        test_edit_files_literal(tmpdir)
        test_edit_files_glob(tmpdir)
        test_edit_files_mixed(tmpdir)
        test_edit_files_no_glob_match(tmpdir)
        test_edit_files_dryrun(tmpdir)
        test_execute_simple(tmpdir)
        test_execute_working_dir(tmpdir)
        test_execute_exit_nonzero(tmpdir)
        test_execute_stderr(tmpdir)
        test_execute_timeout(tmpdir)
        test_execute_workdir_invalid(tmpdir)
        test_execute_missing_command(tmpdir)
        test_execute_file_write(tmpdir)
        test_create_directory(tmpdir)
        test_list_directory(tmpdir)
        test_directory_tree(tmpdir)
        test_directory_tree_depth(tmpdir)
        test_move_file(tmpdir)
        test_delete_file(tmpdir)
        test_delete_directory(tmpdir)
        test_search_files(tmpdir)
        test_get_file_info(tmpdir)
        test_read_file_not_found(tmpdir)
        test_read_binary_file(tmpdir)
        test_read_multiple_files(tmpdir)
        test_glob_search(tmpdir)
        test_glob_search_exclude_patterns(tmpdir)
        test_glob_search_brace(tmpdir)
        test_list_allowed_directories(tmpdir)
        test_path_validation(tmpdir)
        test_missing_required_params(tmpdir)
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
