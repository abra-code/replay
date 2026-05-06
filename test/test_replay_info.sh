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
	echo "  Finished info tests         "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}


echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "   Testing info               "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""

REPLAY_TOOL=$1
echo "REPLAY_TOOL = $REPLAY_TOOL"

if test -z "$REPLAY_TOOL"; then
	echo "Usage: $0 /path/to/built/replay"
	exit 1
fi

REPLAY_PARENT_DIR=$(dirname "$REPLAY_TOOL")
DISPATCH="$REPLAY_PARENT_DIR/dispatch"

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_info_test.XXXXXX)

cleanup()
{
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo "Work dir: $WORK_DIR"
echo ""

# Build test tree
ROOT="$WORK_DIR/root"
mkdir -p "$ROOT/subdir"
printf 'hello world\n' > "$ROOT/file.txt"
chmod 644 "$ROOT/file.txt"
mkdir -p "$ROOT/adir"


# ===========================================================================
echo "------------------------------"
echo "info file via JSON playlist"
echo ""

cat > "$WORK_DIR/info.json" << EOF
[{ "action": "info", "path": "$ROOT/file.txt" }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/info.json")
echo "$output" | /usr/bin/grep -qF "[info:$ROOT/file.txt]"
verify_succeeded "$?" "info (JSON): expected [info:...] header"
echo "$output" | /usr/bin/grep -qF "size:"
verify_succeeded "$?" "info (JSON): size field present"
echo "$output" | /usr/bin/grep -qF "created:"
verify_succeeded "$?" "info (JSON): created field present"
echo "$output" | /usr/bin/grep -qF "modified:"
verify_succeeded "$?" "info (JSON): modified field present"
echo "$output" | /usr/bin/grep -qF "type: file"
verify_succeeded "$?" "info (JSON): type is file"
echo "$output" | /usr/bin/grep -qF "permissions:"
verify_succeeded "$?" "info (JSON): permissions field present"


# ===========================================================================
echo "------------------------------"
echo "info size matches actual file"
echo ""

actual_size=$(wc -c < "$ROOT/file.txt" | /usr/bin/tr -d ' ')
output=$(printf '[info]\t%s\n' "$ROOT/file.txt" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "size: $actual_size"
verify_succeeded "$?" "info: size matches wc -c"


# ===========================================================================
echo "------------------------------"
echo "info directory via streaming format"
echo ""

output=$(printf '[info]\t%s\n' "$ROOT/adir" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "[info:$ROOT/adir]"
verify_succeeded "$?" "info (stream): expected [info:...] header for directory"
echo "$output" | /usr/bin/grep -qF "type: directory"
verify_succeeded "$?" "info (stream): type is directory"
echo "$output" | /usr/bin/grep -q "permissions: d"
verify_succeeded "$?" "info (stream): permissions start with 'd' for directory"


# ===========================================================================
echo "------------------------------"
echo "info file permissions format"
echo ""

output=$(printf '[info]\t%s\n' "$ROOT/file.txt" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -q "permissions: -"
verify_succeeded "$?" "info: permissions start with '-' for regular file"
# 644: rw-r--r--
echo "$output" | /usr/bin/grep -q "rw-r--r--"
verify_succeeded "$?" "info: permissions show rw-r--r-- for mode 644"


# ===========================================================================
echo "------------------------------"
echo "info timestamps are ISO 8601"
echo ""

output=$(printf '[info]\t%s\n' "$ROOT/file.txt" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qE "created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"
verify_succeeded "$?" "info: created timestamp is ISO 8601"
echo "$output" | /usr/bin/grep -qE "modified: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"
verify_succeeded "$?" "info: modified timestamp is ISO 8601"


# ===========================================================================
echo "------------------------------"
echo "info symlink shows type symlink"
echo ""

ln -s "$ROOT/file.txt" "$ROOT/link.txt"
output=$(printf '[info]\t%s\n' "$ROOT/link.txt" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "type: symlink"
verify_succeeded "$?" "info: symlink reported as type symlink"
echo "$output" | /usr/bin/grep -q "permissions: l"
verify_succeeded "$?" "info: symlink permissions start with 'l'"


# ===========================================================================
echo "------------------------------"
echo "info nonexistent path exits with failure"
echo ""

"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/info.json" 2>/dev/null
verify_succeeded "$?" "info nonexistent: baseline JSON works"

cat > "$WORK_DIR/info_missing.json" << EOF
[{ "action": "info", "path": "$WORK_DIR/no_such_file" }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/info_missing.json" 2>/dev/null
verify_failed "$?" "info missing: expected non-zero exit"


# ===========================================================================
echo "------------------------------"
echo "info dry-run: shows descriptor, no metadata"
echo ""

output=$(printf '[info]\t%s\n' "$ROOT/file.txt" | "$REPLAY_TOOL" --dry-run)
echo "$output" | /usr/bin/grep -qF "[info]"
verify_succeeded "$?" "info dry-run: descriptor present"
echo "$output" | /usr/bin/grep -qF "size:"
verify_failed "$?" "info dry-run: metadata must NOT appear"


# ===========================================================================
echo "------------------------------"
echo "info verbose: shows descriptor then metadata"
echo ""

output=$(printf '[info]\t%s\n' "$ROOT/file.txt" | "$REPLAY_TOOL" --verbose)
echo "$output" | /usr/bin/grep -qF "[info]"
verify_succeeded "$?" "info verbose: descriptor present"
echo "$output" | /usr/bin/grep -qF "size:"
verify_succeeded "$?" "info verbose: metadata still present"


# ===========================================================================
echo "------------------------------"
echo "dispatch info"
echo ""

if test -f "$DISPATCH"; then
	"$REPLAY_TOOL" --start-server infotest1 > "$WORK_DIR/dispatch_info_out.txt" &
	sleep 0.3

	"$DISPATCH" infotest1 info "$ROOT/file.txt"
	"$DISPATCH" infotest1 wait
	verify_succeeded "$?" "dispatch info: wait exited successfully"

	output=$(cat "$WORK_DIR/dispatch_info_out.txt")
	echo "$output" | /usr/bin/grep -qF "[info:$ROOT/file.txt]"
	verify_succeeded "$?" "dispatch info: header present"
	echo "$output" | /usr/bin/grep -qF "type: file"
	verify_succeeded "$?" "dispatch info: type field present"
else
	echo "dispatch not found at $DISPATCH, skipping dispatch tests"
fi


report_test_stats
