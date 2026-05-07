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
	echo "  Finished glob dep tests    "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}


echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Testing glob dependencies   "
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

REPLAY_TEST_DIR_PATH="$SCRIPT_DIR"
PLAYLIST="$REPLAY_TEST_DIR_PATH/glob_dependencies.json"

echo "PLAYLIST = $PLAYLIST"
echo ""

# --- Tests that should succeed (valid dependency graphs) ---

echo "=== Glob output -> glob input with overlap ==="
echo "replay --dry-run --verbose --playlist-key \"glob output to glob input overlap\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "glob output to glob input overlap" "$PLAYLIST"
verify_succeeded "$?" "glob output to glob input overlap failed"
echo ""

echo "=== Glob output -> glob input, no overlap (independent tasks) ==="
echo "replay --dry-run --verbose --playlist-key \"glob output to glob input no overlap\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "glob output to glob input no overlap" "$PLAYLIST"
verify_succeeded "$?" "glob output to glob input no overlap failed"
echo ""

echo "=== Concrete output -> glob input ==="
echo "replay --dry-run --verbose --playlist-key \"concrete output to glob input\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "concrete output to glob input" "$PLAYLIST"
verify_succeeded "$?" "concrete output to glob input failed"
echo ""

echo "=== Glob output -> concrete input ==="
echo "replay --dry-run --verbose --playlist-key \"glob output to concrete input\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "glob output to concrete input" "$PLAYLIST"
verify_succeeded "$?" "glob output to concrete input failed"
echo ""

echo "=== Mixed concrete and glob inputs ==="
echo "replay --dry-run --verbose --playlist-key \"mixed concrete and glob inputs\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "mixed concrete and glob inputs" "$PLAYLIST"
verify_succeeded "$?" "mixed concrete and glob inputs failed"
echo ""

echo "=== Glob with braces ==="
echo "replay --dry-run --verbose --playlist-key \"glob with braces\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "glob with braces" "$PLAYLIST"
verify_succeeded "$?" "glob with braces failed"
echo ""

echo "=== Glob exclusive inputs ==="
echo "replay --dry-run --verbose --playlist-key \"glob exclusive inputs\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "glob exclusive inputs" "$PLAYLIST"
verify_succeeded "$?" "glob exclusive inputs failed"
echo ""

echo "=== Malformed glob treated as literal ==="
echo "replay --dry-run --verbose --playlist-key \"malformed glob treated as literal\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "malformed glob treated as literal" "$PLAYLIST" 2>/dev/null
verify_succeeded "$?" "malformed glob treated as literal failed"
echo ""

echo "=== Multiple glob outputs, no false cycle (A->B->C chain) ==="
echo "replay --dry-run --verbose --playlist-key \"multiple glob outputs no false cycle\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "multiple glob outputs no false cycle" "$PLAYLIST"
verify_succeeded "$?" "multiple glob outputs no false cycle failed"
echo ""

echo "=== Glob-only task with no producers still executes ==="
echo "replay --dry-run --verbose --playlist-key \"glob only task with no producers still executes\" \"$PLAYLIST\""
"$REPLAY_TOOL" --dry-run --verbose --playlist-key "glob only task with no producers still executes" "$PLAYLIST"
verify_succeeded "$?" "glob only task with no producers still executes failed"
echo ""

report_test_stats

[ "$failure_counter" -eq 0 ]
