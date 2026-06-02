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
	echo "    Finished dispatch tests    "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
	echo ""
}


echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "    Testing dispatch tool      "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
REPLAY="${1:-$REPO_DIR/build/Release/replay}"
if [ ! -x "$REPLAY" ]; then
	echo "error: replay not found at $REPLAY"
	echo "usage: $0 [path/to/replay]"
	exit 1
fi

REPLAY_PARENT_DIR="$(dirname "$REPLAY")"
REPLAY_TEST_DIR_PATH="$SCRIPT_DIR"

DISPATCH="$REPLAY_PARENT_DIR/dispatch"
if [ ! -x "$DISPATCH" ]; then
	echo "error: dispatch not found at $DISPATCH"
	exit 1
fi

echo "DISPATCH = $DISPATCH"


export REPLAY_TEST_FILES_DIR="$REPLAY_TEST_DIR_PATH/Test Files"
echo "REPLAY_TEST_FILES_DIR = $REPLAY_TEST_FILES_DIR"

export REPLAY_TEST="Replay/Test Files"
echo "REPLAY_TEST = $REPLAY_TEST"


echo ""
echo "------------------------------"
echo ""
echo "Dispatch ad hoc tasks"
echo ""

echo "dispatch \"ad-hoc\" start --verbose --dry-run"
echo "dispatch \"ad-hoc\" echo \"hello replay from dispatch\""
echo "dispatch \"ad-hoc\" clone \"${REPLAY_TEST_FILES_DIR}/test-clone.txt\" \"/Users/${USER}/${REPLAY_TEST}/test-clone.txt\""
echo "dispatch \"ad-hoc\" move \"/Users/${USER}/${REPLAY_TEST}/test-move.txt\" \"/Users/${USER}/${REPLAY_TEST}/test-moved.txt\""
echo "dispatch \"ad-hoc\" hardlink \"${REPLAY_TEST_FILES_DIR}/test-hardlink.txt\" \"/Users/${USER}/${REPLAY_TEST}/test-hardlink.txt\""
echo "dispatch \"ad-hoc\" symlink \"${REPLAY_TEST_FILES_DIR}/test-symlink.txt\" \"/Users/${USER}/${REPLAY_TEST}/test-symlink.txt\""
echo "dispatch \"ad-hoc\" create directory \"${HOME}/${REPLAY_TEST}/test-dir\""
echo "dispatch \"ad-hoc\" create file \"${HOME}/${REPLAY_TEST}/test-create-expanded.txt\" \"This is test file at ${HOME}/${REPLAY_TEST}\""
echo "dispatch \"ad-hoc\" delete \"${HOME}/${REPLAY_TEST}/test-delete1.txt\" \"${HOME}/${REPLAY_TEST}/test-delete2.txt\""
echo "dispatch \"ad-hoc\" execute /bin/echo \"Hello from child tool\""
echo "dispatch \"ad-hoc\" wait"

"$DISPATCH" "ad-hoc" start --verbose --dry-run
"$DISPATCH" "ad-hoc" echo "hello replay from dispatch"
"$DISPATCH" "ad-hoc" clone "${REPLAY_TEST_FILES_DIR}/test-clone.txt" "/Users/${USER}/${REPLAY_TEST}/test-clone.txt"
"$DISPATCH" "ad-hoc" move "/Users/${USER}/${REPLAY_TEST}/test-move.txt" "/Users/${USER}/${REPLAY_TEST}/test-moved.txt"
"$DISPATCH" "ad-hoc" hardlink "${REPLAY_TEST_FILES_DIR}/test-hardlink.txt" "/Users/${USER}/${REPLAY_TEST}/test-hardlink.txt"
"$DISPATCH" "ad-hoc" symlink "${REPLAY_TEST_FILES_DIR}/test-symlink.txt" "/Users/${USER}/${REPLAY_TEST}/test-symlink.txt"
"$DISPATCH" "ad-hoc" create directory "${HOME}/${REPLAY_TEST}/test-dir"
"$DISPATCH" "ad-hoc" create file "${HOME}/${REPLAY_TEST}/test-create-expanded.txt" "This is test file at ${HOME}/${REPLAY_TEST}"
"$DISPATCH" "ad-hoc" delete "${HOME}/${REPLAY_TEST}/test-delete1.txt" "${HOME}/${REPLAY_TEST}/test-delete2.txt"
"$DISPATCH" "ad-hoc" execute /bin/echo "Hello from child tool"
"$DISPATCH" "ad-hoc" wait

verify_succeeded "$?" "action stream test failed"


echo ""
echo "------------------------------"
echo ""
echo "Streamed actions from action_stream.txt"
echo ""

echo "dispatch \"action_stream\" start --verbose --dry-run"
echo "cat \"$REPLAY_TEST_DIR_PATH/action_stream.txt\" | dispatch \"action_stream\""
echo "dispatch \"action_stream\" wait"

"$DISPATCH" "action_stream" start --verbose --dry-run
cat "$REPLAY_TEST_DIR_PATH/action_stream.txt" | "$DISPATCH" "action_stream"
"$DISPATCH" "action_stream" wait

verify_succeeded "$?" "action stream test failed"


echo ""
echo "------------------------------"
echo ""
echo "Streamed actions from text_action_stream.txt"
echo ""

echo "dispatch \"text_action_stream\" start --ordered-output"
echo "cat \"$REPLAY_TEST_DIR_PATH/text_action_stream.txt\" | dispatch \"text_action_stream\""
echo "dispatch \"text_action_stream\" wait"

"$DISPATCH" "text_action_stream" start --ordered-output
cat "$REPLAY_TEST_DIR_PATH/text_action_stream.txt" | "$DISPATCH" "text_action_stream"
"$DISPATCH" "text_action_stream" wait

verify_succeeded "$?" "text action stream test failed"


echo ""
echo "------------------------------"
echo ""
echo "Unordered output from streamed sequential number echo actions in action_stream_ordering.txt"
echo ""

echo "cat \"$REPLAY_TEST_DIR_PATH/action_stream_ordering.txt\" | dispatch \"action_stream_ordering\""
echo "dispatch \"action_stream_ordering\" wait"

cat "$REPLAY_TEST_DIR_PATH/action_stream_ordering.txt" | "$DISPATCH" "action_stream_ordering"
"$DISPATCH" "action_stream_ordering" wait

verify_succeeded "$?" "unoredered output action stream test failed"

echo ""
echo "------------------------------"
echo ""
echo "Ordered output from streamed sequential number echo actions in action_stream_ordering.txt"
echo ""

echo "dispatch \"action_stream_ordering-ordered\" start --ordered-output"
echo "cat \"$REPLAY_TEST_DIR_PATH/action_stream_ordering.txt\" | dispatch \"action_stream_ordering-ordered\""
echo "dispatch \"action_stream_ordering-ordered\" wait"

"$DISPATCH" "action_stream_ordering-ordered" start --ordered-output
cat "$REPLAY_TEST_DIR_PATH/action_stream_ordering.txt" | "$DISPATCH" "action_stream_ordering-ordered"
"$DISPATCH" "action_stream_ordering-ordered" wait

verify_succeeded "$?" "ordered output action stream test failed"

echo ""
echo "------------------------------"
echo ""
echo "Stream all files starting with dot from $HOME directory to execute /bin/echo action"
echo ""

echo "dispatch \"echo-dot-files\" start --ordered-output"
echo "/bin/ls -a \"$HOME\" | /usr/bin/grep -E '^\..*' | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | dispatch \"echo-dot-files\""
echo "dispatch \"echo-dot-files\" wait"

"$DISPATCH" "echo-dot-files" start --ordered-output
/bin/ls -a "$HOME" | /usr/bin/grep -E '^\..*' | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$DISPATCH" "echo-dot-files"
"$DISPATCH" "echo-dot-files" wait

verify_succeeded "$?" "streaming files to execute action failed"


echo ""
echo "------------------------------"
echo ""
echo "Stream all files starting with dot from $HOME directory to print with built-in echo action"
echo ""

echo "dispatch \"echo-dot-files\" start --ordered-output"
echo "/bin/ls -a \"$HOME\" | /usr/bin/grep -E '^\..*' | /usr/bin/sed -E 's|(.+)|[echo]\t\1|' | dispatch \"echo-dot-files\""
echo "dispatch \"echo-dot-files\" wait"

"$DISPATCH" "echo-dot-files" start --ordered-output
/bin/ls -a "$HOME" | /usr/bin/grep -E '^\..*' | /usr/bin/sed -E 's|(.+)|[echo]\t\1|' | "$DISPATCH" "echo-dot-files"
"$DISPATCH" "echo-dot-files" wait

verify_succeeded "$?" "streaming files to echo action failed"


echo ""
echo "------------------------------"
echo ""
echo "Stream all files starting with dot from $HOME directory to echo to redirected stdout into /tmp/echo-dot-files.out"
echo ""

echo "dispatch \"echo-dot-files\" start --ordered-output --stdout /tmp/echo-dot-files.out"
echo "dispatch \"echo-dot-files\" echo \"~~~~~~~~ begin ~~~~~~~~\""
echo "/bin/ls -a \"$HOME\" | /usr/bin/grep -E '^\..*' | /usr/bin/sed -E 's|(.+)|[echo]\t\1|' | dispatch \"echo-dot-files\""
echo "dispatch \"echo-dot-files\" echo \"~~~~~~~~ end ~~~~~~~~~\""
echo "dispatch \"echo-dot-files\" wait"

"$DISPATCH" "echo-dot-files" start --ordered-output --stdout "/tmp/echo-dot-files.out"
"$DISPATCH" "echo-dot-files" echo "~~~~~~~~ begin ~~~~~~~~"
/bin/ls -a "$HOME" | /usr/bin/grep -E '^\..*' | /usr/bin/sed -E 's|(.+)|[echo]\t\1|' | "$DISPATCH" "echo-dot-files"
"$DISPATCH" "echo-dot-files" echo "~~~~~~~~ end ~~~~~~~~~"
"$DISPATCH" "echo-dot-files" wait

verify_succeeded "$?" "streaming files with echo to stdout file failed"

if test ! -f "/tmp/echo-dot-files.out"; then
	verify_succeeded "1" "stdout was not written by \"replay\" in /tmp/echo-dot-files.out"
else
	echo ""
	echo "The content of \"/tmp/echo-dot-files.out\" file:"
	/bin/cat "/tmp/echo-dot-files.out"
	/bin/rm "/tmp/echo-dot-files.out"
fi

echo ""
echo "------------------------------"
echo ""
echo "Test redirecting stderr output to /tmp/execution-failure.err"
echo ""

echo "dispatch \"stderr-test\" start --stderr /tmp/execution-failure.err"
echo "dispatch \"stderr-test\" execute \"/path/to/imaginary/tool\""
echo "dispatch \"stderr-test\" execute /bin/cat \"/sumpthin/stoopid\""
echo "dispatch \"stderr-test\" wait"

"$DISPATCH" "stderr-test" start --stderr "/tmp/execution-failure.err"
"$DISPATCH" "stderr-test" execute "/path/to/imaginary/tool"
"$DISPATCH" "stderr-test" execute /bin/cat "/sumpthin/stoopid"
"$DISPATCH" "stderr-test" wait

verify_succeeded "$?" "test redirecting stderr file failed"

if test ! -f "/tmp/execution-failure.err"; then
	verify_succeeded "1" "stderr was not written by \"replay\" in /tmp/execution-failure.err"
else
	echo ""
	echo "The content of \"/tmp/execution-failure.err\" file (expected errors):"
	/bin/cat "/tmp/execution-failure.err"
	/bin/rm "/tmp/execution-failure.err"
fi

WORK_DIR=$(/usr/bin/mktemp -d /tmp/dispatch_read_test.XXXXXX)
TEXT_FILE="$WORK_DIR/hello.txt"
BINARY_FILE="$WORK_DIR/data.bin"
BLOB_OUT_FILE="$WORK_DIR/blob_out.bin"
ROUNDTRIP_FILE="$WORK_DIR/roundtrip.bin"

printf 'Hello from dispatch!\n' > "$TEXT_FILE"
printf '\x89PNG\x0d\x0a\x1a\x0a' > "$BINARY_FILE"
BINARY_B64="iVBORw0KGgo="

echo ""
echo "------------------------------"
echo ""
echo "Read text file via dispatch (output captured to file)"
echo ""

DISPATCH_READ_TEXT_OUT="/tmp/dispatch-read-text.out"
echo "dispatch \"dispatch-read-text\" start --stdout \"$DISPATCH_READ_TEXT_OUT\""
echo "dispatch \"dispatch-read-text\" read \"$TEXT_FILE\""
echo "dispatch \"dispatch-read-text\" wait"

"$DISPATCH" "dispatch-read-text" start --stdout "$DISPATCH_READ_TEXT_OUT"
"$DISPATCH" "dispatch-read-text" read "$TEXT_FILE"
"$DISPATCH" "dispatch-read-text" wait
verify_succeeded "$?" "dispatch read text: wait failed"

if test -f "$DISPATCH_READ_TEXT_OUT"; then
	/usr/bin/grep -qF "[text:$TEXT_FILE]" "$DISPATCH_READ_TEXT_OUT"
	verify_succeeded "$?" "dispatch read text: expected [text:...] header in output file"
	/usr/bin/grep -qF "Hello from dispatch!" "$DISPATCH_READ_TEXT_OUT"
	verify_succeeded "$?" "dispatch read text: expected file content in output file"
	/bin/rm "$DISPATCH_READ_TEXT_OUT"
else
	verify_succeeded "1" "dispatch read text: output file was not created"
fi


echo ""
echo "------------------------------"
echo ""
echo "Read binary file via dispatch (output captured to file)"
echo ""

DISPATCH_READ_BIN_OUT="/tmp/dispatch-read-binary.out"
echo "dispatch \"dispatch-read-binary\" start --stdout \"$DISPATCH_READ_BIN_OUT\""
echo "dispatch \"dispatch-read-binary\" read \"$BINARY_FILE\""
echo "dispatch \"dispatch-read-binary\" wait"

"$DISPATCH" "dispatch-read-binary" start --stdout "$DISPATCH_READ_BIN_OUT"
"$DISPATCH" "dispatch-read-binary" read "$BINARY_FILE"
"$DISPATCH" "dispatch-read-binary" wait
verify_succeeded "$?" "dispatch read binary: wait failed"

if test -f "$DISPATCH_READ_BIN_OUT"; then
	/usr/bin/grep -qF "[blob:$BINARY_FILE]" "$DISPATCH_READ_BIN_OUT"
	verify_succeeded "$?" "dispatch read binary: expected [blob:...] header in output file"
	/usr/bin/grep -qF "$BINARY_B64" "$DISPATCH_READ_BIN_OUT"
	verify_succeeded "$?" "dispatch read binary: expected base64 content in output file"
	/bin/rm "$DISPATCH_READ_BIN_OUT"
else
	verify_succeeded "1" "dispatch read binary: output file was not created"
fi


echo ""
echo "------------------------------"
echo ""
echo "Create binary file from blob via dispatch"
echo ""

echo "dispatch \"dispatch-create-blob\" create file \"$BLOB_OUT_FILE\" blob \"$BINARY_B64\""
echo "dispatch \"dispatch-create-blob\" wait"

"$DISPATCH" "dispatch-create-blob" create file "$BLOB_OUT_FILE" blob "$BINARY_B64"
"$DISPATCH" "dispatch-create-blob" wait
verify_succeeded "$?" "dispatch create blob: wait failed"

test -f "$BLOB_OUT_FILE"
verify_succeeded "$?" "dispatch create blob: output file was not created"

written_b64=$(base64 < "$BLOB_OUT_FILE")
test "$written_b64" = "$BINARY_B64"
verify_succeeded "$?" "dispatch create blob: file content does not match (got: $written_b64)"


echo ""
echo "------------------------------"
echo ""
echo "Round-trip: create blob then read back via dispatch"
echo ""

DISPATCH_ROUNDTRIP_OUT="/tmp/dispatch-roundtrip.out"
echo "dispatch \"dispatch-roundtrip\" start --serial --stdout \"$DISPATCH_ROUNDTRIP_OUT\""
echo "dispatch \"dispatch-roundtrip\" create file \"$ROUNDTRIP_FILE\" blob \"$BINARY_B64\""
echo "dispatch \"dispatch-roundtrip\" read \"$ROUNDTRIP_FILE\""
echo "dispatch \"dispatch-roundtrip\" wait"

"$DISPATCH" "dispatch-roundtrip" start --serial --stdout "$DISPATCH_ROUNDTRIP_OUT"
"$DISPATCH" "dispatch-roundtrip" create file "$ROUNDTRIP_FILE" blob "$BINARY_B64"
"$DISPATCH" "dispatch-roundtrip" read "$ROUNDTRIP_FILE"
"$DISPATCH" "dispatch-roundtrip" wait
verify_succeeded "$?" "dispatch round-trip: wait failed"

if test -f "$DISPATCH_ROUNDTRIP_OUT"; then
	/usr/bin/grep -qF "[blob:$ROUNDTRIP_FILE]" "$DISPATCH_ROUNDTRIP_OUT"
	verify_succeeded "$?" "dispatch round-trip: expected [blob:...] header in output"
	/usr/bin/grep -qF "$BINARY_B64" "$DISPATCH_ROUNDTRIP_OUT"
	verify_succeeded "$?" "dispatch round-trip: expected base64 content in output"
	/bin/rm "$DISPATCH_ROUNDTRIP_OUT"
else
	verify_succeeded "1" "dispatch round-trip: output file was not created"
fi

rm -rf "$WORK_DIR"


EDIT_WORK_DIR=$(/usr/bin/mktemp -d /tmp/dispatch_edit_test.XXXXXX)

echo ""
echo "------------------------------"
echo ""
echo "dispatch edit: literal replace (unique match, default limit=1)"
echo ""

EDIT_FILE="$EDIT_WORK_DIR/literal.txt"
printf 'hello world\nhello again\n' > "$EDIT_FILE"

# oldText is unique ("hello world") — at the default limit a literal must match
# exactly one place (uniqueness guard), so anchor on the full first line.
"$DISPATCH" "dispatch-edit-literal" edit "$EDIT_FILE" "hello world" "goodbye world"
"$DISPATCH" "dispatch-edit-literal" wait
verify_succeeded "$?" "dispatch edit literal: wait failed"
/usr/bin/grep -qF "goodbye world" "$EDIT_FILE"
verify_succeeded "$?" "dispatch edit literal: unique match replaced"
/usr/bin/grep -qF "hello again" "$EDIT_FILE"
verify_succeeded "$?" "dispatch edit literal: other line unchanged"


echo ""
echo "------------------------------"
echo ""
echo "dispatch edit: delete (empty newText)"
echo ""

EDIT_FILE="$EDIT_WORK_DIR/delete.txt"
printf 'remove this text\n' > "$EDIT_FILE"

"$DISPATCH" "dispatch-edit-delete" edit "$EDIT_FILE" " this" ""
"$DISPATCH" "dispatch-edit-delete" wait
verify_succeeded "$?" "dispatch edit delete: wait failed"
/usr/bin/grep -qF "remove text" "$EDIT_FILE"
verify_succeeded "$?" "dispatch edit delete: substring removed"


echo ""
echo "------------------------------"
echo ""
echo "dispatch edit: limit=0 replaces all occurrences"
echo ""

EDIT_FILE="$EDIT_WORK_DIR/limit.txt"
printf 'foo\nfoo\nfoo\n' > "$EDIT_FILE"

"$DISPATCH" "dispatch-edit-limit" edit "$EDIT_FILE" "foo" "bar" limit=0
"$DISPATCH" "dispatch-edit-limit" wait
verify_succeeded "$?" "dispatch edit limit=0: wait failed"
count=$(/usr/bin/grep -c "bar" "$EDIT_FILE")
test "$count" = "3"
verify_succeeded "$?" "dispatch edit limit=0: all 3 occurrences replaced (got $count)"
/usr/bin/grep -qF "foo" "$EDIT_FILE" && verify_succeeded "1" "dispatch edit limit=0: 'foo' still present"


echo ""
echo "------------------------------"
echo ""
echo "dispatch edit: regex with back-reference swap"
echo ""

EDIT_FILE="$EDIT_WORK_DIR/regex.txt"
printf 'John Smith\n' > "$EDIT_FILE"

"$DISPATCH" "dispatch-edit-regex" edit "$EDIT_FILE" "([A-Za-z]+) ([A-Za-z]+)" '\2, \1' regex=true
"$DISPATCH" "dispatch-edit-regex" wait
verify_succeeded "$?" "dispatch edit regex: wait failed"
/usr/bin/grep -qF "Smith, John" "$EDIT_FILE"
verify_succeeded "$?" "dispatch edit regex: back-reference swap produced 'Smith, John'"


echo ""
echo "------------------------------"
echo ""
echo "dispatch edit: case-insensitive=true"
echo ""

EDIT_FILE="$EDIT_WORK_DIR/case.txt"
printf 'Hello World\n' > "$EDIT_FILE"

"$DISPATCH" "dispatch-edit-case" edit "$EDIT_FILE" "hello" "goodbye" case-insensitive=true
"$DISPATCH" "dispatch-edit-case" wait
verify_succeeded "$?" "dispatch edit case-insensitive: wait failed"
/usr/bin/grep -qF "goodbye World" "$EDIT_FILE"
verify_succeeded "$?" "dispatch edit case-insensitive: matched 'Hello' with pattern 'hello'"


echo ""
echo "------------------------------"
echo ""
echo "dispatch edit: missing newText exits with error"
echo ""

"$DISPATCH" "dispatch-edit-err" edit "$EDIT_WORK_DIR/literal.txt" "foo" 2>/dev/null
verify_failed "$?" "dispatch edit missing newText: should have exited with error"
"$DISPATCH" "dispatch-edit-err" wait 2>/dev/null


rm -rf "$EDIT_WORK_DIR"


# verify there is no orphaned "replay" server running
# count the lines returned by ps for processes with "replay" in name
# there is one system "replayd" we exclude by adding space after "replay"
# another "replay" is from the grep itself below
# so we expect exactly one line with "replay " match
dispatch_process_count=$(/bin/ps -U $USER | /usr/bin/grep "replay " | /usr/bin/wc -l)
if test "$dispatch_process_count" -ne "1"; then
	echo "orphaned \"replay\" server detected:"
	/bin/ps -U $USER | /usr/bin/grep "replay "
fi

report_test_stats


[ "$failure_counter" -eq 0 ]
