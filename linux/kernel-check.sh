#!/bin/bash
# Run the Linux test suites on a newer kernel than Docker's, in an agent-vm box, with the
# tools built in Docker (Ubuntu 24.04, the glibc floor). Docker on a Mac runs Linux 6.8
# (Landlock ABI 4); the default box image, ubuntu-agents (Ubuntu 26.04), runs Linux 7.0
# (Landlock ABI 8), so this covers the sandbox code paths for ABI 6 and newer.
#
# Usage: linux/kernel-check.sh [--box NAME] [--image IMAGE] [--no-build] [--no-setup] [debug|release]
#   --box       the box to use (default replay-ubuntu; created from --image when missing)
#   --image     the agent-vm image for a new box (default ubuntu-agents); any Ubuntu or
#               Debian image on ARM whose distribution packages libswiftlang
#   --no-build  use the tools already in .build-linux/aarch64/<config>
#   --no-setup  leave the box's packages and network rules alone, for a box that has the
#               test tools already (one made from the replay-build image: linux/agent-vm.sh)
#
# The tools are built in Docker with the pinned swift.org toolchain, as releases are; the box
# runs them on the distribution's own Swift runtime (libswiftlang, Ubuntu 26.04: Swift 6.1.3),
# as a packaged install would. linux/kernel-check-setup.sh installs it and the test tools as
# root. The box's network allows the Ubuntu and Debian archives (pack:ubuntu, pack:debian) and
# example.com (the HTTPS test of test_replay_sandbox.sh), nothing else. The box is a test
# machine: delete it with agent-vm box delete when done.
#
# Notes:
# - Inside a command sandbox (such as an agent's) this script needs to run outside it:
#   exec reaches the box's supervisor through a Unix socket, and starting a box starts
#   the Virtualization framework.
# - Expected on Ubuntu 26.04: test_all.sh reports test_replay.sh and test_fingerprint.sh
#   failed, from their plutil checks only (the distribution's plutil is broken, see
#   linux/kernel-check-setup.sh), and test_dispatch.sh skipped until Phase 4.

BOX="replay-ubuntu"
IMAGE="ubuntu-agents"
CONFIG="debug"
BUILD=1
SETUP=1

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
        --image)
            if [ $# -lt 2 ]; then
                echo "Error: --image needs an image name" >&2
                exit 1
            fi
            IMAGE="$2"
            shift
            ;;
        --no-build)
            BUILD=0
            ;;
        --no-setup)
            SETUP=0
            ;;
        debug|Debug)
            CONFIG="debug"
            ;;
        release|Release)
            CONFIG="release"
            ;;
        -h|--help)
            /usr/bin/sed -n '2,28p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1' (see --help)" >&2
            exit 1
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
BUILD_DIR="$REPO_DIR/.build-linux/aarch64/$CONFIG"

if [ "$BUILD" -eq 1 ]; then
    echo "== Building ($CONFIG) in Docker"
    "$LINUX_DIR/docker.sh" --arch aarch64 linux/build.sh "$CONFIG"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: the Docker build failed with status $status" >&2
        exit 1
    fi
fi
if [ ! -x "$BUILD_DIR/replay" ]; then
    echo "Error: $BUILD_DIR/replay is missing; build it first (drop --no-build)" >&2
    exit 1
fi

NET_RULES=(--allow pack:ubuntu --allow pack:debian --allow example.com)
"$AGENT_VM" box status "$BOX" > /dev/null 2>&1
status=$?
if [ "$status" -ne 0 ]; then
    if [ "$SETUP" -eq 0 ]; then
        echo "Error: box $BOX does not exist; --no-setup needs a box that has the test tools (linux/agent-vm.sh --setup makes one)" >&2
        exit 1
    fi
    echo "== Creating box $BOX from image $IMAGE"
    "$AGENT_VM" box create "$BOX" --image "$IMAGE" --net allowlist "${NET_RULES[@]}"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: creating box $BOX failed with status $status" >&2
        exit 1
    fi
elif [ "$SETUP" -eq 1 ]; then
    NET_LOG="$("$AGENT_VM" box network "$BOX" "${NET_RULES[@]}" 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: adding the network rules to box $BOX failed with status $status:" >&2
        echo "$NET_LOG" >&2
        echo "A box made with --net off needs: agent-vm box stop $BOX; agent-vm box network $BOX --net allowlist" >&2
        exit 1
    fi
fi

START_LOG="$("$AGENT_VM" box start "$BOX" 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: starting box $BOX failed with status $status:" >&2
    echo "$START_LOG" >&2
    exit 1
fi

KERNEL="$("$AGENT_VM" exec --box "$BOX" -- /bin/uname -r)"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: running uname in box $BOX failed with status $status" >&2
    exit 1
fi
echo "== Box $BOX runs Linux $KERNEL"

if [ "$SETUP" -eq 1 ]; then
    echo "== Installing the Swift runtime and the test tools in the box"
    "$AGENT_VM" exec --box "$BOX" --project "$REPO_DIR" --user root -- "$LINUX_DIR/kernel-check-setup.sh"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: linux/kernel-check-setup.sh failed in box $BOX with status $status" >&2
        exit 1
    fi
fi

failures=0

echo "== test/test_sandbox_linux.sh"
"$AGENT_VM" exec --box "$BOX" --project "$REPO_DIR" -- \
    "$REPO_DIR/test/test_sandbox_linux.sh" "$BUILD_DIR/replay"
status=$?
if [ "$status" -ne 0 ]; then
    echo "FAIL: test_sandbox_linux.sh exited with status $status"
    failures=$((failures + 1))
fi

echo "== test/test_all.sh"
"$AGENT_VM" exec --box "$BOX" --project "$REPO_DIR" -- \
    "$REPO_DIR/test/test_all.sh" "$BUILD_DIR"
status=$?
if [ "$status" -ne 0 ]; then
    echo "FAIL: test_all.sh exited with status $status"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "== $failures suite(s) failed on Linux $KERNEL"
    exit 1
fi
echo "== All suites passed on Linux $KERNEL"
exit 0
