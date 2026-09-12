#!/bin/sh
# Sign the four built tools in build/Release.
#
# With no argument they are signed ad-hoc, which is enough to run them on this
# machine and nothing more. For anything that leaves this machine pass a
# Developer ID Application identity, which also turns on the hardened runtime
# and a secure timestamp - both are required for notarization, and the
# installer project in installer/ asserts both before it will package them.
#
#   ./codesign.sh                                        # ad-hoc, local only
#   ./codesign.sh "Developer ID Application: Name (TEAM)" # for distribution

self_dir=$(/usr/bin/dirname "$0")
build_dir="$self_dir/build/Release"

identity="$1"

if test -z "$identity"; then
    identity="-"
    timestamp="--timestamp=none"
    sign_options=""
    echo "Signing ad-hoc. These binaries are for local use only."
else
    timestamp="--timestamp"
    sign_options="--options runtime"
    echo "Signing with: $identity"
fi

any_failed=0

for tool in replay dispatch fingerprint gate; do
    app_to_sign="$build_dir/$tool"
    app_id="com.abracode.$tool"

    if [ ! -f "$app_to_sign" ]; then
        echo "ERROR: $tool is not in $build_dir - run ./build.sh first" >&2
        any_failed=1
        continue
    fi

    /usr/bin/codesign --verbose --force $sign_options $timestamp \
        --identifier "$app_id" --sign "$identity" "$app_to_sign"
    result=$?
    if [ "$result" -ne 0 ]; then
        echo "ERROR: failed to sign $tool (codesign exit $result)" >&2
        any_failed=1
    fi
done

if [ "$any_failed" -ne 0 ]; then
    echo "Signing did not complete." >&2
    exit 1
fi

echo "Signed all four tools in $build_dir"
