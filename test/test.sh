#! /bin/sh

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
	echo "    Finished replay tests    "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
	echo ""
}


echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "    Testing replay tool      "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""

REPLAY_TOOL=$1
echo "REPLAY_TOOL = $REPLAY_TOOL"

if test -z "$REPLAY_TOOL"; then
	echo "Usage: ./test.sh /path/to/built/replay"
	exit 1
fi

REPLAY_TEST_DIR_PATH=$(dirname "$0")

export REPLAY_TEST_FILES_DIR="$REPLAY_TEST_DIR_PATH/Test Files"
echo "REPLAY_TEST_FILES_DIR = $REPLAY_TEST_FILES_DIR"

export REPLAY_TEST="Replay/Test Files"
echo "REPLAY_TEST = $REPLAY_TEST"

echo "------------------------------"
echo ""
echo "Testing playlist in JSON format"
echo "Path: \"$REPLAY_TEST_DIR_PATH/playlist.json\""

echo ""
echo "replay --serial --playlist-key \"setup\""
"$REPLAY_TOOL" --serial --playlist-key "setup" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"
verify_succeeded "$?" "'setup' failed"

echo ""
echo "replay --playlist-key \"tests\""
"$REPLAY_TOOL" --playlist-key "tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"
verify_succeeded "$?" "'tests' failed"

echo ""
echo "replay --force --serial --playlist-key \"force tests\""
"$REPLAY_TOOL" --force --serial --playlist-key "force tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"
verify_succeeded "$?" "'force tests' failed"

echo ""
echo "replay --playlist-key \"execute tests\""
"$REPLAY_TOOL" --playlist-key "execute tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"
verify_succeeded "$?" "'execute tests' failed"

echo "------------------------------"
echo ""
echo "Dry run testing multiple playlists executed together in JSON format"
echo ""
echo "replay --dry-run --playlist-key \"tests\" --playlist-key \"symlink tests\""
"$REPLAY_TOOL" --dry-run --playlist-key "tests" --playlist-key "symlink tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"
verify_succeeded "$?" "multiple playlists test failed"

echo ""
echo "------------------------------"
echo ""
echo "Testing playlist in plist format"
echo "Path: \"$REPLAY_TEST_DIR_PATH/playlist.plist\""

echo ""
echo "Validating plist with plutil"
/usr/bin/plutil "$REPLAY_TEST_DIR_PATH/playlist.plist"
verify_succeeded "$?" "plutil playlist.plist failed"

echo ""
echo "replay --serial --playlist-key \"setup\""
"$REPLAY_TOOL" --serial --playlist-key "setup" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"
verify_succeeded "$?" "'setup' failed"

echo ""
echo "replay --playlist-key \"tests\""
"$REPLAY_TOOL" --playlist-key "tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"
verify_succeeded "$?" "'tests' failed"

echo ""
echo "replay --force --serial --playlist-key \"force tests\""
"$REPLAY_TOOL" --force --serial --playlist-key "force tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"
verify_succeeded "$?" "'force tests' failed"

echo ""
echo "replay --playlist-key \"execute tests\""
"$REPLAY_TOOL" --playlist-key "execute tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"
verify_succeeded "$?" "'execute tests' failed"

echo "------------------------------"
echo ""
echo "Dry run testing multiple playlists executed together in plist format"
echo ""
echo "replay --dry-run --playlist-key \"tests\" --playlist-key \"symlink tests\""
"$REPLAY_TOOL" --dry-run --playlist-key "tests" --playlist-key "symlink tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"
verify_succeeded "$?" "replay multiple playlists test failed"


echo ""
echo "------------------------------"
echo ""
echo "Dry run testing playlist array in JSON format"
echo "Path: \"$REPLAY_TEST_DIR_PATH/playlist_array.json\""
echo ""
echo "replay --dry-run"
"$REPLAY_TOOL" --dry-run --verbose "$REPLAY_TEST_DIR_PATH/playlist_array.json"
verify_succeeded "$?" "replay 'playlist_array.json' test failed"


echo ""
echo "------------------------------"
echo ""
echo "Dry run testing playlist array in plist format"
echo "Path: \"$REPLAY_TEST_DIR_PATH/playlist_array.plist\""
echo ""

echo "Validating plist with plutil"
/usr/bin/plutil "$REPLAY_TEST_DIR_PATH/playlist_array.plist"
verify_succeeded "$?" "plutil 'playlist_array.plist' failed"

echo ""
echo "replay --dry-run"
"$REPLAY_TOOL" --dry-run --verbose "$REPLAY_TEST_DIR_PATH/playlist_array.plist"
verify_succeeded "$?" "replay 'playlist_array.plist' test failed"


echo ""
echo "------------------------------"
echo ""
echo "Concurrency violations expected to fail"
echo "Path: \"$REPLAY_TEST_DIR_PATH/concurrency_violations.json\""
echo ""

echo "replay --playlist-key \"two actions with the same output\""
"$REPLAY_TOOL" --dry-run --playlist-key "two actions with the same output" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_failed "$?" "'two actions with the same output' was expected to fail!"

echo ""
echo "replay --playlist-key \"exclusive input in two actions\""
"$REPLAY_TOOL" --dry-run --playlist-key "exclusive input in two actions" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_failed "$?" "'exclusive input in two actions' was expected to fail!"

echo ""
echo "replay --playlist-key \"create under exclusive input\""
"$REPLAY_TOOL" --dry-run --playlist-key "create under exclusive input" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_failed "$?" "'create under exclusive input' was expected to fail!"

echo ""
echo "replay --playlist-key \"consumer under exclusive input\""
"$REPLAY_TOOL" --dry-run --playlist-key "consumer under exclusive input" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_failed "$?" "'consumer under exclusive input' was expected to fail!"

echo ""
echo "replay --playlist-key \"explicit exclusive input in two actions\""
"$REPLAY_TOOL" --dry-run --playlist-key "explicit exclusive input in two actions" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_failed "$?" "'explicit exclusive input in two actions' was expected to fail!"

echo ""
echo "replay --playlist-key \"explicit and implict exclusive input in two actions\""
"$REPLAY_TOOL" --dry-run --playlist-key "explicit and implict exclusive input in two actions" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_failed "$?" "'explicit and implict exclusive input in two actions' was expected to fail!"

echo "------------------------------"
echo ""
echo "Concurrency non-violations expected to pass"
echo "Path: \"$REPLAY_TEST_DIR_PATH/concurrency_violations.json\""
echo ""

echo "replay --playlist-key \"one producer with nested dirs allowed\""
"$REPLAY_TOOL" --dry-run --playlist-key "one producer with nested dirs allowed" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_succeeded "$?" "'one producer with nested dirs allowed' test failed"
echo ""

echo "replay --playlist-key \"one producer one exclusive consumer allowed\""
"$REPLAY_TOOL" --dry-run --playlist-key "one producer one exclusive consumer allowed" "$REPLAY_TEST_DIR_PATH/concurrency_violations.json"
verify_succeeded "$?" "'one producer one exclusive consumer allowed' test failed"
echo ""


report_test_stats
