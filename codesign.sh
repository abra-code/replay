#!/bin/sh

self_dir=$(/usr/bin/dirname "$0")

development_team="T9NM2ZLDTY"

app_to_sign="$self_dir/build/Release/replay"
app_id="com.abracode.replay"

/usr/bin/codesign --deep --verbose --force --options runtime --timestamp --identifier "$app_id" --sign "$development_team" "$app_to_sign"

app_to_sign="$self_dir/build/Release/dispatch"
app_id="com.abracode.dispatch"

/usr/bin/codesign --deep --verbose --force --options runtime --timestamp --identifier "$app_id" --sign "$development_team" "$app_to_sign"

