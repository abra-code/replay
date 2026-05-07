#!/bin/sh

success_counter=0
failure_counter=0

verify_succeeded()
{
	result=$1
	error_message=$2

	if test "$result" != "0"; then
		let failure_counter++
		echo ""
		echo "###########   ERROR   ##############"
		echo "$error_message"
		echo "####################################"
		echo ""
	else
		let success_counter++
	fi
}

verify_failed()
{
	result=$1
	error_message=$2

	if test "$result" = "0"; then
		let failure_counter++
		echo ""
		echo "###########   ERROR   ##############"
		echo "$error_message"
		echo "####################################"
		echo ""
	else
		let success_counter++
	fi
}

report_test_stats()
{
	echo ""
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo " Finished read & blob tests  "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}


echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Testing read & blob create  "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
REPLAY_TOOL="${1:-$REPO_DIR/build/Release/replay}"
if [ ! -x "$REPLAY_TOOL" ]; then
	echo "error: replay not found at $REPLAY_TOOL"
	echo "usage: $0 [path/to/replay]"
	exit 1
fi

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_read_test.XXXXXX)
TEXT_FILE="$WORK_DIR/hello.txt"
BINARY_FILE="$WORK_DIR/data.bin"
BLOB_OUT_FILE="$WORK_DIR/blob_out.bin"
ROUNDTRIP_FILE="$WORK_DIR/roundtrip.bin"

cleanup()
{
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo "Work dir: $WORK_DIR"
echo ""

# 8-byte PNG magic: 89 50 4E 47 0D 0A 1A 0A  →  base64: iVBORw0KGgo=
printf 'Hello, replay!\n' > "$TEXT_FILE"
printf '\x89PNG\x0d\x0a\x1a\x0a' > "$BINARY_FILE"
BINARY_B64="iVBORw0KGgo="


# ===========================================================================
echo "------------------------------"
echo "read text file via JSON playlist"
echo ""

cat > "$WORK_DIR/read_text.json" << EOF
[{ "action": "read", "items": ["$TEXT_FILE"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/read_text.json")
echo "$output" | /usr/bin/grep -qF "[text:$TEXT_FILE]"
verify_succeeded "$?" "read text: expected [text:...] header in output"
echo "$output" | /usr/bin/grep -qF "Hello, replay!"
verify_succeeded "$?" "read text: expected file content in output"


# ===========================================================================
echo "------------------------------"
echo "read binary file via JSON playlist"
echo ""

cat > "$WORK_DIR/read_binary.json" << EOF
[{ "action": "read", "items": ["$BINARY_FILE"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/read_binary.json")
echo "$output" | /usr/bin/grep -qF "[blob:$BINARY_FILE]"
verify_succeeded "$?" "read binary: expected [blob:...] header in output"
echo "$output" | /usr/bin/grep -qF "$BINARY_B64"
verify_succeeded "$?" "read binary: expected base64 content in output"


# ===========================================================================
echo "------------------------------"
echo "read multiple files (text + binary) via JSON playlist"
echo ""

cat > "$WORK_DIR/read_multi.json" << EOF
[{ "action": "read", "items": ["$TEXT_FILE", "$BINARY_FILE"] }]
EOF
output=$("$REPLAY_TOOL" --serial "$WORK_DIR/read_multi.json")
echo "$output" | /usr/bin/grep -qF "[text:$TEXT_FILE]"
verify_succeeded "$?" "read multi: text header present"
echo "$output" | /usr/bin/grep -qF "Hello, replay!"
verify_succeeded "$?" "read multi: text content present"
echo "$output" | /usr/bin/grep -qF "[blob:$BINARY_FILE]"
verify_succeeded "$?" "read multi: binary header present"
echo "$output" | /usr/bin/grep -qF "$BINARY_B64"
verify_succeeded "$?" "read multi: binary base64 content present"


# ===========================================================================
echo "------------------------------"
echo "read text file via streaming format"
echo ""

output=$(printf '[read]\t%s\n' "$TEXT_FILE" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "[text:$TEXT_FILE]"
verify_succeeded "$?" "stream read text: expected [text:...] header"
echo "$output" | /usr/bin/grep -qF "Hello, replay!"
verify_succeeded "$?" "stream read text: expected file content"


# ===========================================================================
echo "------------------------------"
echo "read binary file via streaming format"
echo ""

output=$(printf '[read]\t%s\n' "$BINARY_FILE" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "[blob:$BINARY_FILE]"
verify_succeeded "$?" "stream read binary: expected [blob:...] header"
echo "$output" | /usr/bin/grep -qF "$BINARY_B64"
verify_succeeded "$?" "stream read binary: expected base64 content"


# ===========================================================================
echo "------------------------------"
echo "read multiple files via streaming format"
echo ""

output=$(printf '[read]\t%s\t%s\n' "$TEXT_FILE" "$BINARY_FILE" | "$REPLAY_TOOL" --serial)
echo "$output" | /usr/bin/grep -qF "[text:$TEXT_FILE]"
verify_succeeded "$?" "stream read multi: text header present"
echo "$output" | /usr/bin/grep -qF "[blob:$BINARY_FILE]"
verify_succeeded "$?" "stream read multi: binary header present"


# ===========================================================================
echo "------------------------------"
echo "read nonexistent file exits with failure"
echo ""

cat > "$WORK_DIR/read_missing.json" << EOF
[{ "action": "read", "items": ["$WORK_DIR/no_such_file.txt"] }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/read_missing.json" 2>/dev/null
verify_failed "$?" "read missing: expected non-zero exit"


# ===========================================================================
echo "------------------------------"
echo "dry-run: shows descriptor, does not read content"
echo ""

output=$(printf '[read]\t%s\n' "$TEXT_FILE" | "$REPLAY_TOOL" --dry-run)
echo "$output" | /usr/bin/grep -qF "[read]"
verify_succeeded "$?" "dry-run read: expected [read] descriptor"
echo "$output" | /usr/bin/grep -qF "Hello, replay!"
verify_failed "$?" "dry-run read: file content must NOT appear in dry-run output"


# ===========================================================================
echo "------------------------------"
echo "verbose: shows descriptor before content"
echo ""

output=$(printf '[read]\t%s\n' "$TEXT_FILE" | "$REPLAY_TOOL" --verbose --serial)
echo "$output" | /usr/bin/grep -qF "[read]"
verify_succeeded "$?" "verbose read: expected [read] descriptor"
echo "$output" | /usr/bin/grep -qF "Hello, replay!"
verify_succeeded "$?" "verbose read: expected file content after descriptor"


# ===========================================================================
echo "------------------------------"
echo "create blob via JSON playlist - file has correct binary content"
echo ""

cat > "$WORK_DIR/create_blob.json" << EOF
[{ "action": "create", "file": "$BLOB_OUT_FILE", "blob": "$BINARY_B64" }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/create_blob.json"
verify_succeeded "$?" "create blob (JSON): replay exited successfully"
test -f "$BLOB_OUT_FILE"
verify_succeeded "$?" "create blob (JSON): output file exists"
written_b64=$(base64 < "$BLOB_OUT_FILE")
test "$written_b64" = "$BINARY_B64"
verify_succeeded "$?" "create blob (JSON): file content matches base64 (got: $written_b64)"


# ===========================================================================
echo "------------------------------"
echo "create blob via streaming format (blob=true modifier)"
echo ""

BLOB_STREAM_OUT="$WORK_DIR/blob_stream_out.bin"
printf '[create file blob=true]\t%s\t%s\n' "$BLOB_STREAM_OUT" "$BINARY_B64" | "$REPLAY_TOOL"
verify_succeeded "$?" "create blob (stream): replay exited successfully"
test -f "$BLOB_STREAM_OUT"
verify_succeeded "$?" "create blob (stream): output file exists"
written_b64=$(base64 < "$BLOB_STREAM_OUT")
test "$written_b64" = "$BINARY_B64"
verify_succeeded "$?" "create blob (stream): file content matches base64 (got: $written_b64)"


# ===========================================================================
echo "------------------------------"
echo "round-trip: create blob then read back"
echo ""

cat > "$WORK_DIR/roundtrip.json" << EOF
[
  { "action": "create", "file": "$ROUNDTRIP_FILE", "blob": "$BINARY_B64" },
  { "action": "read", "items": ["$ROUNDTRIP_FILE"] }
]
EOF
output=$("$REPLAY_TOOL" --serial "$WORK_DIR/roundtrip.json")
echo "$output" | /usr/bin/grep -qF "[blob:$ROUNDTRIP_FILE]"
verify_succeeded "$?" "round-trip: read output has [blob:...] header"
echo "$output" | /usr/bin/grep -qF "$BINARY_B64"
verify_succeeded "$?" "round-trip: read output contains original base64"


# ===========================================================================
echo "------------------------------"
echo "create blob dry-run: no file created"
echo ""

BLOB_DRYRUN_OUT="$WORK_DIR/blob_dryrun.bin"
cat > "$WORK_DIR/create_blob_dry.json" << EOF
[{ "action": "create", "file": "$BLOB_DRYRUN_OUT", "blob": "$BINARY_B64" }]
EOF
"$REPLAY_TOOL" --dry-run "$WORK_DIR/create_blob_dry.json"
verify_succeeded "$?" "create blob dry-run: replay exited successfully"
test -f "$BLOB_DRYRUN_OUT"
verify_failed "$?" "create blob dry-run: file must NOT be created in dry-run"


report_test_stats

[ "$failure_counter" -eq 0 ]
