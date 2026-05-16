#!/usr/bin/env python3
"""
generate_stress_playlist.py — generates stress_build_playlist.json

Simulates a multi-module C project build to stress-test replay's dependency
analysis and concurrent scheduling. All paths use ${STRESS_ROOT} so the
generated playlist is reusable across machines and temp dirs.

Build structure:
  Group A: 60 static modules × 20 source files each (1200 compile actions)
           No external deps — all can run immediately and concurrently.
  Codegen tool: 5 source files compiled and linked (6 actions)
               Also runs immediately, concurrent with Group A.
  Codegen run: 1 action, sequential after codegen tool link.
               Produces a stamp file that Group B modules depend on.
  Group B: 30 generated modules × 15 source files each (450 compile actions)
           Each compile declares codegen.stamp as input → waits for codegen run.
  Module archives: 90 actions (60 + 30), one per module.
                   Uses glob inputs (build/MODULE/obj/**/*.o) to pull in
                   all of that module's object files. Exercises Case 2 of
                   ConnectGlobDependencies: concrete output → glob input.
  lib_static.a: 1 action, glob input (build/libs/mod_a_*.a) → waits for
                all 60 Group A archives.
  lib_gen.a: 1 action, glob input (build/libs/mod_b_*.a) → waits for
             all 30 Group B archives.
  app: 1 action, concrete inputs (both .a files) → final node.

Total actions: 1750

Dependency analysis complexity:
  ConnectGlobDependencies Case 2 (concrete-output → glob-input):
    92 consumers with glob inputs × ~1750 producer tasks
    ≈ 161,000 GetPathForNode + concrete_matches_glob calls.

Usage: python3 generate_stress_playlist.py [output_path]
       Default output: playlists/stress_build_playlist.json (next to this script)
"""

import json
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Parameters — change here to regenerate with different scale
# ---------------------------------------------------------------------------

NUM_STATIC_MODS   = 60   # Group A
FILES_PER_STATIC  = 20
NUM_GEN_MODS      = 30   # Group B
FILES_PER_GEN     = 15
CODEGEN_SRCS      = ["ct_main", "ct_parser", "ct_lexer", "ct_emitter", "ct_utils"]

ROOT  = "${STRESS_ROOT}"
TOUCH = "/usr/bin/touch"

# ---------------------------------------------------------------------------
# Build action list
# ---------------------------------------------------------------------------

actions = []


def compile_action(src_path, obj_path, extra_inputs=None):
    inp = [src_path]
    if extra_inputs:
        inp.extend(extra_inputs)
    return {
        "action":    "execute",
        "tool":      TOUCH,
        "arguments": [obj_path],
        "inputs":    inp,
        "outputs":   [obj_path],
    }


def link_action(output_path, inputs):
    return {
        "action":    "execute",
        "tool":      TOUCH,
        "arguments": [output_path],
        "inputs":    inputs,
        "outputs":   [output_path],
    }


# ---- Phase 1a: codegen_tool compile (concurrent, no external deps) --------
for src in CODEGEN_SRCS:
    actions.append(compile_action(
        src_path = f"{ROOT}/src/codegen_tool/src/{src}.c",
        obj_path = f"{ROOT}/build/codegen_tool/obj/{src}.o",
    ))

# ---- Phase 1b: Group A static module compiles (concurrent, no deps) -------
for mod in range(NUM_STATIC_MODS):
    mod_name = f"mod_a_{mod:03d}"
    for f in range(FILES_PER_STATIC):
        fname = f"file_{f:02d}"
        actions.append(compile_action(
            src_path = f"{ROOT}/src/static/{mod_name}/src/{fname}.c",
            obj_path = f"{ROOT}/build/static/{mod_name}/obj/{fname}.o",
        ))

# ---- Phase 2: codegen_tool link (waits for all 5 codegen compiles) --------
# Uses concrete inputs — exact list of .o files produced above.
actions.append(link_action(
    output_path = f"{ROOT}/build/codegen_tool/codegen_tool",
    inputs      = [f"{ROOT}/build/codegen_tool/obj/{src}.o" for src in CODEGEN_SRCS],
))

# ---- Phase 3: codegen run (sequential after codegen_tool link) ------------
# Produces a stamp file; Group B compile actions declare it as input.
actions.append(link_action(
    output_path = f"{ROOT}/build/generated/codegen.stamp",
    inputs      = [f"{ROOT}/build/codegen_tool/codegen_tool"],
))

# ---- Phase 4: Group B generated module compiles (waits for codegen run) ---
# Each compile declares codegen.stamp as an extra concrete input, creating the
# dependency edge: codegen_run → gen_compile via FileTree producer lookup.
for mod in range(NUM_GEN_MODS):
    mod_name = f"mod_b_{mod:03d}"
    for f in range(FILES_PER_GEN):
        fname = f"file_{f:02d}"
        actions.append(compile_action(
            src_path     = f"{ROOT}/src/gen/{mod_name}/src/{fname}.c",
            obj_path     = f"{ROOT}/build/gen/{mod_name}/obj/{fname}.o",
            extra_inputs = [f"{ROOT}/build/generated/codegen.stamp"],
        ))

# ---- Phase 5a: Group A module archives (waits for each module's compiles) -
# Each archive uses a glob input (obj/**/*.o) for its module.  ConnectGlob-
# Dependencies Case 2 matches concrete compile outputs against this pattern.
for mod in range(NUM_STATIC_MODS):
    mod_name = f"mod_a_{mod:03d}"
    actions.append(link_action(
        output_path = f"{ROOT}/build/libs/{mod_name}.a",
        inputs      = [f"{ROOT}/build/static/{mod_name}/obj/**/*.o"],
    ))

# ---- Phase 5b: Group B module archives (waits for each module's compiles) -
for mod in range(NUM_GEN_MODS):
    mod_name = f"mod_b_{mod:03d}"
    actions.append(link_action(
        output_path = f"{ROOT}/build/libs/{mod_name}.a",
        inputs      = [f"{ROOT}/build/gen/{mod_name}/obj/**/*.o"],
    ))

# ---- Phase 6a: lib_static.a (waits for all 60 Group A archives) -----------
# Glob input mod_a_*.a matches all Group A archives but not Group B (mod_b_*).
actions.append(link_action(
    output_path = f"{ROOT}/build/final/lib_static.a",
    inputs      = [f"{ROOT}/build/libs/mod_a_*.a"],
))

# ---- Phase 6b: lib_gen.a (waits for all 30 Group B archives) --------------
actions.append(link_action(
    output_path = f"{ROOT}/build/final/lib_gen.a",
    inputs      = [f"{ROOT}/build/libs/mod_b_*.a"],
))

# ---- Phase 7: final app link (waits for both libraries) -------------------
# Concrete inputs — both .a files must exist before the app is produced.
actions.append(link_action(
    output_path = f"{ROOT}/build/final/app",
    inputs      = [
        f"{ROOT}/build/final/lib_static.a",
        f"{ROOT}/build/final/lib_gen.a",
    ],
))

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

expected_total = (
    len(CODEGEN_SRCS)               # codegen tool compiles
    + NUM_STATIC_MODS * FILES_PER_STATIC  # Group A compiles
    + 1                             # codegen tool link
    + 1                             # codegen run
    + NUM_GEN_MODS * FILES_PER_GEN  # Group B compiles
    + NUM_STATIC_MODS               # Group A archives
    + NUM_GEN_MODS                  # Group B archives
    + 1                             # lib_static.a
    + 1                             # lib_gen.a
    + 1                             # app
)
assert len(actions) == expected_total, f"expected {expected_total}, got {len(actions)}"

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------

out_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "playlists" / "stress_build_playlist.json"
out_path.write_text(json.dumps(actions, indent=2) + "\n", encoding="utf-8")

print(f"Generated {len(actions)} actions → {out_path}")
print(f"  {len(CODEGEN_SRCS)} codegen_tool compiles")
print(f"  {NUM_STATIC_MODS * FILES_PER_STATIC} Group A (static) compiles  [{NUM_STATIC_MODS} modules × {FILES_PER_STATIC} files]")
print(f"  1 codegen_tool link")
print(f"  1 codegen run")
print(f"  {NUM_GEN_MODS * FILES_PER_GEN} Group B (generated) compiles  [{NUM_GEN_MODS} modules × {FILES_PER_GEN} files]")
print(f"  {NUM_STATIC_MODS} Group A module archives  (glob inputs)")
print(f"  {NUM_GEN_MODS} Group B module archives  (glob inputs)")
print(f"  1 lib_static.a  (glob input)")
print(f"  1 lib_gen.a     (glob input)")
print(f"  1 app           (concrete inputs)")
