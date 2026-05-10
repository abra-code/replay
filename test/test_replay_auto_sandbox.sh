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

verify_content()
{
	content=$1
	expected=$2
	error_message=$3

	if test "$content" != "$expected"; then
		let failure_counter++
		echo ""
		echo "###########   ERROR   ##############"
		echo "$error_message"
		echo "Expected: $expected"
		echo "Got:      $content"
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
	echo " Finished auto-sandbox tests "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Testing auto-sandbox paths  "
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

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_auto_sandbox_test.XXXXXX)

cleanup()
{
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo "Work dir: $WORK_DIR"
echo ""

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers read paths from playlist"
echo ""

READ_FILE="$WORK_DIR/source.txt"
printf 'source content' > "$READ_FILE"

cat > "$WORK_DIR/read_only.json" << EOF
[{ "action": "read", "items": ["$READ_FILE"] }]
EOF

output=$("$REPLAY_TOOL" --sandbox "$WORK_DIR/read_only.json" 2>&1)
verify_succeeded "$?" "sandbox auto-read: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "source content"
verify_succeeded "$?" "sandbox auto-read: correct content in output"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers write paths from playlist"
echo ""

cat > "$WORK_DIR/write.json" << EOF
[{ "action": "create", "file": "$WORK_DIR/created.txt", "content": "auto sandbox write" }]
EOF

"$REPLAY_TOOL" --sandbox "$WORK_DIR/write.json"
verify_succeeded "$?" "sandbox auto-write: replay exited successfully"
test -f "$WORK_DIR/created.txt"
verify_succeeded "$?" "sandbox auto-write: file created"
content=$(cat "$WORK_DIR/created.txt")
verify_content "$content" "auto sandbox write" "sandbox auto-write: content matches"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers clone paths (read src, write dst)"
echo ""

CLONE_SRC="$WORK_DIR/clone_src.txt"
printf 'clone content' > "$CLONE_SRC"

cat > "$WORK_DIR/clone.json" << EOF
[{ "action": "clone", "from": "$CLONE_SRC", "to": "$WORK_DIR/clone_dst.txt" }]
EOF

"$REPLAY_TOOL" --sandbox "$WORK_DIR/clone.json"
verify_succeeded "$?" "sandbox auto-clone: replay exited successfully"
test -f "$WORK_DIR/clone_dst.txt"
verify_succeeded "$?" "sandbox auto-clone: destination created"
content=$(cat "$WORK_DIR/clone_dst.txt")
verify_content "$content" "clone content" "sandbox auto-clone: content matches"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers delete paths"
echo ""

TO_DELETE="$WORK_DIR/to_delete.txt"
printf 'delete me' > "$TO_DELETE"

cat > "$WORK_DIR/delete.json" << EOF
[{ "action": "delete", "items": ["$TO_DELETE"] }]
EOF

"$REPLAY_TOOL" --sandbox "$WORK_DIR/delete.json"
verify_succeeded "$?" "sandbox auto-delete: replay exited successfully"
test ! -f "$TO_DELETE"
verify_succeeded "$?" "sandbox auto-delete: file deleted"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers execute tool path"
echo ""

cat > "$WORK_DIR/execute.json" << EOF
[{ "action": "execute", "tool": "/bin/echo", "arguments": ["hello"] }]
EOF

output=$("$REPLAY_TOOL" --sandbox "$WORK_DIR/execute.json" 2>&1)
verify_succeeded "$?" "sandbox auto-execute: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "hello"
verify_succeeded "$?" "sandbox auto-execute: correct output"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: works with --playlist-key"
echo ""

READ_SOURCE="$WORK_DIR/read_source.txt"
printf 'read content' > "$READ_SOURCE"

cat > "$WORK_DIR/multi_key.json" << EOF
{
  "read tests": [
    { "action": "read", "items": ["$READ_SOURCE"] }
  ],
  "write tests": [
    { "action": "create", "file": "$WORK_DIR/write_test.txt", "content": "write test" }
  ]
}
EOF

"$REPLAY_TOOL" --sandbox --playlist-key "read tests" "$WORK_DIR/multi_key.json"
verify_succeeded "$?" "sandbox auto multi-key: read tests exited successfully"
content=$(cat "$READ_SOURCE")
verify_content "$content" "read content" "sandbox auto multi-key read: content matches"

"$REPLAY_TOOL" --sandbox --playlist-key "write tests" "$WORK_DIR/multi_key.json"
verify_succeeded "$?" "sandbox auto multi-key: write tests exited successfully"
test -f "$WORK_DIR/write_test.txt"
verify_succeeded "$?" "sandbox auto multi-key: write test file created"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: mix of auto-discovered and explicit flags"
echo ""

EXTRA_DIR=$(/usr/bin/mktemp -d /tmp/replay_auto_sandbox_extra.XXXXXX)
trap 'rm -rf "$EXTRA_DIR"; cleanup' EXIT

cat > "$WORK_DIR/mixed.json" << EOF
[{ "action": "create", "file": "$EXTRA_DIR/mixed.txt", "content": "mixed" }]
EOF

"$REPLAY_TOOL" \
	--sandbox \
	--allow-write "$EXTRA_DIR" \
	"$WORK_DIR/mixed.json"
verify_succeeded "$?" "sandbox mixed: replay exited successfully"
test -f "$EXTRA_DIR/mixed.txt"
verify_succeeded "$?" "sandbox mixed: file created in explicit dir"
content=$(cat "$EXTRA_DIR/mixed.txt")
verify_content "$content" "mixed" "sandbox mixed: content matches"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers multiple paths in one playlist"
echo ""

cat > "$WORK_DIR/multi_action.json" << EOF
[
  { "action": "create", "file": "$WORK_DIR/multi1.txt", "content": "one" },
  { "action": "create", "file": "$WORK_DIR/multi2.txt", "content": "two" },
  { "action": "read", "items": ["$WORK_DIR/multi1.txt", "$WORK_DIR/multi2.txt"] }
]
EOF

"$REPLAY_TOOL" --sandbox "$WORK_DIR/multi_action.json"
verify_succeeded "$?" "sandbox multi-action: replay exited successfully"
test -f "$WORK_DIR/multi1.txt"
verify_succeeded "$?" "sandbox multi-action: multi1.txt created"
test -f "$WORK_DIR/multi2.txt"
verify_succeeded "$?" "sandbox multi-action: multi2.txt created"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers paths with glob patterns"
echo ""

mkdir -p "$WORK_DIR/glob_dir"
printf 'glob content\n' > "$WORK_DIR/glob_dir/file1.txt"
printf 'more content\n' > "$WORK_DIR/glob_dir/file2.txt"

cat > "$WORK_DIR/glob_test.json" << EOF
[{ "action": "glob", "root": "$WORK_DIR/glob_dir", "glob": ["*.txt"] }]
EOF

output=$("$REPLAY_TOOL" --sandbox "$WORK_DIR/glob_test.json" 2>&1)
verify_succeeded "$?" "sandbox auto-glob: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "file1.txt"
verify_succeeded "$?" "sandbox auto-glob: file1.txt found"
echo "$output" | /usr/bin/grep -qF "file2.txt"
verify_succeeded "$?" "sandbox auto-glob: file2.txt found"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers move paths (src read-write, dst write)"
echo ""

MOVE_SRC="$WORK_DIR/move_src.txt"
printf 'move source' > "$MOVE_SRC"

cat > "$WORK_DIR/move.json" << EOF
[{ "action": "move", "from": "$MOVE_SRC", "to": "$WORK_DIR/move_dst.txt" }]
EOF

"$REPLAY_TOOL" --sandbox "$WORK_DIR/move.json"
verify_succeeded "$?" "sandbox auto-move: replay exited successfully"
test ! -f "$MOVE_SRC"
verify_succeeded "$?" "sandbox auto-move: source removed"
test -f "$WORK_DIR/move_dst.txt"
verify_succeeded "$?" "sandbox auto-move: destination created"
content=$(cat "$WORK_DIR/move_dst.txt")
verify_content "$content" "move source" "sandbox auto-move: content preserved"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: explicit --allow-write /private/tmp for temp files"
echo ""

TMP_FILE="/private/tmp/replay_test_tmp_$$"
trap "rm -f '$TMP_FILE' 2>/dev/null" EXIT

cat > "$WORK_DIR/tmp_write.json" << EOF
[{ "action": "execute", "tool": "/bin/sh", "arguments": ["-c", "echo 'temp content' > $TMP_FILE"] }]
EOF

"$REPLAY_TOOL" --sandbox --allow-write /private/tmp "$WORK_DIR/tmp_write.json"
verify_succeeded "$?" "sandbox tmp: replay exited successfully"
test -f "$TMP_FILE"
verify_succeeded "$?" "sandbox tmp: temp file created"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: glob action with env var root (pre-created playlist)"
echo ""

GLOB_SRCDIR="$WORK_DIR/glob_src"
mkdir -p "$GLOB_SRCDIR/sub"
printf 'alpha\n' > "$GLOB_SRCDIR/a.txt"
printf 'beta\n'  > "$GLOB_SRCDIR/b.txt"
printf 'gamma\n' > "$GLOB_SRCDIR/sub/c.txt"
export REPLAY_TEST_OUTDIR="$GLOB_SRCDIR"

output=$("$REPLAY_TOOL" --sandbox "$SCRIPT_DIR/playlists/glob_action.json" 2>&1)
verify_succeeded "$?" "sandbox glob action: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "a.txt"
verify_succeeded "$?" "sandbox glob action: a.txt found"
echo "$output" | /usr/bin/grep -qF "b.txt"
verify_succeeded "$?" "sandbox glob action: b.txt found"
echo "$output" | /usr/bin/grep -qF "c.txt"
verify_succeeded "$?" "sandbox glob action: c.txt in subdir found"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: edit with ** glob items (pre-created playlist)"
echo ""

GLOB_EDIT_DIR="$WORK_DIR/glob_edit_star"
mkdir -p "$GLOB_EDIT_DIR/sub"
printf 'hello world' > "$GLOB_EDIT_DIR/a.txt"
printf 'hello there' > "$GLOB_EDIT_DIR/sub/b.txt"
export REPLAY_TEST_OUTDIR="$GLOB_EDIT_DIR"

"$REPLAY_TOOL" --sandbox "$SCRIPT_DIR/playlists/glob_star_edit.json"
verify_succeeded "$?" "sandbox glob ** edit: replay exited successfully"
content=$(cat "$GLOB_EDIT_DIR/a.txt")
verify_content "$content" "world world" "sandbox glob ** edit: a.txt replaced"
content=$(cat "$GLOB_EDIT_DIR/sub/b.txt")
verify_content "$content" "world there" "sandbox glob ** edit: sub/b.txt replaced"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: edit with {a,b} brace pattern items (pre-created playlist)"
echo ""

BRACE_EDIT_DIR="$WORK_DIR/glob_edit_brace"
mkdir -p "$BRACE_EDIT_DIR/a" "$BRACE_EDIT_DIR/b"
printf 'say hello' > "$BRACE_EDIT_DIR/a/x.txt"
printf 'hello again' > "$BRACE_EDIT_DIR/b/y.txt"
export REPLAY_TEST_OUTDIR="$BRACE_EDIT_DIR"

"$REPLAY_TOOL" --sandbox "$SCRIPT_DIR/playlists/glob_brace_edit.json"
verify_succeeded "$?" "sandbox glob brace edit: replay exited successfully"
content=$(cat "$BRACE_EDIT_DIR/a/x.txt")
verify_content "$content" "say world" "sandbox glob brace edit: a/x.txt replaced"
content=$(cat "$BRACE_EDIT_DIR/b/y.txt")
verify_content "$content" "world again" "sandbox glob brace edit: b/y.txt replaced"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: pre-created playlist with env vars - multi-action (creates and reads files)"
echo ""

ENVVAR_OUTDIR="$WORK_DIR/envvar_multi"
mkdir -p "$ENVVAR_OUTDIR"
export REPLAY_TEST_OUTDIR="$ENVVAR_OUTDIR"

output=$("$REPLAY_TOOL" --sandbox "$SCRIPT_DIR/playlists/multi_action.json" 2>&1)
verify_succeeded "$?" "sandbox envvar multi-action: replay exited successfully"
test -f "$ENVVAR_OUTDIR/multi1.txt"
verify_succeeded "$?" "sandbox envvar multi-action: multi1.txt created via env var path"
content=$(cat "$ENVVAR_OUTDIR/multi1.txt" 2>/dev/null)
verify_content "$content" "one" "sandbox envvar multi-action: multi1.txt content correct"
test -f "$ENVVAR_OUTDIR/multi2.txt"
verify_succeeded "$?" "sandbox envvar multi-action: multi2.txt created via env var path"
content=$(cat "$ENVVAR_OUTDIR/multi2.txt" 2>/dev/null)
verify_content "$content" "two" "sandbox envvar multi-action: multi2.txt content correct"
echo "$output" | /usr/bin/grep -qF "one"
verify_succeeded "$?" "sandbox envvar multi-action: read output contains 'one'"
echo "$output" | /usr/bin/grep -qF "two"
verify_succeeded "$?" "sandbox envvar multi-action: read output contains 'two'"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: pre-created playlist with env vars - multi-key read playlist"
echo ""

ENVVAR_SRCFILE="$WORK_DIR/envvar_source.txt"
printf 'envvar source content' > "$ENVVAR_SRCFILE"
export REPLAY_TEST_SRCFILE="$ENVVAR_SRCFILE"

output=$("$REPLAY_TOOL" --sandbox --playlist-key "read tests" "$SCRIPT_DIR/playlists/multi_key.json" 2>&1)
verify_succeeded "$?" "sandbox envvar multi-key read: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "envvar source content"
verify_succeeded "$?" "sandbox envvar multi-key read: output contains env-var-resolved file content"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: pre-created playlist with env vars - multi-key write playlist"
echo ""

ENVVAR_WRITEDIR="$WORK_DIR/envvar_write"
mkdir -p "$ENVVAR_WRITEDIR"
export REPLAY_TEST_OUTDIR="$ENVVAR_WRITEDIR"

"$REPLAY_TOOL" --sandbox --playlist-key "write tests" "$SCRIPT_DIR/playlists/multi_key.json"
verify_succeeded "$?" "sandbox envvar multi-key write: replay exited successfully"
test -f "$ENVVAR_WRITEDIR/write_test.txt"
verify_succeeded "$?" "sandbox envvar multi-key write: file created at env-var-resolved path"
content=$(cat "$ENVVAR_WRITEDIR/write_test.txt" 2>/dev/null)
verify_content "$content" "write test" "sandbox envvar multi-key write: content correct"

report_test_stats

[ "$failure_counter" -eq 0 ]