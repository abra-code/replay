# replay MCP Tools Reference

Describes the 14 tools exposed by `replay --mcp-server`, design choices, and error codes.

---

## Tool summary

| Tool | Required params | Extended? | Notes |
|------|----------------|:---------:|-------|
| `read_file` | `path` | | Returns UTF-8 text or `blob` (base64) for binary. Max 10 MB. |
| `read_multiple_files` | `paths` | | Up to 50 files. Errors inline per file. |
| `write_file` | `path`, `content` | | Creates parent dirs automatically. |
| `create_directory` | `path` | | `mkdir -p` semantics. |
| `list_directory` | `path` | | Each entry prefixed `[FILE]` or `[DIR]`. |
| `directory_tree` | `path` | | JSON tree. Optional `depth` (default 10; 0 = root only). |
| `move_file` | `source`, `destination` | | Creates destination parent dirs. |
| `delete_file` | `path` | | Recursive for directories. |
| `get_file_info` | `path` | | type, size, modified timestamp, permissions. |
| `list_allowed_directories` | — | | Lists configured dirs with access mode. |
| `search_files` | `path`, `pattern` | | Filename glob under root. Optional `excludePatterns`. Max 1000. |
| `edit_file` | `path`, `edits` | ✓ | Structured edits: literal/regex, backrefs, limit, caseInsensitive. |
| `edit_files` | `paths`, `edits` | ✓ | Multi-file edit with glob expansion. |
| `glob_search` | `path` | ✓ | Multi-pattern array, brace alternation `{a,b}`, `excludePatterns`. |
| `execute_command` | `command` | ✓ | Shell execution, hard-sandboxed via Seatbelt when `--sandbox` is active. |

---

## Standard filesystem tools (compatible with MCP filesystem spec)

### Divergences from the MCP filesystem spec

- **`edit_file`**: the MCP spec takes a unified diff; replay's version takes structured edit operations (see below). Same tool name, different interface.
- **`read_file`**: binary files are returned as a `blob` content item (base64 + mimeType) rather than an error or escaped text, which is an extension beyond the spec.
- **`search_files`**: spec defines a content-search tool; replay's implementation is a filename/glob search, not a full-text grep. The `glob_search` extended tool covers the same ground with more options.

---

## Extended tools (replay-specific capabilities)

### `edit_file` — single-file text editor

Required: `path`, `edits` (array).  
Optional: `dryRun` (default false).

Each edit item has:
- `oldText` (required) — literal string or POSIX ERE pattern
- `newText` — replacement (default empty). Supports `\1`–`\9` back-references for regex.
- `limit` — max replacements (default 1; 0 = unlimited)
- `regex` — treat `oldText` as ERE pattern (default false)
- `caseInsensitive` — case-insensitive match (default false)

Writes atomically (temp file + rename). Returns -32603 if any edit with `limit > 0` matched fewer than `limit` times.

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
- Glob that matches no files → -32002 error (whole request fails)
- Glob-matched files outside allowed dirs → -32001 error (whole request fails)
- Per-file edit failure → that file's content item contains `"path: [error CODE] message"` (other files still succeed; no JSON-RPC level error)
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

| Dimension | `ExcecuteTool` (action) | `run_command_mcp` (MCP) |
|-----------|------------------------|------------------------|
| Invocation | Binary path + args array | `/bin/sh -c <string>` |
| stdout | Streamed to OutputSerializer | Captured and returned in response |
| stderr | Captured only on failure | Always captured |
| Timeout | None | SIGTERM + SIGKILL with 3s grace |
| Output sink | replay's ordered output pipeline | JSON-RPC `result.content` |
| Failure signal | Sets `ReplayContext.lastError` | `result.isError: true` + exit code |

---

### `glob_search` — multi-pattern file search

Required: `path`.  
Optional: `patterns` (array), `pattern` (single string), `excludePatterns`, `max` (default 1000).

Uses replay's glob engine which supports `**`, `?`, `{a,b}` alternation. Accepts either a `patterns` array or a single `pattern` string.

**vs. `search_files`**: `search_files` is the MCP-standard tool name (single pattern, standard glob). `glob_search` is the extended version adding multi-pattern arrays, brace alternation, and a `max` cap. AI agents that inspect schemas will discover the richer capabilities from `glob_search`'s description and schema.

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

Configured via `--allow-write <dir>` (read+write) and `--allow-read <dir>` (read-only) flags at server startup. Every path in every tool call is validated against these lists. `/` is not a valid allowed directory.
