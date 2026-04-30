# fingerprint

Calculate a combined hash (fingerprint) of files matching specified patterns.

## Features

- **Single file & directory fingerprinting** - Compute 16-character hex fingerprints for files or entire directory trees
- **Multiple hash algorithms** - CRC32C (default, fast) or BLAKE3 (cryptographic)
- **Glob pattern filtering** - Include files with patterns like `*.cpp`, `src/**/*.c`, `*.{h,cpp}`
- **Regex filtering** - Extended regex patterns (ECMAScript syntax)
- **Exclusion patterns** - Subtract specific paths or globs (`-e`) from broader inputs
- **List output** - Display per-file hashes in `<hash>\t<path>` format
- **Xattr caching** - Store fingerprints in extended attributes to avoid recomputation
- **Environment variable expansion** - Support `${VAR}` and `$(VAR)` in file paths and .xcfilelist inputs
- **Fingerprint modes** - `default` (content only), `absolute` (includes full paths in hash), `relative` (relative paths in hash - recommended) - non-default modes detect file renames which don't affect sorting
- **Snapshot formats** - Export to TSV, JSON, or plist
- **Compare mode** - Compare current state against baseline snapshots to detect added/removed/modified files

## Usage

```bash
# Fingerprint a single file with CRC32C hash
fingerprint file.txt

# Fingerprint a directory with BLAKE3 hash
fingerprint --hash=blake3 /path/to/dir

# List all files with their hashes
fingerprint --list /path/to/dir

# Filter by glob pattern
fingerprint --list -g '*.cpp' -g '*.h' /path/to/dir

# Filter by regex
fingerprint --list -r 'src/.*\.cpp$' /path/to/dir

# Exclude a directory subtree (pruned during traversal) and a glob of generated files
fingerprint -e src/generated/ -e 'src/**/*.gen.h' /path/to/src

# Force hash recalculation on each run (on is default for cashing the hash in file's xattr)
fingerprint --xattr=off /path/to/dir

# Save snapshot and compare later
fingerprint -s snapshot.json /path/to/dir
fingerprint -c snapshot.json /path/to/dir
```

## Output Formats

- **Default** - Produce single fingerprint for directory/file
- **List (`-l`)** - Print hashes per-file: `<hash>\t<relative/path>` (8-char for CRC32C, 16-char for BLAKE3)
- **Snapshot (`-s`)** - save to tsv, json, or plist file with file metadata and fingerprint parameters

## Options

| Option | Description |
|--------|-------------|
| `-g, --glob` | Glob pattern (repeatable, case-insensitive) |
| `-r, --regex` | Extended regex pattern (ECMAScript) |
| `-e, --exclude` | Path or glob to exclude from fingerprinting (repeatable, supports `${VAR}`) |
| `-H, --hash` | Hash algorithm: `crc32c` (default) or `blake3` |
| `-F, --fingerprint-mode` | Path handling: `default`, `absolute`, or `relative` |
| `-X, --xattr` | Caching: `on` (default), `off`, `refresh`, or `clear` |
| `-I, --inputs` | Read paths from file (supports .xcfilelist) |
| `-l, --list` | List all files with hashes |
| `-s, --snapshot` | Save snapshot to file |
| `-c, --compare` | Compare against snapshot |
| `-v, --verbose` | Verbose output with timing |

## Glob Behavior

- Patterns without `/` match filenames only (any directory depth)
- Patterns with `/` match relative file paths
- Supports `**` for recursive matching (globstar)
- Supports `?`, `*`, `[abc]`, `[!abc]`, and `{a,b}` brace expansion

## Excluding paths

`-e` / `--exclude` subtracts paths from the set being fingerprinted. Useful for narrow exceptions inside broad inputs (e.g. excluding generated files under a source directory).

There are three accepted shapes. Relative paths resolve against the **currently searched directory**. Note: this is **different from "gate"** tool.

| Shape | Example | Behavior |
|-------|---------|----------|
| Literal file or directory | `src/generated/`, `build/cache.bin` | Exact match for files; whole subtree pruned during traversal for directories. |
| Glob containing `/` | `src/**/*.gen.h`, `vendor/*/internal/*` | Matched against the absolute file path. The literal directory prefix is resolved to absolute; the glob suffix is preserved. |
| Glob without `/` | `*.gen.h`, `*.tmp` | Gitignore-style: matches the basename at any directory depth. |

```sh
# Mix all three: prune a subtree, exclude all *.gen.h anywhere, and exclude one file
fingerprint -e src/generated/ -e '*.gen.h' -e build/cache.bin /path/to/src
```

Excludes are evaluated *after* `-g`/`-r` filters: a file matched by `--glob` but also by `--exclude` is dropped. Excludes are recorded in snapshot metadata so a snapshot saved with one exclude set is distinguishable from another.

## Xattr Caching

When `--xattr=on` (default), fingerprints are stored in extended attributes:
- `public.fingerprint.crc32c` for CRC32C
- `public.fingerprint.blake3` for BLAKE3

On subsequent runs, cached values are used if file inode, size, and mtime are unchanged. This significantly speeds up repeated fingerprinting.