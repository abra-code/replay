#!/bin/bash
# The Linux sandbox's thread check.
#
#   1. sandbox/SandboxThreads.cpp, built here with test/sandbox_threads_check.cpp: an
#      unexpected thread fails the check and is named; an allowed one passes.
#   2. Linux only: replay's own output thread carries the name the check reports
#      ("replay-output"), and at the point where replay applies its sandbox the process
#      has no other thread. A playlist read from a FIFO stops replay inside
#      LoadPlaylist, which runs just before that point.
#
# Usage: test_sandbox_threads.sh [/path/to/replay]   (part 2 is skipped without it)
# Exit:  0 = all checks passed, 1 = a check or a build failed, 2 = no clang or no temporary folder

SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
REPLAY="${1:-}"

if [ -x /usr/bin/clang++ ]; then
    CXX=/usr/bin/clang++
else
    echo "Error: no clang++ at /usr/bin/clang++" >&2
    exit 2
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sandbox-threads.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "Error: could not create a temporary folder" >&2
    exit 2
fi

REPLAY_PID=""
WRITER_PID=""
cleanup() {
    if [ -n "$REPLAY_PID" ]; then
        kill "$REPLAY_PID" 2>/dev/null
    fi
    if [ -n "$WRITER_PID" ]; then
        kill "$WRITER_PID" 2>/dev/null
    fi
    /bin/rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT

failures=0

echo "=== 1. the thread check ==="
build_log="$("$CXX" -std=c++20 -O1 -Wall -Wextra -Werror -pthread -I "$REPO_DIR/sandbox/include" \
    -o "$WORK_DIR/check" "$REPO_DIR/sandbox/SandboxThreads.cpp" "$SCRIPT_DIR/sandbox_threads_check.cpp" 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    echo "  FAIL: building the check (status $status):"
    echo "$build_log"
    failures=$((failures + 1))
else
    "$WORK_DIR/check"
    status=$?
    if [ "$status" -ne 0 ]; then
        failures=$((failures + 1))
    fi
fi

echo ""
echo "=== 2. replay's threads before its sandbox ==="
HOST_OS="$(/usr/bin/uname -s)"
if [ "$HOST_OS" != "Linux" ]; then
    echo "  skipped: Linux only (the macOS sandbox covers the whole process)"
elif [ -z "$REPLAY" ] || [ ! -x "$REPLAY" ]; then
    echo "  skipped: no replay binary given"
else
    fifo="$WORK_DIR/playlist.json"
    /usr/bin/mkfifo "$fifo"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "  FAIL: mkfifo failed (status $status)"
        failures=$((failures + 1))
    else
        "$REPLAY" "$fifo" > "$WORK_DIR/out.txt" 2>&1 &
        REPLAY_PID=$!

        # Wait until replay is blocked opening the FIFO inside LoadPlaylist: the kernel
        # then shows "wait_for_partner" in /proc/<pid>/wchan. Kernels that hide it show
        # "0" there; the wait then falls back to seeing both threads, which may come a
        # little before LoadPlaylist.
        names=""
        count=0
        tries=0
        while [ "$tries" -lt 50 ]; do
            names=""
            count=0
            for task in /proc/"$REPLAY_PID"/task/*; do
                [ -r "$task/comm" ] || continue
                name=""
                read -r name < "$task/comm"
                names="$names $name"
                count=$((count + 1))
            done
            wchan=""
            if [ -r "/proc/$REPLAY_PID/wchan" ]; then
                read -r wchan < "/proc/$REPLAY_PID/wchan"
            fi
            if [ "$wchan" = "wait_for_partner" ]; then
                break
            fi
            if [ "$count" -ge 2 ] && [ "$wchan" = "0" ]; then
                break
            fi
            tries=$((tries + 1))
            /bin/sleep 0.1
        done
        if [ "$wchan" != "wait_for_partner" ]; then
            echo "  note: could not see replay blocked on the FIFO (wchan \"$wchan\"); checking the threads as found"
        fi

        case "$names" in
            *" replay-output"*)
                echo "  PASS: the output thread is named replay-output" ;;
            *)
                echo "  FAIL: no thread named replay-output (threads:$names)"
                failures=$((failures + 1)) ;;
        esac
        if [ "$count" -eq 2 ]; then
            echo "  PASS: two threads before the sandbox, the main and the output thread"
        else
            echo "  FAIL: $count threads before the sandbox, expected 2 (threads:$names)"
            failures=$((failures + 1))
        fi

        # Let replay finish: an empty playlist array. It is written from the background,
        # because opening a FIFO for writing blocks until a reader opens it, and a replay
        # that exited early or never reaches LoadPlaylist would hang the test.
        printf '[]\n' > "$fifo" &
        WRITER_PID=$!
        tries=0
        while kill -0 "$REPLAY_PID" 2>/dev/null && [ "$tries" -lt 100 ]; do
            tries=$((tries + 1))
            /bin/sleep 0.1
        done
        if kill -0 "$REPLAY_PID" 2>/dev/null; then
            echo "  FAIL: replay did not exit within 10 seconds of the empty playlist"
            failures=$((failures + 1))
            kill "$REPLAY_PID" 2>/dev/null
        fi
        wait "$REPLAY_PID"
        status=$?
        REPLAY_PID=""
        if [ "$status" -ne 0 ]; then
            echo "  FAIL: replay exited with status $status after the empty playlist:"
            /bin/cat "$WORK_DIR/out.txt"
            failures=$((failures + 1))
        fi
        kill "$WRITER_PID" 2>/dev/null
        wait "$WRITER_PID" 2>/dev/null
        WRITER_PID=""
    fi
fi

echo ""
if [ "$failures" -ne 0 ]; then
    echo "FAILED: $failures part(s) failed"
    exit 1
fi
echo "All checks passed"
exit 0
