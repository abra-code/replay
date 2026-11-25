#!/bin/bash
# Build and run the test suite on macOS, then on Linux, and pass only if both pass.
# There is no CI, so this is the cross-platform check before a commit that touches
# shared code. Runs on a Mac.
#
# Usage: test/run-both.sh [Debug|Release] [--docker] [--linux-only|--macos-only]
#   Debug|Release  the build configuration for both platforms (default Debug)
#   --docker       run the Linux half in Docker (linux/docker.sh, Ubuntu 24.04, 4 KiB
#                  pages) instead of the agent-vm box (linux/agent-vm.sh, Debian 13,
#                  16 KiB pages)
#   --linux-only, --macos-only  run one half
#
# The Linux half skips what is not ported yet; test/test_all.sh lists each skip with
# the plan phase that removes it.

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
    echo "error: run this on a Mac; on Linux run linux/build.sh and test/test_all.sh directly" >&2
    exit 2
fi

# linux/build.sh takes the configuration in lower case.
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

run_linux() {
    local runner
    local build_dir
    local scratch_args
    if [ "$USE_DOCKER" -eq 1 ]; then
        runner="$REPO_DIR/linux/docker.sh"
        local machine
        machine="$(/usr/bin/uname -m)"
        if [ "$machine" = "arm64" ]; then
            machine="aarch64"
        fi
        # docker.sh mounts the repository at /src; linux/build.sh then builds into
        # .build-linux/<machine> there.
        build_dir="/src/.build-linux/$machine/$LINUX_CONFIG"
        scratch_args=""
    else
        runner="$REPO_DIR/linux/agent-vm.sh"
        # The box shares the repository at its own path. Its build products go on the
        # box's disk: the shared folder is slow with many small files.
        build_dir="/home/agent/build-linux/$LINUX_CONFIG"
        scratch_args="--scratch-path /home/agent/build-linux"
    fi

    echo "=== Linux: linux/build.sh $LINUX_CONFIG $scratch_args"
    # scratch_args is empty or two words, so it is left unquoted on purpose.
    "$runner" linux/build.sh "$LINUX_CONFIG" $scratch_args
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo "error: the Linux build failed (status $status)" >&2
        LINUX_RESULT="build failed"
        return 1
    fi
    echo "=== Linux: test/test_all.sh $build_dir"
    "$runner" test/test_all.sh "$build_dir"
    status=$?
    if [ "$status" -ne 0 ]; then
        LINUX_RESULT="suite failed"
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
