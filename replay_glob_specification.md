# Glob Specification for Replay Input/Output Files

## Glob Applicability per Action

| Action | Param | Glob? | Rationale |
|--------|-------|-------|-----------|
| **clone** | `from` | YES | Copy matching files |
| **clone** | `to` | NO | Must be a concrete destination path |
| **clone** | `items` | YES | Each item in the array could be a glob |
| **clone** | `destination directory` | NO | Must be concrete |
| **move** | `from` | YES | Move matching files |
| **move** | `to` | NO | Must be concrete |
| **move** | `items` | YES | Each item could be a glob |
| **move** | `destination directory` | NO | Must be concrete |
| **hardlink** | `from` | YES | Link matching files |
| **hardlink** | `to` | NO | Must be concrete |
| **hardlink** | `items` | YES | Each item could be a glob |
| **hardlink** | `destination directory` | NO | Must be concrete |
| **symlink** | `from` | NO | Symlink target must be a single concrete path |
| **symlink** | `to` | NO | Symlink location must be concrete |
| **create file** | `file` | NO | Creating a specific file |
| **create directory** | `directory` | NO | Creating a specific directory |
| **delete** | `items` | YES | Delete matching files |
| **execute** | `tool` | NO | Must be a specific executable |
| **execute** | `arguments` | NO | Arguments are opaque strings for the tool |
| **execute** | `inputs` | YES | Dependency declaration - pattern matching |
| **execute** | `exclusive inputs` | YES | Dependency declaration - pattern matching |
| **execute** | `outputs` | YES | Dependency declaration - pattern matching |
| **echo** | `text` | NO | Just text output |

## Two Distinct Uses of Glob

### 1. Operational Globs

Actions: clone/move/hardlink/delete `from`/`items`

These expand at execution time against the real filesystem to determine *which files to act on*. The glob resolves to a concrete file list before the operation runs.

### 2. Declarative Globs

Actions: execute `inputs`/`outputs`/`exclusive inputs`

These are purely for dependency analysis. glob-cpp's textual matching is perfect here. Task A declaring output `build/**/*.o` and Task B declaring input `build/foo/bar.o` -- the dependency engine needs to detect that `build/foo/bar.o` matches `build/**/*.o`, so B depends on A. No filesystem access needed.

## Dependency Detection Between Path Specifications

Three cases arise when comparing an output spec from task A against an input spec from task B:

### Case 1: Concrete vs Concrete

Both are literal paths. Simple string equality. This is the existing behavior.

### Case 2: Concrete vs Glob

One side is a literal path, the other is a glob pattern. Use `glob_match(concrete, glob)` from glob-cpp. This is straightforward and gives an exact answer.

### Case 3: Glob vs Glob -- NFA Product Construction

When both sides are glob patterns, the engine determines overlap using a **two-level NFA product construction** algorithm. This gives exact results for the supported pattern class.

Reference implementation: `globoverlap/GlobOverlap.h` with test suite `test_glob_pattern_overlap.sh`.

#### Supported Glob Features

| Feature | Syntax | Supported | Notes |
|---------|--------|-----------|-------|
| Star | `*` | YES | Matches any chars within a segment (not `/`) |
| Question mark | `?` | YES | Matches any single char |
| Character set | `[abc]`, `[a-z]` | YES | Positive and negative sets |
| Braces | `{a,b,c}` | YES | Pre-expanded before NFA construction |
| Globstar | `**` | YES | Handled via segment-level DP |
| Literals | `foo.o` | YES | Exact character matching |
| Extended globs | `*(...)`, `+(...)`, `?(...)`, `@(...)`, `!(...)` | NO | Conservative fallback with warning |

#### Algorithm Overview

The algorithm operates at two levels:

**Level 1: Segment-level DP (handles `**`)**

Both patterns are split on `/` into segments. A dynamic programming matrix `dp[i][j]` tracks whether pattern A's first `i` segments and pattern B's first `j` segments can describe overlapping path prefixes.

Transitions from `dp[i][j] = true`:
- A[i] is `**`: advance A past `**` (matches 0 segments) → `dp[i+1][j]`
- B[j] is `**`: advance B past `**` (matches 0 segments) → `dp[i][j+1]`
- A[i] is `**`, B[j] is not: A's `**` absorbs segment B[j] matches → `dp[i][j+1]`
- A[i] is not `**`, B[j] is `**`: B's `**` absorbs segment A[i] matches → `dp[i+1][j]`
- Neither is `**`: if segment-level overlap is proven → `dp[i+1][j+1]`

Result: `dp[m][n]` indicates whether the full patterns can overlap.

**Level 2: Character-level NFA product (per-segment overlap)**

For each pair of non-`**` segments, the engine builds NFAs using glob-cpp's Lexer → Parser → AstConsumer pipeline and performs product automaton construction with BFS.

The glob-cpp NFA transition model:
- `CHAR`: consumes matching char via `next[0]`. No epsilon.
- `QUESTION`: consumes any char via `next[0]`. No epsilon.
- `MULT` (`*`): consumes any non-`/` char via `next[0]` (self-loop). Epsilon exit via `next[1]`.
- `SET`: consumes set-matching char via `next[0]`. No epsilon.
- `MATCH`: accepting state. No transitions.
- `FAIL`: rejecting state. No transitions.

Product BFS explores `(state_A, state_B)` pairs:
1. Both in MATCH state → intersection non-empty → overlap proven.
2. Either in FAIL → dead product state, skip.
3. Epsilon transitions (MULT only): advance one NFA's `next[1]` independently.
4. Consuming transitions: probe for common accepted characters. If found, advance both via `next[0]`.

Character commonality is determined by fast-path classification (QUESTION/MULT accept all chars) or by probing all 255 byte values against both states' `Check()` methods.

**Brace pre-expansion**

Before NFA construction, brace groups `{a,b,c}` (including nested braces) are expanded into separate patterns. Each combination is checked independently. This avoids GROUP states in the NFA, which would require the conservative fallback.

#### Extended Glob Handling

Extended glob patterns produce GROUP states in glob-cpp's NFA. GROUP states consume variable-length substrings via embedded sub-automata, which breaks the single-character product construction model.

| Extended Glob | Meaning | Why unsupported |
|---------------|---------|-----------------|
| `@(a\|b)` | Exactly one of a or b | Equivalent to `{a,b}` -- use braces instead |
| `?(a\|b)` | Zero or one of a or b | Could be pre-expanded but adds complexity for no practical gain |
| `*(a\|b)` | Zero or more repetitions | Infinite expansions, cannot enumerate |
| `+(a\|b)` | One or more repetitions | Infinite expansions, cannot enumerate |
| `!(a\|b)` | Negation | Cannot express as union of positive patterns |

When a GROUP state is encountered during NFA product construction, the engine:
1. Prints a warning to stderr: `"warning: extended glob group detected, assuming overlap (conservative)"`
2. Returns overlap for that segment comparison.

However, other segments in the pattern can still prove non-overlap. For example, `build/*(src|lib)/*.o` vs `build/test/*.h` triggers the warning for the middle segment but correctly reports no overlap because `*.o` vs `*.h` is resolved exactly by the NFA product.

**Recommendation:** Do not use extended glob syntax in replay playlists. Use `{a,b}` brace expansion instead of `@(a|b)`, and restructure patterns to avoid `*(...)`, `+(...)`, `?(...)`, and `!(...)`. Standard glob features (`*`, `?`, `[...]`, `{...}`, `**`) cover all practical build-system path patterns and are handled exactly by the dependency engine.

#### Properties

- **Exact for supported patterns**: The NFA product construction gives mathematically correct answers for patterns using `*`, `?`, `[...]`, `{...}`, `**`, and literals. No false positives or false negatives within this class.
- **Conservative for unsupported patterns**: Extended globs fall back to assuming overlap. This may reduce concurrency but never produces incorrect execution order.
- **No filesystem access**: The entire analysis is purely textual. Patterns are compared structurally; files do not need to exist on disk.

### Guidance for Playlist Authors

To help the dependency engine maximize concurrency:

1. **Use distinct directory prefixes** for unrelated outputs. The engine proves non-overlap when root directory segments differ.
   ```json
   { "outputs": ["build/module-a/**/*.o"] }
   { "outputs": ["build/module-b/**/*.o"] }
   ```

2. **Use distinct file extensions** for different artifact types. The NFA product detects extension mismatches even when directory structures overlap.
   ```json
   { "outputs": ["build/**/*.o"] }
   { "inputs": ["build/**/*.h"] }
   ```

3. **Avoid `**` when a single `*` suffices**. Fixed-depth patterns enable tighter segment matching.
   ```json
   { "outputs": ["build/obj/*.o"] }
   ```
   is equivalent in precision to `build/**/*.o` for flat directories but produces simpler analysis.

4. **Use concrete paths when possible**. A concrete path matched against a glob (Case 2) gives an exact answer with a single `glob_match` call.
   ```json
   { "outputs": ["build/obj/main.o", "build/obj/util.o"] }
   ```

5. **Use `{a,b}` instead of `@(a|b)`**. Braces are pre-expanded and handled exactly; extended globs trigger conservative fallback.

## Open Questions

- **symlink `from`**: Currently NO glob support since a symlink points to one target, but could argue for expanding a glob to create multiple symlinks.
