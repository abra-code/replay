#!/bin/bash
# test_gate_env_list.sh — tests for gate -E/--env-list, Xcode env var collection,
# and invalid option error paths

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
GATE="${1:-$REPO_DIR/build/Release/gate}"

if [ ! -x "$GATE" ]; then
    echo "error: gate binary not found at $GATE"
    echo "usage: $0 [path/to/gate]"
    exit 1
fi

PASS=0
FAIL=0
TEST_DIR=$(/usr/bin/mktemp -d)
trap "/bin/rm -rf '$TEST_DIR'" EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

run_gate() {
    "$GATE" -v -c "$TEST_DIR/.gate-cache" "$@" 2>&1
}

# ============================================================
echo "=== env-list: basic cache invalidation on env var change ==="

printf '${MY_BUILD_VAR}\n' > "$TEST_DIR/env.list"
echo "source content" > "$TEST_DIR/src.txt"

export MY_BUILD_VAR="debug"

output=$(run_gate -i "$TEST_DIR/src.txt" -o "$TEST_DIR/out.txt" \
    -E "$TEST_DIR/env.list" \
    -- /bin/cp "$TEST_DIR/src.txt" "$TEST_DIR/out.txt")
if echo "$output" | /usr/bin/grep -q "no cache entry\|executing"; then
    pass "1. first run is cache miss with env-list"
else
    fail "1. first run is cache miss with env-list"
    echo "$output"
fi

output=$(run_gate -i "$TEST_DIR/src.txt" -o "$TEST_DIR/out.txt" \
    -E "$TEST_DIR/env.list" \
    -- /bin/cp "$TEST_DIR/src.txt" "$TEST_DIR/out.txt")
if echo "$output" | /usr/bin/grep -q "cache hit"; then
    pass "2. same env var → cache hit"
else
    fail "2. same env var should hit cache"
    echo "$output"
fi

export MY_BUILD_VAR="release"

output=$(run_gate -i "$TEST_DIR/src.txt" -o "$TEST_DIR/out.txt" \
    -E "$TEST_DIR/env.list" \
    -- /bin/cp "$TEST_DIR/src.txt" "$TEST_DIR/out.txt")
if echo "$output" | /usr/bin/grep -q "input fingerprint changed\|executing"; then
    pass "3. changed env var → cache miss"
else
    fail "3. changed env var should be cache miss"
    echo "$output"
fi

unset MY_BUILD_VAR

# ============================================================
echo "=== env-list: comments and empty lines are skipped ==="

/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "hello" > "$TEST_DIR/in2.txt"
printf '# this is a comment\n\n${SOME_VAR}\n# another comment\n' > "$TEST_DIR/env2.list"

export SOME_VAR="v1"

output=$(run_gate -i "$TEST_DIR/in2.txt" -o "$TEST_DIR/out2.txt" \
    -E "$TEST_DIR/env2.list" \
    -- /bin/cp "$TEST_DIR/in2.txt" "$TEST_DIR/out2.txt")
if echo "$output" | /usr/bin/grep -q "no cache entry\|executing"; then
    pass "4. env-list with comments: first run executes"
else
    fail "4. env-list with comments: first run should execute"
    echo "$output"
fi

output=$(run_gate -i "$TEST_DIR/in2.txt" -o "$TEST_DIR/out2.txt" \
    -E "$TEST_DIR/env2.list" \
    -- /bin/cp "$TEST_DIR/in2.txt" "$TEST_DIR/out2.txt")
if echo "$output" | /usr/bin/grep -q "cache hit"; then
    pass "5. env-list with comments: second run hits cache"
else
    fail "5. env-list with comments: second run should hit cache"
    echo "$output"
fi

unset SOME_VAR

# ============================================================
echo "=== env-list: multiple -E files are combined ==="

/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "key" > "$TEST_DIR/in3.txt"
printf '${VAR_A}\n' > "$TEST_DIR/env_a.list"
printf '${VAR_B}\n' > "$TEST_DIR/env_b.list"

export VAR_A="alpha"
export VAR_B="beta"

output=$(run_gate -i "$TEST_DIR/in3.txt" -o "$TEST_DIR/out3.txt" \
    -E "$TEST_DIR/env_a.list" -E "$TEST_DIR/env_b.list" \
    -- /bin/cp "$TEST_DIR/in3.txt" "$TEST_DIR/out3.txt")
if echo "$output" | /usr/bin/grep -q "no cache entry\|executing"; then
    pass "6. multiple env-list files: first run executes"
else
    fail "6. multiple env-list files: first run should execute"
    echo "$output"
fi

# Change VAR_B: cache miss
export VAR_B="gamma"
output=$(run_gate -i "$TEST_DIR/in3.txt" -o "$TEST_DIR/out3.txt" \
    -E "$TEST_DIR/env_a.list" -E "$TEST_DIR/env_b.list" \
    -- /bin/cp "$TEST_DIR/in3.txt" "$TEST_DIR/out3.txt")
if echo "$output" | /usr/bin/grep -q "input fingerprint changed\|executing"; then
    pass "7. changing VAR_B triggers cache miss when tracked in second env-list"
else
    fail "7. changing tracked var in second env-list should trigger cache miss"
    echo "$output"
fi

unset VAR_A VAR_B

# ============================================================
echo "=== Xcode env var collection ==="

/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "xcode input" > "$TEST_DIR/xcode_in.txt"

export SCRIPT_INPUT_FILE_COUNT=1
export SCRIPT_INPUT_FILE_0="$TEST_DIR/xcode_in.txt"
export SCRIPT_OUTPUT_FILE_COUNT=1
export SCRIPT_OUTPUT_FILE_0="$TEST_DIR/xcode_out.txt"

output=$(run_gate -- /bin/cp "$TEST_DIR/xcode_in.txt" "$TEST_DIR/xcode_out.txt")
if echo "$output" | /usr/bin/grep -q "no cache entry\|executing"; then
    pass "8. Xcode env vars: first run executes (inputs/outputs discovered)"
else
    fail "8. Xcode env vars: first run should execute"
    echo "$output"
fi

if [ -f "$TEST_DIR/xcode_out.txt" ]; then
    pass "9. Xcode output file was created"
else
    fail "9. Xcode output file should be created"
fi

output=$(run_gate -- /bin/cp "$TEST_DIR/xcode_in.txt" "$TEST_DIR/xcode_out.txt")
if echo "$output" | /usr/bin/grep -q "cache hit"; then
    pass "10. Xcode env vars: second run hits cache"
else
    fail "10. Xcode env vars: second run should hit cache"
    echo "$output"
fi

echo "changed content" > "$TEST_DIR/xcode_in.txt"
output=$(run_gate -- /bin/cp "$TEST_DIR/xcode_in.txt" "$TEST_DIR/xcode_out.txt")
if echo "$output" | /usr/bin/grep -q "input fingerprint changed\|executing"; then
    pass "11. Xcode input change triggers cache miss"
else
    fail "11. Xcode input change should trigger cache miss"
    echo "$output"
fi

unset SCRIPT_INPUT_FILE_COUNT SCRIPT_INPUT_FILE_0 SCRIPT_OUTPUT_FILE_COUNT SCRIPT_OUTPUT_FILE_0

# ============================================================
echo "=== Xcode file-list env vars (SCRIPT_INPUT_FILE_LIST_*) ==="

/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "list input" > "$TEST_DIR/list_in.txt"
printf '%s\n' "$TEST_DIR/list_in.txt" > "$TEST_DIR/inputs.xcfilelist"

export SCRIPT_INPUT_FILE_LIST_COUNT=1
export SCRIPT_INPUT_FILE_LIST_0="$TEST_DIR/inputs.xcfilelist"
export SCRIPT_OUTPUT_FILE_COUNT=1
export SCRIPT_OUTPUT_FILE_0="$TEST_DIR/list_out.txt"

output=$(run_gate -- /bin/cp "$TEST_DIR/list_in.txt" "$TEST_DIR/list_out.txt")
if echo "$output" | /usr/bin/grep -q "no cache entry\|executing"; then
    pass "12. Xcode file-list env vars: first run executes"
else
    fail "12. Xcode file-list env vars: first run should execute"
    echo "$output"
fi

output=$(run_gate -- /bin/cp "$TEST_DIR/list_in.txt" "$TEST_DIR/list_out.txt")
if echo "$output" | /usr/bin/grep -q "cache hit"; then
    pass "13. Xcode file-list env vars: second run hits cache"
else
    fail "13. Xcode file-list env vars: second run should hit cache"
    echo "$output"
fi

unset SCRIPT_INPUT_FILE_LIST_COUNT SCRIPT_INPUT_FILE_LIST_0 SCRIPT_OUTPUT_FILE_COUNT SCRIPT_OUTPUT_FILE_0

# ============================================================
echo "=== Invalid options ==="

output=$("$GATE" --hash=bogusalgo -i /dev/null -- /bin/echo ok 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "14. --hash=bogus exits with code 2"
else
    fail "14. --hash=bogus should exit 2 (got $rc)"
fi

output=$("$GATE" --cache-format=bogus -i /dev/null -- /bin/echo ok 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "15. --cache-format=bogus exits with code 2"
else
    fail "15. --cache-format=bogus should exit 2 (got $rc)"
fi

output=$("$GATE" -i /dev/null 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "16. Missing command (no --) exits with code 2"
else
    fail "16. Missing command should exit 2 (got $rc)"
fi

# ============================================================
echo ""
echo "========================================"
printf "  Gate env-list tests: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
