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
	echo " Finished edit action tests  "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Testing edit action         "
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

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_edit_test.XXXXXX)

cleanup()
{
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo "Work dir: $WORK_DIR"
echo ""


# ===========================================================================
echo "------------------------------"
echo "literal replace first match (limit=1 default)"
echo ""

FILE="$WORK_DIR/literal_first.txt"
printf 'foo bar foo' > "$FILE"

cat > "$WORK_DIR/edit_literal_first.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "foo", "newText": "baz"}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_literal_first.json"
verify_succeeded "$?" "literal first: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "baz bar foo"
verify_succeeded "$?" "literal first: only first occurrence replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "literal replace all (limit=0)"
echo ""

FILE="$WORK_DIR/literal_all.txt"
printf 'foo bar foo baz foo' > "$FILE"

cat > "$WORK_DIR/edit_literal_all.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "foo", "newText": "X", "limit": 0}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_literal_all.json"
verify_succeeded "$?" "literal all: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "X bar X baz X"
verify_succeeded "$?" "literal all: all occurrences replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "literal replace limit=2"
echo ""

FILE="$WORK_DIR/literal_limit2.txt"
printf 'a a a a' > "$FILE"

cat > "$WORK_DIR/edit_literal_limit2.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "a", "newText": "b", "limit": 2}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_literal_limit2.json"
verify_succeeded "$?" "literal limit=2: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "b b a a"
verify_succeeded "$?" "literal limit=2: exactly 2 replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "literal not found → error (limit=1)"
echo ""

FILE="$WORK_DIR/literal_notfound.txt"
printf 'hello world' > "$FILE"

cat > "$WORK_DIR/edit_notfound.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "NOSUCHTEXT", "newText": "X"}] }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/edit_notfound.json" 2>/dev/null
verify_failed "$?" "literal not found: expected non-zero exit"
content=$(cat "$FILE")
test "$content" = "hello world"
verify_succeeded "$?" "literal not found: file unchanged (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "literal not found, limit=0 → OK (no error)"
echo ""

FILE="$WORK_DIR/literal_notfound_limit0.txt"
printf 'hello world' > "$FILE"

cat > "$WORK_DIR/edit_notfound_limit0.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "NOSUCHTEXT", "newText": "X", "limit": 0}] }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/edit_notfound_limit0.json" 2>/dev/null
verify_succeeded "$?" "literal not found limit=0: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "hello world"
verify_succeeded "$?" "literal not found limit=0: file unchanged (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "multiple edits applied in sequence"
echo ""

FILE="$WORK_DIR/multi_edits.txt"
printf 'alpha beta gamma' > "$FILE"

cat > "$WORK_DIR/edit_multi.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [
     {"oldText": "alpha", "newText": "A"},
     {"oldText": "beta", "newText": "B"},
     {"oldText": "gamma", "newText": "C"}
   ] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_multi.json"
verify_succeeded "$?" "multi edits: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "A B C"
verify_succeeded "$?" "multi edits: all three replacements applied (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "second edit depends on first (chained)"
echo ""

FILE="$WORK_DIR/chained.txt"
printf 'one two three' > "$FILE"

cat > "$WORK_DIR/edit_chained.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [
     {"oldText": "one", "newText": "1"},
     {"oldText": "1 two", "newText": "ONE_TWO"}
   ] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_chained.json"
verify_succeeded "$?" "chained: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "ONE_TWO three"
verify_succeeded "$?" "chained: second edit sees result of first (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "case-insensitive literal replace"
echo ""

FILE="$WORK_DIR/case_insensitive.txt"
printf 'Hello HELLO hello' > "$FILE"

cat > "$WORK_DIR/edit_case.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "hello", "newText": "HI", "limit": 0, "case-insensitive": true}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_case.json"
verify_succeeded "$?" "case-insensitive: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "HI HI HI"
verify_succeeded "$?" "case-insensitive: all variants replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "newText empty string → deletion"
echo ""

FILE="$WORK_DIR/delete_text.txt"
printf 'remove_me keep' > "$FILE"

cat > "$WORK_DIR/edit_delete.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "remove_me ", "newText": ""}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_delete.json"
verify_succeeded "$?" "delete text: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "keep"
verify_succeeded "$?" "delete text: oldText removed (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "regex replace first match (default limit=1)"
echo ""

FILE="$WORK_DIR/regex_first.txt"
printf 'foo123 bar456 foo789' > "$FILE"

cat > "$WORK_DIR/edit_regex_first.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "[0-9]+", "newText": "NUM", "regex": true}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_regex_first.json"
verify_succeeded "$?" "regex first: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "fooNUM bar456 foo789"
verify_succeeded "$?" "regex first: only first number replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "regex replace all (limit=0)"
echo ""

FILE="$WORK_DIR/regex_all.txt"
printf 'foo123 bar456 baz789' > "$FILE"

cat > "$WORK_DIR/edit_regex_all.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "[0-9]+", "newText": "NUM", "regex": true, "limit": 0}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_regex_all.json"
verify_succeeded "$?" "regex all: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "fooNUM barNUM bazNUM"
verify_succeeded "$?" "regex all: all numbers replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "regex back-reference replacement (\\1, \\2)"
echo ""

FILE="$WORK_DIR/regex_backref.txt"
printf 'John Smith' > "$FILE"

printf '[{ "action": "edit", "items": ["%s"],\n   "edits": [{"oldText": "([A-Za-z]+) ([A-Za-z]+)", "newText": "\\\\2, \\\\1", "regex": true}] }]\n' \
    "$FILE" > "$WORK_DIR/edit_backref.json"
"$REPLAY_TOOL" "$WORK_DIR/edit_backref.json"
verify_succeeded "$?" "backref: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "Smith, John"
verify_succeeded "$?" "backref: name swapped (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "regex case-insensitive"
echo ""

FILE="$WORK_DIR/regex_case.txt"
printf 'Error error ERROR' > "$FILE"

cat > "$WORK_DIR/edit_regex_case.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "error", "newText": "WARNING", "regex": true, "case-insensitive": true, "limit": 0}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_regex_case.json"
verify_succeeded "$?" "regex case-insensitive: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "WARNING WARNING WARNING"
verify_succeeded "$?" "regex case-insensitive: all variants replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "regex invalid pattern → error"
echo ""

FILE="$WORK_DIR/regex_invalid.txt"
printf 'hello' > "$FILE"

cat > "$WORK_DIR/edit_regex_invalid.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "[unclosed", "newText": "X", "regex": true}] }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/edit_regex_invalid.json" 2>/dev/null
verify_failed "$?" "regex invalid: expected non-zero exit for bad pattern"
content=$(cat "$FILE")
test "$content" = "hello"
verify_succeeded "$?" "regex invalid: file unchanged (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "streaming format: [edit] path oldText newText"
echo ""

FILE="$WORK_DIR/stream_edit.txt"
printf 'streaming input test' > "$FILE"

printf '[edit]\t%s\tinput\tOUTPUT\n' "$FILE" | "$REPLAY_TOOL"
verify_succeeded "$?" "streaming: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "streaming OUTPUT test"
verify_succeeded "$?" "streaming: replacement applied (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "streaming format: [edit limit=0] replaces all"
echo ""

FILE="$WORK_DIR/stream_edit_all.txt"
printf 'x y x y x' > "$FILE"

printf '[edit limit=0]\t%s\tx\tZ\n' "$FILE" | "$REPLAY_TOOL"
verify_succeeded "$?" "streaming limit=0: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "Z y Z y Z"
verify_succeeded "$?" "streaming limit=0: all replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "streaming format: [edit regex=true]"
echo ""

FILE="$WORK_DIR/stream_regex.txt"
printf 'version=1.2.3' > "$FILE"

printf '[edit regex=true]\t%s\t[0-9]+\tN\n' "$FILE" | "$REPLAY_TOOL"
verify_succeeded "$?" "streaming regex: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "version=N.2.3"
verify_succeeded "$?" "streaming regex: first number replaced (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "dry-run (global): no file modification"
echo ""

FILE="$WORK_DIR/dryrun_global.txt"
printf 'original content' > "$FILE"

cat > "$WORK_DIR/edit_dryrun.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "original", "newText": "modified"}] }]
EOF
output=$("$REPLAY_TOOL" --dry-run "$WORK_DIR/edit_dryrun.json")
verify_succeeded "$?" "global dry-run: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "[edit]"
verify_succeeded "$?" "global dry-run: [edit] descriptor present"
content=$(cat "$FILE")
test "$content" = "original content"
verify_succeeded "$?" "global dry-run: file not modified (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "action dry-run=true: shows plan, no modification"
echo ""

FILE="$WORK_DIR/dryrun_action.txt"
printf 'hello world' > "$FILE"

cat > "$WORK_DIR/edit_action_dryrun.json" << EOF
[{ "action": "edit", "items": ["$FILE"], "dry-run": true,
   "edits": [{"oldText": "hello", "newText": "goodbye"}] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/edit_action_dryrun.json")
verify_succeeded "$?" "action dry-run: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "[edit-dry-run:"
verify_succeeded "$?" "action dry-run: dry-run plan header present"
echo "$output" | /usr/bin/grep -qF "hello"
verify_succeeded "$?" "action dry-run: oldText shown in plan"
content=$(cat "$FILE")
test "$content" = "hello world"
verify_succeeded "$?" "action dry-run: file not modified (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "verbose: shows [edit] descriptor"
echo ""

FILE="$WORK_DIR/verbose_edit.txt"
printf 'verbose test' > "$FILE"

cat > "$WORK_DIR/edit_verbose.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "test", "newText": "done"}] }]
EOF
output=$("$REPLAY_TOOL" --verbose "$WORK_DIR/edit_verbose.json")
verify_succeeded "$?" "verbose: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "[edit]"
verify_succeeded "$?" "verbose: [edit] descriptor present in output"
content=$(cat "$FILE")
test "$content" = "verbose done"
verify_succeeded "$?" "verbose: file was modified (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "multiline file: replace preserves all content"
echo ""

FILE="$WORK_DIR/multiline.txt"
printf 'line1\nfoo\nline3\nfoo\nline5\n' > "$FILE"

cat > "$WORK_DIR/edit_multiline.json" << EOF
[{ "action": "edit", "items": ["$FILE"],
   "edits": [{"oldText": "foo", "newText": "BAR", "limit": 0}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_multiline.json"
verify_succeeded "$?" "multiline: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "$(printf 'line1\nBAR\nline3\nBAR\nline5\n')"
verify_succeeded "$?" "multiline: both lines replaced, structure preserved (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "nonexistent file → error"
echo ""

cat > "$WORK_DIR/edit_missing.json" << EOF
[{ "action": "edit", "items": ["$WORK_DIR/no_such_file.txt"],
   "edits": [{"oldText": "foo", "newText": "bar"}] }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/edit_missing.json" 2>/dev/null
verify_failed "$?" "missing file: expected non-zero exit"


# ===========================================================================
echo "------------------------------"
echo "missing file key → error"
echo ""

cat > "$WORK_DIR/edit_no_file_key.json" << EOF
[{ "action": "edit",
   "edits": [{"oldText": "foo", "newText": "bar"}] }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/edit_no_file_key.json" 2>/dev/null
verify_failed "$?" "no file key: expected non-zero exit"


# ===========================================================================
echo "------------------------------"
echo "missing edits/oldText → error"
echo ""

FILE="$WORK_DIR/no_edits.txt"
printf 'content' > "$FILE"

cat > "$WORK_DIR/edit_no_edits.json" << EOF
[{ "action": "edit", "items": ["$FILE"] }]
EOF
"$REPLAY_TOOL" --stop-on-error "$WORK_DIR/edit_no_edits.json" 2>/dev/null
verify_failed "$?" "no edits: expected non-zero exit"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep analysis: create -> edit -> read (mutatingInputs chain)"
echo ""

FILE="$WORK_DIR/conc_edit_chain.txt"

cat > "$WORK_DIR/edit_conc_chain.json" << EOF
[
  { "action": "create", "file": "$FILE", "content": "hello world" },
  { "action": "edit",   "items": ["$FILE"], "oldText": "world", "newText": "replay" },
  { "action": "read",   "items": ["$FILE"] }
]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/edit_conc_chain.json")
verify_succeeded "$?" "conc chain: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "hello replay"
verify_succeeded "$?" "conc chain: file has expected content (got: $content)"
echo "$output" | grep -qF "hello replay"
verify_succeeded "$?" "conc chain: read output contains edited content"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep analysis: create -> edit -> edit (chained mutating)"
echo ""

FILE="$WORK_DIR/conc_edit_double.txt"

cat > "$WORK_DIR/edit_conc_double.json" << EOF
[
  { "action": "create", "file": "$FILE", "content": "aaa" },
  { "action": "edit",   "items": ["$FILE"], "oldText": "aaa", "newText": "bbb" },
  { "action": "edit",   "items": ["$FILE"], "oldText": "bbb", "newText": "ccc" }
]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_conc_double.json"
verify_succeeded "$?" "conc double edit: replay exited successfully"
content=$(cat "$FILE")
test "$content" = "ccc"
verify_succeeded "$?" "conc double edit: second edit applied (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "items array: edit two concrete files independently"
echo ""

FILE_A="$WORK_DIR/items_a.txt"
FILE_B="$WORK_DIR/items_b.txt"
printf 'hello world' > "$FILE_A"
printf 'hello world' > "$FILE_B"

cat > "$WORK_DIR/edit_items_two.json" << EOF
[{ "action": "edit",
   "items": ["$FILE_A", "$FILE_B"],
   "edits": [{"oldText": "hello", "newText": "hi"}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_items_two.json"
verify_succeeded "$?" "items two: replay exited successfully"
content_a=$(cat "$FILE_A")
content_b=$(cat "$FILE_B")
test "$content_a" = "hi world"
verify_succeeded "$?" "items two: file A replaced (got: $content_a)"
test "$content_b" = "hi world"
verify_succeeded "$?" "items two: file B replaced (got: $content_b)"


# ===========================================================================
echo "------------------------------"
echo "items array: glob pattern edits all matching files"
echo ""

mkdir -p "$WORK_DIR/glob_edit_src"
printf 'version=OLD' > "$WORK_DIR/glob_edit_src/a.txt"
printf 'version=OLD' > "$WORK_DIR/glob_edit_src/b.txt"
printf 'version=OLD' > "$WORK_DIR/glob_edit_src/c.txt"

cat > "$WORK_DIR/edit_glob.json" << EOF
[{ "action": "edit",
   "items": ["$WORK_DIR/glob_edit_src/*.txt"],
   "edits": [{"oldText": "OLD", "newText": "NEW"}] }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_glob.json"
verify_succeeded "$?" "glob edit: replay exited successfully"
content_a=$(cat "$WORK_DIR/glob_edit_src/a.txt")
content_b=$(cat "$WORK_DIR/glob_edit_src/b.txt")
content_c=$(cat "$WORK_DIR/glob_edit_src/c.txt")
test "$content_a" = "version=NEW"
verify_succeeded "$?" "glob edit: a.txt replaced (got: $content_a)"
test "$content_b" = "version=NEW"
verify_succeeded "$?" "glob edit: b.txt replaced (got: $content_b)"
test "$content_c" = "version=NEW"
verify_succeeded "$?" "glob edit: c.txt replaced (got: $content_c)"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep: create -> glob-edit -> read (glob mutatingInputs)"
echo ""

mkdir -p "$WORK_DIR/glob_conc_src"
FILE_X="$WORK_DIR/glob_conc_src/x.cpp"
FILE_Y="$WORK_DIR/glob_conc_src/y.cpp"

cat > "$WORK_DIR/edit_glob_conc.json" << EOF
[
  { "action": "create", "file": "$FILE_X", "content": "OLD_API" },
  { "action": "create", "file": "$FILE_Y", "content": "OLD_API" },
  { "action": "edit",   "items": ["$WORK_DIR/glob_conc_src/*.cpp"],
    "edits": [{"oldText": "OLD_API", "newText": "NEW_API"}] },
  { "action": "read",   "items": ["$FILE_X", "$FILE_Y"] }
]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/edit_glob_conc.json")
verify_succeeded "$?" "glob conc: replay exited successfully"
content_x=$(cat "$FILE_X")
content_y=$(cat "$FILE_Y")
test "$content_x" = "NEW_API"
verify_succeeded "$?" "glob conc: x.cpp has new content (got: $content_x)"
test "$content_y" = "NEW_API"
verify_succeeded "$?" "glob conc: y.cpp has new content (got: $content_y)"
echo "$output" | grep -qF "NEW_API"
verify_succeeded "$?" "glob conc: read output shows edited content"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep: two sequential glob-edits on same pattern (chain)"
echo ""

mkdir -p "$WORK_DIR/glob_chain_src"
FILE_P="$WORK_DIR/glob_chain_src/p.txt"
printf 'aaa' > "$FILE_P"

cat > "$WORK_DIR/edit_glob_chain.json" << EOF
[
  { "action": "edit", "items": ["$WORK_DIR/glob_chain_src/*.txt"],
    "edits": [{"oldText": "aaa", "newText": "bbb"}] },
  { "action": "edit", "items": ["$WORK_DIR/glob_chain_src/*.txt"],
    "edits": [{"oldText": "bbb", "newText": "ccc"}] }
]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_glob_chain.json"
verify_succeeded "$?" "glob chain: replay exited successfully"
content_p=$(cat "$FILE_P")
test "$content_p" = "ccc"
verify_succeeded "$?" "glob chain: second edit applied (got: $content_p)"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep: read foo BEFORE edit foo (concrete consumer-before-mutator)"
echo ""

# The read task lexically precedes the mutating edit. The reader must
# observe the pre-edit content. Without proper consumer-before-mutator
# ordering, the read races with the edit and may observe edited content.

FILE="$WORK_DIR/conc_read_then_edit.txt"
printf 'hello world' > "$FILE"

cat > "$WORK_DIR/edit_read_first.json" << EOF
[
  { "action": "read", "items": ["$FILE"] },
  { "action": "edit", "items": ["$FILE"], "oldText": "world", "newText": "REPLAY" }
]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/edit_read_first.json")
verify_succeeded "$?" "read-then-edit: replay exited successfully"
echo "$output" | grep -qF "hello world"
verify_succeeded "$?" "read-then-edit: read observed pre-edit content (full output: $output)"
content=$(cat "$FILE")
test "$content" = "hello REPLAY"
verify_succeeded "$?" "read-then-edit: file has post-edit content (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep: read BEFORE glob-edit on same pattern (glob consumer-before-mutator)"
echo ""

# Reader before glob mutator on overlapping path. Read should observe pre-edit
# content. Pass B without playlist-order check would force read to wait for
# the edit, causing wrong content to be observed.

mkdir -p "$WORK_DIR/glob_read_first_src"
FILE_R1="$WORK_DIR/glob_read_first_src/r1.txt"
FILE_R2="$WORK_DIR/glob_read_first_src/r2.txt"
printf 'PREEDIT' > "$FILE_R1"
printf 'PREEDIT' > "$FILE_R2"

cat > "$WORK_DIR/edit_glob_read_first.json" << EOF
[
  { "action": "read", "items": ["$FILE_R1", "$FILE_R2"] },
  { "action": "edit", "items": ["$WORK_DIR/glob_read_first_src/*.txt"],
    "edits": [{"oldText": "PREEDIT", "newText": "POSTEDIT"}] }
]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/edit_glob_read_first.json")
verify_succeeded "$?" "glob read-first: replay exited successfully"
preedit_count=$(echo "$output" | grep -c "PREEDIT")
postedit_count=$(echo "$output" | grep -c "POSTEDIT")
test "$preedit_count" = "2"
verify_succeeded "$?" "glob read-first: both reads observed pre-edit (PREEDIT count: $preedit_count, POSTEDIT count: $postedit_count)"
content_r1=$(cat "$FILE_R1")
test "$content_r1" = "POSTEDIT"
verify_succeeded "$?" "glob read-first: file r1 was edited (got: $content_r1)"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep: glob-edit then concrete-edit on overlapping path (cross-domain chain)"
echo ""

# Glob mutator first, concrete mutator second on a path matched by the glob.
# They must chain in playlist order to produce: aaa -> bbb -> ccc.

mkdir -p "$WORK_DIR/glob_concrete_chain_src"
FILE_M="$WORK_DIR/glob_concrete_chain_src/m.cpp"
printf 'aaa' > "$FILE_M"

cat > "$WORK_DIR/edit_glob_concrete_chain.json" << EOF
[
  { "action": "edit", "items": ["$WORK_DIR/glob_concrete_chain_src/*.cpp"],
    "edits": [{"oldText": "aaa", "newText": "bbb"}] },
  { "action": "edit", "items": ["$FILE_M"],
    "edits": [{"oldText": "bbb", "newText": "ccc"}] }
]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_glob_concrete_chain.json"
verify_succeeded "$?" "glob+concrete chain: replay exited successfully"
content_m=$(cat "$FILE_M")
test "$content_m" = "ccc"
verify_succeeded "$?" "glob+concrete chain: final content reflects both edits (got: $content_m)"


# ===========================================================================
echo "------------------------------"
echo "concurrent dep: concrete-edit then glob-edit on overlapping path (reverse cross-domain)"
echo ""

# Concrete mutator first, glob mutator second. Must chain in playlist order.

mkdir -p "$WORK_DIR/concrete_glob_chain_src"
FILE_N="$WORK_DIR/concrete_glob_chain_src/n.cpp"
printf '111' > "$FILE_N"

cat > "$WORK_DIR/edit_concrete_glob_chain.json" << EOF
[
  { "action": "edit", "items": ["$FILE_N"],
    "edits": [{"oldText": "111", "newText": "222"}] },
  { "action": "edit", "items": ["$WORK_DIR/concrete_glob_chain_src/*.cpp"],
    "edits": [{"oldText": "222", "newText": "333"}] }
]
EOF
"$REPLAY_TOOL" "$WORK_DIR/edit_concrete_glob_chain.json"
verify_succeeded "$?" "concrete+glob chain: replay exited successfully"
content_n=$(cat "$FILE_N")
test "$content_n" = "333"
verify_succeeded "$?" "concrete+glob chain: final content reflects both edits (got: $content_n)"


report_test_stats

[ "$failure_counter" -eq 0 ]
