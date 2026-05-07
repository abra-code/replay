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
	echo "  Finished glob action tests  "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}


echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "   Testing glob action        "
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

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_glob_run.XXXXXX)

cleanup()
{
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo "Work dir: $WORK_DIR"
echo ""

# Build test tree:
#   $WORK_DIR/src/
#     main.swift
#     helper.swift
#     foo.generated.swift       <- excluded by *.generated.swift
#   $WORK_DIR/src/utils/
#     util.swift
#     util.generated.swift      <- excluded by *.generated.swift
#   $WORK_DIR/spec/
#     main_test.swift           <- excluded by *_test.swift
#     helper_test.swift         <- excluded by *_test.swift
#   $WORK_DIR/data/
#     config.json
#     readme.txt

SRC="$WORK_DIR/src"
SPEC="$WORK_DIR/spec"
DATA="$WORK_DIR/data"
mkdir -p "$SRC/utils" "$SPEC" "$DATA"
printf 'main' > "$SRC/main.swift"
printf 'helper' > "$SRC/helper.swift"
printf 'generated' > "$SRC/foo.generated.swift"
printf 'util' > "$SRC/utils/util.swift"
printf 'util.gen' > "$SRC/utils/util.generated.swift"
printf 'main test' > "$SPEC/main_test.swift"
printf 'helper test' > "$SPEC/helper_test.swift"
printf '{}' > "$DATA/config.json"
printf 'readme' > "$DATA/readme.txt"


# ===========================================================================
echo "------------------------------"
echo "glob single relative pattern via JSON playlist"
echo ""

cat > "$WORK_DIR/glob1.json" << EOF
[{ "action": "glob", "root": "$SRC", "glob": ["**/*.swift"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob1.json")
echo "$output" | /usr/bin/grep -qF "[glob]"
verify_succeeded "$?" "glob (JSON): expected [glob] header"
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob (JSON): main.swift in results"
echo "$output" | /usr/bin/grep -qF "$SRC/helper.swift"
verify_succeeded "$?" "glob (JSON): helper.swift in results"
echo "$output" | /usr/bin/grep -qF "$SRC/utils/util.swift"
verify_succeeded "$?" "glob (JSON): utils/util.swift in results"
echo "$output" | /usr/bin/grep -qF "$DATA/config.json"
verify_failed "$?" "glob (JSON): config.json must NOT appear (wrong extension)"


# ===========================================================================
echo "------------------------------"
echo "glob multiple relative patterns (union across subdirs)"
echo ""

cat > "$WORK_DIR/glob_multi.json" << EOF
[{ "action": "glob", "root": "$WORK_DIR", "glob": ["src/**/*.swift", "spec/**/*.swift"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_multi.json")
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob multi: src file present"
echo "$output" | /usr/bin/grep -qF "$SPEC/main_test.swift"
verify_succeeded "$?" "glob multi: spec file present"


# ===========================================================================
echo "------------------------------"
echo "glob with basename exclude pattern"
echo ""

cat > "$WORK_DIR/glob_excl.json" << EOF
[{ "action": "glob", "root": "$SRC", "glob": ["**/*.swift"], "exclude": ["*.generated.swift"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_excl.json")
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob exclude: main.swift still present"
echo "$output" | /usr/bin/grep -qF "$SRC/foo.generated.swift"
verify_failed "$?" "glob exclude: foo.generated.swift must be excluded"
echo "$output" | /usr/bin/grep -qF "$SRC/utils/util.generated.swift"
verify_failed "$?" "glob exclude: util.generated.swift must be excluded"
echo "$output" | /usr/bin/grep -qF "$SRC/utils/util.swift"
verify_succeeded "$?" "glob exclude: util.swift (non-generated) still present"


# ===========================================================================
echo "------------------------------"
echo "glob with multiple exclude patterns"
echo ""

cat > "$WORK_DIR/glob_multi_excl.json" << EOF
[{ "action": "glob", "root": "$WORK_DIR", "glob": ["src/**/*.swift", "spec/**/*.swift"], "exclude": ["*.generated.swift", "*_test.swift"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_multi_excl.json")
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob multi-excl: main.swift present"
echo "$output" | /usr/bin/grep -qF "$SPEC/main_test.swift"
verify_failed "$?" "glob multi-excl: _test.swift files excluded"
echo "$output" | /usr/bin/grep -qF "$SRC/foo.generated.swift"
verify_failed "$?" "glob multi-excl: generated files excluded"


# ===========================================================================
echo "------------------------------"
echo "glob with relative path exclude pattern"
echo ""

cat > "$WORK_DIR/glob_path_excl.json" << EOF
[{ "action": "glob", "root": "$WORK_DIR", "glob": ["src/**/*.swift", "spec/**/*.swift"], "exclude": ["src/utils/*"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_path_excl.json")
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob path-excl: src/main.swift present"
echo "$output" | /usr/bin/grep -qF "$SRC/utils/util.swift"
verify_failed "$?" "glob path-excl: utils/util.swift excluded by relative path pattern"
echo "$output" | /usr/bin/grep -qF "$SPEC/main_test.swift"
verify_succeeded "$?" "glob path-excl: spec files unaffected by src exclusion"


# ===========================================================================
echo "------------------------------"
echo "glob pattern matching top-level files only"
echo ""

cat > "$WORK_DIR/glob_toplevel.json" << EOF
[{ "action": "glob", "root": "$DATA", "glob": ["*.json"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_toplevel.json")
echo "$output" | /usr/bin/grep -qF "$DATA/config.json"
verify_succeeded "$?" "glob toplevel: config.json found"
echo "$output" | /usr/bin/grep -qF "$DATA/readme.txt"
verify_failed "$?" "glob toplevel: readme.txt must NOT appear"


# ===========================================================================
echo "------------------------------"
echo "glob results are sorted alphabetically"
echo ""

output=$("$REPLAY_TOOL" "$WORK_DIR/glob1.json")
gen_line=$(echo "$output" | /usr/bin/grep -n "foo.generated" | /usr/bin/cut -d: -f1)
helper_line=$(echo "$output" | /usr/bin/grep -n "$SRC/helper.swift" | /usr/bin/cut -d: -f1)
main_line=$(echo "$output" | /usr/bin/grep -n "$SRC/main.swift" | /usr/bin/cut -d: -f1)
test "$gen_line" -lt "$helper_line"
verify_succeeded "$?" "glob sort: foo.generated before helper.swift"
test "$helper_line" -lt "$main_line"
verify_succeeded "$?" "glob sort: helper.swift before main.swift"


# ===========================================================================
echo "------------------------------"
echo "glob via streaming format (root + single pattern)"
echo ""

output=$(printf '[glob]\t%s\t**/*.swift\n' "$SRC" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "[glob]"
verify_succeeded "$?" "glob stream: [glob] header present"
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob stream: main.swift present"


# ===========================================================================
echo "------------------------------"
echo "glob via streaming format (root + pattern + exclude)"
echo ""

output=$(printf '[glob]\t%s\t**/*.swift\t!*.generated.swift\n' "$SRC" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob stream excl: main.swift present"
echo "$output" | /usr/bin/grep -qF "foo.generated.swift"
verify_failed "$?" "glob stream excl: foo.generated.swift excluded"
echo "$output" | /usr/bin/grep -qF "util.generated.swift"
verify_failed "$?" "glob stream excl: util.generated.swift excluded"


# ===========================================================================
echo "------------------------------"
echo "glob via streaming format (root + multiple patterns + excludes)"
echo ""

output=$(printf '[glob]\t%s\tsrc/**/*.swift\tspec/**/*.swift\t!*.generated.swift\t!*_test.swift\n' "$WORK_DIR" | "$REPLAY_TOOL")
echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
verify_succeeded "$?" "glob stream multi: src present"
echo "$output" | /usr/bin/grep -qF "$SPEC/main_test.swift"
verify_failed "$?" "glob stream multi: _test.swift files excluded"
echo "$output" | /usr/bin/grep -qF "foo.generated.swift"
verify_failed "$?" "glob stream multi: generated files excluded"


# ===========================================================================
echo "------------------------------"
echo "glob no match: empty result (not an error)"
echo ""

cat > "$WORK_DIR/glob_nomatch.json" << EOF
[{ "action": "glob", "root": "$WORK_DIR", "glob": ["**/*.nonexistent"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_nomatch.json")
exit_code=$?
test "$exit_code" = "0"
verify_succeeded "$?" "glob no match: exit 0"
echo "$output" | /usr/bin/grep -qF "[glob]"
verify_succeeded "$?" "glob no match: [glob] header still present"


# ===========================================================================
echo "------------------------------"
echo "glob dry-run: shows descriptor, no results"
echo ""

output=$(printf '[glob]\t%s\t**/*.swift\n' "$SRC" | "$REPLAY_TOOL" --dry-run)
echo "$output" | /usr/bin/grep -qF "[glob]"
verify_succeeded "$?" "glob dry-run: descriptor present"
echo "$output" | /usr/bin/grep -qF "main.swift"
verify_failed "$?" "glob dry-run: results must NOT appear"


# ===========================================================================
echo "------------------------------"
echo "glob verbose: descriptor and results both present"
echo ""

output=$(printf '[glob]\t%s\t**/*.swift\n' "$SRC" | "$REPLAY_TOOL" --verbose)
echo "$output" | /usr/bin/grep -qF "[glob]"
verify_succeeded "$?" "glob verbose: descriptor present"
echo "$output" | /usr/bin/grep -qF "main.swift"
verify_succeeded "$?" "glob verbose: results still present"


# ===========================================================================
echo "------------------------------"
echo "glob max=2 limits results"
echo ""

cat > "$WORK_DIR/glob_max.json" << EOF
[{ "action": "glob", "root": "$SRC", "glob": ["**/*.swift"], "max": 2 }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_max.json")
count=$(echo "$output" | /usr/bin/grep -c "\.swift")
test "$count" -le 2
verify_succeeded "$?" "glob max=2: at most 2 results"
test "$count" -gt 0
verify_succeeded "$?" "glob max=2: at least 1 result"


# ===========================================================================
echo "------------------------------"
echo "glob deduplication: same file matched by two patterns appears once"
echo ""

cat > "$WORK_DIR/glob_dedup.json" << EOF
[{ "action": "glob", "root": "$SRC", "glob": ["main.swift", "**/*.swift"] }]
EOF
output=$("$REPLAY_TOOL" "$WORK_DIR/glob_dedup.json")
count=$(echo "$output" | /usr/bin/grep -c "main\.swift")
test "$count" -eq 1
verify_succeeded "$?" "glob dedup: main.swift appears exactly once"


# ===========================================================================
echo "------------------------------"
echo "dispatch glob"
echo ""

if test -f "$DISPATCH"; then
	"$REPLAY_TOOL" --start-server globtest1 > "$WORK_DIR/dispatch_glob_out.txt" &
	sleep 0.3

	"$DISPATCH" globtest1 glob "$SRC" "**/*.swift" "!*.generated.swift"
	"$DISPATCH" globtest1 wait
	verify_succeeded "$?" "dispatch glob: wait exited successfully"

	output=$(cat "$WORK_DIR/dispatch_glob_out.txt")
	echo "$output" | /usr/bin/grep -qF "$SRC/main.swift"
	verify_succeeded "$?" "dispatch glob: main.swift in results"
	echo "$output" | /usr/bin/grep -qF "foo.generated.swift"
	verify_failed "$?" "dispatch glob: foo.generated.swift excluded"
	echo "$output" | /usr/bin/grep -qF "util.generated.swift"
	verify_failed "$?" "dispatch glob: util.generated.swift excluded"
else
	echo "dispatch not found at $DISPATCH, skipping dispatch tests"
fi

report_test_stats

[ "$failure_counter" -eq 0 ]
