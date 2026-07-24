#!/usr/bin/env python3
"""
test_replay_cache.py — the cache wrapper: check, skip, store (default engine).

Scenarios:
  1.  execute miss/hit: run 1 executes, run 2 skips (undeclared side-effect log proves it)
  2.  input content change -> re-run; touch without content change -> still hit
  3.  output deleted -> re-run; output tampered -> re-run; output restored identical -> hit
  4.  early cutoff: upstream re-runs producing identical output, downstream still hits
  5.  create file: second run skips; content change in playlist -> new signature -> runs
  6.  create directory: skips even after files were added inside it
  7.  clone / hardlink / symlink: second run skips
  7b. glob-source clone fan-out: hit, new match, matched-content change
  8.  declared env ("env": [NAME]): value change -> re-run; undeclared env change -> hit
  8b. global --cache-env: hit, value change, undefined name is a startup error
  9.  --cache-refresh forces execution but still records; --dry-run prints HIT/MISS,
      executes nothing, writes no manifest
  10. failed task is not cached: next run retries it, then hits once it succeeds
  11. playlist edit removing a step prunes its entry from the manifest
  12. --cache-hash blake3 invalidates a crc32c manifest wholesale
  13. concurrency smoke: 300 independent cacheable executes, cold and warm, with watchdog

Usage: python3 test_replay_cache.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import json
import os
import shutil
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


def run(args: list, timeout: int = 60, env: dict = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(REPLAY)] + [str(a) for a in args],
        capture_output=True, text=True, timeout=timeout, env=env,
    )


def summary(proc: subprocess.CompletedProcess) -> tuple:
    """Parses the 'cache: N hits, M executed, K failed' stderr line. (-1,-1,-1) if absent."""
    for line in proc.stderr.splitlines():
        if line.startswith("cache: ") and " hits, " in line:
            parts = line.split()
            return (int(parts[1]), int(parts[3]), int(parts[5]))
    return (-1, -1, -1)


def manifest_entries(cache_dir: Path) -> dict:
    files = [p for p in cache_dir.iterdir()
             if p.name.endswith(".replay-cache.json") or p.name.endswith(".replay-cache.plist")]
    if len(files) != 1:
        return {}
    data = json.loads(files[0].read_text())
    return data.get("tasks", {})


def cached(playlist: Path, cache: Path, *extra, env: dict = None,
           timeout: int = 60) -> subprocess.CompletedProcess:
    return run(["--cache", "--cache-dir", cache, *extra, playlist], env=env, timeout=timeout)


def test_execute_miss_hit():
    print("\n=== Scenario 1: execute miss then hit ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        (d / "in.txt").write_text("payload v1")
        log = d / "log.txt"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"echo ran >> {log}; cat {d}/in.txt > {d}/out.txt"],
             "inputs": [str(d / "in.txt")], "outputs": [str(d / "out.txt")]},
        ]))
        cache = d / "cache"

        r1 = cached(playlist, cache)
        check("run 1 exits 0", r1.returncode == 0, r1.stderr)
        check("run 1 executed the task", summary(r1) == (0, 1, 0), r1.stderr)
        check("run 1 produced the output", (d / "out.txt").read_text() == "payload v1")

        r2 = cached(playlist, cache)
        check("run 2 exits 0", r2.returncode == 0, r2.stderr)
        check("run 2 hit", summary(r2) == (1, 0, 0), r2.stderr)
        check("tool ran exactly once (undeclared log has one line)",
              log.read_text().count("ran") == 1, log.read_text())
        check("hit is silent on stdout without -v", r2.stdout == "", r2.stdout)


def test_input_changes():
    print("\n=== Scenario 2: input content change vs touch ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        src = d / "in.txt"
        src.write_text("v1")
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"cat {src} > {d}/out.txt"],
             "inputs": [str(src)], "outputs": [str(d / "out.txt")]},
        ]))
        cache = d / "cache"

        cached(playlist, cache)
        src.write_text("v2")
        r2 = cached(playlist, cache)
        check("content change -> re-run", summary(r2) == (0, 1, 0), r2.stderr)
        check("output reflects new input", (d / "out.txt").read_text() == "v2")

        os.utime(src, (1234567890, 1234567890))
        r3 = cached(playlist, cache)
        check("touch without content change -> still hit", summary(r3) == (1, 0, 0), r3.stderr)


def test_output_states():
    print("\n=== Scenario 3: output deleted / tampered / restored ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        (d / "in.txt").write_text("stable")
        out = d / "out.txt"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"cat {d}/in.txt > {out}"],
             "inputs": [str(d / "in.txt")], "outputs": [str(out)]},
        ]))
        cache = d / "cache"

        cached(playlist, cache)
        original = out.read_bytes()

        out.unlink()
        r = cached(playlist, cache)
        check("deleted output -> re-run", summary(r) == (0, 1, 0), r.stderr)

        out.write_text("tampered")
        r = cached(playlist, cache)
        check("tampered output -> re-run", summary(r) == (0, 1, 0), r.stderr)
        check("re-run restored the output", out.read_bytes() == original)

        out.write_bytes(original)
        r = cached(playlist, cache)
        check("byte-identical restored output -> hit", summary(r) == (1, 0, 0), r.stderr)


def test_early_cutoff():
    print("\n=== Scenario 4: early cutoff ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        trigger = d / "trigger.txt"
        trigger.write_text("t1")
        mid = d / "mid.txt"
        log = d / "consumer_log.txt"
        playlist = d / "pl.json"
        # Producer depends on trigger but always emits the same bytes; the
        # consumer must keep hitting when the producer re-runs to the same output.
        playlist.write_text(json.dumps([
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"printf fixed > {mid}"],
             "inputs": [str(trigger)], "outputs": [str(mid)]},
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"echo consumed >> {log}; cat {mid} > {d}/final.txt"],
             "inputs": [str(mid)], "outputs": [str(d / "final.txt")]},
        ]))
        cache = d / "cache"

        r1 = cached(playlist, cache)
        check("cold run executes both", summary(r1) == (0, 2, 0), r1.stderr)

        trigger.write_text("t2")
        r2 = cached(playlist, cache)
        check("producer re-runs, consumer hits", summary(r2) == (1, 1, 0), r2.stderr)
        check("consumer ran exactly once overall", log.read_text().count("consumed") == 1)


def test_create_file():
    print("\n=== Scenario 5: create file ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        target = d / "made.txt"
        cache = d / "cache"
        playlist = d / "pl.json"

        playlist.write_text(json.dumps([
            {"action": "create", "file": str(target), "content": "alpha"},
        ]))
        r1 = cached(playlist, cache)
        check("run 1 creates", summary(r1) == (0, 1, 0), r1.stderr)
        r2 = cached(playlist, cache)
        check("run 2 hits", summary(r2) == (1, 0, 0), r2.stderr)

        playlist.write_text(json.dumps([
            {"action": "create", "file": str(target), "content": "beta"},
        ]))
        r3 = cached(playlist, cache)
        check("changed content -> new signature -> runs", summary(r3) == (0, 1, 0), r3.stderr)
        check("file has the new content", target.read_text() == "beta")
        check("old signature pruned, one entry remains", len(manifest_entries(cache)) == 1)


def test_create_directory():
    print("\n=== Scenario 6: create directory ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        newdir = d / "made_dir"
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "create", "directory": str(newdir)},
        ]))

        r1 = cached(playlist, cache)
        check("run 1 creates the directory", summary(r1) == (0, 1, 0) and newdir.is_dir(), r1.stderr)

        (newdir / "later_content.txt").write_text("added by another task")
        r2 = cached(playlist, cache)
        check("hit even after files appeared inside", summary(r2) == (1, 0, 0), r2.stderr)

        shutil.rmtree(newdir)
        r3 = cached(playlist, cache)
        check("deleted directory -> re-run", summary(r3) == (0, 1, 0) and newdir.is_dir(), r3.stderr)


def test_link_actions():
    print("\n=== Scenario 7: clone / hardlink / symlink ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        src = d / "source.txt"
        src.write_text("link me")
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "clone", "from": str(src), "to": str(d / "cloned.txt")},
            {"action": "hardlink", "from": str(src), "to": str(d / "hard.txt")},
            {"action": "symlink", "from": str(src), "to": str(d / "sym.txt")},
        ]))

        r1 = cached(playlist, cache)
        check("run 1 executes all three", r1.returncode == 0 and summary(r1) == (0, 3, 0), r1.stderr)
        r2 = cached(playlist, cache)
        check("run 2 hits all three", summary(r2) == (3, 0, 0), r2.stderr)

        (d / "cloned.txt").unlink()
        r3 = cached(playlist, cache)
        check("removing one destination re-runs only that one", summary(r3) == (2, 1, 0), r3.stderr)


def test_glob_clone():
    print("\n=== Scenario 7b: glob-source clone fan-out ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        srcdir = d / "src"
        srcdir.mkdir()
        (srcdir / "one.dat").write_text("1")
        (srcdir / "two.dat").write_text("2")
        dest = d / "dest"
        dest.mkdir()
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "clone", "from": f"{srcdir}/*.dat", "to": str(dest)},
        ]))

        # -f on every run: a re-executed fan-out re-clones over existing destinations.
        r1 = cached(playlist, cache, "-f")
        check("glob clone cold run executes", r1.returncode == 0 and summary(r1) == (0, 1, 0), r1.stderr)
        check("glob matches cloned", (dest / "one.dat").exists() and (dest / "two.dat").exists())

        r2 = cached(playlist, cache, "-f")
        check("glob clone warm run hits", summary(r2) == (1, 0, 0), r2.stderr)

        (srcdir / "three.dat").write_text("3")
        r3 = cached(playlist, cache, "-f")
        check("new glob match -> inputs changed -> re-run", summary(r3) == (0, 1, 0), r3.stderr)
        check("new match cloned", (dest / "three.dat").read_text() == "3")

        (srcdir / "one.dat").write_text("1 changed")
        r4 = cached(playlist, cache, "-f")
        check("matched file content change -> re-run", summary(r4) == (0, 1, 0), r4.stderr)
        check("changed match re-cloned", (dest / "one.dat").read_text() == "1 changed")

        r5 = cached(playlist, cache, "-f")
        check("stable glob world hits again", summary(r5) == (1, 0, 0), r5.stderr)


def test_global_cache_env():
    print("\n=== Scenario 8b: global --cache-env ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "create", "file": str(d / "out.txt"), "content": "fixed"},
        ]))

        env = dict(os.environ)
        env["GLOBALCACHEVAR"] = "one"
        r1 = cached(playlist, cache, "--cache-env", "GLOBALCACHEVAR", env=env)
        check("run 1 executes", summary(r1) == (0, 1, 0), r1.stderr)
        r2 = cached(playlist, cache, "--cache-env", "GLOBALCACHEVAR", env=env)
        check("unchanged global env -> hit", summary(r2) == (1, 0, 0), r2.stderr)

        env["GLOBALCACHEVAR"] = "two"
        r3 = cached(playlist, cache, "--cache-env", "GLOBALCACHEVAR", env=env)
        check("global env change -> re-run", summary(r3) == (0, 1, 0), r3.stderr)

        r4 = cached(playlist, cache, "--cache-env", "NOSUCHCACHEVAR", env=env)
        check("undefined --cache-env name is a startup error",
              r4.returncode != 0 and "NOSUCHCACHEVAR" in r4.stderr, r4.stderr)


def test_declared_env():
    print("\n=== Scenario 8: declared env ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"printenv MYCACHEVAR > {d}/out.txt"],
             "outputs": [str(d / "out.txt")], "env": ["MYCACHEVAR"]},
        ]))

        env = dict(os.environ)
        env["MYCACHEVAR"] = "one"
        env["UNDECLAREDVAR"] = "x"
        r1 = cached(playlist, cache, env=env)
        check("run 1 executes", summary(r1) == (0, 1, 0), r1.stderr)

        env["MYCACHEVAR"] = "two"
        r2 = cached(playlist, cache, env=env)
        check("declared env change -> re-run", summary(r2) == (0, 1, 0), r2.stderr)
        check("output reflects the new value", (d / "out.txt").read_text().strip() == "two")

        env["UNDECLAREDVAR"] = "y"
        r3 = cached(playlist, cache, env=env)
        check("undeclared env change -> hit", summary(r3) == (1, 0, 0), r3.stderr)


def test_refresh_and_dry_run():
    print("\n=== Scenario 9: --cache-refresh and --dry-run ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        (d / "in.txt").write_text("v")
        log = d / "log.txt"
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"echo ran >> {log}; cat {d}/in.txt > {d}/out.txt"],
             "inputs": [str(d / "in.txt")], "outputs": [str(d / "out.txt")]},
        ]))

        cached(playlist, cache)
        r2 = cached(playlist, cache, "--cache-refresh")
        check("--cache-refresh executes despite valid entry", summary(r2) == (0, 1, 0), r2.stderr)
        check("tool ran twice", log.read_text().count("ran") == 2)
        r3 = cached(playlist, cache)
        check("refresh stored a fresh entry: next normal run hits", summary(r3) == (1, 0, 0), r3.stderr)

        manifest = [p for p in cache.iterdir() if p.name.endswith(".replay-cache.json")][0]
        before = manifest.read_bytes()

        r4 = cached(playlist, cache, "--dry-run")
        check("dry run prints HIT", "[cache] HIT execute" in r4.stdout, r4.stdout)
        check("dry run executes nothing", log.read_text().count("ran") == 2)
        check("dry run does not touch the manifest", manifest.read_bytes() == before)

        (d / "out.txt").unlink()
        r5 = cached(playlist, cache, "--dry-run")
        check("dry run reports the miss reason", "[cache] MISS (output missing) execute" in r5.stdout, r5.stdout)
        check("dry-run miss still executes nothing", not (d / "out.txt").exists())
        check("dry-run miss writes no manifest", manifest.read_bytes() == before)

        r6 = cached(playlist, cache, "--dry-run", "--cache-refresh")
        check("dry run under refresh reports (refresh)", "[cache] MISS (refresh) execute" in r6.stdout, r6.stdout)


def test_failed_task_not_cached():
    print("\n=== Scenario 10: failed task retried, then cached once it succeeds ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        gate_file = d / "let_me_pass"
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "execute", "tool": "/bin/sh",
             "arguments": ["-c", f"test -e {gate_file} && echo done > {d}/out.txt"],
             "outputs": [str(d / "out.txt")]},
        ]))

        r1 = cached(playlist, cache)
        check("failing run reports failure", r1.returncode != 0 and summary(r1) == (0, 0, 1), r1.stderr)
        check("no entry stored for the failed task", len(manifest_entries(cache)) == 0)

        gate_file.write_text("")
        r2 = cached(playlist, cache)
        check("next run retries and succeeds", r2.returncode == 0 and summary(r2) == (0, 1, 0), r2.stderr)
        r3 = cached(playlist, cache)
        check("now it hits", summary(r3) == (1, 0, 0), r3.stderr)


def test_prune_on_step_removal():
    print("\n=== Scenario 11: removed step is pruned ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "create", "file": str(d / "a.txt"), "content": "a"},
            {"action": "create", "file": str(d / "b.txt"), "content": "b"},
        ]))
        cached(playlist, cache)
        check("two entries stored", len(manifest_entries(cache)) == 2)

        playlist.write_text(json.dumps([
            {"action": "create", "file": str(d / "a.txt"), "content": "a"},
        ]))
        r2 = cached(playlist, cache)
        check("surviving step hits", summary(r2) == (1, 0, 0), r2.stderr)
        entries = manifest_entries(cache)
        check("removed step's entry pruned", len(entries) == 1, str(entries))


def test_hash_algorithm_invalidation():
    print("\n=== Scenario 12: --cache-hash blake3 invalidates a crc32c manifest ===")
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        cache = d / "cache"
        playlist = d / "pl.json"
        playlist.write_text(json.dumps([
            {"action": "create", "file": str(d / "a.txt"), "content": "a"},
            {"action": "create", "file": str(d / "b.txt"), "content": "b"},
        ]))
        cached(playlist, cache)

        r2 = cached(playlist, cache, "--cache-hash", "blake3", "-v")
        check("algorithm switch discards all entries", "cache: loaded 0 entries" in r2.stderr, r2.stderr)
        check("everything re-executes", summary(r2) == (0, 2, 0), r2.stderr)

        files = [p for p in cache.iterdir() if p.name.endswith(".replay-cache.json")]
        data = json.loads(files[0].read_text())
        check("manifest rewritten as blake3", data.get("hash_algorithm") == "blake3", str(data))

        r3 = cached(playlist, cache, "--cache-hash", "blake3")
        check("blake3 manifest then hits", summary(r3) == (2, 0, 0), r3.stderr)


def test_concurrency_smoke():
    print("\n=== Scenario 13: 300-task concurrency smoke (watchdog 180s) ===")
    task_count = 300
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        cache = d / "cache"
        steps = []
        for i in range(task_count):
            src = d / f"in_{i}.txt"
            src.write_text(f"input {i}")
            steps.append({
                "action": "execute", "tool": "/bin/sh",
                "arguments": ["-c", f"cat {src} > {d}/out_{i}.txt"],
                "inputs": [str(src)], "outputs": [str(d / f'out_{i}.txt')],
            })
        playlist = d / "pl.json"
        playlist.write_text(json.dumps(steps))

        try:
            r1 = cached(playlist, cache, timeout=180)
        except subprocess.TimeoutExpired:
            fail("cold concurrent run finished before the watchdog")
            return
        check("cold concurrent run finished before the watchdog", True)
        check("cold run executed everything", r1.returncode == 0 and summary(r1) == (0, task_count, 0), r1.stderr)

        try:
            r2 = cached(playlist, cache, timeout=180)
        except subprocess.TimeoutExpired:
            fail("warm concurrent run finished before the watchdog")
            return
        check("warm concurrent run finished before the watchdog", True)
        check("warm run hit everything", r2.returncode == 0 and summary(r2) == (task_count, 0, 0), r2.stderr)
        check("manifest holds every entry", len(manifest_entries(cache)) == task_count)
        for i in (0, task_count // 2, task_count - 1):
            if (d / f"out_{i}.txt").read_text() != f"input {i}":
                fail(f"output {i} content correct")
                break
        else:
            ok("spot-checked outputs correct")


if not REPLAY.exists():
    print(f"error: replay binary not found at {REPLAY}")
    sys.exit(1)

print(f"Using replay: {REPLAY}")

test_execute_miss_hit()
test_input_changes()
test_output_states()
test_early_cutoff()
test_create_file()
test_create_directory()
test_link_actions()
test_glob_clone()
test_global_cache_env()
test_declared_env()
test_refresh_and_dry_run()
test_failed_task_not_cached()
test_prune_on_step_removal()
test_hash_algorithm_invalidation()
test_concurrency_smoke()

print(f"\n{'='*40}")
print(f"  Passed: {_pass}  Failed: {_fail}")
print(f"{'='*40}")
sys.exit(0 if _fail == 0 else 1)
