# gate

Incremental task execution tool. Wraps a command with input/output fingerprinting to skip unchanged work on subsequent runs.

## Usage

```
gate [OPTIONS] -- COMMAND [ARGS...]
```

On first run, gate fingerprints inputs, executes the command, fingerprints outputs, and caches the result. On subsequent runs with the same inputs and outputs unchanged, the command is skipped.

## Options

| Flag | Description |
|------|-------------|
| `-i, --input=PATH` | Input file or directory (repeatable) |
| `-o, --output=PATH` | Output file (repeatable) |
| `-I, --input-list=FILE` | Read input paths from FILE, one per line (repeatable) |
| `-O, --output-list=FILE` | Read output paths from FILE, one per line (repeatable) |
| `-E, --env-list=FILE` | Fingerprint env vars listed in FILE (repeatable) |
| `-S, --signature-key=KEY` | Additional string for task signature (repeatable) |
| `-c, --cache-dir=DIR` | Cache directory (default: `.gate-cache`) |
| `-C, --cache-format=FMT` | Cache format: `plist` (default) or `json` |
| `-H, --hash=ALGO` | Hash algorithm: `crc32c` (default) or `blake3` |
| `-f, --force` | Force execution, ignore cache (still updates cache after) |
| `--dry-run` | Report hit/miss without executing |
| `-v, --verbose` | Verbose output |
| `-h, --help` | Print usage |
| `-V, --version` | Print version |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Cache hit (skipped) or command succeeded |
| non-zero | Command's own exit code on failure |
| 2 | Gate error (bad arguments, missing inputs, etc.) |

## Examples

### Basic usage

```sh
# First run: executes cp
gate -i src/main.c -i src/util.h -o build/main.o -- gcc -c src/main.c -o build/main.o

# Second run: skips (inputs and output unchanged)
gate -i src/main.c -i src/util.h -o build/main.o -- gcc -c src/main.c -o build/main.o
```

### Using file lists

```sh
gate -I inputs.txt -O outputs.txt -- make build
```

Where `inputs.txt` contains one path per line. Lines starting with `#` are comments.

### Check without executing

```sh
gate --dry-run -i src/main.c -o build/main.o -- gcc -c src/main.c -o build/main.o
# Prints: "gate: cache hit, skipping: ..." or "gate: cache miss, would execute: ..."
```

### Force re-execution

```sh
gate -f -i src/main.c -o build/main.o -- gcc -c src/main.c -o build/main.o
```

### JSON cache for inspection

```sh
gate -C json -i src/main.c -o build/main.o -- gcc -c src/main.c -o build/main.o
cat .gate-cache/cache.json
```

### Run-once tasks (no outputs)

```sh
gate -i config.yaml -- deploy.sh
```

The command runs once per unique input state. No outputs are tracked — gate caches the fact that the command ran successfully.

### Directory inputs

When a directory is passed as an input, gate recursively fingerprints all files within it:

```sh
gate -i src/ -o build/output.o -- make build
```

Any change to any file inside `src/` (including nested subdirectories) will trigger re-execution.

## Glob patterns in inputs and outputs

You can use glob patterns directly in `-i` / `--input` and `-o` / `--output` arguments (and inside `-I` / `-O` file lists if not shared with with Xcode, because Xcode does not support glob).

Glob pattern matching is done with [glob-cpp library](https://github.com/alexst07/glob-cpp) which supports almost all glob features, including recursive `**/` (aka globstar).

**Examples:**

```sh
# Input glob — all C++ files under src/
gate -i "src/**/*.cpp" -i "include/**/*.h" -o "build/app" -- make build

# Output glob — match multiple generated object files
gate -i "src/main.c" -o "build/*.o" -- gcc -c src/main.c -o build/main.o

# Relative glob (resolved from current working directory)
gate -i "src/**/*.rs" -o "target/release/mybin" -- cargo build --release

# Mix of plain paths and globs
gate -i src/config.yaml -i "src/**/*.cpp" -o "build/*.o" -- make build
```

**How glob resolution works:**

- `gate` tool first checks whether the exact string exists on disk as a file or directory.
- If the literal path exists, it is treated as a plain path (even if it contains `*`, `?`, `[` or `{` characters).
- If the literal path does **not** exist and contains glob metacharacters, it is interpreted as a glob pattern.
- The pattern is split at the deepest literal directory prefix. Only that directory is traversed, and the remaining part is used as the glob filter.
- For inputs: all matching files are recursively fingerprinted.
- For outputs: all matching files must exist and their fingerprints must match the cached values.

This feature significantly simplifies build rules that deal with many similar source or output files.

## Environment Variable Expansion

All path arguments (`-i`, `-o`, and paths inside `-I`/`-O` file lists) support environment variable expansion using both `${VAR}` and Xcode `$(VAR)` syntax:

```sh
gate -i '${SRCROOT}/src/main.c' -o '$(BUILT_PRODUCTS_DIR)/main.o' -- gcc -c src/main.c -o build/main.o
```

Unset variables expand to empty string.

## Environment Variable Fingerprinting

By default, environment variables are **not** part of gate's fingerprint. Changing untracked env variable will not trigger re-execution unless you explicitly tell gate to track it.

The `-E`/`--env-list` option takes a file where each line contains variable references. `gate` tool expands them and includes the result in the input fingerprint:

```sh
# env_vars.list:
${SDKROOT}
${XCODE_VERSION_ACTUAL}
${PROJECT_GUID}
${TARGET_NAME}
```

```sh
gate -E env_vars.list -i src/main.c -o build/main.o -- gcc -c src/main.c -o build/main.o
```

If any of the listed variables change value between runs, gate produces a different task signature — effectively treating it as a different task that needs to execute. The expanded env text is hashed in memory (no temp files are written), so concurrent gate invocations are safe.

Multiple `-E` files are supported and their contents are concatenated. Lines starting with `#` are comments. Both `${VAR}` and `$(VAR)` syntax are supported.

This is particularly useful in Xcode build scripts where the same source files may need to be rebuilt when the build configuration, SDK, or architecture changes:

```sh
# In an Xcode Run Script Phase:
"${BUILT_PRODUCTS_DIR}/gate" -E "${SRCROOT}/build_env.list" -- "${BUILT_PRODUCTS_DIR}/my_tool"
```

## Xcode Run Script Phase Integration

When used inside an Xcode "Run Script Phase", gate automatically picks up the inputs and outputs declared in the build phase UI. Xcode exports these as environment variables (`SCRIPT_INPUT_FILE_COUNT`, `SCRIPT_INPUT_FILE_N`, `SCRIPT_INPUT_FILE_LIST_COUNT`, `SCRIPT_INPUT_FILE_LIST_N`, and the corresponding `SCRIPT_OUTPUT_FILE_*` variants).

In a Run Script Phase, the invocation can be as simple as:

```sh
"${BUILT_PRODUCTS_DIR}/gate" -- "${BUILT_PRODUCTS_DIR}/my_tool" --arg1 --arg2
```

No `-i`/`-o` flags are needed — gate reads them from the Xcode script phase environment. CLI arguments and Xcode environment variables are additive, so you can declare common inputs in the Xcode UI and add extra inputs (e.g. glob patterns) on the command line.

File lists (`.xcfilelist`) declared in the build phase are also read automatically. Xcode resolves variables in `.xcfilelist` files before exporting them, so the paths gate receives are already absolute.

## Cache Format

Gate supports two cache formats, selectable with `-C`:

- **`plist`** (default) — binary property list. Compact and fast.
- **`json`** — human-readable JSON. Useful for debugging or AI agent inspection.

Formats use separate file extensions within the cache directory. Switching format does not migrate existing entries.

## Task Signature and Cache Layout

Each task gets its own cache file. The filename is a 16-character hex **task signature** derived from selected identity parameters.

Task signature includes:
- Command string
- Input paths (sorted)
- Output paths (sorted)
- Hash algorithm (`-H`)
- Signature keys (`-S`)
- Xcode build environment variables if present: CONFIGURATION, EFFECTIVE_PLATFORM_NAME, ARCHS

Notes:
- the task signature does not include env file content specified with `-E|--env-list`
- if it's desirable to distinguish tasks by some env variable, you can use `-S|--signature-key=${MY_TASK_UNIQUE_ID}`
- if a task (script) in Xcode should be invariant with regard to build settings, before executing `gate` set them to something fixed like: `export CONFIGURATION=""; export EFFECTIVE_PLATFORM_NAME=""; export ARCHS=""` or remove with: `unset CONFIGURATION; unset EFFECTIVE_PLATFORM_NAME; unset ARCHS`

The cache directory contains one file per task: `<signature>.plist` (or `.json`). Different tasks never share a file, so there is no lock contention between unrelated tasks and cleanup is trivial (delete one file).

Changing any identity parameter — different inputs, different command, switching hash algorithms, changing signature key, etc. — produces a different signature and a separate cache file.

## Cache Behavior

A cache **hit** requires all of the following:
1. Cache file for this signature exists
2. Current input fingerprints match the stored values
3. All declared output files exist
4. Current output fingerprints match the stored values

A cache **miss** occurs if any condition fails. On miss, gate executes the command and updates the cache.

Failed commands (non-zero exit) are never cached. Missing outputs after a successful command are treated as an error (exit 2).

## Concurrency

Multiple gate instances can safely share the same cache directory. Each task has its own cache file, so different tasks never contend. Same-task concurrency uses file-level locking: reads use shared locks (`flock LOCK_SH`), writes use exclusive locks (`flock LOCK_EX`), and writes are atomic (temp file + rename).
