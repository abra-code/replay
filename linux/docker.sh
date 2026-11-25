#!/bin/bash
# Run a command in the replay Linux test container, with this repository mounted at /src.
#
# Usage: linux/docker.sh [--arch aarch64|x86_64] [--seccomp-unconfined] [command [args...]]
#   Default command: an interactive bash.
#   Example: linux/docker.sh linux/build.sh release
#
# The image is built from linux/Dockerfile on top of the Swift image pinned in
# linux/swift-image, and tagged replay-linux-test:<arch>. Docker's layer cache makes the
# build step a no-op when nothing changed.
#
# --arch x86_64 needs an engine that can run amd64 images (emulation on Apple silicon).
# --seccomp-unconfined drops Docker's default system call filter, which ThreadSanitizer needs.
#
# Notes:
# - The repository is a bind mount. On a macOS host it accepts xattr names that Linux
#   file systems refuse (plan, fact 9), so xattr tests must run on the container's own
#   file system, not under /src.
# - Builds go to .build-linux/<machine> inside the repository (gitignored).

ARCH=""
SECCOMP_UNCONFINED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            if [ $# -lt 2 ]; then
                echo "Error: --arch needs aarch64 or x86_64" >&2
                exit 1
            fi
            ARCH="$2"
            shift
            ;;
        --seccomp-unconfined)
            SECCOMP_UNCONFINED=1
            ;;
        -h|--help)
            /usr/bin/sed -n '2,13p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            break
            ;;
    esac
    shift
done

DOCKER="${DOCKER:-}"
if [ -z "$DOCKER" ]; then
    for candidate in /opt/homebrew/bin/docker /usr/local/bin/docker /usr/bin/docker; do
        if [ -x "$candidate" ]; then
            DOCKER="$candidate"
            break
        fi
    done
fi
if [ -z "$DOCKER" ] || [ ! -x "$DOCKER" ]; then
    echo "Error: docker not found. Install Docker or Colima, or set DOCKER=/path/to/docker." >&2
    exit 1
fi

if [ -z "$ARCH" ]; then
    ARCH="$(/usr/bin/uname -m)"
fi
case "$ARCH" in
    aarch64|arm64)
        ARCH="aarch64"
        PLATFORM="linux/arm64"
        ;;
    x86_64|amd64)
        ARCH="x86_64"
        PLATFORM="linux/amd64"
        ;;
    *)
        echo "Error: unsupported architecture '$ARCH' (use aarch64 or x86_64)" >&2
        exit 1
        ;;
esac

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find the repository root above linux/" >&2
    exit 1
fi

SWIFT_IMAGE=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ""|"#"*) ;;
        *)
            SWIFT_IMAGE="$line"
            break
            ;;
    esac
done < "$LINUX_DIR/swift-image"
if [ -z "$SWIFT_IMAGE" ]; then
    echo "Error: no image reference in $LINUX_DIR/swift-image" >&2
    exit 1
fi

IMAGE_TAG="replay-linux-test:$ARCH"
BUILD_LOG="$("$DOCKER" build --quiet --platform "$PLATFORM" --build-arg "SWIFT_IMAGE=$SWIFT_IMAGE" \
    -t "$IMAGE_TAG" -f "$LINUX_DIR/Dockerfile" "$LINUX_DIR" 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: building $IMAGE_TAG from $SWIFT_IMAGE failed with status $status:" >&2
    echo "$BUILD_LOG" >&2
    exit 1
fi

RUN_ARGS=(run --rm --platform "$PLATFORM" -v "$REPO_DIR:/src" -w /src)
if [ -t 0 ] && [ -t 1 ]; then
    RUN_ARGS+=(-it)
else
    RUN_ARGS+=(-i)
fi
if [ "$SECCOMP_UNCONFINED" -eq 1 ]; then
    RUN_ARGS+=(--security-opt seccomp=unconfined)
fi
RUN_ARGS+=("$IMAGE_TAG")
if [ $# -eq 0 ]; then
    RUN_ARGS+=(/bin/bash)
else
    RUN_ARGS+=("$@")
fi

"$DOCKER" "${RUN_ARGS[@]}"
