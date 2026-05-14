# replay MCP Tool Schemas

Detailed JSON parameter reference for all tools exposed by `replay --mcp-server`.

Each parameter is marked with one of:
- **[std]** — defined in the MCP filesystem specification
- **[ext]** — replay extension beyond the spec
- **[std+]** — standard param with replay-extended semantics

---

## `read_file`

```json
{
  "path": "<string>"           // [std] Absolute path to the file
}
```

**Response:** `result.content[0]` is a `text` item (UTF-8) or a `blob` item (base64 + `mimeType`) for binary.  
**Standard:** Returns text content.  
**[ext]:** Binary files return `blob` type instead of an error.  
**Errors:** `-32001` path not allowed · `-32002` not found · `-32603` read failed

---

## `read_multiple_files`

```json
{
  "paths": ["<string>", ...]   // [std] Array of absolute file paths (max 50)
}
```

**Response:** `result.content` array, one item per file. Each item text is prefixed `path:\ncontent`. Errors appear inline as `path:\n[error: ...]`; the whole call never fails.  
**Errors:** `-32602` missing `paths`

---

## `write_file`

```json
{
  "path":    "<string>",       // [std] Absolute path to write (creates parents)
  "content": "<string>"        // [std] UTF-8 content
}
```

**Response:** `result.content[0].text` = `"Successfully wrote <path>"`.  
**Errors:** `-32001` · `-32602` missing param · `-32603` write failed

---

## `create_directory`

```json
{
  "path": "<string>"           // [std] Absolute path (mkdir -p semantics)
}
```

**Errors:** `-32001` · `-32603` OS error

---

## `list_directory`

```json
{
  "path": "<string>"           // [std] Absolute directory path
}
```

**Response:** One entry per line, prefixed `[FILE]` or `[DIR]`.  
**Errors:** `-32001` · `-32002` not found

---

## `directory_tree`

```json
{
  "path":  "<string>",         // [std] Root directory
  "depth": <integer>           // [ext] Max recursion depth (omit = unlimited; 0 = root only)
}
```

**Response:** `result.content[0].text` is a JSON tree `{name, type, children[]}`.

**`depth` semantics** (`find -maxdepth` convention):
- Omitted → unlimited (full recursive tree, standard MCP behavior)
- `0` → root node only, no children
- `1` → root + immediate children
- `N` → N levels deep

**[std]:** `path` only, no `depth` parameter, full recursive tree is the standard behavior.  
**[ext]:** `depth` parameter to cap recursion.  
**Errors:** `-32001` · `-32002`

---

## `move_file`

```json
{
  "source":      "<string>",   // [std] Absolute source path
  "destination": "<string>"    // [std] Absolute destination path (creates parents)
}
```

**Errors:** `-32001` · `-32002` source not found · `-32603` OS error

---

## `delete_file`

```json
{
  "path": "<string>"           // [std] Absolute path (file or directory, recursive)
}
```

**Errors:** `-32001` · `-32002` not found · `-32603` OS error

---

## `get_file_info`

```json
{
  "path": "<string>"           // [std] Absolute path
}
```

**Response:** Multi-line text: `type: file|directory`, `size: <bytes>`, `modified: <ISO8601>`, `permissions: <octal>`.  
**Errors:** `-32001` · `-32002`

---

## `list_allowed_directories`

```json
{}
```

**Response:** One line per configured directory: `<path> (read-write|read-only)`.

---

## `edit_file`

```json
{
  "path":   "<string>",        // [std] Absolute path to the file
  "edits":  [                  // [std] Array of edit operations applied in sequence
    {
      "oldText":        "<string>",    // [std] Text to find (required)
      "newText":        "<string>",    // [std] Replacement text (default: "")
      "limit":          <integer>,     // [ext] Max replacements (default 1; 0 = unlimited)
      "regex":          <boolean>,     // [ext] Treat oldText as POSIX ERE (default false)
      "caseInsensitive": <boolean>     // [ext] Case-insensitive match (default false)
    }
  ],
  "dryRun": <boolean>          // [std] Preview without writing (default false)
}
```

**Matching strategy per edit item:**
1. **Standard mode** (`regex: false`, `caseInsensitive: false`, `limit: 1`):
   - Try exact substring match first.
   - If not found: try **whitespace-normalized** line match — strips the common leading indent from both `oldText` and the candidate content block, then compares line-by-line. This lets `oldText` be copied from a differently-indented context.
   - On replacement: the original indentation of the matched block is preserved and applied to `newText`.
2. **Extended — regex** (`regex: true`): match with POSIX ERE. `newText` may use `\1`–`\9` back-references. No whitespace-normalized fallback.
3. **Extended — case-insensitive** (`caseInsensitive: true`): case-insensitive literal or (combined with `regex`) regex match. No whitespace-normalized fallback.
4. **Extended — limit** (`limit: 0` = unlimited, `limit: N > 1`): replace up to N occurrences. Whitespace-normalized fallback only applies when `limit: 1`.

**`dryRun: true`:**
- Reads the file, applies all edits to an in-memory copy.
- Returns a unified diff (`--- path / +++ path / @@ ... @@`) without writing.
- Returns `(no changes)` if no edits produce a difference.
- Fallback to listing intended edits if the file does not exist.
- Path validation requires read permission only when `dryRun: true`.

**Response:** `result.content[0].text` = `"Successfully edited <path>"`.  
**Errors:** `-32001` · `-32002` file not found · `-32602` missing param · `-32603` pattern not matched / invalid regex / write failed

---

## `edit_files`

```json
{
  "paths": ["<string>", ...],  // [ext] Absolute paths and/or glob patterns
  "edits": [ ... ],            // [ext] Same schema as edit_file.edits
  "dryRun": <boolean>          // [ext] Default false
}
```

**`paths` entries:**
- Literal absolute path → edits exactly that file.
- Glob pattern (contains `*`, `?`, `{`, `}`, or `[`) → expanded at runtime. Error `-32002` if no files match. Error `-32001` if any match is outside allowed dirs.

**Response:** `result.content` array, one item per resolved file. Per-file edit failures appear as `path: [error CODE] message` inline; the call does not error at JSON-RPC level.

Same matching strategy and `dryRun` behavior as `edit_file`.

**Errors:** `-32001` · `-32002` glob no match · `-32602` missing param

---

## `search_files`

```json
{
  "path":            "<string>",    // [std] Root directory (walk recursively)
  "paths":           ["<string>", ...], // [ext] Explicit paths/globs (overrides path)
  "pattern":         "<string>",    // [std] Content search pattern (required)
  "regex":           <boolean>,     // [std+] POSIX ERE (default false)
  "caseInsensitive": <boolean>,     // [std+] Case-insensitive (default false)
  "contextLines":    <integer>,     // [ext] Lines before/after each match, grep -C style (default 0, max 50)
  "maxResults":      <integer>,     // [ext] Total match cap (default 500, max 10000)
  "excludePatterns": ["<string>", ...] // [ext] Glob exclusions (applied with path root dir)
}
```

**Standard MCP:** `path` + `pattern` + `regex`. replay adds `paths`, `caseInsensitive`, `contextLines`, `maxResults`, `excludePatterns`.

**`path` vs `paths`:**
- `path` (string) — root directory; all files beneath are searched recursively (standard).
- `paths` (array) — explicit absolute paths and/or glob patterns; overrides `path` (extended).

**Output format:** grep-style lines:
```
/abs/path/file:5:matching line content
/abs/path/file-4-context line before
/abs/path/file-6-context line after
--
```
Match lines use `:` separators; context lines use `-`. Groups are separated by `--`. Footer: `[N matches]`. Truncated results prepend a notice.

Binary files (containing null bytes in the first 4 KB) are skipped silently.

**Errors:** `-32001` · `-32002` glob no match · `-32602` missing `pattern`

---

## `glob_search`

```json
{
  "path":            "<string>",    // [ext] Root directory (required)
  "pattern":         "<string>",    // [ext] Single glob pattern (alternative to patterns)
  "patterns":        ["<string>", ...], // [ext] Multiple glob patterns relative to path
  "excludePatterns": ["<string>", ...], // [ext] Exclusion globs
  "max":             <integer>      // [ext] Result cap (default 1000; 0 = unlimited)
}
```

Finds files by **filename pattern**, not content. Glob syntax: `**` (recursive), `?` (single char), `{a,b}` (alternation). Either `pattern` (string) or `patterns` (array) is required.

**Errors:** `-32001` · `-32602` missing patterns

---

## `execute_command`

```json
{
  "command":          "<string>",   // [ext] Shell command (runs via /bin/sh -c)
  "workingDirectory": "<string>",   // [ext] Absolute working dir (must be in allowed dirs)
  "timeout":          <integer>     // [ext] Seconds (default 30, max 60)
}
```

**Response:**
- `result.content[0]` — stdout (or `(no output)`) with `[exit code: N]` footer.
- `result.content[1]` — stderr prefixed `[stderr]\n`, present only when non-empty.
- `result.isError: true` — set on non-zero exit or timeout.

**`workingDirectory`:** Defaults to first writable allowed dir, then first readable dir. Requires at least read permission.

**Timeout:** SIGTERM at deadline + SIGKILL after 3-second grace. Partial output included.

**Output cap:** 512 KB per stream; excess truncated with notice.

**Errors:** `-32001` workdir not allowed · `-32602` missing `command`

---

## Error code reference

| Code | Meaning |
|------|---------|
| -32700 | Parse error — input is not valid JSON |
| -32601 | Method not found |
| -32602 | Invalid params — missing required field or wrong type |
| -32600 | Invalid request — malformed JSON-RPC envelope |
| -32001 | Path not allowed — outside configured allowed directories |
| -32002 | File not found / glob matched no files |
| -32603 | Internal / edit error — pattern not matched, invalid regex, I/O failure |
