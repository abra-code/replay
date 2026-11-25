#!/bin/bash
# Build the replay tools for Linux and run the test suites, in whichever Linux environment is
# at hand. On a Mac:
#   agent-vm  the replay-linux box of linux/agent-vm.sh (Debian 13 on ARM): the first choice
#   docker    the test container of linux/docker.sh (Ubuntu 24.04 with the pinned Swift
#             image), in any engine the docker CLI reaches: Colima, a Lima machine made from
#             template:docker, Docker Desktop
# On Linux it builds and tests in place, with the toolchain pinned in linux/swift-image.
#
# Usage: linux/build-and-test.sh [--with auto|agent-vm|docker|local] [--arch aarch64|x86_64]
#                                [--box NAME] [--scratch-path DIR] [--no-test]
#                                [debug|release|both]
#   --with          the environment. auto (default): local on Linux; on a Mac agent-vm when
#                   it is installed, else docker
#   --arch          x86_64 on Apple silicon runs in Docker only, emulated, which needs Colima
#                   with Rosetta (colima start --vz-rosetta); agent-vm runs ARM only
#   --box           the agent-vm box (default replay-linux; make it with linux/agent-vm.sh --setup)
#   --scratch-path  the build folder. Default: .build-linux/<machine> in the repository, and
#                   ~/build-linux in an agent-vm box (its shared folder is slow and as
#                   case-insensitive as the Mac's disk). A leading ~/ is the home folder of
#                   the machine that builds. In Docker only a folder in the repository (a
#                   relative path) outlives the container.
#   --no-test       build only
#   debug|release|both  the configurations (default debug)
#
# Examples:
#   linux/build-and-test.sh                       # debug, in the box or else in Docker
#   linux/build-and-test.sh --with docker both    # both configurations in Docker
#   linux/build-and-test.sh --arch x86_64 release # x86_64 in Docker, emulated on Apple silicon
#
# Notes:
# - Inside a command sandbox (such as an agent's): agent-vm reaches the box through its
#   control socket, and docker through the engine's socket, which the sandbox must allow;
#   starting a stopped box starts the Virtualization framework, which needs to run outside it.
# - Docker runs the suites as root, the box as its own user. Both should pass.

WITH="auto"
ARCH=""
BOX=""
SCRATCH_PATH=""
TEST=1
CONFIGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --with|--arch|--box|--scratch-path)
            if [ $# -lt 2 ]; then
                echo "Error: $1 needs a value (see --help)" >&2
                exit 1
            fi
            case "$1" in
                --with) WITH="$2" ;;
                --arch) ARCH="$2" ;;
                --box) BOX="$2" ;;
                --scratch-path) SCRATCH_PATH="$2" ;;
            esac
            shift
            ;;
        --no-test)
            TEST=0
            ;;
        debug|Debug)
            CONFIGS+=(debug)
            ;;
        release|Release)
            CONFIGS+=(release)
            ;;
        both)
            CONFIGS+=(debug release)
            ;;
        -h|--help)
            /usr/bin/sed -n '2,35p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unrecognized argument: $1 (see --help)" >&2
            exit 1
            ;;
    esac
    shift
done
if [ ${#CONFIGS[@]} -eq 0 ]; then
    CONFIGS=(debug)
fi

case "$ARCH" in
    "") ;;
    aarch64|arm64) ARCH="aarch64" ;;
    x86_64|amd64) ARCH="x86_64" ;;
    *)
        echo "Error: --arch takes aarch64 or x86_64, not '$ARCH'" >&2
        exit 1
        ;;
esac

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find the repository root above linux/" >&2
    exit 1
fi

OS_NAME="$(/usr/bin/uname -s)"
MACHINE="$(/usr/bin/uname -m)"
case "$MACHINE" in
    arm64) MACHINE="aarch64" ;;
    amd64) MACHINE="x86_64" ;;
esac

# The executable of a tool, printed, or nothing. $1: agent-vm, docker, colima or limactl;
# AGENT_VM and DOCKER override the first two.
find_tool() {
    local name="$1"
    local chosen
    case "$name" in
        agent-vm) chosen="${AGENT_VM:-}" ;;
        docker) chosen="${DOCKER:-}" ;;
    esac
    if [ -n "$chosen" ]; then
        if [ -x "$chosen" ]; then
            echo "$chosen"
        fi
        return 0
    fi
    local candidate
    for candidate in "$HOME/.local/bin/$name" "/opt/homebrew/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 0
}

if [ "$WITH" = "auto" ]; then
    if [ "$OS_NAME" = "Linux" ]; then
        WITH="local"
    elif [ -n "$ARCH" ] && [ "$ARCH" != "$MACHINE" ]; then
        WITH="docker"
    elif [ -n "$(find_tool agent-vm)" ]; then
        WITH="agent-vm"
    elif [ -n "$(find_tool docker)" ]; then
        WITH="docker"
    else
        echo "Error: neither agent-vm nor docker found. Install agent-vm (then linux/agent-vm.sh --setup)," >&2
        echo "or Colima (brew install colima docker; colima start), or set AGENT_VM or DOCKER to its path." >&2
        exit 1
    fi
    echo "== Linux environment: $WITH (choose with --with agent-vm|docker)"
fi

# Builds and tests one configuration here, on Linux. $1: debug or release.
build_and_test_here() {
    local config="$1"
    local scratch="$SCRATCH_PATH"
    if [ -z "$scratch" ]; then
        scratch="$REPO_DIR/.build-linux/$MACHINE"
    fi
    case "$scratch" in
        "~/"*) scratch="$HOME/${scratch#\~/}" ;;
        /*) ;;
        *) scratch="$PWD/$scratch" ;;
    esac
    echo ""
    echo "== $config: building in $scratch"
    "$REPO_DIR/build-linux.sh" "$config" --scratch-path "$scratch"
    local build_status=$?
    if [ "$build_status" -ne 0 ]; then
        echo "Error: the $config build failed with status $build_status" >&2
        return 1
    fi
    if [ "$TEST" -ne 1 ]; then
        return 0
    fi
    echo ""
    echo "== $config: running the test suites"
    "$REPO_DIR/test/test_all.sh" "$scratch/$config"
    local test_status=$?
    if [ "$test_status" -ne 0 ]; then
        echo "Error: the $config test suites failed (status $test_status)" >&2
        return 1
    fi
    return 0
}

# The arguments for this script inside another environment.
INNER_ARGS=(--with local)
if [ "$TEST" -ne 1 ]; then
    INNER_ARGS+=(--no-test)
fi
INNER_ARGS+=("${CONFIGS[@]}")

case "$WITH" in
    local)
        if [ "$OS_NAME" != "Linux" ]; then
            echo "Error: --with local runs on Linux only (this is $OS_NAME); use agent-vm or docker" >&2
            exit 1
        fi
        if [ -n "$ARCH" ] && [ "$ARCH" != "$MACHINE" ]; then
            echo "Error: this machine is $MACHINE and cannot build or test $ARCH here" >&2
            exit 1
        fi
        failures=0
        for config in "${CONFIGS[@]}"; do
            build_and_test_here "$config"
            if [ $? -ne 0 ]; then
                failures=$((failures + 1))
            fi
        done
        if [ "$failures" -ne 0 ]; then
            echo "== $failures of ${#CONFIGS[@]} configuration(s) failed"
            exit 1
        fi
        echo "== Done: ${CONFIGS[*]}"
        exit 0
        ;;
    agent-vm)
        if [ -n "$ARCH" ] && [ "$ARCH" != "aarch64" ]; then
            echo "Error: agent-vm runs ARM machines only; build $ARCH with --with docker" >&2
            exit 1
        fi
        AGENT_VM_PATH="$(find_tool agent-vm)"
        if [ -z "$AGENT_VM_PATH" ]; then
            echo "Error: agent-vm not found. Install it, or set AGENT_VM=/path/to/agent-vm." >&2
            exit 1
        fi
        BOX_ARGS=()
        if [ -n "$BOX" ]; then
            BOX_ARGS=(--box "$BOX")
        fi
        # The box shares the repository at its own path, and expands ~/ in its own home.
        AGENT_VM="$AGENT_VM_PATH" exec "$LINUX_DIR/agent-vm.sh" "${BOX_ARGS[@]}" /bin/bash "$LINUX_DIR/build-and-test.sh" \
            "${INNER_ARGS[@]}" --scratch-path "${SCRATCH_PATH:-~/build-linux}"
        ;;
    docker)
        if [ -n "$BOX" ]; then
            echo "Error: --box applies to agent-vm only" >&2
            exit 1
        fi
        DOCKER_PATH="$(find_tool docker)"
        if [ -z "$DOCKER_PATH" ]; then
            echo "Error: docker not found. Install Colima (brew install colima docker), or set DOCKER=/path/to/docker." >&2
            exit 1
        fi
        ENGINE_INFO="$("$DOCKER_PATH" info --format '{{.Architecture}}' 2>&1)"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: the docker CLI reaches no engine:" >&2
            echo "$ENGINE_INFO" >&2
            if [ -n "$(find_tool colima)" ]; then
                echo "Start Colima: colima start (colima start --vz-rosetta to also run x86_64)" >&2
            elif [ -n "$(find_tool limactl)" ]; then
                echo "Start a Lima machine made from template:docker, and use the docker context it prints" >&2
            fi
            exit 1
        fi
        DOCKER_ARGS=()
        if [ -n "$ARCH" ]; then
            DOCKER_ARGS=(--arch "$ARCH")
        fi
        if [ -n "$SCRATCH_PATH" ]; then
            INNER_ARGS+=(--scratch-path "$SCRATCH_PATH")
        fi
        # The repository is mounted at /src, the container's working folder.
        DOCKER="$DOCKER_PATH" exec "$LINUX_DIR/docker.sh" "${DOCKER_ARGS[@]}" /bin/bash ./linux/build-and-test.sh "${INNER_ARGS[@]}"
        ;;
    *)
        echo "Error: --with takes auto, agent-vm, docker or local, not '$WITH'" >&2
        exit 1
        ;;
esac
