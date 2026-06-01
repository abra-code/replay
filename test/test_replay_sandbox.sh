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
	echo " Finished sandbox tests      "
	echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	echo ""
	echo "Number of successful tests: $success_counter"
	echo "Number of failed tests:     $failure_counter"
	echo ""
}

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " Testing sandbox options     "
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

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_sandbox_test.XXXXXX)
DENIED_DIR=$(/usr/bin/mktemp -d /tmp/replay_sandbox_denied.XXXXXX)
EXTRA_DIR=$(/usr/bin/mktemp -d /tmp/replay_sandbox_extra.XXXXXX)

cleanup()
{
	rm -rf "$WORK_DIR"
	rm -rf "$DENIED_DIR"
	rm -rf "$EXTRA_DIR"
}

trap cleanup EXIT

echo "Work dir:   $WORK_DIR"
echo "Denied dir: $DENIED_DIR"
echo "Extra dir:  $EXTRA_DIR"
echo ""


# ===========================================================================
echo "------------------------------"
echo "no sandbox flags: normal write works (baseline sanity)"
echo ""

FILE="$WORK_DIR/no_sandbox.txt"

cat > "$WORK_DIR/nosandbox_create.json" << EOF
[{ "action": "create", "file": "$FILE", "content": "hello" }]
EOF
"$REPLAY_TOOL" "$WORK_DIR/nosandbox_create.json"
verify_succeeded "$?" "no sandbox: create succeeds"
test -f "$FILE"
verify_succeeded "$?" "no sandbox: file created"


# ===========================================================================
echo "------------------------------"
echo "--allow-write: create file in allowed dir succeeds"
echo ""

FILE="$WORK_DIR/sandbox_write.txt"

cat > "$WORK_DIR/sandbox_write.json" << EOF
[{ "action": "create", "file": "$FILE", "content": "sandboxed" }]
EOF
"$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	"$WORK_DIR/sandbox_write.json"
verify_succeeded "$?" "allow-write: replay exited successfully"
content=$(cat "$FILE" 2>/dev/null)
test "$content" = "sandboxed"
verify_succeeded "$?" "allow-write: file created with correct content (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "--allow-read: read from allowed dir succeeds"
echo ""

FILE="$WORK_DIR/readable.txt"
printf 'readable content' > "$FILE"

cat > "$WORK_DIR/sandbox_read.json" << EOF
[{ "action": "read", "items": ["$FILE"] }]
EOF
output=$("$REPLAY_TOOL" \
	--allow-read "$WORK_DIR" \
	"$WORK_DIR/sandbox_read.json")
verify_succeeded "$?" "allow-read: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "readable content"
verify_succeeded "$?" "allow-read: file content in output (output: $output)"


# ===========================================================================
echo "------------------------------"
echo "multiple --allow-write flags: writes to both dirs succeed"
echo ""

FILE_W="$WORK_DIR/multi_work.txt"
FILE_E="$EXTRA_DIR/multi_extra.txt"

cat > "$WORK_DIR/multi_write.json" << EOF
[
  { "action": "create", "file": "$FILE_W", "content": "work" },
  { "action": "create", "file": "$FILE_E", "content": "extra" }
]
EOF
"$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	--allow-write "$EXTRA_DIR" \
	"$WORK_DIR/multi_write.json"
verify_succeeded "$?" "multi-write: replay exited successfully"
test -f "$FILE_W"
verify_succeeded "$?" "multi-write: file in WORK_DIR created"
test -f "$FILE_E"
verify_succeeded "$?" "multi-write: file in EXTRA_DIR created"


# ===========================================================================
echo "------------------------------"
echo "--sandbox-profile JSON: read_write path allows create"
echo ""

PROFILE_DIR="$WORK_DIR/profile_rw"
mkdir -p "$PROFILE_DIR"
PROFILE_TARGET="$PROFILE_DIR/out.txt"
PROFILE_FILE="$WORK_DIR/rw_profile.json"

cat > "$PROFILE_FILE" << EOF
{
  "read_write": ["$WORK_DIR", "$PROFILE_DIR"]
}
EOF
cat > "$WORK_DIR/sandbox_profile_test.json" << EOF
[{ "action": "create", "file": "$PROFILE_TARGET", "content": "from profile" }]
EOF
"$REPLAY_TOOL" \
	--sandbox-profile "$PROFILE_FILE" \
	"$WORK_DIR/sandbox_profile_test.json"
verify_succeeded "$?" "sandbox-profile rw: replay exited successfully"
content=$(cat "$PROFILE_TARGET" 2>/dev/null)
test "$content" = "from profile"
verify_succeeded "$?" "sandbox-profile rw: file created via JSON profile (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "--sandbox-profile JSON: read_only path allows read"
echo ""

RO_DIR="$WORK_DIR/readonly"
mkdir -p "$RO_DIR"
RO_FILE="$RO_DIR/source.txt"
printf 'read only source' > "$RO_FILE"
RO_PROFILE="$WORK_DIR/ro_profile.json"

cat > "$RO_PROFILE" << EOF
{
  "read_only": ["$RO_DIR"],
  "read_write": ["$WORK_DIR"]
}
EOF
cat > "$WORK_DIR/sandbox_ro_test.json" << EOF
[{ "action": "read", "items": ["$RO_FILE"] }]
EOF
output=$("$REPLAY_TOOL" \
	--sandbox-profile "$RO_PROFILE" \
	"$WORK_DIR/sandbox_ro_test.json")
verify_succeeded "$?" "sandbox-profile ro: replay exited successfully"
echo "$output" | /usr/bin/grep -qF "read only source"
verify_succeeded "$?" "sandbox-profile ro: file content in output (output: $output)"


# ===========================================================================
echo "------------------------------"
echo "--sandbox-profile + --allow-write: CLI flag appends to profile"
echo ""

MERGE_FILE="$EXTRA_DIR/merged.txt"
MERGE_PROFILE="$WORK_DIR/merge_profile.json"

cat > "$MERGE_PROFILE" << EOF
{
  "read_write": ["$WORK_DIR"]
}
EOF
cat > "$WORK_DIR/merge_test.json" << EOF
[{ "action": "create", "file": "$MERGE_FILE", "content": "merged" }]
EOF
"$REPLAY_TOOL" \
	--sandbox-profile "$MERGE_PROFILE" \
	--allow-write "$EXTRA_DIR" \
	"$WORK_DIR/merge_test.json"
verify_succeeded "$?" "profile+cli merge: replay exited successfully"
content=$(cat "$MERGE_FILE" 2>/dev/null)
test "$content" = "merged"
verify_succeeded "$?" "profile+cli merge: file created in CLI-added dir (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "invalid sandbox profile JSON: exit before applying sandbox"
echo ""

BAD_PROFILE="$WORK_DIR/bad_profile.json"
printf 'not valid json {{{' > "$BAD_PROFILE"

cat > "$WORK_DIR/bad_profile_create.json" << EOF
[{ "action": "create", "file": "$WORK_DIR/bad_out.txt", "content": "x" }]
EOF
"$REPLAY_TOOL" \
	--sandbox-profile "$BAD_PROFILE" \
	"$WORK_DIR/bad_profile_create.json" 2>/dev/null
verify_failed "$?" "bad profile: expected non-zero exit for invalid JSON"


# ===========================================================================
echo "------------------------------"
echo "execute: tool launch itself is allowed under sandbox"
echo ""

cat > "$WORK_DIR/exec_true.json" << EOF
[{ "action": "execute", "tool": "/usr/bin/true" }]
EOF
"$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	"$WORK_DIR/exec_true.json"
verify_succeeded "$?" "execute allowed: /usr/bin/true succeeds under sandbox"


# ===========================================================================
echo "------------------------------"
echo "execute: tool reads from allowed path"
echo ""

EXEC_SRC="$WORK_DIR/exec_source.txt"
printf 'exec source content' > "$EXEC_SRC"

cat > "$WORK_DIR/exec_read_allowed.json" << EOF
[{ "action": "execute", "tool": "/bin/cat", "arguments": ["$EXEC_SRC"] }]
EOF
"$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	"$WORK_DIR/exec_read_allowed.json"
verify_succeeded "$?" "execute read allowed: cat of allowed path succeeds"


# ===========================================================================
echo "------------------------------"
echo "execute: tool writes to allowed path (copy within sandbox)"
echo ""

EXEC_CP_SRC="$WORK_DIR/exec_cp_src.txt"
EXEC_CP_DST="$WORK_DIR/exec_cp_dst.txt"
printf 'copy me' > "$EXEC_CP_SRC"

cat > "$WORK_DIR/exec_write_allowed.json" << EOF
[{ "action": "execute", "tool": "/bin/cp", "arguments": ["$EXEC_CP_SRC", "$EXEC_CP_DST"] }]
EOF
"$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	"$WORK_DIR/exec_write_allowed.json"
verify_succeeded "$?" "execute write allowed: cp to allowed path succeeds"
content=$(cat "$EXEC_CP_DST" 2>/dev/null)
test "$content" = "copy me"
verify_succeeded "$?" "execute write allowed: destination has expected content (got: $content)"


# ===========================================================================
echo "------------------------------"
echo "execute: tool denied from writing to path outside sandbox"
echo ""
# Note: the denied dir is outside /tmp so bsd.sb baseline does not grant access.
# /tmp reads are broadly allowed by bsd.sb on this platform, but writes are not.

EXEC_CP_DENIED_DST="$DENIED_DIR/exec_cp_out.txt"

cat > "$WORK_DIR/exec_write_denied.json" << EOF
[{ "action": "execute", "tool": "/bin/cp", "arguments": ["$EXEC_CP_SRC", "$EXEC_CP_DENIED_DST"] }]
EOF
"$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	"$WORK_DIR/exec_write_denied.json" 2>/dev/null
# Check the filesystem outcome, not the exit code: the execute action's async
# termination handler has a race with fast-failing children, so replay's exit
# code is unreliable here. The absence of the output file is definitive.
test ! -f "$EXEC_CP_DENIED_DST"
verify_succeeded "$?" "execute write denied: destination file not created in denied dir"



# ===========================================================================
echo "------------------------------"
echo "--allow-read /private/etc/ssl: curl HTTPS succeeds (requires network)"
echo ""
# curl/LibreSSL reads /private/etc/ssl/openssl.cnf during TLS initialisation.
# Without this path in the sandbox it fails with "Operation not permitted"
# before the first byte is sent. Verifies the fix is in place.

cat > "$WORK_DIR/curl_https.json" << EOF
[{
  "action": "execute",
  "tool": "/usr/bin/curl",
  "arguments": ["--silent", "--max-time", "5",
                 "--write-out", "http_code=%{http_code}",
                 "--output", "/dev/null",
                 "https://example.com"]
}]
EOF
output=$("$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	--allow-read /private/etc/ssl \
	"$WORK_DIR/curl_https.json" 2>/dev/null)
echo "$output" | /usr/bin/grep -qF "http_code=200"
verify_succeeded "$?" "curl HTTPS: /private/etc/ssl allows TLS init (got: $output)"


# ===========================================================================
echo "------------------------------"
echo "--deny-network: curl reports http_code=000 (no connection)"
echo ""
# Uses --write-out to capture the result via stdout (bypasses execute action's
# async exit-code race). /private/etc/ssl is added so curl gets past TLS init
# and reaches the actual network call, which (deny network*) then blocks.

cat > "$WORK_DIR/curl_denied.json" << EOF
[{
  "action": "execute",
  "tool": "/usr/bin/curl",
  "arguments": ["--silent", "--max-time", "5",
                 "--write-out", "http_code=%{http_code}",
                 "--output", "/dev/null",
                 "http://example.com"]
}]
EOF
output=$("$REPLAY_TOOL" \
	--allow-write "$WORK_DIR" \
	--allow-read /private/etc/ssl \
	--deny-network \
	"$WORK_DIR/curl_denied.json" 2>/dev/null)
echo "$output" | /usr/bin/grep -qF "http_code=000"
verify_succeeded "$?" "network denied: curl reports http_code=000 (got: $output)"


# ===========================================================================
echo "------------------------------"
echo "path deduplication: nested paths collapse to common parents"
echo ""

DEDUP_DIR="$WORK_DIR/dedup_test"
mkdir -p "$DEDUP_DIR/src"
mkdir -p "$DEDUP_DIR/include"
mkdir -p "$DEDUP_DIR/build"

# Resolve symlinks (e.g., /tmp -> /private/tmp) to match what SBPL will show
DEDUP_DIR_RESOLVED=$(cd "$DEDUP_DIR" && pwd -P)

# Use the static playlist - replay will expand ${WORK_DIR}
export WORK_DIR="$DEDUP_DIR"
output=$("$REPLAY_TOOL" --verbose --sandbox "$SCRIPT_DIR/playlists/nested_paths.json" 2>&1)

# Extract just the SBPL profile section (after "Sandbox profile:" up to action output)
sbpl_section=$(echo "$output" | sed -n '/Sandbox profile:/,/^\[.*\]/p' | sed '$d')
# echo "sbpl_section:\n${sbpl_section}\n"

# Verify that the directory appears (may be deduplicated to parent)
echo "$sbpl_section" | /usr/bin/grep -q "$DEDUP_DIR_RESOLVED"
verify_succeeded "$?" "dedup: dedup_test directory appears in SBPL"
echo "$sbpl_section" | /usr/bin/grep -qF "$DEDUP_DIR_RESOLVED/build"
verify_succeeded "$?" "dedup: build directory appears in SBPL"

# Verify read-write paths are not duplicated in read-only section
# Extract read-only paths (lines with "file-read*" only)
rw_only_section=$(echo "$sbpl_section" | sed -n '/; read-write allowed/,/; /p' | grep "file-read\* file-write")
rw_paths=$(echo "$rw_only_section" | sed 's/.*(subpath "\(.*\)").*/\1/')

# Extract read-only paths
ro_only_section=$(echo "$sbpl_section" | sed -n '/; read-only allowed/,/; read-write/p' | grep "file-read\*" | grep -v "file-read\* file-write")
ro_paths=$(echo "$ro_only_section" | sed 's/.*(subpath "\(.*\)").*/\1/')

# Check: no read-write path should be a parent of any read-only path (or exact match)
# This is handled by the sandbox module internally, but verify it's working
duplicate_found=0
for rw in $rw_paths; do
    for ro in $ro_paths; do
        # Check if rw is a prefix of ro (rw is parent of ro) or equal
        case "$ro" in
            "$rw"|"$rw"/*)
                duplicate_found=1
                break
                ;;
        esac
    done
    [ "$duplicate_found" = "1" ] && break
done

if [ "$duplicate_found" = "0" ]; then
    verify_succeeded 0 "dedup: no read-only paths covered by read-write"
else
    verify_failed 0 "dedup: read-write should not include paths already in read-only"
fi

# Reads now use the file path itself (precise) so individual files SHOULD appear
# unless their parent directory is already in the allowlist (covered by a write).
has_main_cpp=$(echo "$sbpl_section" | grep -c "main.cpp")
if [ "$has_main_cpp" != "0" ]; then
    verify_succeeded 0 "dedup: read of main.cpp appears as a file entry (precise read)"
else
    verify_failed 0 "dedup: main.cpp file entry should appear in SBPL (read uses path itself)"
fi

# build/output.o and build/lib/lib.a are reads but their parents are in writes
# (build/, build/lib → dedup → build/), so the read entries should be dropped.
has_output_o=$(echo "$sbpl_section" | grep -c "output.o")
if [ "$has_output_o" = "0" ]; then
    verify_succeeded 0 "dedup: read of output.o dropped (covered by write of build/)"
else
    verify_failed 0 "dedup: output.o should not appear (covered by build/ write)"
fi

has_lib_a=$(echo "$sbpl_section" | grep -c "lib.a")
if [ "$has_lib_a" = "0" ]; then
    verify_succeeded 0 "dedup: read of lib.a dropped (covered by write of build/)"
else
    verify_failed 0 "dedup: lib.a should not appear (covered by build/ write)"
fi

# build/lib write entry should be deduplicated into build/ write entry.
has_build_lib=$(echo "$sbpl_section" | grep -c "build/lib")
if [ "$has_build_lib" = "0" ]; then
    verify_succeeded 0 "dedup: build/lib write merged into build write"
else
    verify_failed 0 "dedup: build/lib should be deduplicated into build"
fi


report_test_stats

[ "$failure_counter" -eq 0 ]
