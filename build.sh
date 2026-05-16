#!/bin/bash

CONFIG="Release"
SIGNPOST_ARGS=""

for arg in "$@"; do
    if [[ "$arg" == "--signpost" ]]; then
        if [[ -n "$SIGNPOST_ARGS" ]]; then
            echo "Error: --signpost and --timing are mutually exclusive"
            exit 1
        fi
        SIGNPOST_ARGS="REPLAY_SIGNPOSTS_ENABLED_SETTING=1"
    elif [[ "$arg" == "--timing" ]]; then
        if [[ -n "$SIGNPOST_ARGS" ]]; then
            echo "Error: --signpost and --timing are mutually exclusive"
            exit 1
        fi
        SIGNPOST_ARGS="REPLAY_TIMING_ENABLED_SETTING=1"
    elif [[ "$arg" == "Debug" || "$arg" == "Release" ]]; then
        CONFIG="$arg"
    else
        echo "Usage: $0 [Debug|Release] [--signpost|--timing]"
        echo "  Default: Release"
        echo "  --signpost  enable os_signpost intervals (view in Instruments.app)"
        echo "  --timing    enable inline timing accumulators (prints to stderr)"
        exit 1
    fi
done

echo "Building all tools with configuration: $CONFIG"
echo "============================================"

cd "$(dirname "$0")"

any_failed=0

echo "------------------"
echo "** BUILD replay **"

build_log="/tmp/replay-build.log"
xcodebuild -project replay.xcodeproj -scheme replay -configuration "$CONFIG" $SIGNPOST_ARGS build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
result=$?
if [ $result != 0 ]; then
    any_failed=1
    echo "Failed build log saved in: ${build_log}"
else
    /bin/rm -f "${build_log}"
fi

echo "------------------"
echo "** BUILD dispatch **"

build_log="/tmp/dispatch-build.log"
xcodebuild -project dispatch.xcodeproj -scheme dispatch -configuration "$CONFIG" $SIGNPOST_ARGS build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
result=$?
if [ $result != 0 ]; then
    any_failed=1
    echo "Failed build log saved in: ${build_log}"
else
    /bin/rm -f "${build_log}"
fi

echo "------------------"
echo "** BUILD fingerprint **"

build_log="/tmp/fingerprint-build.log"
xcodebuild -project fingerprint.xcodeproj -scheme fingerprint -configuration "$CONFIG" $SIGNPOST_ARGS build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
result=$?
if [ $result != 0 ]; then
    any_failed=1
    echo "Failed build log saved in: ${build_log}"
else
    /bin/rm -f "${build_log}"
fi

echo "------------------"
echo "** BUILD gate **"

build_log="/tmp/gate-build.log"
xcodebuild -project fingerprint.xcodeproj -scheme gate -configuration "$CONFIG" $SIGNPOST_ARGS build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
result=$?
if [ $result != 0 ]; then
    any_failed=1
    echo "Failed build log saved in: ${build_log}"
else
    /bin/rm -f "${build_log}"
fi

echo "============================================"

if [ $any_failed == 0 ]; then
    echo "All tools built successfully!"
else
    echo "Some tools failed to build. Review failed build logs in /tmp"
fi
