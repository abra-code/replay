#!/bin/bash

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
	echo " Finished gate auto-sandbox tests "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Testing gate auto-sandbox paths "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
GATE_TOOL="${1:-$REPO_DIR/build/Release/gate}"
if [ ! -x "$GATE_TOOL" ]; then
	echo "error: gate not found at $GATE_TOOL"
	echo "usage: $0 [path/to/gate]"
	exit 1
fi

WORK_DIR=$(/usr/bin/mktemp -d /tmp/gate_auto_sandbox_test.XXXXXX)
if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then echo "error: mktemp failed for WORK_DIR" >&2; exit 1; fi
CACHE_DIR="$WORK_DIR/.gate-cache"

cleanup()
{
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo "Work dir: $WORK_DIR"
echo ""

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers input as read-only"
echo ""

INPUT_FILE="$WORK_DIR/input.txt"
OUTPUT_FILE="$WORK_DIR/output.txt"
printf 'input content' > "$INPUT_FILE"

"$GATE_TOOL" \
	--sandbox \
	-i "$INPUT_FILE" \
	-o "$OUTPUT_FILE" \
	-c "$CACHE_DIR" \
	-- /bin/cp "$INPUT_FILE" "$OUTPUT_FILE" 2>/dev/null
verify_succeeded "$?" "sandbox auto-read: gate exited successfully"
test -f "$OUTPUT_FILE"
verify_succeeded "$?" "sandbox auto-read: output file created"
content=$(cat "$OUTPUT_FILE")
verify_content "$content" "input content" "sandbox auto-read: content matches"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers cache dir as read-write"
echo ""

INPUT2="$WORK_DIR/input2.txt"
OUTPUT2="$WORK_DIR/output2.txt"
printf 'input2' > "$INPUT2"

"$GATE_TOOL" \
	--sandbox \
	-i "$INPUT2" \
	-o "$OUTPUT2" \
	-c "$CACHE_DIR" \
	-- /bin/cp "$INPUT2" "$OUTPUT2" 2>/dev/null
verify_succeeded "$?" "sandbox auto-cache: gate exited successfully"
test -d "$CACHE_DIR"
verify_succeeded "$?" "sandbox auto-cache: cache directory created"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: multiple inputs are read-only"
echo ""

INPUT3="$WORK_DIR/input3a.txt"
INPUT4="$WORK_DIR/input3b.txt"
OUTPUT3="$WORK_DIR/output3.txt"
printf 'content3a' > "$INPUT3"
printf 'content3b' > "$INPUT4"

"$GATE_TOOL" \
	--sandbox \
	-i "$INPUT3" \
	-i "$INPUT4" \
	-o "$OUTPUT3" \
	-c "$CACHE_DIR" \
	-- /bin/cat "$INPUT3" > "$OUTPUT3" 2>/dev/null
verify_succeeded "$?" "sandbox multi-input: gate exited successfully"
content=$(cat "$OUTPUT3")
verify_content "$content" "content3a" "sandbox multi-input: content matches"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: explicit --allow-write for paths outside declared paths"
echo ""

EXTRA_DIR=$(/usr/bin/mktemp -d /tmp/gate_auto_sandbox_extra.XXXXXX)
if [ -z "$EXTRA_DIR" ] || [ ! -d "$EXTRA_DIR" ]; then echo "error: mktemp failed for EXTRA_DIR" >&2; exit 1; fi
trap 'rm -rf "$EXTRA_DIR"; cleanup' EXIT

EXTRA_FILE="$EXTRA_DIR/extra.txt"
INPUT5="$WORK_DIR/input5.txt"
printf 'extra input' > "$INPUT5"

"$GATE_TOOL" \
	--sandbox \
	--allow-write "$EXTRA_DIR" \
	-i "$INPUT5" \
	-o "$EXTRA_FILE" \
	-c "$CACHE_DIR" \
	-- /bin/cp "$INPUT5" "$EXTRA_FILE" 2>/dev/null
verify_succeeded "$?" "sandbox explicit write: gate exited successfully"
test -f "$EXTRA_FILE"
verify_succeeded "$?" "sandbox explicit write: file created in explicit dir"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: with --input-list"
echo ""

LIST_FILE="$WORK_DIR/input_list.txt"
printf '%s\n' "$INPUT2" "$INPUT3" > "$LIST_FILE"
OUTPUT4="$WORK_DIR/output4.txt"

"$GATE_TOOL" \
	--sandbox \
	-I "$LIST_FILE" \
	-o "$OUTPUT4" \
	-c "$CACHE_DIR" \
	-- /bin/cat "$INPUT2" > "$OUTPUT4" 2>/dev/null
verify_succeeded "$?" "sandbox input-list: gate exited successfully"
test -f "$OUTPUT4"
verify_succeeded "$?" "sandbox input-list: output created"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: mix of auto-discovered and --allow-read"
echo ""

READ_DIR=$(/usr/bin/mktemp -d /tmp/gate_auto_sandbox_read.XXXXXX)
if [ -z "$READ_DIR" ] || [ ! -d "$READ_DIR" ]; then echo "error: mktemp failed for READ_DIR" >&2; exit 1; fi
trap 'rm -rf "$READ_DIR"; cleanup' EXIT

INPUT6="$WORK_DIR/input6.txt"
printf 'read content' > "$INPUT6"

"$GATE_TOOL" \
	--sandbox \
	--allow-read "$READ_DIR" \
	-i "$INPUT6" \
	-c "$CACHE_DIR" \
	-- /bin/echo "read dir allowed" 2>/dev/null
verify_succeeded "$?" "sandbox allow-read: gate exited successfully"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers exclude_inputs as read-write"
echo ""

EXCLUDE_DIR=$(/usr/bin/mktemp -d /tmp/gate_auto_sandbox_exclude.XXXXXX)
if [ -z "$EXCLUDE_DIR" ] || [ ! -d "$EXCLUDE_DIR" ]; then echo "error: mktemp failed for EXCLUDE_DIR" >&2; exit 1; fi
INPUT7="$WORK_DIR/input7.txt"
OUTPUT5="$WORK_DIR/output5.txt"
printf 'exclude test' > "$INPUT7"

"$GATE_TOOL" \
	--sandbox \
	-i "$INPUT7" \
	-e "$EXCLUDE_DIR" \
	-o "$OUTPUT5" \
	-c "$CACHE_DIR" \
	-- /bin/cat "$INPUT7" > "$OUTPUT5" 2>/dev/null
verify_succeeded "$?" "sandbox exclude-input: gate exited successfully"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: outputs are read-write (can create and overwrite)"
echo ""

INPUT8="$WORK_DIR/input8.txt"
OUTPUT6="$WORK_DIR/output6.txt"
printf 'first content' > "$INPUT8"

"$GATE_TOOL" \
	--sandbox \
	-i "$INPUT8" \
	-o "$OUTPUT6" \
	-c "$CACHE_DIR" \
	-- /bin/cp "$INPUT8" "$OUTPUT6" 2>/dev/null
verify_succeeded "$?" "sandbox output create: gate exited successfully"

printf 'second content' > "$INPUT8"

"$GATE_TOOL" \
	--sandbox \
	-i "$INPUT8" \
	-o "$OUTPUT6" \
	-c "$CACHE_DIR" \
	-- /bin/cp "$INPUT8" "$OUTPUT6" 2>/dev/null
verify_succeeded "$?" "sandbox output overwrite: gate exited successfully"
content=$(cat "$OUTPUT6")
verify_content "$content" "second content" "sandbox output overwrite: content updated"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: auto-discovers env-list files as read-only"
echo ""

ENV_LIST_FILE="$WORK_DIR/env_list.txt"
printf 'MY_VAR=value\n' > "$ENV_LIST_FILE"
INPUT10="$WORK_DIR/input10.txt"
OUTPUT7="$WORK_DIR/output7.txt"
printf 'env test' > "$INPUT10"

"$GATE_TOOL" \
	--sandbox \
	-E "$ENV_LIST_FILE" \
	-i "$INPUT10" \
	-o "$OUTPUT7" \
	-c "$CACHE_DIR" \
	-- /bin/cat "$INPUT10" > "$OUTPUT7" 2>/dev/null
verify_succeeded "$?" "sandbox env-list: gate exited successfully"
test -f "$OUTPUT7"
verify_succeeded "$?" "sandbox env-list: output file created"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: denied write to path not in inputs/outputs/cache"
echo ""

DENIED_DIR=$(/usr/bin/mktemp -d /tmp/gate_denied.XXXXXX)
if [ -z "$DENIED_DIR" ] || [ ! -d "$DENIED_DIR" ]; then echo "error: mktemp failed for DENIED_DIR" >&2; exit 1; fi
trap 'rm -rf "$DENIED_DIR"; cleanup' EXIT

DENIED_FILE="$DENIED_DIR/denied_auto.txt"
INPUT9="$WORK_DIR/input9.txt"
printf 'denied test' > "$INPUT9"

"$GATE_TOOL" \
	--sandbox \
	-i "$INPUT9" \
	-c "$CACHE_DIR" \
	-- /bin/sh -c "echo test > $DENIED_FILE" 2>/dev/null
verify_failed "$?" "sandbox denied: expected non-zero exit for path not declared"
test ! -f "$DENIED_FILE"
verify_succeeded "$?" "sandbox denied: file not created"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: glob input (*.txt) allows reading files in the concrete prefix dir"
echo ""

GLOB_SRC="$WORK_DIR/glob_src"
mkdir -p "$GLOB_SRC"
printf 'hello from glob' > "$GLOB_SRC/a.txt"
printf 'second file' > "$GLOB_SRC/b.txt"
GLOB_READ_OUT="$WORK_DIR/glob_read_out.txt"

"$GATE_TOOL" \
	--sandbox \
	-i "$GLOB_SRC/*.txt" \
	-o "$GLOB_READ_OUT" \
	-c "$CACHE_DIR" \
	-- /bin/cat "$GLOB_SRC/a.txt" > "$GLOB_READ_OUT" 2>/dev/null
verify_succeeded "$?" "sandbox glob input: gate exited successfully"
content=$(cat "$GLOB_READ_OUT")
verify_content "$content" "hello from glob" "sandbox glob input: correct file content"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: glob output (*.txt) allows writing files in the concrete prefix dir"
echo ""

GLOB_OUTDIR="$WORK_DIR/glob_outdir"
mkdir -p "$GLOB_OUTDIR"
GLOB_WRITE_IN="$WORK_DIR/glob_write_in.txt"
printf 'glob output test' > "$GLOB_WRITE_IN"

"$GATE_TOOL" \
	--sandbox \
	-i "$GLOB_WRITE_IN" \
	-o "$GLOB_OUTDIR/*.txt" \
	-c "$CACHE_DIR" \
	-- /bin/cp "$GLOB_WRITE_IN" "$GLOB_OUTDIR/result.txt" 2>/dev/null
verify_succeeded "$?" "sandbox glob output: gate exited successfully"
test -f "$GLOB_OUTDIR/result.txt"
verify_succeeded "$?" "sandbox glob output: file created in glob output dir"
content=$(cat "$GLOB_OUTDIR/result.txt")
verify_content "$content" "glob output test" "sandbox glob output: content matches"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: glob input with ** reads files in subdirectories"
echo ""

DEEP_SRC="$WORK_DIR/deep_src"
mkdir -p "$DEEP_SRC/sub/nested"
printf 'deep content' > "$DEEP_SRC/sub/nested/deep.txt"
DEEP_OUT="$WORK_DIR/deep_out.txt"

"$GATE_TOOL" \
	--sandbox \
	-i "$DEEP_SRC/**/*.txt" \
	-o "$DEEP_OUT" \
	-c "$CACHE_DIR" \
	-- /bin/cat "$DEEP_SRC/sub/nested/deep.txt" > "$DEEP_OUT" 2>/dev/null
verify_succeeded "$?" "sandbox glob ** input: gate exited successfully"
content=$(cat "$DEEP_OUT")
verify_content "$content" "deep content" "sandbox glob ** input: content in subdir accessible"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: glob input does not grant write access outside the glob prefix"
echo ""

GLOB_DENY_OUTSIDE=$(/usr/bin/mktemp -d /tmp/gate_glob_deny.XXXXXX)
if [ -z "$GLOB_DENY_OUTSIDE" ] || [ ! -d "$GLOB_DENY_OUTSIDE" ]; then echo "error: mktemp failed for GLOB_DENY_OUTSIDE" >&2; exit 1; fi
trap 'rm -rf "$GLOB_DENY_OUTSIDE"; rm -rf "$DENIED_DIR"; cleanup' EXIT

GLOB_DENY_SRC="$WORK_DIR/glob_deny_src"
mkdir -p "$GLOB_DENY_SRC"
printf 'src file' > "$GLOB_DENY_SRC/file.txt"
GLOB_DENY_FILE="$GLOB_DENY_OUTSIDE/denied.txt"

"$GATE_TOOL" \
	--sandbox \
	-i "$GLOB_DENY_SRC/*.txt" \
	-c "$CACHE_DIR" \
	-- /bin/sh -c "echo denied > $GLOB_DENY_FILE" 2>/dev/null
verify_failed "$?" "sandbox glob deny: write outside glob prefix is denied"
test ! -f "$GLOB_DENY_FILE"
verify_succeeded "$?" "sandbox glob deny: file not created outside glob prefix"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: a tool named without a slash is found in PATH and gets read access"
echo ""

PATH_TOOL_DIR="$WORK_DIR/path_tool_bin"
/bin/mkdir -p "$PATH_TOOL_DIR"
printf '#!/bin/sh\necho "path tool ran"\n' > "$PATH_TOOL_DIR/gate_path_tool"
/bin/chmod 755 "$PATH_TOOL_DIR/gate_path_tool"
printf 'path tool input' > "$WORK_DIR/path_tool_input.txt"

output=$(PATH="$PATH_TOOL_DIR:/usr/bin:/bin" "$GATE_TOOL" --sandbox -f \
	-i "$WORK_DIR/path_tool_input.txt" \
	-c "$CACHE_DIR" \
	-- gate_path_tool 2>&1)
verify_succeeded "$?" "sandbox PATH tool: gate exited successfully"
echo "$output" | /usr/bin/grep -qF "path tool ran"
verify_succeeded "$?" "sandbox PATH tool: the tool ran"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: a derived grant of the whole home folder is reported"
echo ""

FAKE_HOME="$WORK_DIR/fake_home"
/bin/mkdir -p "$FAKE_HOME/sub"
printf 'home input' > "$FAKE_HOME/sub/in.txt"

output=$(cd "$FAKE_HOME" && HOME="$FAKE_HOME" "$GATE_TOOL" --sandbox -f -i "$FAKE_HOME/sub/in.txt" -c "$CACHE_DIR" -- /usr/bin/true 2>&1)
verify_succeeded "$?" "sandbox broad grant: gate run from the home folder exited successfully"
echo "$output" | /usr/bin/grep -qF "grants read access to all of"
verify_succeeded "$?" "sandbox broad grant: the read grant of the current folder, the home folder, is reported"

output=$(cd "$FAKE_HOME" && HOME="$FAKE_HOME" "$GATE_TOOL" --sandbox -f -i . -c "$CACHE_DIR" -- /usr/bin/true 2>&1)
verify_succeeded "$?" "sandbox broad grant twice: gate run from the home folder with -i . exited successfully"
count=$(echo "$output" | /usr/bin/grep -cF "grants read access to all of")
[ "$count" = "1" ]
verify_succeeded "$?" "sandbox broad grant twice: the home folder is reported once, not once per grant"

output=$(cd "$FAKE_HOME/sub" && HOME="$FAKE_HOME" "$GATE_TOOL" --sandbox -f -i "$FAKE_HOME/sub/in.txt" -c "$CACHE_DIR" -- /usr/bin/true 2>&1)
verify_succeeded "$?" "sandbox narrow grant: gate run from a folder below the home folder exited successfully"
echo "$output" | /usr/bin/grep -qF "access to all of"
verify_failed "$?" "sandbox narrow grant: nothing is reported"

# ===========================================================================
echo "------------------------------"
echo "--sandbox: a sub-make gets the job slots of the make above it"
echo ""

# make passes a recursive make two pipe descriptors for its parallel job slots, named in
# MAKEFLAGS. Under the sandbox the commands get only descriptors 0 to 2 otherwise, and a
# sub-make without its job slots runs one job at a time. make 4.4 and newer
# default to a named pipe instead, so the test asks them for the pipe style.
MAKE_TOOL=/usr/bin/make
if [ -x "$MAKE_TOOL" ]; then
	JS_DIR="$WORK_DIR/jobserver"
	/bin/mkdir -p "$JS_DIR"
	# Each of the two jobs waits up to 3 s for the other to start, and fails without it:
	# when they run one at a time, the first one fails.
	printf 'all:\n\t+"$(GATE)" --allow-write "$(JS_DIR)" -f -c "$(JS_DIR)/cache" -- "$(MAKE)" -C "$(JS_DIR)" -f "$(JS_DIR)/Makefile" inner\ninner: a b\na:\n\t@/usr/bin/touch "$(JS_DIR)/a.on"; i=0; while [ ! -e "$(JS_DIR)/b.on" ] && [ $$i -lt 30 ]; do /bin/sleep 0.1; i=$$((i+1)); done; [ -e "$(JS_DIR)/b.on" ]\nb:\n\t@/usr/bin/touch "$(JS_DIR)/b.on"; i=0; while [ ! -e "$(JS_DIR)/a.on" ] && [ $$i -lt 30 ]; do /bin/sleep 0.1; i=$$((i+1)); done; [ -e "$(JS_DIR)/a.on" ]\n' > "$JS_DIR/Makefile"
	make_version=$("$MAKE_TOOL" --version 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/sed -n 's/^GNU Make \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
	make_style=""
	case "$make_version" in
		[5-9]*|"4 "[4-9]*) make_style="--jobserver-style=pipe" ;;
	esac
	output=$("$MAKE_TOOL" -j2 $make_style -f "$JS_DIR/Makefile" GATE="$GATE_TOOL" JS_DIR="$JS_DIR" 2>&1)
	verify_succeeded "$?" "sandbox job slots: the sub-make under the sandbox ran its two jobs at the same time"
else
	echo "  skipped: no /usr/bin/make"
fi

report_test_stats

[ "$failure_counter" -eq 0 ]
