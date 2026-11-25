#!/bin/bash
# Run the Linux build of the replay tools on distribution Swift runtimes they were not
# built with (plan D2 and fact 18):
#   Debian 13, libswiftlang        (Swift 6.0.3, the oldest runtime replay supports)
#   Fedora 44, swift-lang-runtime  (Swift 6.3.2, installed into /usr/lib64)
# Neither container has a Swift toolchain, so this also checks that the tools' RUNPATH
# and the default search path find each distribution's runtime.
#
# Usage: linux/runtime-check.sh [--arch aarch64|x86_64] [debug|release] [debian|fedora]...
#   Default: this machine's architecture, debug, both distributions.
#   Build first: linux/docker.sh linux/build.sh [debug|release]

ARCH=""
CONFIG="debug"
DISTROS=()

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
        debug|Debug)
            CONFIG="debug"
            ;;
        release|Release)
            CONFIG="release"
            ;;
        debian|fedora)
            DISTROS+=("$1")
            ;;
        -h|--help)
            /usr/bin/sed -n '2,12p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unrecognized argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done
if [ ${#DISTROS[@]} -eq 0 ]; then
    DISTROS=(debian fedora)
fi

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
# Check only the per-architecture folder here; the inner script checks each tool, inside
# the container where the binaries run.
if [ ! -d "$REPO_DIR/.build-linux/$ARCH" ]; then
    echo "Error: $REPO_DIR/.build-linux/$ARCH not found. Build first: linux/docker.sh --arch $ARCH linux/build.sh $CONFIG" >&2
    exit 1
fi

overall=0
for distro in "${DISTROS[@]}"; do
    image_tag="replay-runtime-$distro:$ARCH"
    build_log="$("$DOCKER" build --quiet --platform "$PLATFORM" -t "$image_tag" \
        -f "$LINUX_DIR/runtime/$distro.Dockerfile" "$LINUX_DIR/runtime" 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: building $image_tag failed with status $status:" >&2
        echo "$build_log" >&2
        overall=1
        continue
    fi
    # Mount .build-linux at the same path the build container used (/src/.build-linux),
    # so any path SwiftPM recorded in the build folder still resolves.
    "$DOCKER" run --rm --platform "$PLATFORM" \
        -v "$REPO_DIR/.build-linux:/src/.build-linux:ro" \
        -v "$LINUX_DIR/runtime-check-inner.sh:/runtime-check-inner.sh:ro" \
        "$image_tag" /bin/bash /runtime-check-inner.sh "/src/.build-linux/$ARCH/$CONFIG"
    status=$?
    if [ "$status" -ne 0 ]; then
        overall=1
    fi
done

if [ "$overall" -ne 0 ]; then
    echo "runtime check: FAILED" >&2
    exit 1
fi
echo "runtime check: passed on ${DISTROS[*]} ($ARCH, $CONFIG)"
