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

1. **System log** — reads the kernel's violation records from a live `log stream` while the command runs (a `log show` just after the run misses records on recent macOS). Only file violations become grants.
2. **Stderr** — parses the command's own error output for "Operation not permitted" / "permission denied" messages and extracts the denied paths (quoted, or bare before the error text). This catches violations the kernel's per-process log rate-limiter suppressed, and ones it does not log at all.

No sudo.

**Whose violation is it?** The log names a process id, not the command it belongs to. The tool follows the command's descendants while it runs (fork events and a look at the process table), and takes their violations as certain. A violation from a process it did not see, but which did not exist before the command started, is a **candidate**: it may be a child that lived a millisecond, or somebody else's new process. A violation from a process older than the command is ignored. In loop mode candidates are checked before they reach the profile (below); in a single run they are left out and counted in the output.

**Which folder is granted?** A refused file grants its parent folder; a refused folder grants itself. A path directly inside a folder too broad to grant (the home folder, `~/Library`, `/usr`, `/private/var` and the like) is granted by itself, and such a folder that was refused itself is left out: that is a decision for a person. A refused folder that has a grant under it (git looks at the folders above its repository) is given as that one path, not with its contents: it goes into the profile as an `extra_rules` entry, `(allow file-read* (literal "..."))`.

Three modes:

**sandbox-exec mode** (default) — wraps the command with a minimal baseline-only policy. Use for arbitrary commands with no built-in sandbox support. The command will fail or print errors; that is expected.

```sh
# Run once to discover what the command needs:
sandbox/sandbox-discover.py python3 script.py

# This writes sandbox_profile.json. Verify with the generated profile:
python3 --sandbox ... script.py
```

**Loop mode** (`--loop [N]`) — the same, repeated. A refused operation usually fails, so one run finds only the first layer of what a command needs. Each pass runs the command under the baseline plus the folders found so far, until the command succeeds, a pass finds nothing new, or N passes ran (default 8). This is how a profile for a real workflow is found:

```sh
sandbox/sandbox-discover.py --loop -o git.json -- /usr/bin/git -C ~/project status
```

- What the successful pass was still refused is reported as not needed, and left out.
- Candidate folders are granted while the loop looks, then checked: the command is run once more without them. If it still succeeds they are all dropped. If not, each is taken away in turn: one the command succeeds without is dropped, one it fails without is kept. With more than 12 candidates they are not tried one by one; they stay and are listed as **unverified**, for you to check.
- `--allow-read DIR` and `--allow-write DIR` (repeatable) grant folders from the first pass, for what you already know the command needs.
- Exit status: 0 when the command ended up succeeding, 3 when the loop stopped short (the command still fails and nothing new was refused, or the passes ran out). A command that fails for a reason no folder fixes (a system service, the network, its own arguments) ends that way.
- **Refusals the log does not show.** A tool that asks `access(2)` whether it may read a path, before opening it, is refused without a log record (cmake does this for its own `Modules` folder and then reports a broken installation). When a pass fails with nothing new in the log, the loop tries, in this order: the paths the command names in its own output, the application bundle a granted folder is in, and the folder above a granted `bin` folder. What they give is granted as candidates and checked at the end like any other candidate, so a folder the command turns out not to need is dropped.
- `/bin`, `/sbin`, `/usr/bin` and `/usr/sbin` are granted when the command is refused them. A tool that looks for another program lists them, and some crash when they cannot (cmake).
- `--json` writes progress as JSON events on standard error and nothing else: a `pass` event after each run (`pass`, `exit`, `new_read`, `new_write`, the grants so far as `read_only` and `read_write`, and `not_needed` on a successful pass), a `check` event for each candidate check (`without`, `exit`), a `hint` event when folders are tried that the log did not name (`source` as `output`, `bundle` or `layout`, `paths`), and a `done` event (`passes`, `exit`, `stopped` as `success`, `no-new-paths` or `max-passes`, `profile`, the grants, `folder_only`, `unverified`, and `hinted` for the folders in the profile that the log never named).

A single run (no `--loop`) exits with the command's own status, as before.

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
./sandbox/sandbox-discover.py -v ...                    # print violation paths; keep the raw log and output
```

---

## Tools that start a sandbox of their own (Swift, Xcode)

macOS does not let a sandboxed process apply another sandbox. A tool that confines its own helpers with `sandbox-exec` therefore fails under `replay`, `gate` or any other Seatbelt sandbox, whatever directories the profile allows. The sign is this line in the tool's output, usually followed by an error that does not mention the sandbox at all:

```
sandbox-exec: sandbox_apply: Operation not permitted
```

No `read_only` or `read_write` entry fixes it, and `sandbox-discover.py` stops with "no new paths" while the command still fails. The helper's own sandbox has to be turned off, which is a fair trade here: the helper then runs under the outer sandbox, like everything else the command starts.

The Swift and Xcode tools do this in three places.

| Where | What fails | How to turn the inner sandbox off |
|---|---|---|
| `swift build`, `swift test`, `swift package` | Reading `Package.swift` and running package plugins | `swift build --disable-sandbox` |
| The Swift compiler, for macros (`@State`, `@Observable`, `#Preview`, any package macro) | `external macro implementation type ... could not be found`, `swift-plugin-server produced malformed response` | Pass `-disable-sandbox` to the compiler. With xcodebuild: `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` |
| xcodebuild, for a project or workspace with Swift packages | `xcodebuild: error: Could not resolve package dependencies` | The Xcode setting `IDEPackageSupportDisableManifestSandbox` (see below) |

An xcodebuild build of a project that uses SwiftUI, with the compiler's sandbox off:

```sh
/usr/bin/xcodebuild -project App.xcodeproj -scheme App build \
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
```

The quotes keep the shell from expanding `$(inherited)`: xcodebuild must receive it as written, so that the project's own Swift flags stay.

For package manifests xcodebuild has no command line option. The setting is a user default of Xcode, which applies to every later build of that user, in and out of a sandbox, until it is removed. It was not tried for this document, so check it before relying on it:

```sh
/usr/bin/defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
/usr/bin/defaults delete com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox     # to undo
```

### What an Xcode build needs besides that

Tried with Xcode 27 on macOS 27: a clean and an incremental build of a project with Swift, Objective-C and C++ frameworks and three applications passed with these directories, the flag above and, for the applications' icons, the rule shown below.

| Access | Directories |
|---|---|
| Read-only | Xcode itself (`/Applications/Xcode.app`), `/Library/Developer/CommandLineTools`, `/Library/Developer/PrivateFrameworks`, `~/Library/Developer/Xcode/UserData`, and the file `/Library/Preferences/com.apple.dt.Xcode.plist` |
| Read-write | the project, `~/Library/Developer/Xcode/DerivedData`, `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm`, and the per-user cache and temporary directories (`getconf DARWIN_USER_CACHE_DIR`, `getconf DARWIN_USER_TEMP_DIR`) |

`/Library/Developer/PrivateFrameworks` is easy to miss: without it xcodebuild itself does not start ("failed to load a required plug-in").

Two things an Xcode build may need are not directories:

- **An Icon Composer file (`.icon`) in a target.** The icon export step asks Launch Services what kind of file it is, and fails with "The file ... couldn't be opened" and "Icon export exited with status 255". It passes with one more rule in the profile, which lets the process look up, not change, the Launch Services database:

  ```json
  { "extra_rules": ["(allow mach-lookup (global-name \"com.apple.lsd.mapdb\"))"] }
  ```

- **Running tests.** `xcodebuild build-for-testing` works. `xcodebuild test` does not: starting the tests needs the test manager service and a pseudo-terminal, and allowing every service was not enough. Run the tests outside the sandbox.

Signing with a certificate from the keychain and anything that talks to a simulator or a device also go through services outside the sandbox, and were not tried.

---

## Diagnosing sandbox violations

`sandbox-discover.py` reads the system log while a command runs. To watch violations yourself, run this in a separate terminal:

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
