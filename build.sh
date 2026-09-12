#!/bin/bash
# Build all four replay tools with xcodebuild.
#
# Release builds universal (arm64 + x86_64) into build/Release, which is what
# the installer in installer/ packages and what a release ships. Debug builds
# this machine's architecture only, following ReplayProjectDebug.xcconfig.
# --native and --universal override either default.
#
# For a source install into ~/.local/bin use install.sh instead - that path
# goes through Swift Package Manager and is deliberately native-only.

CONFIG="Release"
ARCH_CHOICE=""
INSTRUMENT_SETTING=""
INSTRUMENT_FLAG=""

usage() {
    echo "Usage: $0 [Debug|Release] [--native|--universal] [--signpost|--timing]"
    echo "  Default: Release universal (arm64 + x86_64), Debug native"
    echo "  --native    build for this machine's architecture only (faster)"
    echo "  --universal build both architectures, even for Debug"
    echo "  --signpost  enable os_signpost intervals (view in Instruments.app)"
    echo "  --timing    enable inline timing accumulators (prints to stderr)"
}

for arg in "$@"; do
    if [ "$arg" = "--signpost" ] || [ "$arg" = "--timing" ]; then
        if [ "$INSTRUMENT_FLAG" = "$arg" ]; then
            echo "Error: $arg given twice" >&2
            exit 1
        fi
        if [ -n "$INSTRUMENT_SETTING" ]; then
            echo "Error: $INSTRUMENT_FLAG and $arg are mutually exclusive" >&2
            exit 1
        fi
        INSTRUMENT_FLAG="$arg"
        if [ "$arg" = "--signpost" ]; then
            INSTRUMENT_SETTING="REPLAY_SIGNPOSTS_ENABLED_SETTING=1"
        else
            INSTRUMENT_SETTING="REPLAY_TIMING_ENABLED_SETTING=1"
        fi
    elif [ "$arg" = "--native" ]; then
        ARCH_CHOICE="native"
    elif [ "$arg" = "--universal" ]; then
        ARCH_CHOICE="universal"
    elif [ "$arg" = "Debug" ] || [ "$arg" = "Release" ]; then
        CONFIG="$arg"
    elif [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        usage
        exit 0
    else
        echo "Error: unrecognized argument: $arg" >&2
        usage >&2
        exit 1
    fi
done

# Release ships universal; Debug follows ReplayProjectDebug.xcconfig, which sets
# ONLY_ACTIVE_ARCH = YES on purpose. Forcing both slices on a Debug build would
# override that from the command line and roughly double the time of the compile
# loop this configuration exists for. Either default is overridable.
if [ -z "$ARCH_CHOICE" ]; then
    if [ "$CONFIG" = "Debug" ]; then
        ARCH_CHOICE="native"
    else
        ARCH_CHOICE="universal"
    fi
fi

if [ "$ARCH_CHOICE" = "native" ]; then
    ARCHS_SETTING="$(/usr/bin/uname -m)"
    ARCH_LABEL="native ($ARCHS_SETTING) only"
else
    ARCHS_SETTING="arm64 x86_64"
    ARCH_LABEL="universal (arm64 + x86_64)"
fi

# ARCHS and ONLY_ACTIVE_ARCH are forced on the command line rather than left to
# the xcconfigs. fingerprint.xcodeproj otherwise builds arm64-only products
# even though -showBuildSettings reports "ARCHS = arm64 x86_64" and
# "ONLY_ACTIVE_ARCH = NO" for its schemes; it is also the only one of the three
# projects that warns "Using the first of multiple matching destinations".
# Until that is understood, say it explicitly and every tool comes out the same.
ARCH_ARGS=("ARCHS=$ARCHS_SETTING" "ONLY_ACTIVE_ARCH=NO")

# Never run "xcodebuild clean" on these projects. SYMROOT is the shared build/
# folder, which the build system did not create, so clean fails with
# "Could not delete build/Release because it was not created by the build
# system" - and the products of the other projects went missing from
# build/Release once, right after such a failed clean.
# To start fresh: /bin/rm -rf build

echo "Building all tools"
echo "  configuration: $CONFIG"
echo "  architectures: $ARCH_LABEL"
echo "============================================"

cd "$(/usr/bin/dirname "$0")" || exit 1

any_failed=0

build_tool() {
    local _project="$1"
    local _scheme="$2"
    # Not /tmp: it is world-writable, so a pre-created symlink there would have
    # tee overwrite whatever it points at, and two people building at once
    # clobber each other's logs.
    local _log="${TMPDIR:-/tmp}/${_scheme}-build.log"

    echo "------------------"
    echo "** BUILD $_scheme **"

    # $? after a pipeline is the LAST command's status, so xcodebuild's own
    # status has to come out of PIPESTATUS. grep -v exits 1 when it filters
    # everything away, which is a perfectly good build.
    /usr/bin/xcodebuild -project "$_project" -scheme "$_scheme" \
        -configuration "$CONFIG" "${ARCH_ARGS[@]}" $INSTRUMENT_SETTING build \
        | /usr/bin/tee "$_log" \
        | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
    local _result=${PIPESTATUS[0]}

    if [ "$_result" != 0 ]; then
        any_failed=1
        echo "Failed build log saved in: $_log"
    else
        /bin/rm -f "$_log"
    fi
}

build_tool replay.xcodeproj replay
build_tool dispatch.xcodeproj dispatch
build_tool fingerprint.xcodeproj fingerprint
build_tool fingerprint.xcodeproj gate

echo "============================================"

if [ "$any_failed" != 0 ]; then
    echo "Some tools failed to build. Review the failed build logs named above." >&2
    exit 1
fi

# Report what actually came out. The settings above should guarantee it, but
# this is the check that would have caught fingerprint and gate shipping
# arm64-only, so it runs every time rather than on request.
echo "Built products in build/$CONFIG:"
arch_mismatch=0
for tool in replay dispatch fingerprint gate; do
    # Assigned below; declared here because their setters are conditional.
    lipo_status=""
    product="build/$CONFIG/$tool"
    if [ ! -x "$product" ]; then
        echo "  $tool: MISSING from build/$CONFIG" >&2
        arch_mismatch=1
        continue
    fi
    built_archs="$(/usr/bin/lipo -archs "$product" 2>&1)"
    lipo_status=$?
    if [ "$lipo_status" != 0 ]; then
        echo "  $tool: lipo could not read it: $built_archs" >&2
        arch_mismatch=1
        continue
    fi
    version="$("$product" --version 2>/dev/null | /usr/bin/head -1)"
    printf '  %-12s %-16s %s\n' "$tool" "[$built_archs]" "$version"
    for wanted in $ARCHS_SETTING; do
        case " $built_archs " in
            *" $wanted "*) ;;
            *)
                echo "  $tool: expected $wanted, lipo reports [$built_archs]" >&2
                arch_mismatch=1
                ;;
        esac
    done
done

if [ "$arch_mismatch" != 0 ]; then
    echo "Build finished, but the products are not what was asked for." >&2
    exit 1
fi

echo "All tools built successfully!"
