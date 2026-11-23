#!/usr/bin/env python3
"""
test_replay_fs_semantics.py - file system behavior replay keeps the same on macOS and
Linux, although the file systems differ.

Scenarios:
  1. info "created" is the file's birth time, not its inode change time or its
     modification time: after utime moves both, "created" still shows when the file
     was made. Where the file system keeps no birth time (statx reports none), it is
     the ctime, as before.
  2. glob matching ignores case: "*.txt" matches a.txt and B.TXT.
  3. on a case-sensitive file system (most Linux ones), a pattern matches every name
     that differs only in case: "x.txt" finds both x.txt and X.txt.
  4. dependency analysis compares paths without case: a task declaring the input
     "out.txt" waits for the task declaring the output "Out.txt". Conservative on a
     case-sensitive file system (they may be different files), never wrong.

Usage: python3 test_replay_fs_semantics.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import calendar
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY         = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY
IS_LINUX       = sys.platform.startswith("linux")

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


def run_stream(text: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(REPLAY)], input=text, capture_output=True, text=True, timeout=60)


def run_playlist(playlist: list) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(playlist, f)
        path = f.name
    try:
        return subprocess.run([str(REPLAY), path], capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(path)


def birth_time(path: Path):
    """The file's birth time in whole seconds, or None when the file system keeps none."""
    if not IS_LINUX:
        return int(os.stat(path).st_birthtime)
    proc = subprocess.run(["/usr/bin/stat", "-c", "%W", str(path)],
                          capture_output=True, text=True, timeout=10)
    text = proc.stdout.strip()
    if proc.returncode != 0 or not text.isdigit() or text == "0":
        return None
    return int(text)


def created_of(output: str):
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("created:"):
            stamp = line.split(":", 1)[1].strip()
            return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
    return None


# ---------------------------------------------------------------------------

def test_birth_time(work: Path) -> None:
    print("\n--- 1. info created is the birth time ---")
    path = work / "born.txt"
    path.write_text("born")
    first = os.stat(path)
    time.sleep(2.2)
    # Move mtime a day ahead, so it no longer equals the birth time, and ctime to now.
    # Ahead, not back: macOS pulls the birth time back to an mtime set before it.
    later = int(first.st_mtime) + 86400
    os.utime(path, (later, later))
    st = os.stat(path)
    born = birth_time(path)
    result = run_stream(f"[info]\t{path}\n")
    created = created_of(result.stdout)
    if not check("info prints a created time", created is not None, result.stdout + result.stderr):
        return
    check("ctime really moved past the creation", int(st.st_ctime) >= int(first.st_ctime) + 2,
          f"ctime={st.st_ctime} at creation={first.st_ctime}")
    check("created is not the mtime", created != later, f"created={created} mtime={later}")
    if born is None:
        print("  note: this file system keeps no birth time; created falls back to ctime")
        check("created is the ctime", created == int(st.st_ctime), f"{created} vs {st.st_ctime}")
    else:
        check("created is the birth time", created == born, f"created={created} birth={born}")
        check("created is not the later ctime", created < int(st.st_ctime),
              f"created={created} ctime={st.st_ctime}")


def glob_action(root: Path, pattern: str) -> list:
    result = run_playlist([{"action": "glob", "root": str(root), "glob": [pattern]}])
    return sorted(Path(line.strip()).name for line in result.stdout.splitlines()
                  if line.strip().startswith(str(root)))


def is_case_sensitive(folder: Path) -> bool:
    probe = folder / "CaseProbe"
    probe.write_text("")
    try:
        return not (folder / "caseprobe").exists()
    finally:
        probe.unlink()


def test_glob_case(work: Path) -> None:
    print("\n--- 2. glob matching ignores case ---")
    root = work / "glob"
    root.mkdir()
    for name in ("a.txt", "B.TXT", "c.md"):
        (root / name).write_text(name)
    check("*.txt matches a.txt and B.TXT", glob_action(root, "*.txt") == ["B.TXT", "a.txt"],
          str(glob_action(root, "*.txt")))
    check("*.TXT matches the same two", glob_action(root, "*.TXT") == ["B.TXT", "a.txt"],
          str(glob_action(root, "*.TXT")))

    print("\n--- 3. names differing only in case ---")
    if not is_case_sensitive(work):
        print("  skipped: this file system is case-insensitive")
        return
    both = work / "both"
    both.mkdir()
    (both / "x.txt").write_text("lower")
    (both / "X.txt").write_text("upper")
    check("x.txt matches x.txt and X.txt", glob_action(both, "x.txt") == ["X.txt", "x.txt"],
          str(glob_action(both, "x.txt")))


def test_dependency_case(work: Path) -> None:
    print("\n--- 4. dependency analysis compares paths without case ---")
    d = work / "deps"
    d.mkdir()
    produced = d / "Out.txt"
    consumer_saw = d / "consumer.saw"
    # The producer writes Out.txt after a second; without the dependency the consumer
    # would start at once and not find it. No clocks: one-second stamps from two
    # processes can tie even when the consumer started first.
    playlist = [
        {"action": "execute", "tool": "/bin/sh",
         "arguments": ["-c", f"sleep 1; echo p > '{produced}'"],
         "outputs": [str(produced)]},
        {"action": "execute", "tool": "/bin/sh",
         "arguments": ["-c", f"if [ -e '{produced}' ]; then echo present; else echo absent; fi"
                             f" > '{consumer_saw}'"],
         "inputs": [str(d / "out.txt")]},
    ]
    result = run_playlist(playlist)
    check("the playlist runs", result.returncode == 0, result.stderr)
    if produced.exists() and consumer_saw.exists():
        saw = consumer_saw.read_text().strip()
        check("the consumer of out.txt started after the producer of Out.txt finished",
              saw == "present", f"the consumer found Out.txt {saw}")
    else:
        fail("both tasks ran", f"producer={produced.exists()} consumer={consumer_saw.exists()}")


# ---------------------------------------------------------------------------

if not REPLAY.exists():
    print(f"error: replay binary not found at {REPLAY}")
    sys.exit(1)

print(f"Using replay: {REPLAY}")

with tempfile.TemporaryDirectory(prefix="replay-fs-semantics.") as tmp:
    work = Path(tmp).resolve()
    test_birth_time(work)
    test_glob_case(work)
    test_dependency_case(work)

print(f"\n{'='*40}")
print(f"  Passed: {_pass}  Failed: {_fail}")
print(f"{'='*40}")
sys.exit(0 if _fail == 0 else 1)
