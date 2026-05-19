#!/usr/bin/env python3
"""
test_replay_execute_stress.py — stress-test concurrent execute actions (posix_spawn path).

Scenarios:
  1. token-echo      200 concurrent /bin/echo actions; --ordered-output
                     Verifies every token captured, no drops, no duplicates.
  2. large-stdout    50 concurrent "seq 1 200" actions (10 000 lines total)
                     Verifies correct total line count under high stdout volume.
  3. failure-mix     50 succeed + 50 exit-42 concurrently (no --stop-on-error)
                     Verifies errors reported for all 50 failing actions.
  4. slow-parallel   100 concurrent /bin/sleep 0.05 actions
                     Verifies no hangs/deadlocks under sustained concurrency.

Usage: python3 test_replay_execute_stress.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import json
import math
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR     = Path(__file__).parent.resolve()
REPO_DIR       = SCRIPT_DIR.parent
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY         = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

N_ECHO    = 200   # scenario 1: parallel echo count
N_LINES   = 200   # scenario 2: lines per action (seq 1 N_LINES)
N_LARGE   = 50    # scenario 2: number of parallel actions
N_FAIL    = 50    # scenario 3: failing actions
N_SUCCEED = 50    # scenario 3: succeeding actions alongside failures
N_SLOW    = 100   # scenario 4: parallel sleep count
SLOW_SECS = 0.05  # scenario 4: sleep duration per action
N_LONG    = 200   # scenario 5: parallel long-running tasks
LONG_SECS = 5     # scenario 5: sleep duration — exposes thread starvation

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
        msg += f"\n        {reason[:200]}"
    print(msg)

def check(name: str, condition: bool, reason: str = "") -> bool:
    if condition:
        ok(name)
        return True
    fail(name, reason)
    return False

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run_replay(playlist: list, extra_args: list[str] = (), timeout: int = 60) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(playlist, f)
        playlist_path = f.name
    try:
        result = subprocess.run(
            [str(REPLAY), "--concurrent"] + list(extra_args) + [playlist_path],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    finally:
        os.unlink(playlist_path)
    return result

# ---------------------------------------------------------------------------
# Scenario 1: token-echo — 200 parallel echo, ordered output
# ---------------------------------------------------------------------------

def test_token_echo() -> None:
    print(f"\n--- Scenario 1: {N_ECHO} parallel /bin/echo (ordered output) ---")

    playlist = [
        {"action": "execute", "tool": "/bin/echo", "arguments": [f"token-{i}"]}
        for i in range(N_ECHO)
    ]

    t0 = time.monotonic()
    result = run_replay(playlist, ["--ordered-output"])
    elapsed = time.monotonic() - t0

    check("token-echo: replay exited 0", result.returncode == 0,
          f"rc={result.returncode} stderr={result.stderr[:200]}")

    lines = [ln for ln in result.stdout.splitlines() if ln.startswith("token-")]
    tokens_found = {ln for ln in lines}
    expected     = {f"token-{i}" for i in range(N_ECHO)}

    check(f"token-echo: all {N_ECHO} tokens present",
          tokens_found == expected,
          f"missing={sorted(expected - tokens_found)[:10]} extra={sorted(tokens_found - expected)[:10]}")

    check(f"token-echo: no duplicate tokens",
          len(lines) == N_ECHO,
          f"got {len(lines)} lines for {N_ECHO} tokens")

    print(f"  time: {elapsed:.2f}s for {N_ECHO} actions")

# ---------------------------------------------------------------------------
# Scenario 2: large-stdout — 50 parallel "seq 1 200"
# ---------------------------------------------------------------------------

def test_large_stdout() -> None:
    print(f"\n--- Scenario 2: {N_LARGE} parallel 'seq 1 {N_LINES}' ({N_LARGE * N_LINES} lines) ---")

    playlist = [
        {"action": "execute", "tool": "/usr/bin/seq", "arguments": ["1", str(N_LINES)]}
        for _ in range(N_LARGE)
    ]

    t0 = time.monotonic()
    result = run_replay(playlist)
    elapsed = time.monotonic() - t0

    check("large-stdout: replay exited 0", result.returncode == 0,
          f"rc={result.returncode} stderr={result.stderr[:200]}")

    lines = [ln for ln in result.stdout.splitlines() if ln.strip().isdigit()]
    total_expected = N_LARGE * N_LINES

    check(f"large-stdout: total line count = {total_expected}",
          len(lines) == total_expected,
          f"got {len(lines)}, expected {total_expected}")

    print(f"  time: {elapsed:.2f}s, stdout={len(result.stdout):,} bytes")

# ---------------------------------------------------------------------------
# Scenario 3: failure-mix — 50 exit-42 + 50 /bin/echo, no --stop-on-error
# ---------------------------------------------------------------------------

def test_failure_mix() -> None:
    print(f"\n--- Scenario 3: {N_FAIL} failing + {N_SUCCEED} succeeding concurrently ---")

    playlist = []
    for i in range(N_FAIL):
        playlist.append({"action": "execute", "tool": "/bin/sh",
                          "arguments": ["-c", "exit 42"]})
    for i in range(N_SUCCEED):
        playlist.append({"action": "execute", "tool": "/bin/echo",
                          "arguments": [f"ok-{i}"]})

    t0 = time.monotonic()
    result = run_replay(playlist)
    elapsed = time.monotonic() - t0

    # replay exits non-zero because some actions failed
    check("failure-mix: replay exits non-zero when actions fail",
          result.returncode != 0,
          f"expected non-zero, got {result.returncode}")

    # Each failing action should emit "Error: 42" in stderr
    error_count = result.stderr.count("Error: 42")
    check(f"failure-mix: {N_FAIL} 'Error: 42' lines in stderr",
          error_count == N_FAIL,
          f"found {error_count}, expected {N_FAIL}\nstderr[:300]={result.stderr[:300]}")

    # All succeeding echo outputs should appear
    ok_tokens = {ln for ln in result.stdout.splitlines() if ln.startswith("ok-")}
    check(f"failure-mix: all {N_SUCCEED} ok-tokens in stdout",
          len(ok_tokens) == N_SUCCEED,
          f"found {len(ok_tokens)}/{N_SUCCEED}")

    print(f"  time: {elapsed:.2f}s")

# ---------------------------------------------------------------------------
# Scenario 4: slow-parallel — 100 concurrent sleeps, no hang
# ---------------------------------------------------------------------------

def test_slow_parallel() -> None:
    print(f"\n--- Scenario 4: {N_SLOW} parallel /bin/sleep {SLOW_SECS} ---")

    playlist = [
        {"action": "execute", "tool": "/bin/sleep", "arguments": [str(SLOW_SECS)]}
        for _ in range(N_SLOW)
    ]

    t0 = time.monotonic()
    result = run_replay(playlist, timeout=30)
    elapsed = time.monotonic() - t0

    check("slow-parallel: replay exited 0", result.returncode == 0,
          f"rc={result.returncode} stderr={result.stderr[:200]}")

    # With true concurrency all N_SLOW actions should finish close to SLOW_SECS,
    # not N_SLOW * SLOW_SECS (serial). Allow generous headroom for CI.
    serial_bound = N_SLOW * SLOW_SECS
    parallel_bound = SLOW_SECS * 8   # 8× the single-sleep duration

    check(f"slow-parallel: finished in {parallel_bound:.1f}s (not serial {serial_bound:.0f}s)",
          elapsed < parallel_bound,
          f"took {elapsed:.2f}s; parallel ceiling={parallel_bound:.1f}s")

    print(f"  time: {elapsed:.2f}s  (serial equivalent: {serial_bound:.0f}s)")

# ---------------------------------------------------------------------------
# Scenario 5: long-parallel — 200 tasks that each sleep 5s then echo a token.
# Exposes thread starvation: a naive 1-thread-per-task drain would cap concurrency
# at the OS thread limit, serialising tasks into batches and taking ~N*5s total.
# ---------------------------------------------------------------------------

def test_long_parallel() -> None:
    print(f"\n--- Scenario 5: {N_LONG} parallel tasks sleeping {LONG_SECS}s (thread-starvation probe) ---")

    playlist = [
        {"action": "execute", "tool": "/bin/sh",
         "arguments": ["-c", f"sleep {LONG_SECS} && echo long-{i}"]}
        for i in range(N_LONG)
    ]

    t0 = time.monotonic()
    result = run_replay(playlist, timeout=60)
    elapsed = time.monotonic() - t0

    check("long-parallel: replay exited 0", result.returncode == 0,
          f"rc={result.returncode} stderr={result.stderr[:200]}")

    tokens = {ln for ln in result.stdout.splitlines() if ln.startswith("long-")}
    check(f"long-parallel: all {N_LONG} tokens present",
          len(tokens) == N_LONG,
          f"got {len(tokens)}/{N_LONG}")

    # GCD custom concurrent queue creates ~cpu_count*8 worker threads under blocking
    # load (empirical; scales with hardware).  Ceiling = expected batches + 2 for
    # spawn overhead, scaled to this machine so the test is portable across core counts.
    cpu_count = os.cpu_count() or 4
    gcd_cap   = cpu_count * 8
    batches   = math.ceil(N_LONG / gcd_cap)
    parallel_bound = LONG_SECS * (batches + 2)
    serial_equiv   = N_LONG * LONG_SECS
    check(f"long-parallel: finished in {parallel_bound:.0f}s (not serial {serial_equiv}s)",
          elapsed < parallel_bound,
          f"took {elapsed:.2f}s; ceiling={parallel_bound:.0f}s (cpu={cpu_count}, gcd_cap≈{gcd_cap})")

    print(f"  time: {elapsed:.2f}s  (serial equivalent: {serial_equiv}s)")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    if not REPLAY.exists():
        print(f"ERROR: replay not found at {REPLAY}")
        sys.exit(1)

    print(f"replay: {REPLAY}")

    test_token_echo()
    test_large_stdout()
    test_failure_mix()
    test_slow_parallel()
    test_long_parallel()

    print()
    total = _pass + _fail
    if _fail == 0:
        print(f"  all {total} checks passed")
        sys.exit(0)
    else:
        print(f"  {_pass}/{total} passed, {_fail} FAILED")
        sys.exit(1)
