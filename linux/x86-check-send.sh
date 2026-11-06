#!/bin/bash
# Take the working tree to an Intel Mac and run linux/x86-check.sh there (plan Phase 3, the
# x86_64 tests), or pack it for copying by hand.
#
# Usage: linux/x86-check-send.sh --bundle [FILE]
#        linux/x86-check-send.sh [user@]host [x86-check.sh options...]
#        linux/x86-check-send.sh --status [user@]host
#        linux/x86-check-send.sh --fetch [user@]host
#
#   --bundle   write the sources to FILE (default .build-linux/replay-x86-src.tar.gz) and print
#              how to run them on the Intel Mac: copy the file there (AirDrop, a USB drive), then
#                tar -xzf replay-x86-src.tar.gz -C ~ && ~/replay-x86-src/linux/x86-check.sh
#   host       copy the sources over SSH to ~/replay-x86-src on that Mac (replacing the last
#              copy) and start linux/x86-check.sh there in the background, so it keeps running
#              if the connection drops. Its output goes to ~/replay-x86-check.log there.
#              Options after the host go to linux/x86-check.sh (see its --help).
#   --status   print the last lines of that log
#   --fetch    copy that log here, to .build-linux/x86-check-<host>.log, and print its summary
#
# The sources are the working tree, not the last commit: tracked files as they are now plus
# untracked files that are not ignored (so private/ and build folders stay here).
# SOURCE-INFO.txt in the copy names the commit and whether the tree had changes.
#
# Needs Remote Login (System Settings > General > Sharing) on the Intel Mac and an SSH key
# this Mac can use to log in there. Inside a command sandbox (such as an agent's) SSH needs to
# run outside it.

MODE=""
TARGET=""
BUNDLE=""

case "${1:-}" in
    --bundle)
        MODE="bundle"
        BUNDLE="${2:-}"
        ;;
    --status|--fetch)
        MODE="${1#--}"
        TARGET="${2:-}"
        if [ -z "$TARGET" ]; then
            echo "Error: $1 needs a host (see --help)" >&2
            exit 1
        fi
        ;;
    ""|-h|--help)
        /usr/bin/sed -n '2,26p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "Error: unknown option '$1' (see --help)" >&2
        exit 1
        ;;
    *)
        MODE="run"
        TARGET="$1"
        shift
        ;;
esac

# The host goes into ssh and scp arguments: letters, digits, dots, dashes, underscores and
# one user@ only.
case "$TARGET" in
    *[!A-Za-z0-9.@_-]*|-*|*@*@*)
        echo "Error: '$TARGET' does not look like [user@]host" >&2
        exit 1
        ;;
esac
# The options for linux/x86-check.sh go into a remote command line: plain words only.
REMOTE_ARGS=""
if [ "$MODE" = "run" ]; then
    for arg in "$@"; do
        case "$arg" in
            ''|*[!A-Za-z0-9-]*)
                echo "Error: option '$arg' for linux/x86-check.sh must be letters, digits and dashes" >&2
                exit 1
                ;;
        esac
        REMOTE_ARGS="$REMOTE_ARGS $arg"
    done
fi

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find the repository root above linux/" >&2
    exit 1
fi
SSH=(/usr/bin/ssh -o ConnectTimeout=15)
REMOTE_LOG="replay-x86-check.log"

if [ "$MODE" = "status" ]; then
    "${SSH[@]}" "$TARGET" "/usr/bin/tail -n 25 ~/$REMOTE_LOG"
    exit $?
fi

if [ "$MODE" = "fetch" ]; then
    LOCAL_LOG="$REPO_DIR/.build-linux/x86-check-${TARGET#*@}.log"
    /bin/mkdir -p "$REPO_DIR/.build-linux"
    "${SSH[@]}" "$TARGET" "/bin/cat ~/$REMOTE_LOG" > "$LOCAL_LOG"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: reading ~/$REMOTE_LOG on $TARGET failed with status $status" >&2
        exit 1
    fi
    echo "== Saved $LOCAL_LOG"
    /usr/bin/grep -E '^== |^  (PASS|FAIL): \[|Passed: |FAILED: |SKIPPED' "$LOCAL_LOG" | /usr/bin/tail -n 60
    exit 0
fi

# Pack the working tree.
GIT=/usr/bin/git
FILES="$("$GIT" -C "$REPO_DIR" -c core.quotepath=off ls-files --cached --others --exclude-standard)"
status=$?
if [ "$status" -ne 0 ] || [ -z "$FILES" ]; then
    echo "Error: git ls-files failed in $REPO_DIR (status $status)" >&2
    exit 1
fi
STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/replay-x86-send.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$STAGE" ] || [ ! -d "$STAGE" ]; then
    echo "Error: could not create a temporary folder" >&2
    exit 1
fi
cleanup() {
    /bin/rm -rf "${STAGE:?}"
}
trap cleanup EXIT

LIST="$STAGE/files.txt"
: > "$LIST"
count=0
while IFS= read -r path; do
    case "$path" in
        '"'*)
            echo "Error: git quoted the file name $path; rename it or pack by hand" >&2
            exit 1
            ;;
        .build*|build/*)
            continue
            ;;
    esac
    # A tracked file deleted in the working tree is left out, as a commit of the tree would.
    if [ -e "$REPO_DIR/$path" ] || [ -L "$REPO_DIR/$path" ]; then
        printf '%s\n' "$path" >> "$LIST"
        count=$((count + 1))
    fi
done <<EOF
$FILES
EOF

/bin/mkdir -p "$STAGE/replay-x86-src"
COPYFILE_DISABLE=1 /usr/bin/tar -C "$REPO_DIR" --no-mac-metadata --no-xattrs -cf - -T "$LIST" \
    | /usr/bin/tar -C "$STAGE/replay-x86-src" -xf -
copy_status=("${PIPESTATUS[@]}")
if [ "${copy_status[0]}" -ne 0 ] || [ "${copy_status[1]}" -ne 0 ]; then
    echo "Error: copying the working tree failed (tar: ${copy_status[0]} and ${copy_status[1]})" >&2
    exit 1
fi

COMMIT="$("$GIT" -C "$REPO_DIR" rev-parse --short HEAD)"
CHANGES="$("$GIT" -C "$REPO_DIR" status --porcelain)"
if [ -n "$CHANGES" ]; then
    CHANGED_COUNT="$(printf '%s\n' "$CHANGES" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    STATE="with $CHANGED_COUNT changed or new paths"
else
    STATE="clean"
fi
printf 'commit %s, working tree %s, packed %s\n' "$COMMIT" "$STATE" "$(/bin/date '+%Y-%m-%d %H:%M')" > "$STAGE/replay-x86-src/SOURCE-INFO.txt"

if [ "$MODE" = "bundle" ]; then
    if [ -z "$BUNDLE" ]; then
        /bin/mkdir -p "$REPO_DIR/.build-linux"
        BUNDLE="$REPO_DIR/.build-linux/replay-x86-src.tar.gz"
    fi
else
    BUNDLE="$STAGE/replay-x86-src.tar.gz"
fi
COPYFILE_DISABLE=1 /usr/bin/tar -C "$STAGE" --no-mac-metadata --no-xattrs -czf "$BUNDLE" replay-x86-src
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: writing $BUNDLE failed with status $status" >&2
    exit 1
fi
SIZE_LINE="$(/usr/bin/du -h "$BUNDLE")"
echo "== Packed $count files (commit $COMMIT, working tree $STATE): ${SIZE_LINE%%	*}"

if [ "$MODE" = "bundle" ]; then
    echo "== Wrote $BUNDLE"
    echo "On the Intel Mac, from the folder you copied it to:"
    echo "  /bin/rm -rf ~/replay-x86-src && /usr/bin/tar -xzf replay-x86-src.tar.gz -C ~ && ~/replay-x86-src/linux/x86-check.sh"
    exit 0
fi

echo "== Copying to $TARGET"
/usr/bin/scp -q -o ConnectTimeout=15 "$BUNDLE" "$TARGET:replay-x86-src.tar.gz"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: scp to $TARGET failed with status $status (Remote Login on, and an SSH key this Mac can use?)" >&2
    exit 1
fi
# One remote command line, run by the login shell there (zsh on macOS): unpack, then start
# the check detached from this connection.
REMOTE="/bin/rm -rf ~/replay-x86-src && /usr/bin/tar -xzf ~/replay-x86-src.tar.gz -C ~ && /bin/rm -f ~/replay-x86-src.tar.gz"
REMOTE="$REMOTE && { /usr/bin/nohup /bin/bash ~/replay-x86-src/linux/x86-check.sh$REMOTE_ARGS > ~/$REMOTE_LOG 2>&1 < /dev/null & }"
"${SSH[@]}" "$TARGET" "$REMOTE"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: unpacking or starting the check on $TARGET failed with status $status" >&2
    exit 1
fi
echo "== Started linux/x86-check.sh$REMOTE_ARGS on $TARGET (the first run takes one to two hours)"
echo "Progress: $0 --status $TARGET"
echo "Result:   $0 --fetch $TARGET"
exit 0
