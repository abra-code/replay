# replay MCP Tools Reference

Describes the 15 tools exposed by `replay --mcp-server`, design choices, and error codes.

---

## Tool summary

| Tool | Required params | Extended? | Notes |
|------|----------------|:---------:|-------|
| `read_file` | `path` | | Returns UTF-8 text or `blob` (base64) for binary. Max 10 MB. |
| `read_multiple_files` | `paths` | | Up to 50 files; literal paths only (globs not expanded). Errors inline per file. |
| `write_file` | `path`, `content` | | Creates parent dirs automatically. |
| `create_directory` | `path` | | `mkdir -p` semantics. |
| `list_directory` | `path` | | Each entry prefixed `[FILE]` or `[DIR]`. |
| `directory_tree` | `path` | ✓ | JSON tree. Optional `depth` (omit = unlimited; 0 = root only; `find -maxdepth` semantics). |
| `move_file` | `source`, `destination` | | Creates destination parent dirs. |
| `delete_file` | `path` | | Recursive for directories. |
| `get_file_info` | `path` | | type, size, modified timestamp, permissions. |
| `list_allowed_directories` | — | | Lists configured dirs with access mode. |
| `search_files` | `directory`, `nameContains` | | Case-insensitive literal substring match against basenames. No result cap. `nameContains` is not a glob or regex. Legacy `path`/`pattern`/`excludePatterns` accepted as silent aliases. |
| `edit_file` | `path`, `edits` | ✓ | Structured edits: literal/regex, backrefs, limit, caseInsensitive. |
| `edit_files` | `paths`, `edits` | ✓ | Multi-file edit with glob expansion. |
| `glob_search` | `directory`, `globs` | ✓ | Filename-glob search; `globs` array, brace alternation `{a,b}`, `excludeGlobs`. Returns files only (not directories). |
| `grep_files` | `regex` | ✓ | Content search (grep), always POSIX ERE. Requires `directory` and/or `globs`. Case-insensitive, context lines. |
| `execute_command` | `command` | ✓ | Shell execution, hard-sandboxed via Seatbelt when `--sandbox` is active. |

---

## Standard filesystem tools (compatible with MCP filesystem spec)

### Divergences from the MCP filesystem spec

- **`edit_file`**: the MCP spec takes `oldText`/`newText` structured edits (same as replay). replay adds `isRegex`, `caseInsensitive`, `limit`, and back-references on top. `dryRun` returns a unified diff (standard behavior). Whitespace-normalized matching (standard MCP behavior) is used as a fallback for literal edits when exact match fails.
- **`read_file`**: binary files are returned as a `blob` content item (base64 + mimeType) rather than an error or escaped text, which is an extension beyond the spec.
- **`search_files`**: standard MCP defines filename pattern matching (case-insensitive substring match against basenames). replay implements this, but renames the params to `directory`/`nameContains`/`excludeGlobs` for clarity (the spec names `path`/`pattern`/`excludePatterns` are still accepted as silent aliases). The content-search capability is provided as the separate `grep_files` extension tool.

---

## Extended tools (replay-specific capabilities)

### `grep_files` — content search (grep-style)

Required: `regex` (the POSIX ERE search pattern). Also required: at least one of `directory` / `globs`.  
Optional: `caseInsensitive`, `contextLines` (default 0, max 50), `maxResults` (default 500, max 10000), `excludeGlobs`.

**The query is always a regex.** There is no boolean flag — `grep_files` is named after grep and behaves like it. For a literal-substring search, escape ERE metacharacters in `regex` (e.g. `\*`, `\.`).

File selection:
- **`directory`** (string) — root directory; searched recursively.
- **`globs`** (array) — file globs. A **relative** glob (e.g. `**/*.sh`) resolves *under* `directory`; an **absolute** glob (starting with `/`) is used as-is. Omit `globs` to search every file under `directory`.
- `directory` and `globs` **compose** — `directory` is the root, `globs` filter within it. (This differs from the old `path`/`paths`, where `paths` silently overrode `path`.)
- Without a `directory`, relative globs resolve under the **project directory** (the first allowed directory; see [Access control](#access-control)) — **never** the process working directory.
- `excludeGlobs` — exclusion globs, honored in every mode.

Output is grep-style `file:linenum:content`. Context lines use `-` separators (`file-linenum-context`). Groups separated by `--`. Binary files are skipped silently. A `[N matches]` footer is always appended. When results are truncated by `maxResults`, a truncation notice is prepended. Candidate paths that resolve outside the allowed directories (e.g. an absolute glob, or a symlink escaping the sandbox) are skipped — not fatal — and reported in a `[N path(s) skipped …]` note. An invalid `regex` is a hard `-32603` error.

**vs. `glob_search`**: `glob_search` finds files by *filename glob*. `grep_files` finds text *inside* files.

**vs. `search_files`**: `search_files` matches file and directory *names* as a substring. `grep_files` searches file *contents*.

---

### `edit_file` — single-file text editor

Required: `path`, `edits` (array).  
Optional: `dryRun` (default false).

Each edit item has:
- `oldText` (required) — text to find. **Standard mode** (no extended flags): tries exact match first, then falls back to whitespace-normalized line matching (strips common leading indent per block, then compares). **Extended mode** (`isRegex: true`): POSIX ERE pattern.
- `newText` — replacement (default empty). In standard mode, indentation of the matched block is preserved. In regex mode, supports `\1`–`\9` back-references.
- `limit` — max replacements (default 1; 0 = unlimited). Extended: limit ≠ 1 disables whitespace-normalized fallback.
- `isRegex` — treat `oldText` as ERE pattern (default false). Extended.
- `caseInsensitive` — case-insensitive match (default false). Extended. Disables whitespace-normalized fallback.

`dryRun: true` reads the file, applies all edits to an in-memory copy, and returns a unified diff (`--- / +++ / @@ ... @@`) without writing. Returns `(no changes)` if the edits produce no difference. If the file does not exist, falls back to listing intended edits.

Writes atomically (temp file + rename). Returns -32603 if any edit with `limit > 0` matched fewer than `limit` times (after exhausting both exact and normalized fallback).

---

### `edit_files` — multi-file editor with glob expansion

Required: `paths` (array of strings), `edits` (array, same schema as `edit_file`).  
Optional: `dryRun` (default false).

`paths` entries are either:
- **Literal absolute paths** — edit exactly that file
- **Absolute glob patterns** (any entry containing `*`, `?`, `{`, `}`, or `[`) — expanded at runtime to all matching files

Design rationale for a separate tool rather than extending `edit_file`:
- A single `path` field that can hold either a literal or a glob is ambiguous from an AI agent's perspective. The agent can't tell from the field name alone that a glob is valid, which degrades auto-discovery.
- `edit_files` (plural) signals clearly in the tool name that multiple files are in scope.
- The response shape differs: `edit_files` returns a `content` array with one item per resolved file; `edit_file` returns a single item. Keeping them separate avoids overloading the response schema.

Behavior:
- Glob that matches no files -> -32002 error (whole request fails)
- Glob-matched files outside allowed dirs -> -32001 error (whole request fails)
- Per-file edit failure -> that file's content item contains `"path: [error CODE] message"` (other files still succeed; no JSON-RPC level error)
- Response: `result.content` is an array with one text item per resolved file

---

### `execute_command` — sandboxed shell execution

Required: `command`.  
Optional: `workingDirectory`, `timeout` (default 30s, max 60s).

Runs `command` via `/bin/sh -c <command>`. Captures both stdout and stderr. Supports any shell syntax: pipes, redirects, environment variable expansion, compound commands.

**Response shape** (differs from all other tools):
- `result.content[0]` — stdout text (or `(no output)` if empty) with `[exit code: N]` footer
- `result.content[1]` — stderr text prefixed `[stderr]\n`, present only when non-empty
- `result.isError: true` — set when exit code is non-zero or command timed out

**`workingDirectory`**: validated against allowed dirs (read permission sufficient). Defaults to the first writable allowed dir, or first readable dir if no writable dir is configured. Passed as `chdir` to the shell process before executing.

**Timeout**: SIGTERM sent at deadline; if the process does not exit within 3 seconds, SIGKILL is sent. Partial stdout/stderr collected up to the kill point are included in the response.

**Output cap**: 512 KB per stream. Excess is truncated with a `[output truncated at 512 KB]` notice.

**Why this tool exists**: For filesystem tools, the server can statically validate every path argument before executing the action — the soft (path-checking) and hard (Seatbelt kernel) sandboxes are equivalent in outcome. Shell commands are opaque to static analysis: a command can access paths via symlinks, subprocesses, eval, or file descriptors without those paths appearing in the command string. Only the Seatbelt kernel sandbox can actually enforce filesystem restrictions for shell execution. When replay is started with `--sandbox`, the sandbox profile is inherited by every child process via `fork`, giving shell commands the same filesystem confinement as all other tools.

**Difference from `ExcecuteTool` (replay action system)**:

| Dimension | `ExcecuteTool` (action) | `ExcecuteToolMCPCore` |
|-----------|------------------------|------------------------|
| Invocation | Binary path + args array | `/bin/sh -c <string>` |
| stdout | Streamed to OutputSerializer | Captured and returned in response |
| stderr | Captured only on failure | Always captured |
| Timeout | None | SIGTERM + SIGKILL with 3s grace |
| Output sink | replay's ordered output pipeline | JSON-RPC `result.content` |
| Failure signal | Sets `ReplayContext.lastError` | `result.isError: true` + exit code |

---

### `glob_search` — filename-glob file search

Required: `directory`, `globs` (array).  
Optional: `excludeGlobs`, `max` (default 1000).

Uses replay's glob engine which supports `**`, `?`, `{a,b}` alternation. `globs` are relative to `directory`. **Returns files only — directories are not included in results**, even when a directory's name matches a glob.

**vs. `search_files`**: `search_files` does a literal substring match against basenames (no glob syntax). `glob_search` interprets `globs` as glob patterns with wildcards and alternation.

**vs. `grep_files`**: `grep_files` searches file *contents*. `glob_search` finds files by *filename glob*.

---

## Capabilities intentionally not exposed as MCP tools

### Symlinks and hardlinks

replay's action system supports `symlink` and `hardlink` operations (`ln -s` / `ln`). These are not exposed as MCP tools because agents can create links via `execute_command` (`ln`, `ln -s`) — the operation does not benefit from the dedicated path-validation wrapper that justifies a standalone tool. Adding them would be surface area with no practical advantage.

### Clone (copy-on-write clone)

Similarly, replay supports `cloneItem` (APFS copy-on-write clone via `clonefile(2)`). Shell-accessible via `cp -c` through `execute_command`.

---

## Error codes

| Code | Meaning |
|------|---------|
| -32700 | Parse error — input is not valid JSON |
| -32601 | Method not found |
| -32602 | Invalid params — missing required field or wrong type |
| -32600 | Invalid request — malformed JSON-RPC envelope |
| -32001 | Path not allowed — outside configured allowed directories |
| -32002 | File not found / glob matched no files |
| -32603 | Internal / edit error — edit pattern not matched, invalid regex, I/O failure |

---

## Concurrency model

The MCP server runs on a GCD concurrent queue (`DISPATCH_QUEUE_CONCURRENT`). Each `tools/call` request is dispatched as an independent block; responses may arrive out of request order. Clients that need ordering guarantees (e.g., write then read the same file) must send sequentially (wait for response before sending next request).

`edit_files` runs all per-file edits synchronously within a single GCD task, so one `edit_files` call is self-contained with respect to file state.

---

## Access control

Configured via `--allow-write <dir>` (read+write) and `--allow-read <dir>` (read-only) flags at server startup. The `read_only`/`read_write` directories of a `--sandbox-profile <file>` JSON are **also** included, so the MCP soft path-check stays in sync with the kernel sandbox (which already honors the profile). The combined list is de-duplicated by canonical path, with a read-write grant superseding a read-only one for the same path. Every path in every tool call is validated against this list. `/` is not a valid allowed directory.

> Paths granted via a profile's raw `extra_rules` (SBPL) cannot be statically extracted and are **not** added to the MCP allowed list — express such dirs with `read_only`/`read_write` if MCP tools need to reach them.

### Project (working) directory

The **first explicit** `--allow-read`/`--allow-write` directory (in command-line order) is treated as the **project (working) directory** for the session; if no CLI dirs are given, the first `read_write` directory from the `--sandbox-profile` is used. It is the conceptual root of the workspace the server is operating on. Tools that accept an optional `directory` use it as the default base: `grep_files`, given relative `globs` and no `directory`, resolves those globs under the project directory. Relative globs are **never** resolved against the process's actual working directory (`getcwd`), which is unspecified for a server launched by an MCP client.
