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
	echo "  Finished list & tree tests  "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}


echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "   Testing list & tree        "
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

REPLAY_PARENT_DIR="$(dirname "$REPLAY_TOOL")"
DISPATCH="$REPLAY_PARENT_DIR/dispatch"

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_list_tree_test.XXXXXX)

cleanup()
{
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo "Work dir: $WORK_DIR"
echo ""

# Build test tree:
#   $WORK_DIR/root/
#     alpha.txt
#     beta.bin
#     subdir/
#       deep.txt
#     empty_dir/

ROOT="$WORK_DIR/root"
mkdir -p "$ROOT/subdir" "$ROOT/empty_dir"
printf 'text content\n' > "$ROOT/alpha.txt"
printf '\x89PNG\x0d\x0a\x1a\x0a' > "$ROOT/beta.bin"
printf 'deeper text\n' > "$ROOT/subdir/deep.txt"


# ===========================================================================
echo "------------------------------"
echo "list directory via JSON playlist"
echo ""

cat > "$WORK_DIR/list.json" << EOF
[{ "action": "list", "directory": "$ROOT" }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/list.json")
echo "$output" | /usr/bin/grep -qF "[list:$ROOT]"
verify_succeeded "$?" "list (JSON): expected [list:...] header"
echo "$output" | /usr/bin/grep -qF "[FILE] alpha.txt"
verify_succeeded "$?" "list (JSON): alpha.txt listed as FILE"
echo "$output" | /usr/bin/grep -qF "[FILE] beta.bin"
verify_succeeded "$?" "list (JSON): beta.bin listed as FILE"
echo "$output" | /usr/bin/grep -qF "[DIR] subdir"
verify_succeeded "$?" "list (JSON): subdir listed as DIR"
echo "$output" | /usr/bin/grep -qF "[DIR] empty_dir"
verify_succeeded "$?" "list (JSON): empty_dir listed as DIR"


# ===========================================================================
echo "------------------------------"
echo "list directory via streaming format"
echo ""

output=$(printf '[list]\t%s\n' "$ROOT" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "[list:$ROOT]"
verify_succeeded "$?" "list (stream): expected [list:...] header"
echo "$output" | /usr/bin/grep -qF "[FILE] alpha.txt"
verify_succeeded "$?" "list (stream): alpha.txt listed as FILE"
echo "$output" | /usr/bin/grep -qF "[DIR] subdir"
verify_succeeded "$?" "list (stream): subdir listed as DIR"


# ===========================================================================
echo "------------------------------"
echo "list output is sorted alphabetically"
echo ""

output=$(printf '[list]\t%s\n' "$ROOT" | "$REPLAY_TOOL")
# alpha.txt (a) must appear before beta.bin (b) which appears before empty_dir (e) and subdir (s)
alpha_line=$(echo "$output" | /usr/bin/grep -n "alpha.txt" | /usr/bin/cut -d: -f1)
beta_line=$(echo "$output" | /usr/bin/grep -n "beta.bin" | /usr/bin/cut -d: -f1)
empty_line=$(echo "$output" | /usr/bin/grep -n "empty_dir" | /usr/bin/cut -d: -f1)
subdir_line=$(echo "$output" | /usr/bin/grep -n "subdir" | /usr/bin/cut -d: -f1)
test "$alpha_line" -lt "$beta_line"
verify_succeeded "$?" "list sort: alpha.txt before beta.bin"
test "$beta_line" -lt "$empty_line"
verify_succeeded "$?" "list sort: beta.bin before empty_dir"
test "$empty_line" -lt "$subdir_line"
verify_succeeded "$?" "list sort: empty_dir before subdir"


# ===========================================================================
echo "------------------------------"
echo "list nonexistent directory exits with failure"
echo ""

cat > "$WORK_DIR/list_missing.json" << EOF
[{ "action": "list", "directory": "$WORK_DIR/no_such_dir" }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/list_missing.json" 2>/dev/null
verify_failed "$?" "list missing: expected non-zero exit"


# ===========================================================================
echo "------------------------------"
echo "list dry-run: shows descriptor, does not list contents"
echo ""

output=$(printf '[list]\t%s\n' "$ROOT" | "$REPLAY_TOOL" --dry-run)
echo "$output" | /usr/bin/grep -qF "[list]"
verify_succeeded "$?" "list dry-run: expected [list] descriptor"
echo "$output" | /usr/bin/grep -qF "alpha.txt"
verify_failed "$?" "list dry-run: entries must NOT appear in dry-run output"


# ===========================================================================
echo "------------------------------"
echo "list verbose: shows descriptor then listing"
echo ""

output=$(printf '[list]\t%s\n' "$ROOT" | "$REPLAY_TOOL" --verbose)
echo "$output" | /usr/bin/grep -qF "[list]"
verify_succeeded "$?" "list verbose: descriptor present"
echo "$output" | /usr/bin/grep -qF "[FILE] alpha.txt"
verify_succeeded "$?" "list verbose: listing still present"


# ===========================================================================
echo "------------------------------"
echo "tree directory via JSON playlist"
echo ""

cat > "$WORK_DIR/tree.json" << EOF
[{ "action": "tree", "directory": "$ROOT" }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/tree.json")
echo "$output" | /usr/bin/grep -qF "[tree:$ROOT]"
verify_succeeded "$?" "tree (JSON): expected [tree:...] header"
echo "$output" | /usr/bin/grep -qF '"name":"root"'
verify_succeeded "$?" "tree (JSON): root node name present"
echo "$output" | /usr/bin/grep -qF '"type":"directory"'
verify_succeeded "$?" "tree (JSON): root type is directory"
echo "$output" | /usr/bin/grep -qF '"name":"alpha.txt"'
verify_succeeded "$?" "tree (JSON): alpha.txt in output"
echo "$output" | /usr/bin/grep -qF '"name":"subdir"'
verify_succeeded "$?" "tree (JSON): subdir in output"
echo "$output" | /usr/bin/grep -qF '"name":"deep.txt"'
verify_succeeded "$?" "tree (JSON): deep.txt in output (recursive)"


# ===========================================================================
echo "------------------------------"
echo "tree directory via streaming format"
echo ""

output=$(printf '[tree]\t%s\n' "$ROOT" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "[tree:$ROOT]"
verify_succeeded "$?" "tree (stream): expected [tree:...] header"
echo "$output" | /usr/bin/grep -qF '"name":"root"'
verify_succeeded "$?" "tree (stream): root node present"
echo "$output" | /usr/bin/grep -qF '"name":"deep.txt"'
verify_succeeded "$?" "tree (stream): deep.txt present (recursive)"


# ===========================================================================
echo "------------------------------"
echo "tree with depth=0: root node only, no children listed"
echo ""

cat > "$WORK_DIR/tree_depth0.json" << EOF
[{ "action": "tree", "directory": "$ROOT", "depth": 0 }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/tree_depth0.json")
echo "$output" | /usr/bin/grep -qF '"name":"root"'
verify_succeeded "$?" "tree depth=0: root node present"
echo "$output" | /usr/bin/grep -qF '"name":"alpha.txt"'
verify_failed "$?" "tree depth=0: children must NOT appear"


# ===========================================================================
echo "------------------------------"
echo "tree with depth=1 via streaming modifier: no deep.txt"
echo ""

output=$(printf '[tree depth=1]\t%s\n' "$ROOT" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF '"name":"subdir"'
verify_succeeded "$?" "tree depth=1: subdir present at depth 1"
echo "$output" | /usr/bin/grep -qF '"name":"deep.txt"'
verify_failed "$?" "tree depth=1: deep.txt must NOT appear (too deep)"


# ===========================================================================
echo "------------------------------"
echo "tree nonexistent directory exits with failure"
echo ""

cat > "$WORK_DIR/tree_missing.json" << EOF
[{ "action": "tree", "directory": "$WORK_DIR/no_such_dir" }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/tree_missing.json" 2>/dev/null
verify_failed "$?" "tree missing: expected non-zero exit"


# ===========================================================================
echo "------------------------------"
echo "tree dry-run: shows descriptor, no JSON output"
echo ""

output=$(printf '[tree]\t%s\n' "$ROOT" | "$REPLAY_TOOL" --dry-run)
echo "$output" | /usr/bin/grep -qF "[tree]"
verify_succeeded "$?" "tree dry-run: expected [tree] descriptor"
echo "$output" | /usr/bin/grep -qF '"name"'
verify_failed "$?" "tree dry-run: JSON must NOT appear in dry-run output"


# ===========================================================================
echo "------------------------------"
echo "tree verbose: shows descriptor then JSON"
echo ""

output=$(printf '[tree]\t%s\n' "$ROOT" | "$REPLAY_TOOL" --verbose)
echo "$output" | /usr/bin/grep -qF "[tree]"
verify_succeeded "$?" "tree verbose: descriptor present"
echo "$output" | /usr/bin/grep -qF '"name":"root"'
verify_succeeded "$?" "tree verbose: JSON output still present"


# ===========================================================================
echo "------------------------------"
echo "dispatch list"
echo ""

if test -f "$DISPATCH"; then
	"$REPLAY_TOOL" --start-server listtreetest1 > "$WORK_DIR/dispatch_list_out.txt" &
	sleep 0.3

	"$DISPATCH" listtreetest1 list "$ROOT"
	"$DISPATCH" listtreetest1 wait
	verify_succeeded "$?" "dispatch list: wait exited successfully"

	output=$(cat "$WORK_DIR/dispatch_list_out.txt")
	echo "$output" | /usr/bin/grep -qF "[list:$ROOT]"
	verify_succeeded "$?" "dispatch list: header present"
	echo "$output" | /usr/bin/grep -qF "[FILE] alpha.txt"
	verify_succeeded "$?" "dispatch list: alpha.txt listed"
	echo "$output" | /usr/bin/grep -qF "[DIR] subdir"
	verify_succeeded "$?" "dispatch list: subdir listed"
else
	echo "dispatch not found at $DISPATCH, skipping dispatch tests"
fi


# ===========================================================================
echo "------------------------------"
echo "dispatch tree"
echo ""

if test -f "$DISPATCH"; then
	"$REPLAY_TOOL" --start-server listtreetest2 > "$WORK_DIR/dispatch_tree_out.txt" &
	sleep 0.3

	"$DISPATCH" listtreetest2 tree "$ROOT"
	"$DISPATCH" listtreetest2 wait
	verify_succeeded "$?" "dispatch tree: wait exited successfully"

	output=$(cat "$WORK_DIR/dispatch_tree_out.txt")
	echo "$output" | /usr/bin/grep -qF "[tree:$ROOT]"
	verify_succeeded "$?" "dispatch tree: header present"
	echo "$output" | /usr/bin/grep -qF '"name":"root"'
	verify_succeeded "$?" "dispatch tree: root node present"
	echo "$output" | /usr/bin/grep -qF '"name":"deep.txt"'
	verify_succeeded "$?" "dispatch tree: deep.txt present (recursive)"
else
	echo "dispatch not found at $DISPATCH, skipping dispatch tests"
fi


# ===========================================================================
echo "------------------------------"
echo "dispatch tree with depth"
echo ""

if test -f "$DISPATCH"; then
	"$REPLAY_TOOL" --start-server listtreetest3 > "$WORK_DIR/dispatch_tree_depth_out.txt" &
	sleep 0.3

	"$DISPATCH" listtreetest3 tree "$ROOT" 1
	"$DISPATCH" listtreetest3 wait
	verify_succeeded "$?" "dispatch tree depth=1: wait exited successfully"

	output=$(cat "$WORK_DIR/dispatch_tree_depth_out.txt")
	echo "$output" | /usr/bin/grep -qF '"name":"subdir"'
	verify_succeeded "$?" "dispatch tree depth=1: subdir present"
	echo "$output" | /usr/bin/grep -qF '"name":"deep.txt"'
	verify_failed "$?" "dispatch tree depth=1: deep.txt must NOT appear"
else
	echo "dispatch not found at $DISPATCH, skipping dispatch tests"
fi


report_test_stats

[ "$failure_counter" -eq 0 ]
