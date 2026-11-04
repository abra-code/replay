#!/bin/bash
# Run a command in the replay Linux build box (agent-vm), with this repository shared at its
# own path. The agent-vm counterpart of linux/docker.sh, and the default Linux dev loop.
#
# Usage: linux/agent-vm.sh [--box NAME] [--setup] [command [args...]]
#   Default command: an interactive login shell in the box.
#   Example: linux/agent-vm.sh ./build-linux.sh debug --scratch-path /home/agent/build-linux
#   --setup  make what is missing: the Debian 13 image replay-debian13, the image
#            replay-build from it (linux/agent-vm/swift-toolchain/recipe.json), and the box
#   --box    the box to use (default replay-linux; created from replay-build by --setup)
#
# The box runs Debian 13 on ARM with the swift.org toolchain pinned in the recipe (keep it
# equal to linux/swift-image). Its kernel has 16 KiB memory pages. It has no network and needs
# none. What stays in Docker (linux/docker.sh, linux/runtime-check.sh): x86_64, Fedora, and
# release builds on Ubuntu 24.04 for the glibc floor (plan D3).
#
# Notes:
# - The shared folder is as case-insensitive as the Mac's disk, and slow with many small
#   files: keep the build products on the box's disk (--scratch-path /home/agent/...).
# - agent-vm needs the Virtualization framework, so this does not work inside a sandbox that
#   blocks it (such as an agent's command sandbox).

BOX="replay-linux"
SETUP=0
BASE_IMAGE="replay-debian13"
BUILD_IMAGE="replay-build"

while [ $# -gt 0 ]; do
    case "$1" in
        --box)
            if [ $# -lt 2 ]; then
                echo "Error: --box needs a name" >&2
                exit 1
            fi
            BOX="$2"
            shift
            ;;
        --setup)
            SETUP=1
            ;;
        -h|--help)
            /usr/bin/sed -n '2,15p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            break
            ;;
    esac
    shift
done

AGENT_VM="${AGENT_VM:-}"
if [ -z "$AGENT_VM" ]; then
    for candidate in "$HOME/.local/bin/agent-vm" /usr/local/bin/agent-vm /opt/homebrew/bin/agent-vm; do
        if [ -x "$candidate" ]; then
            AGENT_VM="$candidate"
            break
        fi
    done
fi
if [ -z "$AGENT_VM" ] || [ ! -x "$AGENT_VM" ]; then
    echo "Error: agent-vm not found. Install it, or set AGENT_VM=/path/to/agent-vm." >&2
    exit 1
fi

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find the repository root above linux/" >&2
    exit 1
fi
RECIPE="$LINUX_DIR/agent-vm/swift-toolchain/recipe.json"

if [ "$SETUP" -eq 1 ]; then
    "$AGENT_VM" image info "$BASE_IMAGE" > /dev/null 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Creating image $BASE_IMAGE (Debian 13)"
        "$AGENT_VM" image create "$BASE_IMAGE" --linux debian-13
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: creating image $BASE_IMAGE failed with status $status" >&2
            exit 1
        fi
    fi
    "$AGENT_VM" image info "$BUILD_IMAGE" > /dev/null 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Creating image $BUILD_IMAGE from $BASE_IMAGE with $RECIPE"
        "$AGENT_VM" image create "$BUILD_IMAGE" --from "$BASE_IMAGE" --recipe "$RECIPE"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: creating image $BUILD_IMAGE failed with status $status" >&2
            exit 1
        fi
    fi
    "$AGENT_VM" box status "$BOX" > /dev/null 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Creating box $BOX from $BUILD_IMAGE"
        "$AGENT_VM" box create "$BOX" --image "$BUILD_IMAGE"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: creating box $BOX failed with status $status" >&2
            exit 1
        fi
    fi
fi

START_LOG="$("$AGENT_VM" box start "$BOX" 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: starting box $BOX failed with status $status:" >&2
    echo "$START_LOG" >&2
    echo "If the box does not exist yet: linux/agent-vm.sh --setup" >&2
    exit 1
fi

if [ $# -eq 0 ]; then
    exec "$AGENT_VM" exec --box "$BOX" --project "$REPO_DIR" --tty -- /bin/bash --login
fi
exec "$AGENT_VM" exec --box "$BOX" --project "$REPO_DIR" -- "$@"
