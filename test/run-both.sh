#!/bin/bash
# Build and run the test suite on macOS, then on Linux, and pass only if both pass: the
# cross-platform check before a commit that touches shared code, on the Mac, before CI runs
# the same on GitHub after the push. Runs on a Mac.
#
# Usage: test/run-both.sh [Debug|Release] [--docker] [--linux-only|--macos-only]
#   Debug|Release  the build configuration for both platforms (default Debug)
#   --docker       run the Linux half in Docker (linux/docker.sh, Ubuntu 24.04, 4 KiB
#                  pages). Default: the agent-vm box (linux/agent-vm.sh, Debian 13, 16 KiB
#                  pages) when agent-vm is installed, else Docker; linux/build-and-test.sh
#                  decides and runs the Linux half
#   --linux-only, --macos-only  run one half
#
# The Linux half skips what does not apply there; test/test_all.sh lists each skip with its
# reason.

SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$SCRIPT_DIR/.." && pwd)"

CONFIG="Debug"
USE_DOCKER=0
RUN_MACOS=1
RUN_LINUX=1

usage() {
    echo "Usage: $0 [Debug|Release] [--docker] [--linux-only|--macos-only]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        Debug|Release) CONFIG="$1" ;;
        --docker) USE_DOCKER=1 ;;
        --linux-only) RUN_MACOS=0 ;;
        --macos-only) RUN_LINUX=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$RUN_MACOS" -eq 0 ] && [ "$RUN_LINUX" -eq 0 ]; then
    echo "error: --linux-only and --macos-only exclude each other" >&2
    exit 2
fi

host_os="$(/usr/bin/uname -s)"
if [ "$host_os" != "Darwin" ]; then
    echo "error: run this on a Mac; on Linux run linux/build-and-test.sh" >&2
    exit 2
fi

# The Linux configuration in lower case, as linux/build.sh names its build folders.
if [ "$CONFIG" = "Debug" ]; then
    LINUX_CONFIG="debug"
else
    LINUX_CONFIG="release"
fi

MACOS_RESULT="not run"
LINUX_RESULT="not run"

run_macos() {
    echo "=== macOS: ./build.sh $CONFIG"
    "$REPO_DIR/build.sh" "$CONFIG"
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo "error: the macOS build failed (status $status)" >&2
        MACOS_RESULT="build failed"
        return 1
    fi
    echo "=== macOS: test/test_all.sh build/$CONFIG"
    "$SCRIPT_DIR/test_all.sh" "$REPO_DIR/build/$CONFIG"
    status=$?
    if [ "$status" -ne 0 ]; then
        MACOS_RESULT="suite failed"
        return 1
    fi
    MACOS_RESULT="passed"
    return 0
}

# linux/build-and-test.sh builds and runs the suites in the box or the container, and says
# which; its own messages tell a failed build from failed suites.
run_linux() {
    local with="auto"
    if [ "$USE_DOCKER" -eq 1 ]; then
        with="docker"
    fi
    echo "=== Linux: linux/build-and-test.sh --with $with $LINUX_CONFIG"
    "$REPO_DIR/linux/build-and-test.sh" --with "$with" "$LINUX_CONFIG"
    local status=$?
    if [ "$status" -ne 0 ]; then
        LINUX_RESULT="failed (status $status)"
        return 1
    fi
    LINUX_RESULT="passed"
    return 0
}

failed=0
if [ "$RUN_MACOS" -eq 1 ]; then
    run_macos
    status=$?
    if [ "$status" -ne 0 ]; then
        failed=1
    fi
fi
if [ "$RUN_LINUX" -eq 1 ]; then
    run_linux
    status=$?
    if [ "$status" -ne 0 ]; then
        failed=1
    fi
fi

echo ""
echo "macOS: $MACOS_RESULT"
echo "Linux: $LINUX_RESULT"
exit "$failed"
