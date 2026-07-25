#!/usr/bin/env python3
"""
test_replay_cache_sandbox.py - the incremental cache under the hard sandbox.

Scenarios:
  1. sandboxed cached run: cold run executes, warm run hits; the cache dir is
     created before the sandbox is applied (nested, nonexistent) and the
     manifest is written from inside the sandbox
  2. xattr memoization defaults to off under --sandbox: verbose note printed,
     no fingerprint xattrs written anywhere, no xattr noise on stderr
  3. explicit --cache-xattr on under --sandbox: denied input-file xattr writes
     are silent and non-fatal (run exits 0, second run still hits, stderr
     clean), while outputs in read-write areas do get memoized; no verbose
     default-off note
  3b. read-only (chmod 444) input with explicit --cache-xattr on: the denied
     lchmod/setxattr sequence leaves the file's mode unaltered
  4. --dry-run --cache --sandbox: a cold dry run creates no cache dir; a warm
     dry run reports HIT from inside the sandbox
  5. serial engine (-s) under --sandbox: warm run hits
  6. mutator fixed point under --sandbox: create -> edit chain fully skips on
     run 2; an input change still re-runs the chain (correctness intact)
  7. no --sandbox: the xattr default stays "on" (input files gain the
     fingerprint xattr), guarding the flag logic against regressions

Usage: python3 test_replay_cache_sandbox.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY         = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

XATTR_NAMES = ("public.fingerprint.crc32c", "public.fingerprint.blake3")
# Strings that must never appear on stderr of a cached sandboxed run: the xattr
# memoization write path degrades silently on permission failures.
NOISE = ("setxattr", "lchmod", "EPERM", "Operation not permitted", "Warning:")

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


def run(args: list, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(REPLAY)] + [str(a) for a in args],
        capture_output=True, text=True, timeout=timeout,
    )


def summary(proc: subprocess.CompletedProcess) -> tuple:
    """Parses the 'cache: N hits, M executed, K failed' stderr line. (-1,-1,-1) if absent."""
    for line in proc.stderr.splitlines():
        if line.startswith("cache: ") and " hits, " in line:
            parts = line.split()
            return (int(parts[1]), int(parts[3]), int(parts[5]))
    return (-1, -1, -1)


def xattr_names(path: Path) -> list:
    proc = subprocess.run(["/usr/bin/xattr", str(path)],
                          capture_output=True, text=True, timeout=10)
    return proc.stdout.split()


def has_fingerprint_xattr(path: Path) -> bool:
    names = xattr_names(path)
    return any(n in names for n in XATTR_NAMES)


def stderr_noise(proc: subprocess.CompletedProcess) -> str:
    for marker in NOISE:
        if marker in proc.stderr:
            return marker
    return ""


def make_tree(d: Path) -> tuple:
    """Standard tree: a read-only input dir, a separate output dir, a playlist
    whose execute copies input to output. Separate dirs matter: the sandbox
    grants the input file read-only, so xattr writes on it are denied."""
    src = d / "src"
    out = d / "out"
    src.mkdir()
    out.mkdir()
    (src / "in.txt").write_text("payload v1")
    playlist = d / "pl.json"
    playlist.write_text(json.dumps([
        {"action": "execute", "tool": "/bin/sh",
         "arguments": ["-c", f"cat {src}/in.txt > {out}/out.txt"],
         "inputs": [str(src / "in.txt")], "outputs": [str(out / "out.txt")]},
    ]))
    return playlist, src / "in.txt", out / "out.txt"


def test_sandbox_miss_hit():
    print("\n=== Scenario 1: sandboxed cold run executes, warm run hits ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, in_file, out_file = make_tree(d)
        # Nested and nonexistent: proves the pre-sandbox mkdir handles
        # intermediate components, not just the leaf.
        cache = d / "nested" / "cache"

        r1 = run(["--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("run 1 executed the task", summary(r1) == (0, 1, 0), r1.stderr)
        check("run 1 produced the output", out_file.read_text() == "payload v1")
        manifests = list(cache.glob("*.replay-cache.json"))
        check("manifest written inside the sandbox", len(manifests) == 1,
              str(list(cache.iterdir()) if cache.exists() else "cache dir missing"))

        r2 = run(["--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("run 2 exits 0", r2.returncode == 0, r2.stderr)
        check("run 2 hit", summary(r2) == (1, 0, 0), r2.stderr)
        check("run 2 stderr free of xattr noise", stderr_noise(r2) == "",
              f"found {stderr_noise(r2)!r} in: {r2.stderr}")


def test_sandbox_xattr_default_off():
    print("\n=== Scenario 2: xattr memoization defaults to off under --sandbox ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, in_file, out_file = make_tree(d)
        cache = d / "cache"

        r1 = run(["--sandbox", "--cache", "--cache-dir", cache, "-v", playlist])
        check("verbose run exits 0", r1.returncode == 0, r1.stderr)
        check("verbose note about the xattr default",
              "xattr memoization defaults to off under --sandbox" in r1.stderr, r1.stderr)

        r2 = run(["--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("warm run hits with xattr off", summary(r2) == (1, 0, 0), r2.stderr)
        check("no fingerprint xattr on the input", not has_fingerprint_xattr(in_file),
              str(xattr_names(in_file)))
        check("no fingerprint xattr on the output", not has_fingerprint_xattr(out_file),
              str(xattr_names(out_file)))
        check("warm stderr free of xattr noise", stderr_noise(r2) == "",
              f"found {stderr_noise(r2)!r} in: {r2.stderr}")


def test_sandbox_xattr_explicit_on():
    print("\n=== Scenario 3: explicit --cache-xattr on: denied writes are silent, run unaffected ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, in_file, out_file = make_tree(d)
        cache = d / "cache"
        args = ["--sandbox", "--cache-xattr", "on", "--cache-dir", cache]

        r1 = run(args + [playlist])
        check("run 1 exits 0 despite denied input xattr writes", r1.returncode == 0, r1.stderr)
        check("run 1 executed the task", summary(r1) == (0, 1, 0), r1.stderr)
        check("run 1 stderr free of xattr noise", stderr_noise(r1) == "",
              f"found {stderr_noise(r1)!r} in: {r1.stderr}")
        check("sandbox denied the input xattr write silently",
              not has_fingerprint_xattr(in_file), str(xattr_names(in_file)))
        check("output in the read-write area was memoized",
              has_fingerprint_xattr(out_file), str(xattr_names(out_file)))

        r2 = run(args + ["-v", playlist])
        check("run 2 hits", summary(r2) == (1, 0, 0), r2.stderr)
        check("no default-off note when --cache-xattr is explicit",
              "xattr memoization defaults to off" not in r2.stderr, r2.stderr)


def test_sandbox_xattr_readonly_input_mode_preserved():
    print("\n=== Scenario 3b: read-only input file: denied lchmod leaves the mode intact ===")
    # write_xattr_fileinfo tries lchmod(mode | S_IWUSR) on non-user-writable
    # files before setxattr, then restores. Under the sandbox both are denied;
    # this pins that the input's mode survives unaltered and the run is clean.
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, in_file, out_file = make_tree(d)
        in_file.chmod(0o444)
        cache = d / "cache"
        args = ["--sandbox", "--cache-xattr", "on", "--cache-dir", cache]

        r1 = run(args + [playlist])
        check("run 1 exits 0 with a chmod 444 input", r1.returncode == 0, r1.stderr)
        check("run 1 stderr free of xattr noise", stderr_noise(r1) == "",
              f"found {stderr_noise(r1)!r} in: {r1.stderr}")
        mode1 = in_file.stat().st_mode & 0o7777
        check("input mode unchanged after run 1", mode1 == 0o444, oct(mode1))
        check("no fingerprint xattr on the read-only input",
              not has_fingerprint_xattr(in_file), str(xattr_names(in_file)))

        r2 = run(args + [playlist])
        check("run 2 hits", summary(r2) == (1, 0, 0), r2.stderr)
        mode2 = in_file.stat().st_mode & 0o7777
        check("input mode unchanged after run 2", mode2 == 0o444, oct(mode2))


def test_sandbox_dry_run():
    print("\n=== Scenario 4: --dry-run --cache --sandbox ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, in_file, out_file = make_tree(d)
        cache = d / "cache"

        r1 = run(["--sandbox", "--cache", "--cache-dir", cache, "--dry-run", playlist])
        check("cold dry run exits 0", r1.returncode == 0, r1.stderr)
        check("cold dry run creates no cache dir", not cache.exists(), str(cache))
        check("cold dry run reports MISS", "[cache] MISS" in r1.stdout + r1.stderr,
              r1.stdout + r1.stderr)

        r2 = run(["--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("real run executes and saves", summary(r2) == (0, 1, 0), r2.stderr)

        r3 = run(["--sandbox", "--cache", "--cache-dir", cache, "--dry-run", playlist])
        check("warm dry run exits 0", r3.returncode == 0, r3.stderr)
        check("warm dry run reports HIT from inside the sandbox",
              "[cache] HIT" in r3.stdout + r3.stderr, r3.stdout + r3.stderr)


def test_sandbox_serial():
    print("\n=== Scenario 5: serial engine under --sandbox ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, in_file, out_file = make_tree(d)
        cache = d / "cache"

        r1 = run(["-s", "--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("serial run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("serial run 1 executed", summary(r1) == (0, 1, 0), r1.stderr)

        r2 = run(["-s", "--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("serial run 2 hit", summary(r2) == (1, 0, 0), r2.stderr)


def test_sandbox_mutator_fixed_point():
    print("\n=== Scenario 6: create -> edit fixed point under --sandbox ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        work = d / "work"
        work.mkdir()
        gen = work / "gen.txt"
        cache = d / "cache"
        playlist = d / "pl.json"

        def write_playlist(content: str) -> None:
            playlist.write_text(json.dumps([
                {"action": "create", "file": str(gen), "content": content, "raw": True},
                {"action": "edit", "items": [str(gen)],
                 "oldText": "stable", "newText": "edited"},
            ]))

        write_playlist("v1 stable")
        r1 = run(["--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("run 1 executed both steps", summary(r1) == (0, 2, 0), r1.stderr)
        check("edit applied", gen.read_text() == "v1 edited")

        r2 = run(["--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("run 2 fully skips the mutator chain", summary(r2) == (2, 0, 0), r2.stderr)
        check("post-edit state preserved", gen.read_text() == "v1 edited")

        write_playlist("v2 stable")
        r3 = run(["--sandbox", "--cache", "--cache-dir", cache, playlist])
        check("changed content re-runs the chain", summary(r3) == (0, 2, 0), r3.stderr)
        check("new post-edit state", gen.read_text() == "v2 edited")


def test_no_sandbox_xattr_default_unchanged():
    print("\n=== Scenario 7: without --sandbox the xattr default stays on ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td).resolve()
        playlist, in_file, out_file = make_tree(d)
        cache = d / "cache"

        r1 = run(["--cache", "--cache-dir", cache, playlist])
        check("run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("input gained the fingerprint xattr", has_fingerprint_xattr(in_file),
              str(xattr_names(in_file)))


def main() -> int:
    if not REPLAY.exists():
        print(f"error: replay not found at {REPLAY}")
        return 1

    print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
    print(" Testing replay cache under sandbox")
    print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
    print(f"replay: {REPLAY}")

    test_sandbox_miss_hit()
    test_sandbox_xattr_default_off()
    test_sandbox_xattr_explicit_on()
    test_sandbox_xattr_readonly_input_mode_preserved()
    test_sandbox_dry_run()
    test_sandbox_serial()
    test_sandbox_mutator_fixed_point()
    test_no_sandbox_xattr_default_unchanged()

    print(f"\nNumber of successful tests: {_pass}")
    print(f"Number of failed tests:     {_fail}")
    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
