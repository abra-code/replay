#!/usr/bin/env python3
"""
test_replay_stress_playlist.py — stress-test replay's dependency analysis and scheduling.

Runs stress_build_playlist.json, which simulates a 1750-action software build
with complex implicit dependencies and glob-based fan-in/fan-out:

  Group A:    60 modules × 20 files  — 1200 compiles, fully concurrent
  Codegen:    5 compiles + 1 link + 1 run  — sequential chain
  Group B:    30 modules × 15 files  — 450 compiles, blocked on codegen
  Archives:   90 module-level link steps using glob inputs
  Libraries:  lib_static.a, lib_gen.a using glob inputs over archives
  App:        final link with concrete inputs

For detailed profiling, run under Instruments (Time Profiler or os_signpost)
to see time breakdown per phase. See stress_build_design.md for the full
dependency graph analysis.

Usage: python3 test_replay_stress_playlist.py [/path/to/replay]
Exit:  0 = all checks passed, 1 = one or more failures
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR   = Path(__file__).parent.resolve()
REPO_DIR     = SCRIPT_DIR.parent
PLAYLIST     = SCRIPT_DIR / "playlists" / "stress_build_playlist.json"
DEFAULT_REPLAY = REPO_DIR / "build" / "Release" / "replay"
REPLAY       = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_REPLAY

# Must match generate_stress_playlist.py
NUM_STATIC_MODS  = 60
FILES_PER_STATIC = 20
NUM_GEN_MODS     = 30
FILES_PER_GEN    = 15
CODEGEN_SRCS     = ["ct_main", "ct_parser", "ct_lexer", "ct_emitter", "ct_utils"]

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
# File-system setup
# ---------------------------------------------------------------------------

def create_workspace(root: Path) -> None:
    """Create all source dirs, mock source files, and build output dirs."""
    dirs_to_create = []

    # Source dirs + files
    ct_src = root / "src" / "codegen_tool" / "src"
    dirs_to_create.append(ct_src)

    for mod in range(NUM_STATIC_MODS):
        dirs_to_create.append(root / "src" / "static" / f"mod_a_{mod:03d}" / "src")

    for mod in range(NUM_GEN_MODS):
        dirs_to_create.append(root / "src" / "gen" / f"mod_b_{mod:03d}" / "src")

    # Build dirs (touch needs parent to exist)
    dirs_to_create.append(root / "build" / "codegen_tool" / "obj")
    dirs_to_create.append(root / "build" / "generated")
    dirs_to_create.append(root / "build" / "libs")
    dirs_to_create.append(root / "build" / "final")

    for mod in range(NUM_STATIC_MODS):
        dirs_to_create.append(root / "build" / "static" / f"mod_a_{mod:03d}" / "obj")

    for mod in range(NUM_GEN_MODS):
        dirs_to_create.append(root / "build" / "gen" / f"mod_b_{mod:03d}" / "obj")

    for d in dirs_to_create:
        d.mkdir(parents=True, exist_ok=True)

    # Create mock source files (empty — touch doesn't read them, but realistic)
    for src in CODEGEN_SRCS:
        (ct_src / f"{src}.c").touch()

    for mod in range(NUM_STATIC_MODS):
        src_dir = root / "src" / "static" / f"mod_a_{mod:03d}" / "src"
        for f in range(FILES_PER_STATIC):
            (src_dir / f"file_{f:02d}.c").touch()

    for mod in range(NUM_GEN_MODS):
        src_dir = root / "src" / "gen" / f"mod_b_{mod:03d}" / "src"
        for f in range(FILES_PER_GEN):
            (src_dir / f"file_{f:02d}.c").touch()


# ---------------------------------------------------------------------------
# Verification helpers
# ---------------------------------------------------------------------------

def check_outputs(root: Path) -> int:
    """Return the number of failed output checks."""
    failures = 0

    def require(p: Path, label: str) -> None:
        nonlocal failures
        if not p.exists():
            fail(label, f"missing: {p}")
            failures += 1

    # Codegen chain
    for src in CODEGEN_SRCS:
        require(root / "build" / "codegen_tool" / "obj" / f"{src}.o",
                f"codegen_tool compile: {src}.o")
    require(root / "build" / "codegen_tool" / "codegen_tool", "codegen_tool link")
    require(root / "build" / "generated" / "codegen.stamp",    "codegen run stamp")

    # Spot-check Group A: first and last module, first and last file
    for mod in [0, NUM_STATIC_MODS - 1]:
        for f in [0, FILES_PER_STATIC - 1]:
            p = root / "build" / "static" / f"mod_a_{mod:03d}" / "obj" / f"file_{f:02d}.o"
            require(p, f"Group A compile mod_a_{mod:03d}/file_{f:02d}.o")
        require(root / "build" / "libs" / f"mod_a_{mod:03d}.a",
                f"Group A archive mod_a_{mod:03d}.a")

    # Spot-check Group B: first and last module, first and last file
    for mod in [0, NUM_GEN_MODS - 1]:
        for f in [0, FILES_PER_GEN - 1]:
            p = root / "build" / "gen" / f"mod_b_{mod:03d}" / "obj" / f"file_{f:02d}.o"
            require(p, f"Group B compile mod_b_{mod:03d}/file_{f:02d}.o")
        require(root / "build" / "libs" / f"mod_b_{mod:03d}.a",
                f"Group B archive mod_b_{mod:03d}.a")

    # Final products
    require(root / "build" / "final" / "lib_static.a", "lib_static.a")
    require(root / "build" / "final" / "lib_gen.a",    "lib_gen.a")
    require(root / "build" / "final" / "app",           "app")

    if failures == 0:
        ok("all expected outputs present")

    return failures


def check_ordering(root: Path) -> None:
    """Verify dependency ordering via file modification timestamps.

    After the playlist runs, the output file timestamps should satisfy the
    ordering implied by the dependency graph.  This is a probabilistic check:
    concurrent actions may have identical mtime resolution, so we only verify
    relationships that span distinct serialization points (the codegen chain).
    """
    def mtime(p: Path) -> float:
        try:
            return p.stat().st_mtime
        except FileNotFoundError:
            return float("inf")

    stamp    = mtime(root / "build" / "generated" / "codegen.stamp")
    tool_bin = mtime(root / "build" / "codegen_tool" / "codegen_tool")
    tool_obj = mtime(root / "build" / "codegen_tool" / "obj" / "ct_main.o")

    lib_static = mtime(root / "build" / "final" / "lib_static.a")
    lib_gen    = mtime(root / "build" / "final" / "lib_gen.a")
    app        = mtime(root / "build" / "final" / "app")

    # Sample a Group B object — must be newer than the stamp
    b_obj = mtime(root / "build" / "gen" / "mod_b_000" / "obj" / "file_00.o")
    # Sample a Group A object — must be older than lib_static
    a_obj = mtime(root / "build" / "static" / "mod_a_000" / "obj" / "file_00.o")

    check("codegen_tool obj precedes codegen_tool binary",
          tool_obj <= tool_bin,
          f"obj mtime={tool_obj:.6f} binary mtime={tool_bin:.6f}")

    check("codegen_tool binary precedes codegen.stamp",
          tool_bin <= stamp,
          f"binary mtime={tool_bin:.6f} stamp mtime={stamp:.6f}")

    check("codegen.stamp precedes Group B object",
          stamp <= b_obj,
          f"stamp mtime={stamp:.6f} b_obj mtime={b_obj:.6f}")

    check("Group A object precedes lib_static.a",
          a_obj <= lib_static,
          f"a_obj mtime={a_obj:.6f} lib_static mtime={lib_static:.6f}")

    check("lib_static.a precedes app",
          lib_static <= app,
          f"lib_static mtime={lib_static:.6f} app mtime={app:.6f}")

    check("lib_gen.a precedes app",
          lib_gen <= app,
          f"lib_gen mtime={lib_gen:.6f} app mtime={app:.6f}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    print()
    print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
    print("  replay stress build: dependency analysis & scheduling")
    print("  1750 actions, 92 glob-input consumers")
    print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
    print()

    if not REPLAY.exists():
        print(f"error: replay binary not found at {REPLAY}")
        print(f"usage: python3 {Path(__file__).name} [/path/to/replay]")
        return 1

    if not PLAYLIST.exists():
        print(f"error: playlist not found at {PLAYLIST}")
        print(f"  run: python3 generate_stress_playlist.py")
        return 1

    print(f"Replay:   {REPLAY}")
    print(f"Playlist: {PLAYLIST}")
    print()

    with tempfile.TemporaryDirectory(prefix="replay_stress_build_") as tmpdir:
        root = Path(tmpdir)
        print(f"Workspace: {root}")
        print()

        # Setup
        t0 = time.perf_counter()
        create_workspace(root)
        setup_s = time.perf_counter() - t0
        print(f"Setup:    {setup_s:.2f}s  (created dirs and {len(CODEGEN_SRCS) + NUM_STATIC_MODS*FILES_PER_STATIC + NUM_GEN_MODS*FILES_PER_GEN} source files)")

        # Run replay
        env = {**os.environ, "STRESS_ROOT": str(root)}
        print()
        print("Running replay...")
        t1 = time.perf_counter()
        result = subprocess.run(
            [str(REPLAY), str(PLAYLIST)],
            env=env,
            capture_output=True,
            text=True,
        )
        replay_s = time.perf_counter() - t1

        print(f"Elapsed:  {replay_s:.2f}s")
        print()

        # Print timing output if replay emitted any (--timing build)
        if result.stderr and "[timing]" in result.stderr:
            print(result.stderr.rstrip())
            print()

        # Check exit code
        check("replay exit code 0", result.returncode == 0,
              f"exit={result.returncode}\nstderr: {result.stderr[:500]}" if result.returncode != 0 else "")

        if result.returncode != 0:
            print()
            print("--- replay stderr ---")
            print(result.stderr[:2000])
            return 1

        # Verify outputs
        print()
        print("Checking outputs...")
        output_failures = check_outputs(root)

        if output_failures == 0:
            # Ordering check (only when all files exist)
            print()
            print("Checking ordering via file timestamps...")
            check_ordering(root)

        # Summary
        total_s = time.perf_counter() - t0
        print()
        print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        print(f"  Actions:  1750")
        print(f"  Setup:    {setup_s:.2f}s")
        print(f"  Replay:   {replay_s:.2f}s")
        print(f"  Total:    {total_s:.2f}s")
        print(f"  Passed:   {_pass}")
        print(f"  Failed:   {_fail}")
        print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        print()

    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
