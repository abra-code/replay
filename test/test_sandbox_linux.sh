#!/bin/bash
# The Linux sandbox's own behavior, including the network and process creation,
# beyond what the shared
# sandbox suites check on both platforms: denials outside the grants, paths that do not
# exist yet, hard links, refused options, the --verbose listing, the system call filter,
# the denied network and process creation, the i386 compat entry on x86_64, the documented gaps, terminals, and shared memory. Linux only; it reports itself skipped elsewhere.
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

echo ""
echo "=== 5. the --verbose listing ==="
run_stdin "[execute]	/bin/true" --verbose --allow-write "$ALLOWED"
case "$out" in *"Sandbox (Linux Landlock, ABI "*) r=0 ;; *) r=1 ;; esac
check $r "it names Landlock and its ABI" "$out"
ABI="$(printf '%s\n' "$out" | /usr/bin/sed -n 's/^Sandbox (Linux Landlock, ABI \([0-9]*\)).*/\1/p' | /usr/bin/head -n 1)"
case "$out" in *"  read-write: $ALLOWED  [granted]"*) r=0 ;; *) r=1 ;; esac
check $r "it lists the write grant" "$out"
case "$out" in *"  read-only: /usr  [baseline]"*) r=0 ;; *) r=1 ;; esac
check $r "it lists the baseline" "$out"
case "$out" in *"  execute: /  [allow_exec]"*) r=0 ;; *) r=1 ;; esac
check $r "it lists program execution" "$out"
case "$out" in *"Not covered by the sandbox:"*) r=0 ;; *) r=1 ;; esac
check $r "it lists the gaps" "$out"
LISTING="$out"

# /etc/resolv.conf is a link into /run on systems with systemd-resolved (Ubuntu, Fedora),
# NetworkManager or resolvconf; Landlock judges the link's target, so the baseline grants
# targets of links in /etc. Docker writes a plain file there, so the link case runs only
# on such a system (the x86_64 machine of linux/x86-check.sh is one).
RESOLV_PLAIN=""
if [ -e /etc/resolv.conf ]; then
    RESOLV_PLAIN="$(/bin/cat /etc/resolv.conf 2>/dev/null)"
fi
# Empty content (or a failed read) would match any output, so the check needs some.
if [ -n "$RESOLV_PLAIN" ]; then
    run_stdin "[execute]	/bin/cat	/etc/resolv.conf" --allow-write "$ALLOWED"
    case "$out" in *"$RESOLV_PLAIN"*) r=0 ;; *) r=1 ;; esac
    check $r "a sandboxed program reads /etc/resolv.conf (host name lookups need it)" "$out"
    RESOLV_TARGET=""
    if [ -L /etc/resolv.conf ]; then
        RESOLV_TARGET="$(/usr/bin/readlink -f /etc/resolv.conf)"
    fi
    case "$RESOLV_TARGET" in
        "" | /etc/* | /usr/* | /proc/*)
            echo "  SKIP: /etc/resolv.conf is not a link out of the baseline folders here"
            ;;
        *)
            RESOLV_TARGET_DIR="$(/usr/bin/dirname "$RESOLV_TARGET")"
            case "$LISTING" in *"  read-only: $RESOLV_TARGET_DIR  [baseline: a link in /etc]"*|*"  read-only: $RESOLV_TARGET  [baseline: a link in /etc]"*) r=0 ;; *) r=1 ;; esac
            check $r "the listing names the target of the /etc/resolv.conf link ($RESOLV_TARGET)" "$LISTING"
            ;;
    esac
else
    echo "  SKIP: no readable, non-empty /etc/resolv.conf here"
fi

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
    # Playlists, whose commands the user wrote, keep Unix sockets on every ABI unless
    # --deny-unix-sockets is given.
    case "$NL$out$NL" in *"${NL}socket-unix ok$NL"*) r=0 ;; *) r=1 ;; esac
    check $r "a playlist command can create a Unix socket" "$out"
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
echo "=== 8. Unix sockets in MCP server mode ==="
# An AI agent chooses the MCP server's commands, so below Landlock ABI 9, which cannot
# limit connecting to Unix sockets by path, the sandbox denies creating them there.
if [ ! -x "$WORK_DIR/probe" ]; then
    echo "  skipped: no system call probe (section 7)"
else
    call="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"execute_command\",\"arguments\":{\"command\":\"$WORK_DIR/probe $ALLOWED/probe.txt\"}}}"
    out="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        "$call" \
        | "$REPLAY" --allow-write "$ALLOWED" --allow-read "$WORK_DIR/probe" --mcp-server 2>&1)"
    rc=$?
    test "$rc" -eq 0
    check $? "the MCP server starts sandboxed" "rc $rc; $out"
    case "$ABI" in
        ''|*[!0-9]*) check 1 "the Landlock ABI is known (section 5)" "ABI '$ABI'" ;;
        *)
            if [ "$ABI" -lt 9 ]; then
                case "$out" in *"socket-unix EACCES"*) r=0 ;; *) r=1 ;; esac
                check $r "below ABI 9, an MCP command cannot create a Unix socket (EACCES)" "$out"
            else
                case "$out" in *"socket-unix ok"*) r=0 ;; *) r=1 ;; esac
                check $r "from ABI 9, an MCP command can create a Unix socket (Landlock limits connecting)" "$out"
            fi
            ;;
    esac
    case "$out" in *"socketpair-unix ok"*) r=0 ;; *) r=1 ;; esac
    check $r "socketpair stays allowed in MCP mode" "$out"
    case "$out" in *"socket-inet ok"*) r=0 ;; *) r=1 ;; esac
    check $r "other address families stay allowed in MCP mode" "$out"
    case "$out" in *"setxattr EACCES"*) r=0 ;; *) r=1 ;; esac
    check $r "the rest of the filter applies in MCP mode too" "$out"

    # Playlists and gate keep Unix sockets (section 7) unless --deny-unix-sockets asks
    # for the MCP server's limit.
    NL=$'\n'
    run_stdin "[execute]	$WORK_DIR/probe	$ALLOWED/probe.txt" --allow-write "$ALLOWED" --allow-read "$WORK_DIR/probe" --deny-unix-sockets
    GATE="$(/usr/bin/dirname -- "$REPLAY")/gate"
    gate_out=""
    if [ -x "$GATE" ]; then
        gate_out="$("$GATE" --deny-unix-sockets --allow-write "$ALLOWED" --allow-read "$WORK_DIR/probe" \
                     -c "$ALLOWED/gate-cache-unix" -f -- "$WORK_DIR/probe" "$ALLOWED/probe.txt" 2>&1)"
    fi
    case "$ABI" in
        ''|*[!0-9]*) check 1 "the Landlock ABI is known (section 5)" "ABI '$ABI'" ;;
        *)
            if [ "$ABI" -lt 9 ]; then
                case "$NL$out$NL" in *"${NL}socket-unix EACCES$NL"*) r=0 ;; *) r=1 ;; esac
                check $r "below ABI 9, --deny-unix-sockets: a playlist command cannot create a Unix socket" "$out"
                if [ -x "$GATE" ]; then
                    case "$NL$gate_out$NL" in *"${NL}socket-unix EACCES$NL"*) r=0 ;; *) r=1 ;; esac
                    check $r "below ABI 9, gate --deny-unix-sockets: the command cannot create a Unix socket" "$gate_out"
                fi
            fi
            ;;
    esac
    case "$NL$out$NL" in *"${NL}socketpair-unix ok$NL"*) r=0 ;; *) r=1 ;; esac
    check $r "--deny-unix-sockets: socketpair stays allowed" "$out"
    case "$NL$out$NL" in *"${NL}socket-inet ok$NL"*) r=0 ;; *) r=1 ;; esac
    check $r "--deny-unix-sockets: the network stays allowed" "$out"
fi

echo ""
echo "=== 9. the network denied ==="
# --deny-network and "allow_network": false: creating a socket of any family fails with
# EACCES, Unix included on every ABI, as macOS denies connecting to Unix sockets then;
# socketpair stays allowed.
NL=$'\n'
if [ ! -x "$WORK_DIR/probe" ]; then
    echo "  skipped: no system call probe (section 7)"
else
    run_stdin "[execute]	$WORK_DIR/probe	$ALLOWED/probe.txt" --allow-write "$ALLOWED" --allow-read "$WORK_DIR/probe" --deny-network
    for call in socket-inet socket-inet6 socket-netlink socket-packet socket-vsock; do
        case "$NL$out$NL" in *"$NL$call EACCES$NL"*) r=0 ;; *) r=1 ;; esac
        check $r "--deny-network: $call is denied with EACCES" "$out"
    done
    case "$NL$out$NL" in *"${NL}socketpair-unix ok$NL"*) r=0 ;; *) r=1 ;; esac
    check $r "--deny-network: socketpair stays allowed" "$out"
    case "$NL$out$NL" in *"${NL}socket-unix EACCES$NL"*) r=0 ;; *) r=1 ;; esac
    check $r "--deny-network: Unix sockets are denied too, on every ABI" "$out"
    case "$NL$out$NL" in *"${NL}fork ok$NL"*) r=0 ;; *) r=1 ;; esac
    check $r "--deny-network: processes can still be started" "$out"

    cat > "$WORK_DIR/no_network.json" << EOF2
{ "read_write": ["$ALLOWED"], "read_only": ["$WORK_DIR/probe"], "allow_network": false }
EOF2
    run_stdin "[execute]	$WORK_DIR/probe	$ALLOWED/probe.txt" --sandbox-profile "$WORK_DIR/no_network.json"
    case "$NL$out$NL" in *"${NL}socket-inet EACCES$NL"*) r=0 ;; *) r=1 ;; esac
    check $r "\"allow_network\": false in a profile denies the network without --deny-network" "$out"
fi
run_stdin "[execute]	/bin/true" --verbose --allow-write "$ALLOWED" --deny-network
case "$out" in *"Also denied: the network"*) r=0 ;; *) r=1 ;; esac
check $r "--verbose lists the denied network" "$out"

echo ""
echo "=== 10. process creation denied ==="
# "allow_fork": false: no new process (fork, vfork, clone without CLONE_THREAD; clone3 is
# unavailable), so posix_spawn fails too and no program can be started; threads stay.
cat > "$WORK_DIR/no_fork.json" << EOF2
{ "read_write": ["$ALLOWED"], "allow_fork": false }
EOF2
: > "$WORK_DIR/creates.txt"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    printf '[create file]\t%s/nofork-%s.txt\tcontent %s\n' "$ALLOWED" "$i" "$i" >> "$WORK_DIR/creates.txt"
done
out="$("$REPLAY" --sandbox-profile "$WORK_DIR/no_fork.json" < "$WORK_DIR/creates.txt" 2>&1)"
rc=$?
count="$(/usr/bin/find "$ALLOWED" -maxdepth 1 -name 'nofork-*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
test "$rc" -eq 0 && test "$count" = "20"
check $? "\"allow_fork\": false: 20 concurrent actions run (threads are allowed)" "rc $rc, $count files; $out"
run_stdin "[execute]	/bin/true" --sandbox-profile "$WORK_DIR/no_fork.json"
test "$rc" -ne 0
check $? "\"allow_fork\": false: an execute action fails" "$out"
case "$out" in *"posix_spawn(/bin/true): Permission denied"*) r=0 ;; *) r=1 ;; esac
check $r "the failure is posix_spawn's EACCES (Permission denied)" "$out"
run_stdin "[create file]	$ALLOWED/verbose-nofork.txt	x" --verbose --sandbox-profile "$WORK_DIR/no_fork.json"
case "$out" in *"Also denied: starting processes"*) r=0 ;; *) r=1 ;; esac
check $r "--verbose lists the denied process creation" "$out"

# The filter alone, through a launcher that installs it and then replaces itself with
# the probe (execv starts no process): the calls that create processes, one by one.
FILTER_LOG="$WORK_DIR/filter-build.log"
if [ ! -x "$WORK_DIR/probe" ]; then
    echo "  skipped: no system call probe (section 7)"
elif [ ! -x /usr/bin/clang++ ]; then
    echo "  skipped: no /usr/bin/clang++ to build the filter launcher"
else
    /usr/bin/clang++ -std=c++20 -O1 -Wall -Wextra -Werror -o "$WORK_DIR/filter-exec" \
        "$SCRIPT_DIR/../sandbox/SandboxSeccomp.cpp" "$SCRIPT_DIR/sandbox_filter_exec.cpp" > "$FILTER_LOG" 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        check 1 "building the filter launcher" "$(/bin/cat "$FILTER_LOG")"
    else
        plain="$("$WORK_DIR/filter-exec" -- "$WORK_DIR/probe" "$ALLOWED/probe.txt" 2>&1)"
        out="$("$WORK_DIR/filter-exec" --deny-fork -- "$WORK_DIR/probe" "$ALLOWED/probe.txt" 2>&1)"
        for call in fork vfork posix_spawn; do
            case "$NL$plain$NL" in *"$NL$call ok$NL"*) r=0 ;; *) r=1 ;; esac
            check $r "control: $call works under the filter without --deny-fork" "$plain"
            case "$NL$out$NL" in *"$NL$call EACCES$NL"*) r=0 ;; *) r=1 ;; esac
            check $r "$call is denied with EACCES" "$out"
        done
        # x86_64 only: its own fork system call, which glibc's fork() does not use.
        case "$NL$plain$NL" in
            *"${NL}fork-syscall "*)
                case "$NL$out$NL" in *"${NL}fork-syscall EACCES$NL"*) r=0 ;; *) r=1 ;; esac
                check $r "the fork system call is denied with EACCES" "$out"
                ;;
        esac
        case "$NL$out$NL" in *"${NL}clone3 ENOSYS$NL"*) r=0 ;; *) r=1 ;; esac
        check $r "clone3 is unavailable (ENOSYS), so glibc falls back to clone" "$out"
        # A container's own filter (Docker's) may already answer ENOSYS to clone3.
        case "$NL$plain$NL" in
            *"${NL}clone3 ENOSYS$NL"*) echo "  note: clone3 gives ENOSYS without --deny-fork too (the container's filter), so the check above cannot tell whether the filter blocks it" ;;
        esac
        case "$NL$out$NL" in *"${NL}thread ok$NL"*) r=0 ;; *) r=1 ;; esac
        check $r "a thread can still be created" "$out"
        case "$NL$out$NL" in *"${NL}socket-inet ok$NL"*) r=0 ;; *) r=1 ;; esac
        check $r "the network stays allowed" "$out"
    fi
fi

echo ""
echo "=== 11. the i386 compat entry (x86_64 only) ==="
# A 32-bit program reaches the kernel through the compat entry, which the filter checks
# with its own system call numbers. The same probe built with -m32 must get the same
# answers as the native one under every filter option, and its two i386 ways to create
# a socket (the direct call and socketcall) must be denied where the options say so.
MACHINE="$(/usr/bin/uname -m)"
PROBE32_LOG="$WORK_DIR/probe32-build.log"
if [ "$MACHINE" != "x86_64" ]; then
    echo "  skipped: not an x86_64 machine ($MACHINE)"
elif [ ! -x "$WORK_DIR/filter-exec" ]; then
    echo "  skipped: no filter launcher (section 10)"
else
    /usr/bin/clang -m32 -O1 -Wall -o "$WORK_DIR/probe32" "$SCRIPT_DIR/sandbox_syscall_probe.c" > "$PROBE32_LOG" 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "  skipped: clang -m32 cannot build the probe (is a 32-bit C library missing? gcc-multilib on Debian and Ubuntu):"
        /usr/bin/head -n 5 "$PROBE32_LOG" | /usr/bin/sed 's/^/    /'
    else
        "$WORK_DIR/probe32" "$ALLOWED/probe.txt" < /dev/null > "$WORK_DIR/probe32-plain.txt" 2>&1
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "  skipped: the 32-bit probe does not run (status $status; a kernel without IA32 emulation?): $(/usr/bin/head -c 200 "$WORK_DIR/probe32-plain.txt")"
        else
            # Every line of the native probe's output must appear unchanged in the 32-bit one.
            same_answers() {
                # $1: native output; $2: 32-bit output. Prints the lines that differ.
                local line
                while IFS= read -r line; do
                    case "$NL$2$NL" in
                        *"$NL$line$NL"*) ;;
                        *) echo "native: $line; 32-bit: $(printf '%s\n' "$2" | /usr/bin/grep "^${line%% *} ")" ;;
                    esac
                done <<EOF
$1
EOF
            }
            for options in "" "--deny-network --deny-unix-sockets" "--deny-fork"; do
                # $options is unquoted on purpose: it holds zero, one or two options.
                out64="$("$WORK_DIR/filter-exec" $options -- "$WORK_DIR/probe" "$ALLOWED/probe.txt" < /dev/null 2>&1)"
                out32="$("$WORK_DIR/filter-exec" $options -- "$WORK_DIR/probe32" "$ALLOWED/probe.txt" < /dev/null 2>&1)"
                diffs="$(same_answers "$out64" "$out32")"
                test -n "$out64" && test -z "$diffs"
                check $? "the 32-bit probe gets the native answers with options '${options:-none}'" "$diffs"
            done

            # The i386 socket calls, one by one. Without options: all allowed (control).
            # The tools' network denial: every family on both calls. The MCP server below
            # Landlock ABI 9 (Unix sockets only): the direct call by family, socketcall for
            # every family, since the filter cannot read its arguments. The network alone
            # (the launcher's option, not used by the tools): the reverse by family.
            expect_lines() {
                # $1: options; $2: what; then pairs of "<name> <answer>" lines expected.
                local options="$1" what="$2" expected missing=""
                shift 2
                # $options is unquoted on purpose, as above.
                out32="$("$WORK_DIR/filter-exec" $options -- "$WORK_DIR/probe32" "$ALLOWED/probe.txt" < /dev/null 2>&1)"
                for expected in "$@"; do
                    case "$NL$out32$NL" in *"$NL$expected$NL"*) ;; *) missing="$missing [$expected]" ;; esac
                done
                test -z "$missing"
                check $? "$what" "missing:$missing; output: $out32"
            }
            expect_lines "" "control: both i386 socket calls work without options" \
                "socket-syscall-unix ok" "socket-syscall-inet ok" "socketcall-unix ok" "socketcall-inet ok"
            expect_lines "--deny-network --deny-unix-sockets" "the network denied: both i386 socket calls are denied for every family" \
                "socket-syscall-unix EACCES" "socket-syscall-inet EACCES" "socketcall-unix EACCES" "socketcall-inet EACCES" "socketpair-unix ok"
            expect_lines "--deny-unix-sockets" "Unix sockets denied: the direct call by family, socketcall for every family" \
                "socket-syscall-unix EACCES" "socket-syscall-inet ok" "socketcall-unix EACCES" "socketcall-inet EACCES" "socketpair-unix ok"
            expect_lines "--deny-network" "the network without Unix sockets: the direct call by family, socketcall for every family" \
                "socket-syscall-unix ok" "socket-syscall-inet EACCES" "socketcall-unix EACCES" "socketcall-inet EACCES"
            expect_lines "--deny-fork" "process creation denied: i386 fork, vfork, clone and clone3" \
                "fork EACCES" "fork-syscall EACCES" "vfork EACCES" "posix_spawn EACCES" "clone3 ENOSYS" "thread ok"
        fi
    fi
fi

echo ""
echo "=== 12. documented gaps, pinned ==="
/bin/chmod 644 "$OUTSIDE/secret.txt"
run_stdin "[execute]	/bin/chmod	600	$OUTSIDE/secret.txt" --allow-write "$ALLOWED"
mode="$(/usr/bin/stat -c %a "$OUTSIDE/secret.txt")"
test "$mode" = "600"
check $? "chmod outside the grants still works (Landlock does not cover metadata)" "mode $mode; $out"

echo ""
echo "=== 13. terminals ==="
# Only the terminal on replay's own descriptors 0 to 2 is granted, not all of /dev/pts:
# another terminal of the user must be neither readable nor writable.
if [ ! -x /usr/bin/python3 ]; then
    echo "  skipped: needs /usr/bin/python3"
else
    out="$(/usr/bin/python3 "$SCRIPT_DIR/sandbox_terminal_check.py" "$REPLAY" "$ALLOWED" 2>&1)"
    case "$out" in *"OWN-WRITE-ALLOWED"*) r=0 ;; *) r=1 ;; esac
    check $r "a step can write to replay's own terminal by name" "$out"
    case "$out" in *"OTHER-WRITE-REFUSED"*) r=0 ;; *) r=1 ;; esac
    check $r "a step cannot write to another terminal" "$out"
    case "$out" in *"OTHER-READ-REFUSED"*) r=0 ;; *) r=1 ;; esac
    check $r "a step cannot open another terminal for reading" "$out"
fi

echo ""
echo "=== 13b. adopted orphans are reaped during the run ==="
# As subreaper replay adopts every orphaned descendant; one that exits must not stay a
# zombie until replay exits. Step 1 leaves an orphan that exits after 0.3 s, step 2
# waits, step 3 counts replay's zombie children (replay is the steps' parent, $PPID).
ZOMBIE_COUNT='cat /proc/[0-9]*/stat 2>/dev/null | /usr/bin/awk -v p="$PPID" '"'"'{ sub(/.*\) /, ""); if ($2 == p && $1 == "Z") n++ } END { print "zombies=" n+0 }'"'"''
run_stdin "$(printf '[execute]\t/bin/sh\t-c\t(/bin/sleep 0.3 &)\n[execute]\t/bin/sleep\t1\n[execute]\t/bin/sh\t-c\t%s' "$ZOMBIE_COUNT")" \
    --serial --allow-write "$ALLOWED"
case "$out" in *"zombies=0"*) r=0 ;; *) r=1 ;; esac
check $r "sandboxed playlist: an adopted orphan that exited is reaped before the next step ends" "$out"

echo ""
echo "=== 14. processes that leave with setsid ==="
# A command that starts a process in its own session escapes the process group that a
# timeout kills. Under the sandbox replay and gate are its subreaper and end it when
# they exit; unsandboxed it keeps running, as before.
# The command waits (up to 2 s) for the pid file, so the file exists before replay or
# gate can exit and end the process: otherwise it could be ended before writing it.
SURVIVOR="setsid /bin/sh -c 'echo \$\$ > PIDFILE; exec sleep 300' < /dev/null > /dev/null 2>&1 & for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s PIDFILE ] && break; sleep 0.1; done"

# Waits up to 3 s for the process in $1 (a pid file) to be gone; returns 0 when gone.
gone_within_3s() {
    local pid
    pid="$(/bin/cat "$1" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        kill -0 "$pid" 2>/dev/null || return 0
        /bin/sleep 0.2
    done
    return 1
}

survivor_step() { # $1: pid file
    printf '[execute]\t/bin/sh\t-c\t%s\n' "${SURVIVOR//PIDFILE/$1}"
}

run_stdin "$(survivor_step "$ALLOWED/plain.pid")"
test -s "$ALLOWED/plain.pid" && ! gone_within_3s "$ALLOWED/plain.pid"
check $? "control: unsandboxed, the setsid process outlives replay" "$out"

run_stdin "$(survivor_step "$ALLOWED/boxed.pid")" --allow-write "$ALLOWED"
test -s "$ALLOWED/boxed.pid" && gone_within_3s "$ALLOWED/boxed.pid"
check $? "sandboxed playlist: the setsid process ends with replay" "$out"

mcp_command="${SURVIVOR//PIDFILE/$ALLOWED/mcp.pid}"
mcp_command="${mcp_command//\\/\\\\}"
mcp_command="${mcp_command//\"/\\\"}"
out="$(printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"execute_command\",\"arguments\":{\"command\":\"$mcp_command\"}}}" \
    | "$REPLAY" --allow-write "$ALLOWED" --mcp-server 2>&1)"
test -s "$ALLOWED/mcp.pid" && gone_within_3s "$ALLOWED/mcp.pid"
check $? "sandboxed MCP server: the setsid process ends when the server exits" "$out"

GATE="$(/usr/bin/dirname -- "$REPLAY")/gate"
if [ -x "$GATE" ]; then
    out="$("$GATE" --allow-write "$ALLOWED" -c "$ALLOWED/gate-cache-setsid" -f -- \
           /bin/sh -c "${SURVIVOR//PIDFILE/$ALLOWED/gate.pid}" 2>&1)"
    test -s "$ALLOWED/gate.pid" && gone_within_3s "$ALLOWED/gate.pid"
    check $? "sandboxed gate: the setsid process ends with gate" "$out"
else
    echo "  skipped: no gate next to replay"
fi

# Gives the process in $1 five seconds to end, then kills it, so that a regression that
# swallows SIGTERM fails the check below (status 137) instead of hanging the suite.
end_within_5s() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
        kill -0 "$1" 2>/dev/null || return 0
        /bin/sleep 0.2
    done
    kill -KILL "$1" 2>/dev/null
}

# Stopped by SIGTERM, as an MCP client stops its server: the descendants are ended
# first, then SIGTERM ends the server (exit status 143). The server reads its requests
# from a FIFO kept open here, so it is still running when the signal comes.
/usr/bin/mkfifo "$WORK_DIR/mcp-term.in"
mcp_command="${SURVIVOR//PIDFILE/$ALLOWED/mcpterm.pid}"
mcp_command="${mcp_command//\\/\\\\}"
mcp_command="${mcp_command//\"/\\\"}"
"$REPLAY" --allow-write "$ALLOWED" --mcp-server < "$WORK_DIR/mcp-term.in" > "$WORK_DIR/mcp-term.out" 2>&1 &
mcp_server=$!
exec 4> "$WORK_DIR/mcp-term.in"
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"execute_command\",\"arguments\":{\"command\":\"$mcp_command\"}}}" >&4
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -s "$ALLOWED/mcpterm.pid" ] && break
    /bin/sleep 0.1
done
kill -TERM "$mcp_server"
end_within_5s "$mcp_server"
wait "$mcp_server"
mcp_status=$?
exec 4>&-
test -s "$ALLOWED/mcpterm.pid" && gone_within_3s "$ALLOWED/mcpterm.pid" && [ "$mcp_status" -eq 143 ]
check $? "sandboxed MCP server stopped by SIGTERM: the setsid process ends, then the server (status 143)" \
    "status $mcp_status; $(/bin/cat "$WORK_DIR/mcp-term.out")"

if [ -x "$GATE" ]; then
    "$GATE" --allow-write "$ALLOWED" -c "$ALLOWED/gate-cache-term" -f -- \
        /bin/sh -c "${SURVIVOR//PIDFILE/$ALLOWED/gateterm.pid}; exec /bin/sleep 30" > "$WORK_DIR/gate-term.out" 2>&1 &
    gate_pid=$!
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        [ -s "$ALLOWED/gateterm.pid" ] && break
        /bin/sleep 0.1
    done
    kill -TERM "$gate_pid"
    end_within_5s "$gate_pid"
    wait "$gate_pid"
    gate_status=$?
    test -s "$ALLOWED/gateterm.pid" && gone_within_3s "$ALLOWED/gateterm.pid" && [ "$gate_status" -eq 143 ]
    check $? "sandboxed gate stopped by SIGTERM: the setsid process ends, then gate (status 143)" \
        "status $gate_status; $(/bin/cat "$WORK_DIR/gate-term.out")"
fi

# End the control's process, and any that a failed check above left running.
for name in plain boxed mcp gate mcpterm gateterm; do
    pid="$(/bin/cat "$ALLOWED/$name.pid" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null ;; esac
done

echo "=== 15. shared memory in /dev/shm ==="
# POSIX shared memory and named semaphores are files in /dev/shm; Python's
# multiprocessing locks need them. The baseline grants files there, not folders.
if [ -d /dev/shm ] && [ -x /usr/bin/python3 ]; then
    run_stdin "[execute]	/usr/bin/python3	$SCRIPT_DIR/sandbox_shm_probe.py" --allow-read "$SCRIPT_DIR" --allow-write "$ALLOWED"
    case "$out" in *LOCK-OK*) r=0 ;; *) r=1 ;; esac
    check $r "a multiprocessing lock works under the sandbox" "$out"
    case "$out" in *SHM-OK*) r=0 ;; *) r=1 ;; esac
    check $r "POSIX shared memory can be made, read and removed under the sandbox" "$out"
    case "$out" in *DIR-REFUSED*) r=0 ;; *) r=1 ;; esac
    check $r "a folder cannot be made in /dev/shm" "$out"
else
    echo "  skipped: no /dev/shm or no /usr/bin/python3"
fi

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
