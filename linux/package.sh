#!/bin/bash
# Builds the release tools and packs the Linux release tarballs for this machine's
# architecture. Runs on Linux with the toolchain pinned in linux/swift-image installed in
# /usr: in the pinned Swift image (linux/release.sh runs it there, for either architecture)
# or in the x86_64 machine of linux/x86-check.sh --package.
#
# Usage: linux/package.sh [--out DIR] [--scratch-path DIR] [--no-build]
#   --out DIR   where the tarballs go (default .build-linux/dist)
#   --scratch-path DIR  the build folder (default .build-linux/<arch>); linux/release.sh
#               passes a new one inside the container, so every release is a clean build
#   --no-build  pack the existing release build in the build folder
#
# Writes, with <version> from common/include/replay_version.h, <arch> from uname -m and
# <swift> the toolchain's Swift version:
#   replay_<version>_linux_<arch>.tar.gz
#       replay_<version>_linux_<arch>/bin/{replay,dispatch,fingerprint,gate} (debug
#       information stripped), install.sh (linux/install.sh), LICENSE, BUILD-INFO.txt
#   swift-runtime_<swift>_linux_<arch>.tar.gz
#       swift-runtime_<swift>_linux_<arch>/lib/abracode/swift/linux/: the Swift runtime
#       libraries the tools load, unchanged, plus LICENSE-Swift.txt, LICENSE-ICU.txt and
#       VERSION. Needed only where the system has no Swift runtime (plan D2). Unpacked into
#       the prefix that holds bin/, where the tools find it through their search entry
#       $ORIGIN/../lib/abracode/swift/linux.
#   a <tarball>.sha256 file for each.
#
# The source commit in BUILD-INFO.txt comes from REPLAY_SOURCE_COMMIT (linux/release.sh
# sets it) or from the SOURCE-INFO.txt of a linux/x86-check-send.sh bundle.

OUT_DIR=""
BUILD=1
SCRATCH_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            if [ $# -lt 2 ]; then
                echo "Error: --out needs a folder" >&2
                exit 1
            fi
            OUT_DIR="$2"
            shift
            ;;
        --scratch-path)
            if [ $# -lt 2 ]; then
                echo "Error: --scratch-path needs a folder" >&2
                exit 1
            fi
            SCRATCH_PATH="$2"
            shift
            ;;
        --no-build)
            BUILD=0
            ;;
        -h|--help)
            /usr/bin/sed -n '2,27p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unrecognized argument: $1 (see --help)" >&2
            exit 1
            ;;
    esac
    shift
done

OS_NAME="$(/usr/bin/uname -s)"
if [ "$OS_NAME" != "Linux" ]; then
    echo "Error: package.sh runs on Linux only (this is $OS_NAME); on a Mac use linux/release.sh" >&2
    exit 1
fi

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find the repository root above linux/" >&2
    exit 1
fi
if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$REPO_DIR/.build-linux/dist"
fi

ARCH="$(/usr/bin/uname -m)"
VERSION="$(/usr/bin/sed -n 's/^#define REPLAY_VERSION[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*$/\1/p' "$REPO_DIR/common/include/replay_version.h")"
if [ -z "$VERSION" ]; then
    echo "Error: no REPLAY_VERSION in common/include/replay_version.h" >&2
    exit 1
fi

SWIFT="/usr/bin/swift"
if [ ! -x "$SWIFT" ]; then
    echo "Error: no Swift toolchain at $SWIFT" >&2
    exit 1
fi
SWIFT_VERSION_LINE="$("$SWIFT" --version 2>&1 | /usr/bin/head -n 1)"
SWIFT_VERSION="$(printf '%s\n' "$SWIFT_VERSION_LINE" | /usr/bin/sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p')"
if [ -z "$SWIFT_VERSION" ]; then
    echo "Error: cannot read the Swift version from '$SWIFT_VERSION_LINE'" >&2
    exit 1
fi
# The toolchain's own runtime folder, the one the release tarball copies from.
TOOLCHAIN_RUNTIME="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$(/usr/bin/readlink -f "$SWIFT")")/../lib/swift/linux" 2>/dev/null && pwd)"
if [ -z "$TOOLCHAIN_RUNTIME" ] || [ ! -f "$TOOLCHAIN_RUNTIME/libFoundation.so" ]; then
    echo "Error: no libFoundation.so in the toolchain's runtime folder ('$TOOLCHAIN_RUNTIME')" >&2
    exit 1
fi
SWIFT_LICENSE="$(CDPATH= cd -P -- "$TOOLCHAIN_RUNTIME/../../../share/swift" 2>/dev/null && pwd)/LICENSE.txt"
if [ ! -f "$SWIFT_LICENSE" ]; then
    echo "Error: the toolchain's LICENSE.txt is not at $SWIFT_LICENSE" >&2
    exit 1
fi
ICU_LICENSE="$LINUX_DIR/licenses/ICU-LICENSE.txt"
if [ ! -f "$ICU_LICENSE" ]; then
    echo "Error: $ICU_LICENSE is missing (linux/licenses/fetch-icu-license.sh writes it)" >&2
    exit 1
fi

COMMIT="${REPLAY_SOURCE_COMMIT:-}"
if [ -z "$COMMIT" ] && [ -f "$REPO_DIR/SOURCE-INFO.txt" ]; then
    COMMIT="$(/bin/cat "$REPO_DIR/SOURCE-INFO.txt")"
fi
if [ -z "$COMMIT" ]; then
    COMMIT="unknown"
fi

if [ -z "$SCRATCH_PATH" ]; then
    SCRATCH_PATH="$REPO_DIR/.build-linux/$ARCH"
fi
BIN_DIR="$SCRATCH_PATH/release"
if [ "$BUILD" -eq 1 ]; then
    "$REPO_DIR/linux/build.sh" release --scratch-path "$SCRATCH_PATH"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: the release build failed with status $status" >&2
        exit 1
    fi
fi
for tool in replay dispatch fingerprint gate; do
    if [ ! -x "$BIN_DIR/$tool" ]; then
        echo "Error: $BIN_DIR/$tool is missing; build first (or drop --no-build)" >&2
        exit 1
    fi
done

# The libraries the tools load, from ldd (which lists the whole closure). Each must be
# either in the toolchain's runtime folder, which the runtime tarball copies, or one of the
# system libraries every supported distribution has.
LDD_OUT="$(for tool in replay dispatch fingerprint gate; do /usr/bin/ldd "$BIN_DIR/$tool"; done 2>&1)"
LIBS="$(printf '%s\n' "$LDD_OUT" | /usr/bin/sed -n 's/^[[:space:]]*\([^ ]*\) => \([^ ]*\) .*/\1 \2/p' | /usr/bin/sort -u)"
if [ -z "$LIBS" ]; then
    echo "Error: ldd listed no libraries:" >&2
    printf '%s\n' "$LDD_OUT" >&2
    exit 1
fi
RUNTIME_LIBS=()
problems=""
while read -r name path; do
    case "$path" in
        "$TOOLCHAIN_RUNTIME/"*)
            RUNTIME_LIBS+=("$name")
            ;;
        *)
            case "$name" in
                libc.so.6|libm.so.6|libstdc++.so.6|libgcc_s.so.1) ;;
                *) problems="$problems $name ($path)" ;;
            esac
            ;;
    esac
done <<EOF
$LIBS
EOF
if [ -n "$problems" ]; then
    echo "Error: the tools load libraries that are neither the Swift runtime nor basic system libraries:$problems" >&2
    exit 1
fi
case " ${RUNTIME_LIBS[*]} " in
    *" libFoundation.so "*) ;;
    *)
        echo "Error: libFoundation.so is not among the runtime libraries the tools load (${RUNTIME_LIBS[*]})" >&2
        exit 1
        ;;
esac

STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/replay-package.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$STAGE" ] || [ ! -d "$STAGE" ]; then
    echo "Error: cannot create a staging folder" >&2
    exit 1
fi
cleanup() {
    /bin/rm -rf "${STAGE:?}"
}
trap cleanup EXIT

/bin/mkdir -p "$OUT_DIR"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: cannot create $OUT_DIR" >&2
    exit 1
fi
OUT_DIR="$(CDPATH= cd -P -- "$OUT_DIR" && pwd)"

# Packs $STAGE/$1 into $OUT_DIR/$1.tar.gz, owned by root and in name order, and writes
# its .sha256 file.
pack() {
    local name="$1"
    local tarball="$OUT_DIR/$name.tar.gz"
    /bin/tar -C "$STAGE" --sort=name --owner=0 --group=0 --numeric-owner -cf - "$name" | /bin/gzip -n -9 > "$tarball"
    local pack_status=("${PIPESTATUS[@]}")
    if [ "${pack_status[0]}" -ne 0 ] || [ "${pack_status[1]}" -ne 0 ]; then
        echo "Error: packing $tarball failed (tar ${pack_status[0]}, gzip ${pack_status[1]})" >&2
        return 1
    fi
    local sum_line
    sum_line="$(CDPATH= cd -P -- "$OUT_DIR" && /usr/bin/sha256sum "$name.tar.gz")"
    if [ -z "$sum_line" ]; then
        echo "Error: sha256sum failed on $tarball" >&2
        return 1
    fi
    printf '%s\n' "$sum_line" > "$tarball.sha256"
    local size_kb
    size_kb="$(/usr/bin/du -k "$tarball" | /usr/bin/cut -f1)"
    echo "Wrote $tarball (${size_kb} KB)"
    return 0
}

# 1. The tools
TOOLS_NAME="replay_${VERSION}_linux_$ARCH"
/bin/mkdir -p "$STAGE/$TOOLS_NAME/bin"
for tool in replay dispatch fingerprint gate; do
    /usr/bin/strip --strip-debug -o "$STAGE/$TOOLS_NAME/bin/$tool" "$BIN_DIR/$tool"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: strip failed on $BIN_DIR/$tool (status $status)" >&2
        exit 1
    fi
    /bin/chmod 755 "$STAGE/$TOOLS_NAME/bin/$tool"
done
/bin/cp "$REPO_DIR/LICENSE" "$STAGE/$TOOLS_NAME/LICENSE"
status=$?
if [ "$status" -eq 0 ]; then
    /bin/cp "$LINUX_DIR/install.sh" "$STAGE/$TOOLS_NAME/install.sh"
    status=$?
fi
if [ "$status" -ne 0 ]; then
    echo "Error: cannot copy LICENSE and linux/install.sh into the tools folder" >&2
    exit 1
fi
/bin/chmod 755 "$STAGE/$TOOLS_NAME/install.sh"
OS_NAME_LINE="$(. /etc/os-release && echo "$PRETTY_NAME")"
GLIBC_LINE="$(/usr/bin/ldd --version 2>&1 | /usr/bin/head -n 1)"
{
    echo "replay $VERSION for Linux $ARCH"
    echo "source: $COMMIT"
    echo "built: $(/bin/date -u '+%Y-%m-%d %H:%M UTC') on $OS_NAME_LINE ($GLIBC_LINE)"
    echo "compiler: $SWIFT_VERSION_LINE"
    echo "needs: glibc 2.39 or newer, and a Swift runtime: the distribution's (libswiftlang on Debian 13 and Ubuntu 26.04, swift-lang-runtime on Fedora), a swift.org toolchain in /usr, or the runtime tarball below unpacked into the prefix that holds bin/"
    # Read by install.sh.
    echo "runtime-tarball: swift-runtime_${SWIFT_VERSION}_linux_$ARCH.tar.gz"
} > "$STAGE/$TOOLS_NAME/BUILD-INFO.txt"
pack "$TOOLS_NAME"
status=$?
if [ "$status" -ne 0 ]; then
    exit 1
fi

# 2. The runtime
RUNTIME_NAME="swift-runtime_${SWIFT_VERSION}_linux_$ARCH"
RUNTIME_DEST="$STAGE/$RUNTIME_NAME/lib/abracode/swift/linux"
/bin/mkdir -p "$RUNTIME_DEST"
for lib in "${RUNTIME_LIBS[@]}"; do
    /bin/cp -L "$TOOLCHAIN_RUNTIME/$lib" "$RUNTIME_DEST/$lib"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: cannot copy $TOOLCHAIN_RUNTIME/$lib" >&2
        exit 1
    fi
done
/bin/cp "$SWIFT_LICENSE" "$RUNTIME_DEST/LICENSE-Swift.txt"
status=$?
if [ "$status" -eq 0 ]; then
    /bin/cp "$ICU_LICENSE" "$RUNTIME_DEST/LICENSE-ICU.txt"
    status=$?
fi
if [ "$status" -ne 0 ]; then
    echo "Error: cannot copy the licenses into the runtime folder" >&2
    exit 1
fi
{
    echo "$SWIFT_VERSION_LINE"
    echo "The Swift runtime libraries replay $VERSION loads, unchanged from the toolchain (${#RUNTIME_LIBS[@]} libraries)."
    echo "lib_FoundationICU.so is ICU 74 (LICENSE-ICU.txt); the rest is under LICENSE-Swift.txt."
} > "$RUNTIME_DEST/VERSION"
pack "$RUNTIME_NAME"
status=$?
if [ "$status" -ne 0 ]; then
    exit 1
fi

echo "Packed replay $VERSION for $ARCH (source: $COMMIT); runtime: Swift $SWIFT_VERSION, ${#RUNTIME_LIBS[@]} libraries"
exit 0
