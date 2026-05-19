#!/usr/bin/env python3
"""
test_replay_errors.py — tests for error handling and lesser-covered features.

Scenarios:
  1. --max-tasks with stdin streaming — verify concurrency limit doesn't drop tasks
  2. --playlist-key with a missing key — error message printed, graceful exit
  3. create file blob (valid base64) — file created with correct binary content
  4. create file blob (streaming format, blob=true) — same via pipe
  5. edit regex back-references \\1/\\2 in replacement string
  6. edit regex back-reference word swap

Usage: python3 test_replay_errors.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY         = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

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


def run_replay_json(playlist: list, extra_args: list = (), timeout: int = 30) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(playlist, f)
        path = f.name
    try:
        result = subprocess.run(
            [str(REPLAY)] + list(extra_args) + [path],
            capture_output=True, text=True, timeout=timeout,
        )
    finally:
        os.unlink(path)
    return result


def run_replay_stdin(lines: list, extra_args: list = (), timeout: int = 30) -> subprocess.CompletedProcess:
    stdin_data = "".join(lines)
    return subprocess.run(
        [str(REPLAY)] + list(extra_args),
        input=stdin_data, capture_output=True, text=True, timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Scenario 1: --max-tasks with stdin streaming
# ---------------------------------------------------------------------------

def test_max_tasks_streaming() -> None:
    print("\n--- Scenario 1: --max-tasks 2 with stdin streaming (20 echo actions) ---")

    n = 20
    lines = [f"[echo]\ttoken-{i}\n" for i in range(n)]
    result = run_replay_stdin(lines, extra_args=["--max-tasks", "2", "--ordered-output"])

    check("exit 0 with streaming + --max-tasks 2", result.returncode == 0,
          f"stderr: {result.stderr[:200]}")

    tokens_found = sum(1 for i in range(n) if f"token-{i}" in result.stdout)
    check(f"all {n} tokens appear in output",
          tokens_found == n,
          f"only {tokens_found}/{n} found; first missing: "
          f"{next((f'token-{i}' for i in range(n) if f'token-{i}' not in result.stdout), 'none')}")


# ---------------------------------------------------------------------------
# Scenario 2: --playlist-key with a key that does not exist
# ---------------------------------------------------------------------------

def test_missing_playlist_key() -> None:
    print("\n--- Scenario 2: --playlist-key with non-existent key ---")

    playlist_dict = {
        "Steps": [{"action": "echo", "text": "hello"}]
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(playlist_dict, f)
        path = f.name
    try:
        result = subprocess.run(
            [str(REPLAY), "--playlist-key", "NonExistentKey", path],
            capture_output=True, text=True, timeout=10,
        )
    finally:
        os.unlink(path)

    # Current behavior: LogError to stderr, exits 0 (treated as "nothing to run")
    check("error message mentions the missing key name",
          "NonExistentKey" in result.stderr,
          f"stderr: {result.stderr[:200]}")
    check("error message says 'Invalid or empty playlist'",
          "Invalid" in result.stderr or "empty" in result.stderr or "No steps" in result.stderr,
          f"stderr: {result.stderr[:200]}")


# ---------------------------------------------------------------------------
# Scenario 3: create file blob (valid base64) via JSON playlist
# ---------------------------------------------------------------------------

def test_blob_valid_json() -> None:
    print("\n--- Scenario 3: create file blob (valid base64, JSON format) ---")

    content = b"Hello, binary world!\x00\x01\x02\xFF"
    b64 = base64.b64encode(content).decode("ascii")

    with tempfile.TemporaryDirectory() as td:
        out_file = f"{td}/blob_output.bin"
        playlist = [{"action": "create", "file": out_file, "blob": b64}]
        result = run_replay_json(playlist)

        check("exit 0 for valid blob create", result.returncode == 0,
              result.stderr[:200])
        check("blob file was created", Path(out_file).exists(), "file not found")

        if Path(out_file).exists():
            actual = Path(out_file).read_bytes()
            check("blob file has correct binary content", actual == content,
                  f"expected {content!r}, got {actual!r}")


# ---------------------------------------------------------------------------
# Scenario 4: create file blob via streaming format (blob=true modifier)
# ---------------------------------------------------------------------------

def test_blob_valid_streaming() -> None:
    print("\n--- Scenario 4: create file blob via streaming (blob=true) ---")

    content = b"Binary data \xDE\xAD\xBE\xEF"
    b64 = base64.b64encode(content).decode("ascii")

    with tempfile.TemporaryDirectory() as td:
        out_file = f"{td}/stream_blob.bin"
        # Streaming format: [create file blob=true]\t<path>\t<base64>
        line = f"[create file blob=true]\t{out_file}\t{b64}\n"
        result = run_replay_stdin([line])

        check("exit 0 for streaming blob create", result.returncode == 0,
              result.stderr[:200])
        check("streaming blob file was created", Path(out_file).exists(), "file not found")

        if Path(out_file).exists():
            actual = Path(out_file).read_bytes()
            check("streaming blob file has correct content", actual == content,
                  f"expected {content!r}, got {actual!r}")


# ---------------------------------------------------------------------------
# Scenario 5: edit with regex back-references (\1, \2)
# ---------------------------------------------------------------------------

def test_edit_regex_backreferences() -> None:
    print("\n--- Scenario 5: edit regex back-references (version stripping) ---")

    with tempfile.TemporaryDirectory() as td:
        src = f"{td}/source.txt"
        Path(src).write_text("version: 1.2.3\nversion: 4.5.6\n")

        # Capture major and minor, drop patch: "1.2.3" → "1.2"
        playlist = [{
            "action": "edit",
            "items": [src],
            "oldText": "version: ([0-9]+)\\.([0-9]+)\\.[0-9]+",
            "newText": "version: \\1.\\2",
            "regex": True,
            "limit": 0,
        }]
        result = run_replay_json(playlist)
        check("exit 0 for back-reference edit", result.returncode == 0, result.stderr[:200])

        actual = Path(src).read_text()
        check("first back-reference (\\1) correct",  "version: 1.2" in actual, actual)
        check("second back-reference (\\1) correct", "version: 4.5" in actual, actual)
        check("patch number removed from first version",  "1.2.3" not in actual, actual)
        check("patch number removed from second version", "4.5.6" not in actual, actual)


# ---------------------------------------------------------------------------
# Scenario 6: edit with regex — swap two captured groups
# ---------------------------------------------------------------------------

def test_edit_regex_group_swap() -> None:
    print("\n--- Scenario 6: edit regex back-reference group swap ---")

    with tempfile.TemporaryDirectory() as td:
        src = f"{td}/swap.txt"
        Path(src).write_text("foo bar\nbaz qux\n")

        # ([a-z]+) ([a-z]+) → \2 \1  (swap the two words)
        playlist = [{
            "action": "edit",
            "items": [src],
            "oldText": "([a-z]+) ([a-z]+)",
            "newText": "\\2 \\1",
            "regex": True,
            "limit": 0,
        }]
        result = run_replay_json(playlist)
        check("exit 0 for word-swap edit", result.returncode == 0, result.stderr[:200])

        actual = Path(src).read_text()
        check("first line words swapped",  "bar foo" in actual, actual)
        check("second line words swapped", "qux baz" in actual, actual)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if not REPLAY.exists():
    print(f"error: replay binary not found at {REPLAY}")
    sys.exit(1)

print(f"Using replay: {REPLAY}")

test_max_tasks_streaming()
test_missing_playlist_key()
test_blob_valid_json()
test_blob_valid_streaming()
test_edit_regex_backreferences()
test_edit_regex_group_swap()

print(f"\n{'='*40}")
print(f"  Passed: {_pass}  Failed: {_fail}")
print(f"{'='*40}")
sys.exit(0 if _fail == 0 else 1)
