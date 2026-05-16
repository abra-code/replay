# Stress Build Playlist — Design Document

## Overview

`stress_build_playlist.json` is a static, 1750-action playlist that simulates a
multi-module C project build.  Its purpose is to make replay's dependency
analysis and concurrent scheduling **measurably visible** — the individual
actions are near-instant `touch` calls, so elapsed time is dominated by the
scheduling algorithm, not I/O.

## How to Run

```sh
# Build replay first
./build.sh

# Option A: run directly (set STRESS_ROOT to any writable temp dir)
STRESS_ROOT=$(mktemp -d) build/Release/replay test/stress_build_playlist.json

# Option B: run through the Python harness (handles workspace creation + checks)
python3 test/test_replay_stress_playlist.py

# Option C: regenerate the playlist with different scale
python3 test/generate_stress_playlist.py   # overwrites stress_build_playlist.json
```

## Build Structure

### Module Groups

| Group | Count | Files/mod | Total files | External deps |
|-------|-------|-----------|-------------|---------------|
| A (static)    | 60   | 20 | 1 200 | None — runs immediately       |
| codegen tool  | 1    | 5  | 5     | None — runs immediately       |
| B (generated) | 30   | 15 | 450   | codegen.stamp (sequential)    |

### Action Count Breakdown

```
Phase 1 (immediately concurrent)
  5    codegen_tool compile  (src/codegen_tool/src/*.c → build/codegen_tool/obj/*.o)
  1200 Group A compile       (src/static/mod_a_NNN/src/file_MM.c → build/static/mod_a_NNN/obj/file_MM.o)

Phase 2 (waits for phase 1)
  1    codegen_tool link     (build/codegen_tool/obj/*.o → build/codegen_tool/codegen_tool)
                             concrete inputs — FileTree dependency chain

  60   Group A module archives (build/static/mod_a_NNN/obj/**/*.o → build/libs/mod_a_NNN.a)
                               glob inputs — ConnectGlobDependencies Case 2

Phase 3 (waits for codegen_tool link only)
  1    codegen run           (build/codegen_tool/codegen_tool → build/generated/codegen.stamp)
                             concrete input — FileTree chain

Phase 4 (waits for phase 3)
  450  Group B compile       (src/gen/mod_b_NNN/src/file_MM.c + codegen.stamp
                              → build/gen/mod_b_NNN/obj/file_MM.o)
                             codegen.stamp is a concrete input; FileTree links
                             codegen_run → all 450 gen compiles

Phase 5 (waits for phase 4)
  30   Group B module archives (build/gen/mod_b_NNN/obj/**/*.o → build/libs/mod_b_NNN.a)
                               glob inputs

Phase 6 (waits for phases 2 + 5)
  1    lib_static.a          (build/libs/mod_a_*.a → build/final/lib_static.a)
                             glob input — matches all 60 Group A archives
  1    lib_gen.a             (build/libs/mod_b_*.a → build/final/lib_gen.a)
                             glob input — matches all 30 Group B archives

Phase 7 (waits for phase 6)
  1    app                   (lib_static.a + lib_gen.a → build/final/app)
                             concrete inputs

TOTAL: 1 750 actions
```

## Dependency Graph

```
  [codegen_tool compiles ×5] ───────────────────┐
          │ (concrete: 5 obj files)             │
          ▼                                     │ (concurrent start)
  [codegen_tool link ×1]                        │
          │ (concrete: codegen_tool binary)     │
          ▼                                     │
  [codegen run ×1]        [Group A compiles ×1200, concurrent]
          │ (concrete: codegen.stamp)                  │
          ▼                                            │ (glob: mod_a_NNN/obj/**/*.o)
  [Group B compiles ×450, concurrent]          [Group A archives ×60, concurrent]
          │ (glob: mod_b_NNN/obj/**/*.o)               │
          ▼                                            │
  [Group B archives ×30, concurrent]                   │
          │ (glob: mod_b_*.a)         (glob: mod_a_*.a)│
          ▼                                            ▼
  [lib_gen.a ×1] ────────────────────────── [lib_static.a ×1]
          │ (concrete)                        │ (concrete)
          └──────────────┬────────────────────┘
                         ▼
                      [app ×1]
```

### Critical Path

The longest sequential chain determines minimum runtime:

```
codegen_tool compile (1 touch)
  → codegen_tool link (1 touch)
    → codegen run (1 touch)
      → Group B compile (1 touch, any one of 450)
        → Group B archive (1 touch, any one of 30)
          → lib_gen.a (1 touch)
            → app (1 touch)

7 sequential stages, rest is fully parallel.
```

At the same time, Group A's critical path is:
```
Group A compile (1 touch) → Group A archive (1 touch) → lib_static.a (1 touch) → app
= 4 sequential stages  ← shorter, not the bottleneck
```

The codegen chain (7 stages) is the critical path.

## Dependency Detection Algorithm Analysis

### ConnectGlobDependencies Complexity

The playlist has 92 tasks with glob inputs:

| Consumer glob pattern                         | Matches |
|-----------------------------------------------|---------|
| `build/static/mod_a_NNN/obj/**/*.o`  (×60)   | 20 producers each |
| `build/gen/mod_b_NNN/obj/**/*.o`     (×30)   | 15 producers each |
| `build/libs/mod_a_*.a`               (×1)    | 60 producers |
| `build/libs/mod_b_*.a`               (×1)    | 30 producers |

**Case 2** (concrete output → glob input) dominates:
```
92 consumers × 1750 producers × 1 output each
= 161,000 GetPathForNode + concrete_matches_glob calls
```

Most calls fail quickly on path prefix mismatch (e.g., `build/gen/` ≠
`build/static/`), but the glob pattern is compiled anew for every call —
an O(n²) pressure point visible in Instruments.

### FileTree Scale

- **Output nodes inserted**: 1 750 (one per action)
- **Concrete input nodes inserted**: ~2 260 total
  - 5 codegen_tool .o files (for codegen_tool link)
  - 1 codegen_tool binary (for codegen run)
  - 1 codegen.stamp (for each of 450 Group B compiles = 450 refs, but 1 node)
  - 2 final library paths (for app)
- **Total unique FileTree nodes**: ~1 753 (many input paths alias to existing nodes)

`ConnectImplicitProducers` walks ~1 753 nodes; its cost is linear in tree depth
and node count.

### ConnectDynamicInputsForScheduler

Iterates all 1 750 tasks; for each:
- codegen_tool link: 5 concrete inputs → 5 producer lookups → linked
- codegen run: 1 concrete input → 1 producer lookup → linked
- Group B compiles (×450): 2 concrete inputs → 2 lookups each (1 static, 1 dynamic)
- All others (Group A compiles, archives, lib links): 0 concrete inputs (or static)

Complexity: O(total_concrete_input_nodes) — fast, dominated by Group B.

## Signpost Instrumentation

replay emits `os_signpost` intervals to the `com.abracode.replay / scheduler`
log subsystem.  To view them:

1. Open **Instruments.app** → **os_signpost** template.
2. Run: `STRESS_ROOT=$(mktemp -d) xcrun xctrace record --template 'Time Profiler' --launch -- build/Release/replay test/stress_build_playlist.json`
3. Or attach Instruments to a running replay process.

Key intervals to look for:

| Interval name                  | Location              | What it measures |
|--------------------------------|-----------------------|------------------|
| `TaskProxyBuild`               | ReplayTask.mm         | JSON → TaskProxy objects (1 750 allocations + FileTree inserts) |
| `ConnectImplicitProducers`     | SchedulerMedusa.mm    | FileTree walk for parent-dir → child-file edges |
| `ConnectGlobDependencies`      | SchedulerMedusa.mm    | 161 K glob_match calls for Case 2 |
| `ConnectDynamicInputs`         | SchedulerMedusa.mm    | producer lookup for 450 × 2 concrete inputs |
| `SchedulerExecution`           | SchedulerMedusa.mm    | GCD-based concurrent task execution |

## Known Performance Opportunities Revealed by This Test

1. **`concrete_matches_glob` pattern re-compilation**: A `glob::glob g(pattern)`
   object is constructed per call inside `ConnectGlobDependencies`. With 92
   patterns checked against 1 750 producers, the pattern is re-compiled 1 750
   times each. Caching the compiled pattern per consumer loop iteration would
   reduce this to 92 compilations.

2. **`GetPathForNode` path reconstruction**: Called for every producer output in
   Case 2, walking up the FileTree to reconstruct the full path string. The
   reconstructed paths could be cached in the FileNode or computed once up-front.

3. **O(n²) consumer × producer scan**: For very large playlists (10K+ actions),
   a prefix-trie on producer output paths could skip whole subtrees when a
   consumer's glob concrete prefix doesn't match.

## File Layout in ${STRESS_ROOT}

```
src/
  codegen_tool/src/           ← 5 mock .c files
  static/mod_a_NNN/src/       ← 60 × 20 mock .c files
  gen/mod_b_NNN/src/          ← 30 × 15 mock .c files

build/
  codegen_tool/
    obj/                      ← 5 .o files (touch-created)
    codegen_tool              ← mock binary
  generated/
    codegen.stamp             ← dependency sentinel
  static/mod_a_NNN/obj/       ← 20 .o files per module
  gen/mod_b_NNN/obj/          ← 15 .o files per module
  libs/
    mod_a_NNN.a               ← 60 module archives
    mod_b_NNN.a               ← 30 module archives
  final/
    lib_static.a
    lib_gen.a
    app
```
