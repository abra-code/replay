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

REPLAY=$1
echo "REPLAY = $REPLAY"

if test -z "$REPLAY"; then
	echo "Usage: ./test.sh /path/to/built/replay"
	exit 1
fi

REPLAY_PARENT_DIR=$(dirname "$REPLAY")
REPLAY_TEST_DIR_PATH=$(dirname "$0")

DISPATCH="$REPLAY_PARENT_DIR/dispatch"
if test ! -f "$DISPATCH"; then
	echo "Error: \"dispatch\" tool is expected to be in the same directory as \"dispatch\""
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

verify_succeeded "$?" "streaming files to execute action failed"

# verify there is no orphaned "replay" server running
# count the lines returned by ps for processes with "replay" in name
# there is one system "replayd" we exclude by adding space after "replay"
# another "replay" is from the grep itself below
# so we expect exactly one line with "replay"
dispatch_process_count=$(/bin/ps -U $USER | /usr/bin/grep "replay " | /usr/bin/wc -l)
if test "$dispatch_process_count" -ne "1"; then
	echo "orphaned \"replay\" server detected:"
	/bin/ps -U $USER | /usr/bin/grep "replay "
fi

report_test_stats

