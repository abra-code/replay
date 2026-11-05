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
echo "=== 7. documented gaps, pinned ==="
/bin/chmod 644 "$OUTSIDE/secret.txt"
run_stdin "[execute]	/bin/chmod	600	$OUTSIDE/secret.txt" --allow-write "$ALLOWED"
mode="$(/usr/bin/stat -c %a "$OUTSIDE/secret.txt")"
test "$mode" = "600"
check $? "chmod outside the grants still works (Landlock does not cover metadata)" "mode $mode; $out"

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
