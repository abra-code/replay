#!/bin/sh

self_dir=$(/usr/bin/dirname "$0")

identity="$1"

if test -z "$identity"; then
    identity="-"
    timestamp="--timestamp=none"
    sign_options=""
else
    timestamp="--timestamp"
    sign_options="--options runtime"
fi

app_to_sign="$self_dir/build/Release/replay"
app_id="com.abracode.replay"

/usr/bin/codesign --verbose --force $sign_options $timestamp --identifier "$app_id" --sign "$identity" "$app_to_sign"

app_to_sign="$self_dir/build/Release/dispatch"
app_id="com.abracode.dispatch"

/usr/bin/codesign --verbose --force $sign_options $timestamp --identifier "$app_id" --sign "$identity" "$app_to_sign"


app_to_sign="$self_dir/build/Release/fingerprint"
app_id="com.abracode.fingerprint"

/usr/bin/codesign --verbose --force $sign_options $timestamp --identifier "$app_id" --sign "$identity" "$app_to_sign"
