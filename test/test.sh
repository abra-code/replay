#! /bin/sh

echo ""
echo "          **********************************************"
echo "                       Testing replay tool"
echo "          **********************************************"
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

echo ""
echo "replay --serial --playlist-key \"setup\""
"$REPLAY_TOOL" --serial --playlist-key "setup" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"

echo ""
echo "replay --playlist-key \"tests\""
"$REPLAY_TOOL" --playlist-key "tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"

echo ""
echo "replay --force --serial tests --playlist-key \"force tests\""
"$REPLAY_TOOL" --force --serial --playlist-key "force tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.json"

echo ""
echo "------------------------------"
echo ""
echo "Testing playlist in plist format"

echo ""
echo "Validating plist with plutil"
/usr/bin/plutil "$REPLAY_TEST_DIR_PATH/playlist.plist"

echo ""
echo "replay --serial --playlist-key \"setup\""
"$REPLAY_TOOL" --serial --playlist-key "setup" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"

echo ""
echo "replay --playlist-key \"tests\""
"$REPLAY_TOOL" --playlist-key "tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"

echo ""
echo "replay --force --serial tests --playlist-key \"force tests\""
"$REPLAY_TOOL" --force --serial --playlist-key "force tests" --verbose "$REPLAY_TEST_DIR_PATH/playlist.plist"

echo ""
