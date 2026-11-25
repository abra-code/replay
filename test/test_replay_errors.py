#!/usr/bin/env python3
"""
test_replay_errors.py — tests for error handling and lesser-covered features.

Scenarios:
  1. --max-tasks with stdin streaming — verify concurrency limit doesn't drop tasks
  2. the playlist file and --playlist-key: a dictionary root needs a key; a missing key, a key for an
     array root and an unreadable file fail; an empty playlist does not
  3. create file blob (valid base64) — file created with correct binary content
  4. create file blob (streaming format, blob=true) — same via pipe
  5. edit regex back-references \\1/\\2 in replacement string
  6. edit regex back-reference word swap
  7. --stdout and --stderr log files, not written through a symbolic link

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
# Scenario 2: the playlist file and --playlist-key
# ---------------------------------------------------------------------------

def run_playlist_file(content: bytes, suffix: str, args: list) -> subprocess.CompletedProcess:
    """Runs replay on a playlist file holding content, with args before the path."""
    with tempfile.NamedTemporaryFile(mode="wb", suffix=suffix, delete=False) as f:
        f.write(content)
        path = f.name
    try:
        return subprocess.run([str(REPLAY)] + list(args) + [path],
                              capture_output=True, text=True, timeout=10)
    finally:
        os.unlink(path)


def test_playlist_file_and_key() -> None:
    print("\n--- Scenario 2: the playlist file and --playlist-key ---")
    import plistlib

    steps = [{"action": "echo", "text": "hello from Steps"}]
    other = [{"action": "echo", "text": "hello from Other"}]
    dict_json = json.dumps({"Steps": steps, "Other": other, "Note": "not a playlist"}).encode()
    dict_plist = plistlib.dumps({"Steps": steps, "Other": other})
    array_json = json.dumps(steps).encode()

    def report(r):
        return f"rc={r.returncode} stdout={r.stdout[:150]!r} stderr={r.stderr[:300]!r}"

    r = run_playlist_file(dict_json, ".json", ["--playlist-key", "Steps"])
    check("a key of a root dictionary runs its playlist (exit 0)",
          r.returncode == 0 and "hello from Steps" in r.stdout and "hello from Other" not in r.stdout, report(r))

    r = run_playlist_file(dict_json, ".json", ["--playlist-key", "NonExistentKey"])
    check("a missing key fails", r.returncode != 0, report(r))
    check("the message names the missing key and the file's playlists, not other keys",
          "NonExistentKey" in r.stderr and '"Other", "Steps"' in r.stderr and "Note" not in r.stderr, report(r))

    for label, content, suffix in (("JSON", dict_json, ".json"), ("plist", dict_plist, ".plist")):
        r = run_playlist_file(content, suffix, [])
        check(f"{label}: a root dictionary without --playlist-key fails and runs nothing",
              r.returncode != 0 and "hello" not in r.stdout, report(r))
        check(f"{label}: the message says to pass --playlist-key and lists the playlists",
              "--playlist-key" in r.stderr and '"Other", "Steps"' in r.stderr, report(r))

    r = run_playlist_file(array_json, ".json", ["--playlist-key", "Steps"])
    check("a key for a root array fails and says to run it without one",
          r.returncode != 0 and "without --playlist-key" in r.stderr, report(r))

    r = run_playlist_file(array_json, ".json", [])
    check("a root array runs without a key (exit 0)",
          r.returncode == 0 and "hello from Steps" in r.stdout, report(r))

    r = run_playlist_file(b"[]", ".json", [])
    check("an empty playlist is not an error (exit 0) and says it is empty",
          r.returncode == 0 and "empty" in r.stderr, report(r))

    r = run_playlist_file(json.dumps({"Steps": []}).encode(), ".json", ["--playlist-key", "Steps"])
    check("an empty playlist under a key is not an error (exit 0)", r.returncode == 0, report(r))

    r = run_playlist_file(b'["a", "b"]', ".json", [])
    check("a root array with items but no action step fails and says so",
          r.returncode != 0 and "2 item(s) but no action step" in r.stderr, report(r))

    r = run_playlist_file(b'{"S": ["a"]}', ".json", ["--playlist-key", "S"])
    check("a playlist under a key with items but no action step fails",
          r.returncode != 0 and "1 item(s) but no action step" in r.stderr, report(r))

    r = run_playlist_file(b'{"A": [], "A": [], "B": []}', ".json", [])
    check("a key repeated in the JSON object is listed once",
          r.returncode != 0 and '("A", "B")' in r.stderr, report(r))

    r = run_playlist_file(b'[ {"action": "echo", "text": "x" ', ".json", [])
    check("a file that does not parse fails and says what it expected",
          r.returncode != 0 and "is not a JSON or plist file" in r.stderr, report(r))

    r = run_playlist_file(dict_json, ".json", ["--playlist-key", "Missing", "--playlist-key", "Steps"])
    check("without --stop-on-error a missing key fails the run, the other playlist still runs",
          r.returncode != 0 and "hello from Steps" in r.stdout, report(r))

    r = run_playlist_file(dict_json, ".json", ["--stop-on-error", "--playlist-key", "Missing", "--playlist-key", "Steps"])
    check("with --stop-on-error a missing key stops before the next playlist",
          r.returncode != 0 and "hello from Steps" not in r.stdout, report(r))


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
# Scenario 7: --stdout and --stderr do not write through a symbolic link
# ---------------------------------------------------------------------------

def test_log_files_not_through_links() -> None:
    print("\n--- Scenario 7: --stdout / --stderr log files ---")

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        out_log = work / "out.log"
        err_log = work / "err.log"
        result = run_replay_stdin(["[echo]\tlogged-line\n"],
                                  extra_args=["--stdout", str(out_log), "--stderr", str(err_log)])
        check("exit 0 with --stdout and --stderr", result.returncode == 0, result.stderr[:200])
        check("--stdout writes the output into the log file",
              out_log.exists() and "logged-line" in out_log.read_text(),
              out_log.read_text() if out_log.exists() else "no log file")

        # A link at the log path, as someone who can write the folder could plant one:
        # the file it names must keep its contents.
        target = work / "precious.txt"
        target.write_text("keep me\n")
        for option, name in (("--stdout", "out-link.log"), ("--stderr", "err-link.log")):
            link = work / name
            os.symlink(target, link)
            result = run_replay_stdin(["[echo]\tlink-line\n"], extra_args=[option, str(link)])
            check(f"{option} through a link: refused (exit not 0)", result.returncode != 0,
                  f"exit {result.returncode}")
            check(f"{option} through a link: the message says why",
                  "symbolic link" in result.stderr, result.stderr[:300])
            check(f"{option} through a link: the linked file is unchanged",
                  target.read_text() == "keep me\n", target.read_text()[:100])

        # /dev/stdout and /dev/stderr are links the system made: they keep working.
        result = run_replay_stdin(["[echo]\tdev-stderr-line\n"], extra_args=["--stdout", "/dev/stderr"])
        check("--stdout /dev/stderr: the output goes to standard error",
              result.returncode == 0 and "dev-stderr-line" in result.stderr,
              f"exit {result.returncode}, stderr: {result.stderr[:200]}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if not REPLAY.exists():
    print(f"error: replay binary not found at {REPLAY}")
    sys.exit(1)

print(f"Using replay: {REPLAY}")

test_max_tasks_streaming()
test_playlist_file_and_key()
test_blob_valid_json()
test_blob_valid_streaming()
test_edit_regex_backreferences()
test_edit_regex_group_swap()
test_log_files_not_through_links()

print(f"\n{'='*40}")
print(f"  Passed: {_pass}  Failed: {_fail}")
print(f"{'='*40}")
sys.exit(0 if _fail == 0 else 1)
