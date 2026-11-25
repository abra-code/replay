# Sandbox Reference

`replay` and `gate` can self-sandbox at startup: on macOS with Seatbelt (TrustedBSD MAC), on Linux with Landlock and a system call filter. The policy is kernel-enforced: once applied it covers the process and every child process it spawns; it cannot be removed or weakened from user space. It does not stop a sandboxed command from asking a process outside the sandbox to act for it: by default the command can connect to the user's Unix sockets (ssh-agent, Docker, the D-Bus session bus on Linux), and some of those run what they are sent. `--deny-unix-sockets` limits that; the MCP server always does (see [Unix sockets](#unix-sockets-macos)). A running `replay --start-server` is not among those services: a client must first send the server's token, a file in the socket folder that the sandbox does not let a command read.

The flags and the JSON profile are the same on both systems. Most of this document describes macOS; the [Linux](#linux) section at the end says what is different there.

## What the sandbox is for

The sandbox keeps the mistakes of a command, or of an AI agent, that means well inside the granted folders: a wrong path, an `rm` that goes too far, a build step that writes outside its tree. It is not built to hold a command or an agent that works against the user, such as an agent following instructions planted in a file it read. With the default settings such a command can still:
- send out what it can read over the network, the environment included, with any token in it: commands get the network (`--deny-network` takes it away) and every variable of the environment of `replay` or `gate`; the MCP server prints both when it starts;
- reach the user's Unix sockets from playlists and gate (ssh-agent, Docker; `--deny-unix-sockets` limits them, and the MCP server always does);
- read file metadata anywhere, and on macOS every preference domain; on Linux all of `/proc`, and change the mode, owner and times of files, which Landlock does not cover (see [Linux](#linux));
- leave something behind that runs or is trusted later, outside the sandbox: inside a write grant it can rewrite a git hook, a build file or a client's configuration, and it can write the cache directory, so a later run may skip steps.

For an agent you do not trust, run `replay --mcp-server` inside an isolated machine (an agent-vm box, for example) and treat the machine as the boundary; the server's own path checks and the kernel sandbox are then a second line.

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
| `--deny-network` | - | Denies all outbound and inbound network connections. Without this flag network is allowed. On Linux creating any socket fails, Unix ones included (see Linux below). |
| `--deny-unix-sockets` | - | Limits Unix sockets (see [Unix sockets](#unix-sockets-macos)): on macOS only sockets inside the write grants can be connected to; on Linux below Landlock version 9 no Unix socket can be created, and from version 9 only sockets inside the write grants can be connected to. Always on for `--mcp-server`. Implicitly enables `--sandbox`. |

All flags may be repeated. At least one sandbox flag must be present to activate the sandbox — without any flags the process runs unsandboxed.

`replay --start-server` (the server `dispatch` talks to) cannot run sandboxed, on macOS or Linux: the sandbox flags are refused with it. On macOS the sandbox denies registering its message port; on Linux the grant it would need, the shared socket folder, would let the sandboxed actions of one batch reach the servers of other batches.

**Auto-sandboxing for `replay`**: When `--sandbox` is used with a playlist file (not stdin), `replay` automatically extracts declared paths from the playlist and adds them to the sandbox policy. Read operations (read, list, tree, glob, clone source) are added as read-only - **at the file or directory referenced**, not its parent - so a `read /etc/passwd` action does not unlock all of `/etc`. Write operations (create, edit, delete, clone destination, execute outputs) need parent-directory access for atomic-replace and creation, and so are added as read-write **on the parent directory**. The filesystem root `/` is rejected with a warning if any auto-discovered or `--allow-*` path resolves to it. A derived grant of the whole home folder, or of any folder above it other than the root, is kept but reported with a warning, since nothing in it is then protected from the commands (a file written directly into the home folder, or a playlist kept there, whose folder is granted read, is enough). `gate --sandbox` reports the same for its derived grants, its current folder included: run from the home folder, it grants reading all of it. You can still combine `--sandbox` with `--allow-read`, `--allow-write`, and `--sandbox-profile` to add additional paths.

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
| `import_baseline` | bool | `true` | Import `bsd.sb` (see below; on Linux, the Linux baseline). Rarely needs to be `false`. |
| `read_only` | string array | `[]` | Directories where `file-read*` is allowed (recursively). |
| `read_write` | string array | `[]` | Directories where `file-read*` and `file-write*` are allowed (recursively). |
| `allow_network` | bool | `true` | Allow all network operations. Set to `false` to deny. Equivalent of `--deny-network`. |
| `allow_exec` | bool | `true` | Allow `process-exec*` (launch any executable). See Execution below. |
| `allow_fork` | bool | `true` | Allow creating processes. `false` keeps every program from starting, since starting one creates a process: `execute` actions fail (EPERM on macOS, EACCES on Linux), on both systems. Threads still work. |
| `extra_rules` | string array | `[]` | Raw SBPL rules appended verbatim at the end of the profile. Use as an escape hatch for rules not expressible via the structured fields. macOS only: a profile with it is refused on Linux. |

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

## What `bsd.sb` covers (macOS)

When `import_baseline` is `true` (the default), the profile imports Apple's `bsd.sb` baseline. This baseline pre-allows several things needed for normal process operation:

- **dyld / dynamic linker**: loading system dylibs from `/usr/lib`, `/System/Library`, `/private/var/db/dyld`, and similar system paths
- **Mach IPC**: bootstrap port, task and thread ports — needed for Obj-C runtime, XPC, etc.
- **`/dev` nodes**: `/dev/null`, `/dev/random`, `/dev/urandom`, `/dev/dtracehelper` (not `/dev/tty`: the baseline has no rule for it, checked on macOS 27.2)
- **`/tmp` symlink**: only `file-read-metadata` on the `/tmp` literal itself (so `stat` of the symlink resolves). Neither reads nor writes to files under `/tmp` are allowed by the baseline — those require explicit `read_only` or `read_write` entries.
- **Network**: `bsd.sb` does not grant network access on its own. Network is allowed or denied by an explicit rule that `replay`/`gate` always emits - `(allow network*)` when `allow_network` is true (the default), `(deny network*)` when it is false or `--deny-network` is passed.

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

### Tool names and PATH

`replay`'s `execute` action and `gate`'s wrapped command (after `--`) take a path or a bare name. A name without a slash is looked up in the absolute folders of `PATH`, in order; an empty or relative entry, which would mean the current folder, is skipped, so a tool planted in the working folder never runs in place of the one in `PATH`. If `PATH` is not set, `/usr/bin` and `/bin` are searched.

Under `--sandbox` the lookup happens before the sandbox starts, and the tool it finds gets read access (`gate`: the file; `replay`'s automatic sandbox: its folder):

```sh
gate --sandbox -i src.c -o out.o -- clang -c src.c -o out.o              # clang from PATH
gate --sandbox -i src.c -o out.o -- /usr/bin/clang -c src.c -o out.o     # a path, used as given
```

The grant covers the tool itself, not what it loads or reads: a tool that runs other programs, reads its own support files outside the system folders, or is a script whose interpreter lives elsewhere still needs `--allow-read` for those.

### Descriptors

The sandbox checks files when they are opened, not a descriptor that is already open, so under the sandbox a command gets only descriptors 0 to 2 (standard input, output and error): a descriptor that `replay` or `gate` got from its caller, on a file outside the grants for example, does not reach it. Without the sandbox, commands get every descriptor that is not close-on-exec, as before.

The one exception is make's job slots. A `make -j` that runs a recursive make passes it two pipe descriptors, named in `MAKEFLAGS` (`--jobserver-auth=R,W`, or `--jobserver-fds=R,W` before make 4.2), so that the sub-make shares the parallel jobs; a sub-make without them runs one job at a time. When `replay` or `gate` starts with such a pair of open pipes, its commands get them too. make 4.4 and newer use a named pipe instead (`--jobserver-auth=fifo:/tmp/GMfifo...`), made in `$MAKE_TMPDIR`, `$TMPDIR` or else `/tmp`, which are outside the grants, so a sandboxed sub-make there runs one job at a time (`make[1]: cannot open jobserver ...`, then `jobserver unavailable: using -j1`) unless the top make is run with `--jobserver-style=pipe`.

---

## Network

By default the sandbox allows network. Use `--deny-network` or `"allow_network": false` to block it.

The profile always emits an explicit network rule — `(allow network*)` by default, `(deny network*)` when denied. There is no implicit fallback: the rule is always present.

On macOS, with the network allowed, the profile also lets a command look up the certificate trust service, `(allow mach-lookup (global-name "com.apple.TrustEvaluationAgent"))`. Apple's `curl` checks a server's certificate against `/etc/ssl/cert.pem` first and asks this service only when the chain ends at a root that file lacks, as example.com's does; without the rule such a connection fails ("unable to get local issuer certificate", curl exit 60), while sites whose root is in the file still work. Apps under App Sandbox may look up this service too.

### Unix sockets (macOS)

Seatbelt counts connecting to a Unix socket as network access, so `(allow network*)` lets a sandboxed command connect to any Unix socket its user may open, inside the grants or not: ssh-agent, gpg-agent, Docker and Colima, and the socket of a `replay --start-server` when `REPLAY_IPC_BACKEND=socket` is set. That server still refuses the command, which cannot read the server's token file; the default message port of that server is not reachable at all, because the profile does not allow looking it up.

Playlists and `gate` keep this by default, since builds use these sockets (fetching over ssh, `docker build`, signing with gpg). With `--deny-unix-sockets`, and always in MCP server mode, the profile adds:

```
(deny network-outbound (remote unix-socket))
(allow network-outbound (literal "/private/var/run/mDNSResponder") (literal "/private/var/run/syslog"))
(allow network-outbound (remote unix-socket (subpath "<each read_write dir>")))
```

A command can then connect only to sockets inside its write grants. Name lookups keep working: every DNS lookup goes through mDNSResponder's socket. With the network denied, `(deny network*)` already covers Unix sockets.

---

## Discovering path requirements (macOS)

Use `sandbox/sandbox-discover.py` to capture sandbox violations and emit a profile. It reads the macOS system log and has no Linux version yet; on Linux, see [Diagnosing sandbox violations](#diagnosing-sandbox-violations).

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

## Tools that start a sandbox of their own (Swift, Xcode; macOS)

This section is about macOS. Linux lets a sandboxed process apply a sandbox of its own.

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

On Linux there is no log of denials that an ordinary user can read. `--verbose` prints the sandbox before it is applied: the Landlock version, every rule with its rights and the reason it is there, and the gaps that apply on that kernel. A denied operation fails with "Permission denied" (EACCES), so the error message of the failing tool usually names the path.

---

## Path matching rules (macOS)

- All paths are matched with `(subpath ...)` — the rule covers the given directory and every file or directory below it recursively.
- Paths are canonicalized via `realpath(3)` before being written into the SBPL profile. Symlinks in the path are resolved. If the path does not exist yet (e.g. an output directory to be created), canonicalization falls back to the raw path.
- The kernel applies `realpath` independently when checking access. The two resolutions should agree in normal use; if a path is accessed through a different symlink chain, the sandbox may deny it.

---

## Rule precedence (macOS)

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
4. `--deny-network` sets `allow_network = false` (overrides the JSON field). Without the flag the JSON field stands, so `"allow_network": false` in a profile denies the network on its own.

This lets a base profile define most of the policy while the caller adds a single extra output directory via a CLI flag.

---

## Failure behavior

If any sandbox flag or profile is supplied and sandbox initialization fails (invalid JSON, `sandbox_init_with_parameters` returns an error, or the SPI is unavailable; on Linux, a kernel without a usable Landlock, or an option Linux does not support), the tool exits immediately with a non-zero status before processing any actions. There is no fallback to an unsandboxed run.

Sandbox violations at runtime do not terminate the process - the offending syscall returns `EPERM` (macOS) or `EACCES` (Linux) to the caller, which surfaces as a normal I/O error.

---

## Linux

On Linux the sandbox is built from two kernel features: Landlock, the kernel's file system sandbox, which limits what the process and its children may read, write and run; and a system call filter (seccomp), which denies a few calls Landlock does not cover. Both are applied at startup, before any action runs, and every child inherits them. The flags and the JSON profile are the same as on macOS; this section lists what differs.

### Kernel requirements

Landlock has grown in versions (its ABI, application binary interface, version). The sandbox needs version 3 or newer, which is Linux 6.2 or newer, with Landlock enabled. Otherwise `replay` and `gate` refuse to start sandboxed and say why: the kernel was built without Landlock, Landlock is built in but not enabled at boot (the `lsm=` kernel parameter), the Landlock calls are blocked by the system call filter of the container the tool runs in, or the version is too old. To run without the sandbox, leave out the sandbox options (for the MCP server, pass `--no-sandbox`).

Newer versions close gaps:

| Landlock version | Linux | What it adds here |
|---|---|---|
| 3 | 6.2 | The minimum: renames across folders, and control of truncating files. |
| 6 | 6.12 | Signals only to processes inside the same sandbox. In MCP server mode, abstract Unix sockets only inside the sandbox. |
| 8 | 7.0 | The sandbox is applied to all threads at once. |
| 9 | 7.1 | With Unix sockets limited (MCP server mode, `--deny-unix-sockets`): connecting to a Unix socket by path only inside the write grants (see Unix sockets below). |

In November 2026, Ubuntu 24.04 runs 6.8 (version 4) on servers and 7.0 (version 8) on desktops, Ubuntu 26.04 7.0 (version 8), Debian 13 6.12 (version 6), and Arch 7.2 (version 10). `--verbose` prints the version of the running kernel.

### What a grant allows

| Grant | Allowed |
|---|---|
| `read_only` folder | Reading its files and listing its folders, all the way down. |
| `read_write` folder | Also creating, writing, truncating, deleting and renaming files and folders, and making links, sockets and named pipes. Not device nodes. |
| A file instead of a folder | Reading that file (and, for `read_write`, writing and truncating it). |
| `allow_exec: true` | Running programs anywhere. A program still needs read access to its shared libraries, and a script to the script itself. |

The baseline (`import_baseline`, in place of `bsd.sb`) grants, read-only: `/usr`, and `/bin`, `/sbin`, `/lib`, `/lib32` and `/lib64` where they are real folders; all of `/etc`, and what the links directly in `/etc` point to (for a file under `/run`, its folder, except in `/run/user`, the users' own runtime folders, which are never granted this way: `/etc/resolv.conf` is a link to `/run/systemd/resolve/stub-resolv.conf` on Ubuntu and Fedora, and without it a program cannot look up host names); all of `/proc`; `/sys/devices/system/cpu`; the folder of the `replay` or `gate` executable; and the folder of every shared library the process has loaded outside those folders (for example a Swift runtime in `/opt`). Read and write: `/dev/null`, `/dev/zero`, `/dev/full`, `/dev/random`, `/dev/urandom`, `/dev/tty`, and the terminal on descriptor 0, 1 or 2 when there is one (so that `/dev/stdin` and `/dev/stderr` open). Files in `/dev/shm`, read and write (creating and removing them included, but no folders, sockets, FIFOs or symbolic links): POSIX shared memory and named semaphores live there, and without them every Python `multiprocessing` lock and pool fails; the cost is that a command can read and change the shared memory of the user's other programs kept there. Not granted, as on macOS: `/tmp`, the home folder, and the rest of `/dev/pts`: another terminal of the user could be read (what the user types there) and written to. Inside a container where `/dev/ptmx` is a link into `/dev/pts`, a step therefore cannot make a new terminal either (`script`, `expect`, `tmux`); on a normal system `/dev/ptmx` was never granted.

Programs installed outside these folders (in `/opt`, `~/.local`, a Python virtual environment) need their folder in `read_only`, as Homebrew tools do on macOS.

### Paths that do not exist yet

Landlock rules need an existing file or folder:
- A read path inside a write grant needs no rule of its own. Any other read path that does not exist is refused, naming it.
- A write path that does not exist is replaced by its nearest existing parent folder, with a warning naming both. This keeps an output tree that does not exist yet working. The replacement is never `/`, the home folder, or a folder of the baseline: such a path is refused instead.
- `/` itself is never granted.

### Differences from macOS

- **Errors:** a denied operation fails with EACCES ("Permission denied"), and a refused hard link with EXDEV ("Invalid cross-device link"). macOS returns EPERM ("Operation not permitted").
- **Rules belong to the file or folder, not to the path.** Landlock attaches a rule to the file or folder found when the sandbox starts:
  - A granted folder that is renamed or moved keeps its grant under its new name. A symbolic link in a granted path is followed once, at startup.
  - A granted folder that an action deletes and creates again keeps working, as long as its parent may be written: the parent's rule covers the new folder.
  - A file granted by itself (the auto sandbox grants read inputs this way) that something outside the sandbox replaces during the run, for example an editor saving through a temporary file, is a different file, and stays unreadable for the rest of the run.
- **Links and renames cannot give a file more rights than it has where it is.** A hard link from a read-only input into an output folder fails with EXDEV, and moving a file out of a read-only folder fails with EACCES: writing through such a link would change the read-only input. The auto sandbox grants write on the source folder of `move` and `hardlink` actions, so those keep working.
- **Not covered by Landlock** on any kernel: file metadata (`stat`, `chmod`, `chown`, timestamps) anywhere on the system, and ioctl calls on devices. Below version 6, signals to any process of the same user; connecting to Unix sockets by path, except with Unix sockets limited from version 9 (below).
- **No new privileges.** Programs that gain privileges when they start (set-user-ID programs such as `sudo`, `su` and `passwd`, and programs with file capabilities) run without them.
- **`> /dev/stderr` opens a new file on Linux** (macOS duplicates the descriptor), so it fails when standard error is a file outside the grants. Write `>&2` instead. A terminal or a pipe works.
- **Namespace tools do not work sandboxed:** `unshare -r`, rootless podman and bubblewrap write under `/proc/self`, and Landlock refuses the mounts they make.
- **A sandboxed program may apply a sandbox of its own,** unlike on macOS.

### The system call filter

- **Extended attributes cannot be written or removed**, anywhere, also inside write grants (EACCES); reading them works. Otherwise a sandboxed command could attach a forged fingerprint xattr to an input it may not write, and later runs would trust it. Effects:
  - `replay --hash-store xattr` is refused together with the sandbox; the default `sidecar` hash store works.
  - replay's `clone` and `copy` actions do not carry user extended attributes over to the copies (macOS does).
  - `gate` reads the fingerprint xattrs its inputs already have but writes none, so inputs without one are hashed again on every sandboxed run.
  - Commands run by `execute` cannot set them: `cp -a` drops them without a message, `cp --preserve=xattr` fails.
- **io_uring is unavailable** (ENOSYS), because its own operations would get past the filter. Programs that use it fall back to ordinary calls.
- **`TIOCSTI` and `TIOCLINUX` are denied** (EACCES). They push characters into a terminal's input, which would let a command type into the user's shell. Other ioctl calls work.

### Unix sockets

From Landlock version 9, with Unix sockets limited (MCP server mode, `--deny-unix-sockets`), a Unix socket with a path can be connected to only inside the write grants. The docker socket, ssh-agent, gpg-agent and the D-Bus session bus are then reachable only if their folder is granted read-write. Playlists and `gate` without the flag keep Unix sockets on every kernel, version 9 included.

Below version 9 the kernel does not check connecting to a Unix socket by path, so a sandboxed command can reach any socket its user may open. Through the D-Bus session bus that is a complete way out (`systemd-run --user` starts a program outside the sandbox). Therefore:
- **MCP server mode** (`--mcp-server`, where an AI agent chooses the commands), and `--deny-unix-sockets`: creating a Unix socket fails with EACCES. `socketpair` and other kinds of sockets still work. Commands that talk to a local service fail: ssh-agent, gpg-agent, the docker command, D-Bus clients; `syslog(3)` messages are lost; user and group names known only through SSSD, winbind or systemd's user database do not resolve (`id`, `whoami`, `~user`); Python's default process pool (`multiprocessing`, `concurrent.futures`, whose default start method is `forkserver` from Python 3.14) and `multiprocessing.Manager` fail, while the `fork` and `spawn` start methods work. From version 6 the flag also limits abstract Unix sockets (which have no path) to those made inside the sandbox.
- **Playlists** and `gate`, whose commands the user wrote, keep Unix sockets, unless `--deny-unix-sockets` is given or the network is denied (below). On those kernels a playlist's commands can reach the services above. They can also connect to the socket of a running `replay` server, but it drops them: a client must first send the server's token, a file in the socket folder (mode 0600) that the sandbox does not let a command read. Granting the socket folder (`$XDG_RUNTIME_DIR/replay` or `/tmp/replay-<uid>`; `$TMPDIR/replay` on macOS), or a folder that holds it such as `/tmp` or `$TMPDIR`, gives that back, and with it a way out of the sandbox.
- A datagram `socketpair` can still send to datagram sockets with a path, such as the system log's (`/dev/log`, the journal), on any version.

### Network and process creation

- **`--deny-network`** and `"allow_network": false`: the system call filter refuses creating a socket of any family (EACCES), Unix sockets included on every kernel, as macOS denies connecting to them; `socketpair` still works. Name lookups (DNS) fail too. Only new sockets are refused: a socket a command inherits, for example one its caller passed down through `replay`, keeps working.
- **`"allow_fork": false`**: the filter refuses `fork`, `vfork` and every `clone` that does not make a thread (EACCES), and `clone3` answers ENOSYS (the C library then makes its threads with `clone`). Starting a program needs a new process, so `execute` actions fail, as on macOS. Threads, and with them `replay`'s own work, are not affected.
- **Nothing sandboxed outlives the run.** Under the sandbox, `replay` and `gate` make themselves the subreaper of what they start, so a process that leaves its process group with `setsid` (which a timeout's kill of the group misses) is re-parented to them instead of the system. When they exit normally they end every remaining descendant: SIGTERM, then SIGKILL after a second. This also ends background servers that a command started and left running (an sccache or Gradle daemon, a development server); they would have kept the first command's grants anyway. The same happens when `replay` or `gate` is stopped by SIGTERM (how an MCP client or a service manager stops a server), SIGINT or SIGHUP: the descendants are ended first, then the signal ends `replay` or `gate` as before (a signal its caller set to be ignored stays ignored). Not on SIGKILL. macOS has no subreaper: there a process in its own session keeps running, sandboxed, after `replay` exits.

### Not supported on Linux yet

- `extra_rules`: these are macOS sandbox rules; a profile that has them is refused.
- `sandbox-discover.py`.
