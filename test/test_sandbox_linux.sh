#!/bin/bash
# The Linux sandbox's own behavior (private/linux_phase5a_sandbox_design.md), beyond
# what the shared sandbox suites check on both platforms: denials outside the grants,
# paths that do not exist yet, hard links, refused options, the --verbose listing, and
# the documented gaps. Linux only; it reports itself skipped elsewhere.
#
# Usage: test_sandbox_linux.sh [/path/to/replay]
# Exit:  0 = all checks passed (or skipped), 1 = a failure, 2 = setup failed

SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
REPLAY="${1:-$REPO_DIR/build/Release/replay}"

HOST_OS="$(/usr/bin/uname -s)"
if [ "$HOST_OS" != "Linux" ]; then
    echo "skipped: the Landlock sandbox exists on Linux only"
    exit 0
fi
if [ ! -x "$REPLAY" ]; then
    echo "Error: replay not found at $REPLAY" >&2
    exit 2
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sandbox-linux.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "Error: could not create a temporary folder" >&2
    exit 2
fi
cleanup() {
    /bin/chmod -R u+w "${WORK_DIR:?}" 2>/dev/null
    /bin/rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT

pass=0
fail=0
check() {
    # $1: 0 for success; $2: what; $3: detail shown on failure
    if [ "$1" -eq 0 ]; then
        pass=$((pass + 1))
        echo "  PASS: $2"
    else
        fail=$((fail + 1))
        echo "  FAIL: $2"
        if [ -n "${3:-}" ]; then
            echo "        $3" | /usr/bin/head -c 600
            echo ""
        fi
    fi
}

# Runs replay with the given arguments, reading actions from stdin (no playlist file,
# so no automatic grants: only what the arguments grant). Sets out and rc.
run_stdin() {
    local actions="$1"
    shift
    out="$(printf '%s\n' "$actions" | "$REPLAY" "$@" 2>&1)"
    rc=$?
}

ALLOWED="$WORK_DIR/allowed"
OUTSIDE="$WORK_DIR/outside"
/bin/mkdir -p "$ALLOWED" "$OUTSIDE"
echo "CONTENT-OUTSIDE-GRANTS" > "$OUTSIDE/secret.txt"

echo "=== 1. denials outside the grants ==="
run_stdin "[execute]	/bin/sh	-c	echo x > $OUTSIDE/written.txt" --allow-write "$ALLOWED"
test ! -e "$OUTSIDE/written.txt"
check $? "a write outside the grants does not happen" "$out"
case "$out" in *"Permission denied"*) r=0 ;; *) r=1 ;; esac
check $r "the denial is EACCES (Permission denied)" "$out"

run_stdin "[execute]	/bin/cat	$OUTSIDE/secret.txt" --allow-write "$ALLOWED"
case "$out" in *"CONTENT-OUTSIDE-GRANTS"*) r=1 ;; *) r=0 ;; esac
check $r "a read outside the grants does not happen" "$out"
case "$out" in *"secret.txt: Permission denied"*) r=0 ;; *) r=1 ;; esac
check $r "cat ran and was denied (not skipped for another reason)" "$out"

run_stdin "[execute]	/bin/sh	-c	echo inside > $ALLOWED/inside.txt" --allow-write "$ALLOWED"
test -f "$ALLOWED/inside.txt"
check $? "a write inside the grants happens" "$out"

echo ""
echo "=== 2. paths that do not exist yet ==="
run_stdin "[execute]	/bin/true" --allow-write "$ALLOWED/new/deeper"
check $rc "a missing write path runs" "$out"
case "$out" in *"does not exist yet; granting its nearest existing folder \"$ALLOWED\""*) r=0 ;; *) r=1 ;; esac
check $r "it warns and grants the nearest existing folder" "$out"

run_stdin "[execute]	/bin/true" --allow-write "/nonexistent-replay-test/out"
test "$rc" -ne 0
check $? "a missing write path whose nearest folder is / is refused" "$out"
case "$out" in *"too broad to grant in its place"*) r=0 ;; *) r=1 ;; esac
check $r "the refusal says why" "$out"

FAKE_HOME="$WORK_DIR/home"
/bin/mkdir -p "$FAKE_HOME"
out="$(printf '[execute]\t/bin/true\n' | HOME="$FAKE_HOME" "$REPLAY" --allow-write "$FAKE_HOME/proj/build" 2>&1)"
rc=$?
test "$rc" -ne 0
check $? "a missing write path whose nearest folder is the home folder is refused" "$out"
case "$out" in *"\"$FAKE_HOME\" is too broad to grant in its place"*) r=0 ;; *) r=1 ;; esac
check $r "the refusal names the home folder" "$out"

echo "a file" > "$WORK_DIR/plain.txt"
run_stdin "[execute]	/bin/true" --allow-write "$WORK_DIR/plain.txt/out"
test "$rc" -ne 0
check $? "a write path under a regular file is refused" "$out"
case "$out" in *"is a file, not a folder"*) r=0 ;; *) r=1 ;; esac
check $r "the refusal says the parent is a file" "$out"

run_stdin "[execute]	/bin/true" --allow-write "/usr/bin/replay-test-missing/out"
test "$rc" -ne 0
check $? "a missing write path never widens to a system folder (/usr/bin)" "$out"
case "$out" in *"is too broad to grant in its place"*) r=0 ;; *) r=1 ;; esac
check $r "the refusal says the folder is too broad" "$out"

run_stdin "[execute]	/bin/true" --allow-read "$WORK_DIR/missing.txt"
test "$rc" -ne 0
check $? "a missing read path is refused" "$out"
case "$out" in *"does not exist"*) r=0 ;; *) r=1 ;; esac
check $r "the refusal names the missing read path" "$out"

echo ""
echo "=== 3. hard links ==="
SRC="$WORK_DIR/src"
DST="$WORK_DIR/dst"
/bin/mkdir -p "$SRC" "$DST"
echo "linked" > "$SRC/file.txt"
cat > "$WORK_DIR/hardlink.json" << EOF
[{ "action": "hardlink", "from": "$SRC/file.txt", "to": "$DST/link.txt" }]
EOF
out="$("$REPLAY" --sandbox "$WORK_DIR/hardlink.json" 2>&1)"
rc=$?
src_inode="$(/usr/bin/stat -c %i "$SRC/file.txt")"
dst_inode="$(/usr/bin/stat -c %i "$DST/link.txt" 2>/dev/null)"
test "$rc" -eq 0 && test "$src_inode" = "$dst_inode"
check $? "the auto sandbox lets a hardlink action link its source (the source folder is granted write)" "$out"

run_stdin "[hardlink]	$SRC/file.txt	$DST/link2.txt" --allow-read "$SRC" --allow-write "$DST"
test ! -e "$DST/link2.txt"
check $? "a hard link from a read-only folder into a writable one is refused" "$out"
case "$out" in *"Invalid cross-device link"*|*"cross-device"*) r=0 ;; *) r=1 ;; esac
check $r "the refusal is EXDEV, as documented" "$out"

echo ""
echo "=== 4. options Linux refuses ==="
cat > "$WORK_DIR/extra_rules.json" << EOF
{ "read_write": ["$ALLOWED"], "extra_rules": ["(allow file-read*)"] }
EOF
run_stdin "[execute]	/bin/true" --sandbox-profile "$WORK_DIR/extra_rules.json"
test "$rc" -ne 0
check $? "a profile with macOS extra_rules is refused" "$out"

cat > "$WORK_DIR/no_fork.json" << EOF
{ "read_write": ["$ALLOWED"], "allow_fork": false }
EOF
run_stdin "[execute]	/bin/true" --sandbox-profile "$WORK_DIR/no_fork.json"
test "$rc" -ne 0
check $? "allow_fork false is refused (not supported on Linux yet)" "$out"

out="$("$REPLAY" --mcp-server --allow-write "$ALLOWED" < /dev/null 2>&1)"
rc=$?
test "$rc" -ne 0
check $? "the MCP server refuses to start sandboxed until its Unix socket rule exists" "$out"
case "$out" in *"MCP server mode with the sandbox is not available on Linux yet"*) r=0 ;; *) r=1 ;; esac
check $r "the MCP refusal says why" "$out"

echo ""
echo "=== 5. the --verbose listing ==="
run_stdin "[execute]	/bin/true" --verbose --allow-write "$ALLOWED"
case "$out" in *"Sandbox (Linux Landlock, ABI "*) r=0 ;; *) r=1 ;; esac
check $r "it names Landlock and its ABI" "$out"
case "$out" in *"  read-write: $ALLOWED  [granted]"*) r=0 ;; *) r=1 ;; esac
check $r "it lists the write grant" "$out"
case "$out" in *"  read-only: /usr  [baseline]"*) r=0 ;; *) r=1 ;; esac
check $r "it lists the baseline" "$out"
case "$out" in *"  execute: /  [allow_exec]"*) r=0 ;; *) r=1 ;; esac
check $r "it lists program execution" "$out"
case "$out" in *"Not covered by the sandbox:"*) r=0 ;; *) r=1 ;; esac
check $r "it lists the gaps" "$out"

echo ""
echo "=== 6. running programs ==="
printf '#!/bin/sh\necho built-tool-ran\n' > "$ALLOWED/tool.sh"
/bin/chmod +x "$ALLOWED/tool.sh"
run_stdin "[execute]	$ALLOWED/tool.sh" --allow-write "$ALLOWED"
case "$out" in *"built-tool-ran"*) r=0 ;; *) r=1 ;; esac
check $r "a program in a write folder runs (execute is allowed everywhere)" "$out"

echo ""
echo "=== 7. the system call filter ==="
PROBE_LOG="$WORK_DIR/probe-build.log"
if [ -x /usr/bin/clang ]; then
    /usr/bin/clang -O1 -Wall -o "$WORK_DIR/probe" "$SCRIPT_DIR/sandbox_syscall_probe.c" > "$PROBE_LOG" 2>&1
    status=$?
else
    status=127
fi
if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 127 ]; then
        echo "  skipped: no /usr/bin/clang to build the probe"
    else
        check 1 "building the system call probe" "$(/bin/cat "$PROBE_LOG")"
    fi
else
    echo "probe" > "$ALLOWED/probe.txt"
    # Unsandboxed, for comparison: xattrs work (where the file system allows them).
    plain="$("$WORK_DIR/probe" "$ALLOWED/probe.txt" < /dev/null 2>&1)"
    NL=$'\n'
    run_stdin "[execute]	$WORK_DIR/probe	$ALLOWED/probe.txt" --allow-write "$ALLOWED" --allow-read "$WORK_DIR/probe"
    for call in setxattr lsetxattr removexattr lremovexattr fsetxattr fremovexattr setxattrat removexattrat; do
        # Whole lines: "setxattr EACCES" is also the tail of "fsetxattr EACCES".
        case "$NL$out$NL" in *"$NL$call EACCES$NL"*) r=0 ;; *) r=1 ;; esac
        check $r "$call is denied with EACCES, even inside a write grant" "sandboxed: $out; unsandboxed: $plain"
    done
    case "$out" in *"getxattr ENODATA"*|*"getxattr ENOTSUP"*) r=0 ;; *) r=1 ;; esac
    check $r "getxattr still works (reading memos is allowed)" "$out"
    case "$out" in *"io_uring_setup ENOSYS"*) r=0 ;; *) r=1 ;; esac
    check $r "io_uring is unavailable (ENOSYS)" "sandboxed: $out; unsandboxed: $plain"
    case "$out" in *"TIOCSTI EACCES"*) r=0 ;; *) r=1 ;; esac
    check $r "TIOCSTI is denied (EACCES, not the kernel's ENOTTY)" "sandboxed: $out; unsandboxed: $plain"
    case "$out" in *"TIOCGWINSZ ENOTTY"*) r=0 ;; *) r=1 ;; esac
    check $r "other ioctls reach the kernel (TIOCGWINSZ gives ENOTTY)" "$out"
fi

# A playlist file: in stdin mode replay ignores --cache and never gets that far.
cat > "$WORK_DIR/memo.json" << EOF
[{ "action": "execute", "tool": "/bin/true" }]
EOF
out="$("$REPLAY" --sandbox --cache-dir "$ALLOWED/cache" --cache-memo xattr "$WORK_DIR/memo.json" 2>&1)"
rc=$?
test "$rc" -ne 0
check $? "--cache-memo xattr with the sandbox is refused" "$out"
case "$out" in *"cannot be used with the sandbox on Linux"*) r=0 ;; *) r=1 ;; esac
check $r "the refusal says why" "$out"

# gate writes its memo by making a read-only input writable for the call and restoring
# the mode afterwards, which changes the input's ctime. Under the sandbox the write
# could only fail, so gate must not try: the input's ctime stays put.
GATE="$(/usr/bin/dirname -- "$REPLAY")/gate"
if [ ! -x "$GATE" ]; then
    echo "  skipped: no gate next to replay"
else
    for name in ro-plain ro-sandboxed; do
        echo "$name" > "$ALLOWED/$name.txt"
        /bin/chmod 444 "$ALLOWED/$name.txt"
    done
    before="$(/usr/bin/stat -c '%z' "$ALLOWED/ro-plain.txt")"
    /bin/sleep 0.05
    out="$("$GATE" -c "$ALLOWED/gate-cache-plain" -i "$ALLOWED/ro-plain.txt" -- /bin/true 2>&1)"
    after="$(/usr/bin/stat -c '%z' "$ALLOWED/ro-plain.txt")"
    test "$before" != "$after"
    check $? "control: unsandboxed gate writes its memo, changing a read-only input's ctime" "before $before, after $after; $out"

    before="$(/usr/bin/stat -c '%z %a' "$ALLOWED/ro-sandboxed.txt")"
    /bin/sleep 0.05
    out="$("$GATE" --sandbox --allow-write "$ALLOWED" -c "$ALLOWED/gate-cache-sandboxed" -i "$ALLOWED/ro-sandboxed.txt" -- /bin/true 2>&1)"
    rc=$?
    after="$(/usr/bin/stat -c '%z %a' "$ALLOWED/ro-sandboxed.txt")"
    test "$rc" -eq 0 && test "$before" = "$after"
    check $? "sandboxed gate leaves a read-only input's ctime and mode alone" "rc $rc, before $before, after $after; $out"
fi

echo ""
echo "=== 8. documented gaps, pinned ==="
/bin/chmod 644 "$OUTSIDE/secret.txt"
run_stdin "[execute]	/bin/chmod	600	$OUTSIDE/secret.txt" --allow-write "$ALLOWED"
mode="$(/usr/bin/stat -c %a "$OUTSIDE/secret.txt")"
test "$mode" = "600"
check $? "chmod outside the grants still works (Landlock does not cover metadata)" "mode $mode; $out"

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
