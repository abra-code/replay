#!/bin/bash
# Runs inside a distribution container that has only that distribution's Swift runtime
# package and no toolchain (linux/runtime/*.Dockerfile). Started by linux/runtime-check.sh.
#
# Usage: runtime-check-inner.sh <folder with replay, dispatch, fingerprint, gate>
#
# Every tool starts with LD_BIND_NOW=1, so a function or variable missing from this
# runtime fails at start instead of at first call (plan, fact 18). Then a small plist
# playlist and a fingerprint snapshot exercise CF parsing and writing, libdispatch and blocks.

BIN_DIR="$1"
if [ -z "$BIN_DIR" ] || [ ! -d "$BIN_DIR" ]; then
    echo "Error: usage: $0 <folder with the built tools>" >&2
    exit 1
fi

DISTRO="unknown"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$PRETTY_NAME"
fi
echo "== $DISTRO"

failures=0
fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

for tool in replay dispatch fingerprint gate; do
    bin="$BIN_DIR/$tool"
    if [ ! -x "$bin" ]; then
        fail "$bin is missing"
        continue
    fi
    libs="$(/usr/bin/ldd "$bin" 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "ldd $tool: $libs"
        continue
    fi
    missing="$(printf '%s\n' "$libs" | /usr/bin/grep 'not found')"
    if [ -n "$missing" ]; then
        fail "$tool has unresolved libraries: $missing"
        continue
    fi
    foundation="$(printf '%s\n' "$libs" | /usr/bin/sed -n 's/^[[:space:]]*libFoundation\.so => \([^ ]*\) .*/\1/p')"
    output="$(LD_BIND_NOW=1 "$bin" --version 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "$tool --version exited with $status: $output"
        continue
    fi
    echo "ok   $tool --version: $(printf '%s' "$output" | /usr/bin/head -n 1) (libFoundation.so from ${foundation:-?})"
done

WORK_DIR="$(/usr/bin/mktemp -d)"
status=$?
if [ "$status" -ne 0 ] || [ -z "$WORK_DIR" ]; then
    fail "mktemp -d failed"
    echo "runtime check: $failures failure(s)"
    exit 1
fi

PLAYLIST="$WORK_DIR/playlist.plist"
/bin/cat > "$PLAYLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>action</key>
		<string>create</string>
		<key>directory</key>
		<string>$WORK_DIR/out</string>
	</dict>
	<dict>
		<key>action</key>
		<string>create</string>
		<key>file</key>
		<string>$WORK_DIR/out/a.txt</string>
		<key>content</key>
		<string>runtime check</string>
	</dict>
</array>
</plist>
EOF

output="$(LD_BIND_NOW=1 "$BIN_DIR/replay" "$PLAYLIST" 2>&1)"
status=$?
content=""
if [ -f "$WORK_DIR/out/a.txt" ]; then
    content="$(< "$WORK_DIR/out/a.txt")"
fi
if [ "$status" -ne 0 ] || [ "$content" != "runtime check" ]; then
    fail "replay plist playlist: status $status, file content '$content': $output"
else
    echo "ok   replay ran a plist playlist"
fi

for format in plist json; do
    snapshot="$WORK_DIR/snapshot.$format"
    output="$(LD_BIND_NOW=1 "$BIN_DIR/fingerprint" --xattr=off --snapshot="$snapshot" "$WORK_DIR/out" 2>&1)"
    status=$?
    if [ "$status" -ne 0 ] || [ ! -s "$snapshot" ]; then
        fail "fingerprint --snapshot=$format: status $status: $output"
        continue
    fi
    output="$(LD_BIND_NOW=1 "$BIN_DIR/fingerprint" --xattr=off --compare="$snapshot" "$WORK_DIR/out" 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        fail "fingerprint --compare with the $format snapshot: status $status: $output"
        continue
    fi
    echo "ok   fingerprint wrote and compared a $format snapshot"
done

/bin/rm -rf "$WORK_DIR"

if [ "$failures" -ne 0 ]; then
    echo "runtime check on $DISTRO: $failures failure(s)"
    exit 1
fi
echo "runtime check on $DISTRO: all passed"
