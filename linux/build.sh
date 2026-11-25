#!/bin/bash
# Build the four replay tools on Linux with Swift Package Manager.
#
# Runs on Linux only, with the Swift toolchain pinned in linux/swift-image. From a Mac,
# linux/build-and-test.sh runs it in an agent-vm box or a Docker container. Products go to
# .build-linux/<machine>/<config>/ (replay, dispatch, fingerprint, gate).
#
# The Linux-only compiler and linker flags live here, not in Package.swift, because SwiftPM
# refuses unsafeFlags in a package used as a dependency.

CONFIG="debug"
SCRATCH_PATH=""
JOBS=""
PRINT_ONLY=0
EXTRA_ARGS=()
SWIFT="${SWIFT:-/usr/bin/swift}"

# Runtime search list, in order (plan D2). Missing folders are skipped by the loader.
#   1. Debian and Ubuntu package libswiftlang
#   2. Swift Docker images, and toolchain tarballs unpacked into /usr
#   3. our copy of the runtime (linux/package.sh packs it), installed only when no system
#      runtime exists, into <prefix>/lib/abracode/swift/linux beside the tools in
#      <prefix>/bin: /usr/local for everyone (needs root), ~/.local for one user. $ORIGIN is the folder
#      of the executable; the loader expands it (it is ignored in set-user-ID programs).
# Fedora's swift-lang-runtime installs into /usr/lib64, which the loader searches by
# default after these.
RUNTIME_SEARCH_PATHS=(
    "/usr/libexec/swift/lib/swift/linux"
    "/usr/lib/swift/linux"
    '$ORIGIN/../lib/abracode/swift/linux'
)

usage() {
    echo "Usage: $0 [debug|release] [--jobs N] [--scratch-path DIR] [--print-command] [-- swift-build-args...]"
    echo "  Default: debug, scratch path .build-linux/<machine>"
    echo "  --print-command  print the swift build command and exit"
    echo "  SWIFT=/path/to/swift overrides the toolchain (default /usr/bin/swift)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        debug|Debug)
            CONFIG="debug"
            ;;
        release|Release)
            CONFIG="release"
            ;;
        --jobs|-j)
            if [ $# -lt 2 ]; then
                echo "Error: $1 needs a number" >&2
                exit 1
            fi
            JOBS="$2"
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
        --print-command)
            PRINT_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        *)
            echo "Error: unrecognized argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$JOBS" in
    "") ;;
    *[!0-9]*|0*)
        echo "Error: --jobs needs a positive integer, got '$JOBS'" >&2
        exit 1
        ;;
esac

OS_NAME="$(/usr/bin/uname -s)"
if [ "$OS_NAME" != "Linux" ]; then
    echo "Error: linux/build.sh runs on Linux only (this is $OS_NAME)." >&2
    echo "On macOS, build and test in an agent-vm box or a Docker container: linux/build-and-test.sh" >&2
    exit 1
fi

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ -z "$REPO_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find Package.swift above linux/" >&2
    exit 1
fi

if [ -z "$SCRATCH_PATH" ]; then
    MACHINE="$(/usr/bin/uname -m)"
    SCRATCH_PATH="$REPO_DIR/.build-linux/$MACHINE"
fi

if [ ! -x "$SWIFT" ]; then
    echo "Error: no Swift toolchain at $SWIFT. Set SWIFT=/path/to/swift, or build in the container (linux/docker.sh)." >&2
    exit 1
fi

# The CF headers live in the toolchain's runtime resource folder, which is not on the default
# include path (plan, fact 4).
TARGET_INFO="$("$SWIFT" -print-target-info 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: '$SWIFT -print-target-info' failed with status $status:" >&2
    echo "$TARGET_INFO" >&2
    exit 1
fi
RESOURCE_PATH="$(printf '%s\n' "$TARGET_INFO" | /usr/bin/sed -n 's/.*"runtimeResourcePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | /usr/bin/head -n 1)"
if [ -z "$RESOURCE_PATH" ] || [ ! -f "$RESOURCE_PATH/CoreFoundation/CoreFoundation.h" ]; then
    echo "Error: CoreFoundation headers not found under the toolchain's runtime resource path '$RESOURCE_PATH'." >&2
    exit 1
fi

# The oldest toolchain release the tools are built and tested with; any newer one builds them too
# (linux/swift-image pins the one release builds use)
MIN_SWIFT_MAJOR=6
MIN_SWIFT_MINOR=2
SWIFT_VERSION_TEXT="$("$SWIFT" --version 2>&1)"
SWIFT_MAJOR="$(printf '%s\n' "$SWIFT_VERSION_TEXT" | /usr/bin/sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1/p' | /usr/bin/head -n 1)"
SWIFT_MINOR="$(printf '%s\n' "$SWIFT_VERSION_TEXT" | /usr/bin/sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\2/p' | /usr/bin/head -n 1)"
if [ -z "$SWIFT_MAJOR" ] || [ -z "$SWIFT_MINOR" ]; then
    echo "Error: cannot read the Swift version from '$SWIFT --version':" >&2
    echo "$SWIFT_VERSION_TEXT" >&2
    exit 1
fi
if [ "$SWIFT_MAJOR" -lt "$MIN_SWIFT_MAJOR" ] || { [ "$SWIFT_MAJOR" -eq "$MIN_SWIFT_MAJOR" ] && [ "$SWIFT_MINOR" -lt "$MIN_SWIFT_MINOR" ]; }; then
    echo "Error: Swift $SWIFT_MAJOR.$SWIFT_MINOR is older than $MIN_SWIFT_MAJOR.$MIN_SWIFT_MINOR, the oldest that builds these tools. Set SWIFT=/path/to/swift, or build in the container (linux/docker.sh)." >&2
    exit 1
fi

# The runtime libraries the tools link (Foundation, dispatch, BlocksRuntime), beside the CF
# headers' folder in every toolchain layout
RUNTIME_LIB_DIR="$RESOURCE_PATH/linux"
if [ ! -f "$RUNTIME_LIB_DIR/libFoundation.so" ]; then
    echo "Error: the toolchain's runtime libraries are not in '$RUNTIME_LIB_DIR' (no libFoundation.so)." >&2
    exit 1
fi

# On Linux a CFSTR with non-ASCII text produces a broken string: its length is the UTF-8
# byte count (plan, fact 20). Reject such literals, raw or written with \u, \U or \x escapes.
# Use a string created at run time instead.
NON_ASCII_CFSTR="$(LC_ALL=C /usr/bin/grep -rnE \
    --include='*.c' --include='*.cpp' --include='*.h' --include='*.hpp' --include='*.mm' \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=.build-linux --exclude-dir=build --exclude-dir=private \
    'CFSTR\("([^"\\]|\\[^uUx])*([^ -~]|\\[uUx])' "$REPO_DIR")"
status=$?
if [ "$status" -eq 0 ]; then
    echo "Error: non-ASCII text in CFSTR literals, which is broken on Linux (use a string created at run time):" >&2
    echo "$NON_ASCII_CFSTR" >&2
    exit 1
fi
if [ "$status" -ne 1 ]; then
    echo "Error: the non-ASCII CFSTR check could not read the sources (grep status $status)." >&2
    exit 1
fi

SWIFT_ARGS=(build -c "$CONFIG" --package-path "$REPO_DIR" --scratch-path "$SCRATCH_PATH")
if [ -n "$JOBS" ]; then
    SWIFT_ARGS+=(-j "$JOBS")
fi

# C and C++: CF headers, clang blocks, and CF's Swift object layout (plan, fact 1).
# The CF folder is a system include folder (-isystem, not -I): the toolchain's headers give
# about 120 nullability warnings, and its ForSwiftFoundationOnly.h has narrowing conversions
# that are hard errors in C++ (plan, fact 5). Both are silenced in system headers only, so
# narrowing in our own code stays an error, as on macOS. That matters on aarch64 Linux,
# where plain char is unsigned.
for flag in "-isystem$RESOURCE_PATH" -fblocks -fcf-runtime-abi=swift -DDEPLOYMENT_RUNTIME_SWIFT=1; do
    SWIFT_ARGS+=(-Xcc "$flag" -Xcxx "$flag")
done

# C++ only: SwiftPM passes -fmodule-map-file without -fmodules on Linux, and clang in C++20
# mode then treats headers covered by those maps as modules nobody built (plan, fact 6).
SWIFT_ARGS+=(-Xcxx -Xclang -Xcxx -fno-cxx-modules)

# Link: replace the toolchain's runtime path with the search list above (plan, D2).
SWIFT_ARGS+=(-Xswiftc -no-toolchain-stdlib-rpath)
# And name the runtime libraries' folder: Swift 6.2's driver added it to every link, but the
# build engine of newer toolchains (6.4) links the C++ tools with clang++ without it ("cannot
# find -lFoundation"). GNU ld applies a -L to every -l, wherever it appears.
SWIFT_ARGS+=(-Xlinker "-L$RUNTIME_LIB_DIR")
for runtime_path in "${RUNTIME_SEARCH_PATHS[@]}"; do
    SWIFT_ARGS+=(-Xlinker -rpath -Xlinker "$runtime_path")
done

if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
    SWIFT_ARGS+=("${EXTRA_ARGS[@]}")
fi

if [ "$PRINT_ONLY" -eq 1 ]; then
    printf '%q ' "$SWIFT" "${SWIFT_ARGS[@]}"
    printf '\n'
    exit 0
fi

echo "Building replay tools ($CONFIG) with $("$SWIFT" --version 2>&1 | /usr/bin/head -n 1)"
echo "Scratch path: $SCRATCH_PATH"
"$SWIFT" "${SWIFT_ARGS[@]}"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: swift build failed with status $status" >&2
    exit "$status"
fi

BIN_DIR="$SCRATCH_PATH/$CONFIG"
EXPECTED_RUNPATH=""
for runtime_path in "${RUNTIME_SEARCH_PATHS[@]}"; do
    EXPECTED_RUNPATH="$EXPECTED_RUNPATH:$runtime_path"
done
EXPECTED_RUNPATH="${EXPECTED_RUNPATH#:}"

check_failed=0
for tool in replay dispatch fingerprint gate; do
    bin="$BIN_DIR/$tool"
    if [ ! -x "$bin" ]; then
        echo "Error: $bin was not built" >&2
        check_failed=1
        continue
    fi
    dynamic_section="$(/usr/bin/readelf -d "$bin" 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: readelf failed on $bin: $dynamic_section" >&2
        check_failed=1
        continue
    fi
    # Exactly our list, after the $ORIGIN that SwiftPM adds. Anything else, such as the
    # toolchain's own runtime folder, would be searched before the distribution's runtime.
    runpath="$(printf '%s\n' "$dynamic_section" | /usr/bin/sed -n 's/.*(RUNPATH)[^[]*\[\(.*\)\]$/\1/p')"
    if [ "$runpath" != "$EXPECTED_RUNPATH" ] && [ "$runpath" != "\$ORIGIN:$EXPECTED_RUNPATH" ]; then
        echo "Error: $tool has RUNPATH '$runpath', expected '\$ORIGIN:$EXPECTED_RUNPATH'" >&2
        check_failed=1
    fi
done
if [ "$check_failed" -ne 0 ]; then
    exit 1
fi

echo "Built: $BIN_DIR/{replay,dispatch,fingerprint,gate}"
echo "Runtime search path: $EXPECTED_RUNPATH"
