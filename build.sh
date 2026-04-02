#!/bin/bash

CONFIG="${1:-Release}"

if [[ "$CONFIG" != "Debug" && "$CONFIG" != "Release" ]]; then
    echo "Usage: $0 [Debug|Release]"
    echo "  Default: Release"
    exit 1
fi

echo "Building all tools with configuration: $CONFIG"
echo "============================================"

cd "$(dirname "$0")"

any_failed=0

echo "------------------"
echo "** BUILD replay **"

build_log="/tmp/replay-build.log"
xcodebuild -project replay.xcodeproj -scheme replay -configuration "$CONFIG" build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
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
xcodebuild -project dispatch.xcodeproj -scheme dispatch -configuration "$CONFIG" build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
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
xcodebuild -project fingerprint.xcodeproj -scheme fingerprint -configuration "$CONFIG" build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
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
xcodebuild -project fingerprint.xcodeproj -scheme gate -configuration "$CONFIG" build | /usr/bin/tee "${build_log}" | /usr/bin/grep --invert-match -E -e '^ ' -e '^-'
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


