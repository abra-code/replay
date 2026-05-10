# Sandbox Reference

`replay` and `gate` can self-sandbox at startup using macOS Seatbelt (TrustedBSD MAC). The policy is kernel-enforced: once applied it covers the process and every child process it spawns; there is no way to escape or weaken it from user space.

---

## Quick start

```sh
# enable sandbox with minimal default policy; allow writes to one directory
replay --sandbox --allow-write ~/project/build actions.json

# allow writes to two directories
replay \
  --sandbox \
  --allow-write ~/project/build \
  --allow-write ~/project/output \
  actions.json

# load a JSON profile file (implicitly enables sandbox)
replay --sandbox-profile profile.json actions.json

# combine profile + extra CLI flag
replay --sandbox-profile profile.json --allow-write ~/project/extra actions.json

# deny outbound network (allowed by default)
replay --sandbox --allow-write ~/project/build --deny-network actions.json
```

---

## CLI flags

| Flag | Argument | Effect |
|---|---|---|
| `--sandbox` | — | Enable hard sandbox with minimal default policy. Allows re-reading the playlist file. |
| `--allow-read <path>` | directory | Grants `file-read*` on the directory and all descendants. Implicitly enables `--sandbox`. |
| `--allow-write <path>` | directory | Grants `file-read*` and `file-write*` on the directory and all descendants. Implicitly enables `--sandbox`. |
| `--sandbox-profile <file>` | JSON file | Loads a profile file (see JSON schema below). Implicitly enables `--sandbox`. |
| `--deny-network` | — | Denies all outbound and inbound network connections. Without this flag network is allowed. |

All flags may be repeated. At least one sandbox flag must be present to activate the sandbox — without any flags the process runs unsandboxed.

**Auto-sandboxing for `replay`**: When `--sandbox` is used with a playlist file (not stdin), `replay` automatically extracts declared paths from the playlist and adds them to the sandbox policy. Read operations (read, list, tree, glob, clone source) are added as read-only — **at the file or directory referenced**, not its parent — so a `read /etc/passwd` action does not unlock all of `/etc`. Write operations (create, edit, delete, clone destination, execute outputs) need parent-directory access for atomic-replace and creation, and so are added as read-write **on the parent directory**. The filesystem root `/` is rejected with a warning if any auto-discovered or `--allow-*` path resolves to it. You can still combine `--sandbox` with `--allow-read`, `--allow-write`, and `--sandbox-profile` to add additional paths.

---

## JSON profile schema

All fields are optional.

```json
{
  "import_baseline": true,
  "read_only":       ["/path/to/dir", ...],
  "read_write":      ["/path/to/dir", ...],
  "allow_network":   true,
  "allow_exec":      true,
  "allow_fork":      true,
  "extra_rules":     ["(allow ...)"]
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `import_baseline` | bool | `true` | Import `bsd.sb` (see below). Rarely needs to be `false`. |
| `read_only` | string array | `[]` | Directories where `file-read*` is allowed (recursively). |
| `read_write` | string array | `[]` | Directories where `file-read*` and `file-write*` are allowed (recursively). |
| `allow_network` | bool | `true` | Allow all network operations. Set to `false` to deny. Equivalent of `--deny-network`. |
| `allow_exec` | bool | `true` | Allow `process-exec*` (launch any executable). See Execution below. |
| `allow_fork` | bool | `true` | Allow `process-fork` (fork without exec). |
| `extra_rules` | string array | `[]` | Raw SBPL rules appended verbatim at the end of the profile. Use as an escape hatch for rules not expressible via the structured fields. |

### Example: read-only source, read-write output

```json
{
  "read_only":  ["/Users/alice/project/src"],
  "read_write": ["/Users/alice/project/build"]
}
```

### Example: deny network, keep exec

```json
{
  "read_write":    ["/Users/alice/project/build"],
  "allow_network": false
}
```

### Example: lock down exec too

```json
{
  "read_write":  ["/Users/alice/project/build"],
  "allow_exec":  false,
  "allow_fork":  false,
  "allow_network": false
}
```

---

## What `bsd.sb` covers

When `import_baseline` is `true` (the default), the profile imports Apple's `bsd.sb` baseline. This baseline pre-allows several things needed for normal process operation:

- **dyld / dynamic linker**: loading system dylibs from `/usr/lib`, `/System/Library`, `/private/var/db/dyld`, and similar system paths
- **Mach IPC**: bootstrap port, task and thread ports — needed for Obj-C runtime, XPC, etc.
- **`/dev` nodes**: `/dev/null`, `/dev/random`, `/dev/urandom`, `/dev/tty`
- **`/tmp` symlink**: only `file-read-metadata` on the `/tmp` literal itself (so `stat` of the symlink resolves). Neither reads nor writes to files under `/tmp` are allowed by the baseline — those require explicit `read_only` or `read_write` entries.
- **Network**: `bsd.sb` does not grant network access on its own. Network is allowed or denied by an explicit rule that `replay`/`gate` always emits — `(allow network*)` when `allow_network` is true (the default), `(deny network*)` when `--deny-network` is passed.

Setting `import_baseline: false` removes all of the above. The process will likely crash during startup (dyld cannot load any dylib). Only do this if you are constructing a fully bespoke SBPL profile via `extra_rules`.

---

## Execution (`execute` action / `allow_exec`)

### System binaries: no explicit read needed

Binaries in `/bin`, `/usr/bin`, `/sbin`, `/usr/sbin` work without adding those directories to `read_only`. The `(allow process-exec*)` rule covers the exec syscall itself, and `bsd.sb` covers loading their system dylibs.

```sh
# This works without any read_only on /usr/bin:
replay --sandbox --allow-write ~/project/build actions.json
# where actions.json contains: [{"action":"execute","tool":"/usr/bin/true"}]
```

### Third-party binaries: need their framework/dylib path

Binaries that load dylibs outside the system paths covered by `bsd.sb` will fail at startup. The most common case is Python, Node, Ruby, or tools installed via Homebrew:

```
dyld: Library not loaded: /Library/Frameworks/Python.framework/Versions/3.x/Python
  Reason: file system sandbox blocked open()
```

Fix: add the framework root (or the Homebrew prefix) to `read_only`:

```json
{
  "read_only":  [
    "/Library/Frameworks/Python.framework",
    "/usr/local/lib"
  ],
  "read_write": ["/Users/alice/project/build"]
}
```

Or for Homebrew tools:

```json
{
  "read_only":  ["/opt/homebrew", "/usr/local"],
  "read_write": ["/Users/alice/project/build"]
}
```

### Execution permission is not per-binary

`allow_exec: true` emits `(allow process-exec*)` — a blanket allow for any executable path. There is no supported way to allow only specific binaries without dropping to raw `extra_rules`. If you need to restrict which tools can be launched, do it in application logic (whitelist the `tool` field) rather than SBPL.

### Tool paths must be absolute under sandbox

`replay`'s `execute` action and `gate`'s wrapped command (after `--`) must specify the tool by an **absolute path** when `--sandbox` is active:

```sh
gate --sandbox -i src.c -o out.o -- /usr/bin/clang -c src.c -o out.o    # OK
gate --sandbox -i src.c -o out.o -- clang        -c src.c -o out.o      # may fail
```

`$PATH` lookup happens inside `posix_spawn`/`NSTask` after the sandbox is active, so a bare name like `clang` cannot be turned into an allowlist entry at startup. Tools in `/bin`, `/usr/bin`, `/sbin`, `/usr/sbin` happen to keep working with bare names because `bsd.sb` covers those locations, but anything else (Homebrew, Python virtualenv, custom installs) needs the absolute path so the right read entries can be added.

---

## Network

By default the sandbox allows network. Use `--deny-network` or `"allow_network": false` to block it.

The profile always emits an explicit network rule — `(allow network*)` by default, `(deny network*)` when denied. There is no implicit fallback: the rule is always present.

---

## Discovering path requirements

Use `sandbox/sandbox-discover.py` to capture sandbox violations and emit a profile.

1. **System log** — queries the unified log database with `log show` after the command exits. Covers framework-level violations (LaunchServices, dyld, mach-lookup).
2. **Stderr** — parses the command's own error output for "Operation not permitted" / "permission denied" messages and extracts the denied paths. This catches action-level file violations that the kernel's per-process violation log rate-limiter may suppress when many startup-phase violations are generated first.

No guesswork, no sudo.

Two modes:

**sandbox-exec mode** (default) — wraps the command with a minimal baseline-only policy. Use for arbitrary commands with no built-in sandbox support. The command will fail or print errors; that is expected.

```sh
# Run once to discover what the command needs:
sandbox/sandbox-discover.py python3 script.py

# This writes sandbox_profile.json. Verify with the generated profile:
python3 --sandbox ... script.py
```

**Native mode** (`-n`) — runs the command directly without wrapping, relying on the tool's own sandbox (e.g. `replay` or `gate` with `--sandbox` or `--sandbox-profile`) to generate violations.

> **Note**: replay must be able to read its own playlist file. If the playlist lives outside the allowed paths, replay fails to read it before any actions run. Include the playlist directory in `--allow-read`.

```sh
./sandbox/sandbox-discover.py -n -- path/to/replay \
  --sandbox \
  --allow-read ~/project/tools \
  --allow-write /tmp/out \
  ~/project/tools/actions.json
```

Additional flags:

```sh
./sandbox/sandbox-discover.py -o my_profile.json ...    # custom output path
./sandbox/sandbox-discover.py -v ...                    # print violation paths; save raw log to /tmp
```

---

## Diagnosing sandbox violations

`sandbox-discover.py` automatically queries the system log after a command exits. If you want to watch violations in real-time, run this in a separate terminal before invoking the tool:

```sh
log stream --style compact --predicate 'subsystem == "com.apple.sandbox" || sender == "Sandbox"'
```

---

## Path matching rules

- All paths are matched with `(subpath ...)` — the rule covers the given directory and every file or directory below it recursively.
- Paths are canonicalized via `realpath(3)` before being written into the SBPL profile. Symlinks in the path are resolved. If the path does not exist yet (e.g. an output directory to be created), canonicalization falls back to the raw path.
- The kernel applies `realpath` independently when checking access. The two resolutions should agree in normal use; if a path is accessed through a different symlink chain, the sandbox may deny it.

---

## Rule precedence

Seatbelt uses a simple precedence model:

0. macOS sandbox profile (SBPL) implicitly defaults to (deny default)
1. `(import "bsd.sb")` — allows for system operations
2. explicit `(allow ...)` rules — added on top of the baseline
3. explicit `(deny ...)` rules — e.g. `(deny network*)` overrides bsd.sb's network allow

More specific rules beat less specific rules. Because the profile always emits an explicit network rule after the `bsd.sb` import, the chosen `allow` or `deny` is always the operative one.

---

## Merging profiles and CLI flags

When `--sandbox-profile` and `--allow-*` flags are both present, they merge:

1. The JSON profile is loaded first.
2. `--allow-read` paths are appended to `read_only`.
3. `--allow-write` paths are appended to `read_write`.
4. `--deny-network` sets `allow_network = false` (overrides the JSON field).

This lets a base profile define most of the policy while the caller adds a single extra output directory via a CLI flag.

---

## Failure behavior

If any sandbox flag or profile is supplied and sandbox initialization fails (invalid JSON, `sandbox_init_with_parameters` returns an error, or the SPI is unavailable), the tool exits immediately with a non-zero status before processing any actions. There is no fallback to an unsandboxed run.

Sandbox violations at runtime do not terminate the process — the offending syscall returns `EPERM` to the caller, which surfaces as a normal I/O error.
