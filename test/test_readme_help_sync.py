#!/usr/bin/env python3
"""
test_readme_help_sync.py - README's fenced help blocks must be the tools' real --help.

README.md introduces four fenced blocks with "The content of `<tool> --help`:", so each
one is a claim about what the tool prints. Nothing checked it, and the replay block's
cache section did drift from DisplayHelp: the two texts described the same behaviour in
different words, which is the failure mode a reader cannot detect, because both look
authoritative. This asserts the claim the file makes.

The blocks carry no leading or trailing blank line, unlike the raw output, so those runs
are trimmed on both sides before comparing. Everything else must match exactly.

Usage: python3 test_readme_help_sync.py [/path/to/replay]
       python3 test_readme_help_sync.py --write   regenerate every block from the binaries
Exit:  0 = all checks passed, 1 = one or more failures
"""

import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_DIR   = SCRIPT_DIR.parent
README     = REPO_DIR / "README.md"

WRITE = "--write" in sys.argv[1:]
ARGS  = [a for a in sys.argv[1:] if a != "--write"]

# The tools live beside replay, wherever the caller says replay is.
REPLAY    = Path(ARGS[0]) if len(ARGS) > 0 else REPO_DIR / "build" / "Release" / "replay"
BUILD_DIR = REPLAY.parent

# Marker text varies in inner whitespace across the four ("of  `dispatch"), so each entry
# is matched on its normalized form rather than character for character.
TOOLS = ["replay", "dispatch", "fingerprint", "gate"]

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
        msg += f"\n        {reason[:600]}"
    print(msg)


def check(name: str, condition: bool, reason: str = "") -> bool:
    if condition:
        ok(name)
        return True
    fail(name, reason)
    return False


def normalized(line: str) -> str:
    return " ".join(line.split())


def marker_for(tool: str) -> str:
    return normalized(f"The content of `{tool} --help`:")


def trimmed(seq: list) -> list:
    """Drops leading and trailing blank runs, the one difference the blocks are allowed."""
    out = list(seq)
    while len(out) > 0 and out[0].strip() == "":
        out.pop(0)
    while len(out) > 0 and out[-1].strip() == "":
        out.pop()
    return out


def find_block(lines: list, tool: str):
    """Returns (open_idx, close_idx) of the fence pair following the tool's marker."""
    marker = marker_for(tool)
    start = None
    for i, line in enumerate(lines):
        if normalized(line) == marker:
            start = i
            break
    if start is None:
        return None

    open_idx = None
    for i in range(start, len(lines)):
        if lines[i].rstrip() == "```":
            open_idx = i
            break
    if open_idx is None:
        return None

    for i in range(open_idx + 1, len(lines)):
        if lines[i].rstrip() == "```":
            return (open_idx, i)
    return None


def live_help(tool: str):
    """Returns the tool's help lines, or None with a reason if it could not be obtained."""
    path = BUILD_DIR / tool
    if not path.exists():
        return (None, f"{path} does not exist")
    try:
        proc = subprocess.run([str(path), "--help"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return (None, f"{path} --help failed to run: {exc}")
    if proc.returncode != 0:
        return (None, f"{path} --help exited {proc.returncode}: {proc.stderr[:200]}")
    if len(trimmed(proc.stdout.split("\n"))) == 0:
        return (None, f"{path} --help printed nothing on stdout")
    return (proc.stdout.split("\n"), "")


def first_difference(a: list, b: list) -> str:
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return (f"first difference at block line {i + 1}:\n"
                    f"        README: {a[i]!r}\n"
                    f"        --help: {b[i]!r}")
    if len(a) != len(b):
        longer, which = (a, "README") if len(a) > len(b) else (b, "--help")
        return (f"{which} has {abs(len(a) - len(b))} extra line(s), "
                f"starting with {longer[min(len(a), len(b))]!r}")
    return "no difference found"


if not README.exists():
    print(f"error: README not found at {README}")
    sys.exit(1)

print(f"Using build directory: {BUILD_DIR}")

lines = README.read_text().split("\n")
rewrites = 0

for tool in TOOLS:
    print(f"\n=== {tool} --help ===")

    span = find_block(lines, tool)
    if not check(f"{tool}: README has a marked help block", span is not None,
                 f"no fenced block after a line reading {marker_for(tool)!r}"):
        continue

    live, why = live_help(tool)
    if not check(f"{tool}: binary is present and printed help", live is not None, why):
        continue

    open_idx, close_idx = span
    block = trimmed(lines[open_idx + 1:close_idx])
    expected = trimmed(live)

    if WRITE:
        if block != expected:
            lines[open_idx + 1:close_idx] = expected
            rewrites += 1
            print(f"  WROTE: {tool} block regenerated ({len(block)} -> {len(expected)} lines)")
        else:
            print(f"  OK:    {tool} block already matches")
        continue

    check(f"{tool}: README block is the tool's real --help output",
          block == expected, first_difference(block, expected))

if WRITE:
    if rewrites > 0:
        README.write_text("\n".join(lines))
    print(f"\n{rewrites} block(s) regenerated in {README}")
    # A block that could not be located, or a tool that would not run, is still a failure
    # in --write mode: exiting 0 there would report a successful sync that did not happen.
    sys.exit(0 if _fail == 0 else 1)

print(f"\n{'='*40}")
print(f"  Passed: {_pass}  Failed: {_fail}")
print(f"{'='*40}")
if _fail > 0:
    print("\nRegenerate the drifted block(s) with:")
    print(f"  python3 {Path(__file__).name} --write")
sys.exit(0 if _fail == 0 else 1)
