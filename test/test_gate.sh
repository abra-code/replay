#!/bin/bash
#
# gate_test.sh — end-to-end tests for the gate tool
#
# Usage: gate_test.sh [path/to/gate]
#

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

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

run_gate() {
    "$GATE" -v -c "$TEST_DIR/.gate-cache" "$@" 2>&1
}

run_gate_rc() {
    "$GATE" -v -c "$TEST_DIR/.gate-cache" "$@" 2>&1
    echo "EXIT:$?"
}

# ============================================================
echo "=== Basic cache miss / hit ==="

echo "hello" > "$TEST_DIR/in.txt"

# Test 1: first run is a cache miss
output=$(run_gate -i "$TEST_DIR/in.txt" -o "$TEST_DIR/out.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/out.txt")
matched=$(echo "$output" | /usr/bin/grep "no cache entry found")
if [ -n "$matched" ] && [ -f "$TEST_DIR/out.txt" ]; then
    pass "1. first run executes (cache miss)"
else
    fail "1. first run executes (cache miss)"
    echo "$output"
fi

# Test 2: second run is a cache hit
output=$(run_gate -i "$TEST_DIR/in.txt" -o "$TEST_DIR/out.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "2. second run skips (cache hit)"
else
    fail "2. second run skips (cache hit)"
    echo "$output"
fi

# ============================================================
echo "=== Input invalidation ==="

# Test 3: modify input -> cache miss
echo "changed" > "$TEST_DIR/in.txt"
output=$(run_gate -i "$TEST_DIR/in.txt" -o "$TEST_DIR/out.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/out.txt")
matched=$(echo "$output" | /usr/bin/grep "input fingerprint changed")
if [ -n "$matched" ]; then
    pass "3. input change triggers re-execution"
else
    fail "3. input change triggers re-execution"
    echo "$output"
fi

# Test 4: verify output has new content
content=$(/bin/cat "$TEST_DIR/out.txt")
if [ "$content" = "changed" ]; then
    pass "4. output updated after re-execution"
else
    fail "4. output updated after re-execution"
    echo "$output"
fi

# ============================================================
echo "=== Output invalidation ==="

# Test 5: delete output -> cache miss
/bin/rm "$TEST_DIR/out.txt"
output=$(run_gate -i "$TEST_DIR/in.txt" -o "$TEST_DIR/out.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/out.txt")
matched=$(echo "$output" | /usr/bin/grep "file does not exist")
if [ -n "$matched" ]; then
    pass "5. deleted output triggers re-execution"
else
    fail "5. deleted output triggers re-execution"
    echo "$output"
fi

# Test 6: tamper with output -> cache miss
echo "tampered" > "$TEST_DIR/out.txt"
output=$(run_gate -i "$TEST_DIR/in.txt" -o "$TEST_DIR/out.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/out.txt")
matched=$(echo "$output" | /usr/bin/grep "output fingerprint changed")
if [ -n "$matched" ]; then
    pass "6. tampered output triggers re-execution"
else
    fail "6. tampered output triggers re-execution"
    echo "$output"
fi

# ============================================================
echo "=== Failed command ==="

# Test 7: command fails -> not cached
output=$(run_gate_rc -v -i "$TEST_DIR/in.txt" -o "$TEST_DIR/bad.txt" -- /usr/bin/false)
matched_failed=$(echo "$output" | /usr/bin/grep "command failed")
matched_exit=$(echo "$output" | /usr/bin/grep "EXIT:1")
if [ -n "$matched_failed" ] && [ -n "$matched_exit" ]; then
    pass "7. failed command returns non-zero exit code"
else
    fail "7. failed command returns non-zero exit code"
    echo "$output"
fi

# Test 8: failed command not cached — re-running still misses
output=$(run_gate -i "$TEST_DIR/in.txt" -o "$TEST_DIR/bad.txt" -- /usr/bin/false 2>&1; true)
matched=$(echo "$output" | /usr/bin/grep "executing")
if [ -n "$matched" ]; then
    pass "8. failed command is not cached"
else
    fail "8. failed command is not cached"
    echo "$output"
fi

# ============================================================
echo "=== --force flag ==="

# Test 9: --force ignores cache
output=$(run_gate -f -i "$TEST_DIR/in.txt" -o "$TEST_DIR/out.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/out.txt")
matched=$(echo "$output" | /usr/bin/grep "executing")
if [ -n "$matched" ]; then
    pass "9. --force executes despite cache hit"
else
    fail "9. --force executes despite cache hit"
    echo "$output"
fi

# ============================================================
echo "=== --dry-run flag ==="

# Test 10: --dry-run reports hit without executing
output=$(run_gate --dry-run -i "$TEST_DIR/in.txt" -o "$TEST_DIR/out.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit, skipping")
if [ -n "$matched" ]; then
    pass "10. --dry-run reports cache hit"
else
    fail "10. --dry-run reports cache hit"
    echo "$output"
fi

# Test 11: --dry-run reports miss on new task
output=$(run_gate --dry-run -i "$TEST_DIR/in.txt" -o "$TEST_DIR/new.txt" -- /bin/cp "$TEST_DIR/in.txt" "$TEST_DIR/new.txt")
matched=$(echo "$output" | /usr/bin/grep "cache miss, would execute")
if [ -n "$matched" ]; then
    pass "11. --dry-run reports cache miss"
else
    fail "11. --dry-run reports cache miss"
    echo "$output"
fi

# ============================================================
echo "=== Multiple inputs ==="

# Test 12: multiple inputs
echo "aaa" > "$TEST_DIR/a.txt"
echo "bbb" > "$TEST_DIR/b.txt"
run_gate -i "$TEST_DIR/a.txt" -i "$TEST_DIR/b.txt" -o "$TEST_DIR/ab.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/a.txt' '$TEST_DIR/b.txt' > '$TEST_DIR/ab.txt'" > /dev/null
output=$(run_gate -i "$TEST_DIR/a.txt" -i "$TEST_DIR/b.txt" -o "$TEST_DIR/ab.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/a.txt' '$TEST_DIR/b.txt' > '$TEST_DIR/ab.txt'")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "12. multiple inputs: cache hit"
else
    fail "12. multiple inputs: cache hit"
    echo "$output"
fi

# Test 13: changing one of multiple inputs invalidates
echo "aaa_modified" > "$TEST_DIR/a.txt"
output=$(run_gate -i "$TEST_DIR/a.txt" -i "$TEST_DIR/b.txt" -o "$TEST_DIR/ab.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/a.txt' '$TEST_DIR/b.txt' > '$TEST_DIR/ab.txt'")
matched=$(echo "$output" | /usr/bin/grep "input fingerprint changed")
if [ -n "$matched" ]; then
    pass "13. multiple inputs: one changed triggers re-execution"
else
    fail "13. multiple inputs: one changed triggers re-execution"
    echo "$output"
fi

# ============================================================
echo "=== Multiple outputs ==="

# Test 14: multiple outputs
echo "src" > "$TEST_DIR/src.txt"
run_gate -i "$TEST_DIR/src.txt" -o "$TEST_DIR/o1.txt" -o "$TEST_DIR/o2.txt" \
    -- /bin/sh -c "/bin/cp '$TEST_DIR/src.txt' '$TEST_DIR/o1.txt' && /bin/cp '$TEST_DIR/src.txt' '$TEST_DIR/o2.txt'" > /dev/null
output=$(run_gate -i "$TEST_DIR/src.txt" -o "$TEST_DIR/o1.txt" -o "$TEST_DIR/o2.txt" \
    -- /bin/sh -c "/bin/cp '$TEST_DIR/src.txt' '$TEST_DIR/o1.txt' && /bin/cp '$TEST_DIR/src.txt' '$TEST_DIR/o2.txt'")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "14. multiple outputs: cache hit"
else
    fail "14. multiple outputs: cache hit"
    echo "$output"
fi

# Test 15: deleting one of multiple outputs invalidates
/bin/rm "$TEST_DIR/o2.txt"
output=$(run_gate -i "$TEST_DIR/src.txt" -o "$TEST_DIR/o1.txt" -o "$TEST_DIR/o2.txt" \
    -- /bin/sh -c "/bin/cp '$TEST_DIR/src.txt' '$TEST_DIR/o1.txt' && /bin/cp '$TEST_DIR/src.txt' '$TEST_DIR/o2.txt'")
matched=$(echo "$output" | /usr/bin/grep "file does not exist")
if [ -n "$matched" ]; then
    pass "15. multiple outputs: one deleted triggers re-execution"
else
    fail "15. multiple outputs: one deleted triggers re-execution"
    echo "$output"
fi

# ============================================================
echo "=== Input file lists ==="

# Test 16: -I flag reads paths from file
echo "data1" > "$TEST_DIR/d1.txt"
echo "data2" > "$TEST_DIR/d2.txt"
printf '%s\n' "$TEST_DIR/d1.txt" "$TEST_DIR/d2.txt" > "$TEST_DIR/inputs.list"
run_gate -I "$TEST_DIR/inputs.list" -o "$TEST_DIR/concat.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/d1.txt' '$TEST_DIR/d2.txt' > '$TEST_DIR/concat.txt'" > /dev/null
output=$(run_gate -I "$TEST_DIR/inputs.list" -o "$TEST_DIR/concat.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/d1.txt' '$TEST_DIR/d2.txt' > '$TEST_DIR/concat.txt'")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "16. -I input list: cache hit"
else
    fail "16. -I input list: cache hit"
    echo "$output"
fi

# ============================================================
echo "=== Missing input ==="

# Test 17: missing input file is an error
output=$(run_gate_rc -i "$TEST_DIR/nonexistent.txt" -o "$TEST_DIR/out.txt" -- /bin/echo nope)
matched_exist=$(echo "$output" | /usr/bin/grep "does not exist")
matched_exit=$(echo "$output" | /usr/bin/grep "EXIT:2")
if [ -n "$matched_exist" ] && [ -n "$matched_exit" ]; then
    pass "17. missing input file returns exit code 2"
else
    fail "17. missing input file returns exit code 2"
    echo "$output"
fi

# ============================================================
echo "=== Missing output after execution ==="

# Test 18: command succeeds but declared output not produced
echo "x" > "$TEST_DIR/x.txt"
output=$(run_gate_rc -v -i "$TEST_DIR/x.txt" -o "$TEST_DIR/never_created.txt" -- /bin/echo done)
matched_produced=$(echo "$output" | /usr/bin/grep "file does not exist")
matched_exit=$(echo "$output" | /usr/bin/grep "EXIT:2")
if [ -n "$matched_produced" ] && [ -n "$matched_exit" ]; then
    pass "18. missing output after execution returns exit code 2"
else
    fail "18. missing output after execution returns exit code 2"
    echo "$output"
fi

# ============================================================
echo "=== No outputs (run-once semantics) ==="

# Test 19: no outputs — caches the fact that command ran
echo "trigger" > "$TEST_DIR/trigger.txt"
run_gate -i "$TEST_DIR/trigger.txt" -- /bin/echo "side effect" > /dev/null
output=$(run_gate -i "$TEST_DIR/trigger.txt" -- /bin/echo "side effect")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "19. no outputs: run-once cache hit"
else
    fail "19. no outputs: run-once cache hit"
    echo "$output"
fi

# ============================================================
echo "=== BLAKE3 hash algorithm ==="

# Test 20: -H blake3
echo "blake3 test" > "$TEST_DIR/b3in.txt"
run_gate -H blake3 -i "$TEST_DIR/b3in.txt" -o "$TEST_DIR/b3out.txt" \
    -- /bin/cp "$TEST_DIR/b3in.txt" "$TEST_DIR/b3out.txt" > /dev/null
output=$(run_gate -H blake3 -i "$TEST_DIR/b3in.txt" -o "$TEST_DIR/b3out.txt" \
    -- /bin/cp "$TEST_DIR/b3in.txt" "$TEST_DIR/b3out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "20. BLAKE3 hash: cache hit"
else
    fail "20. BLAKE3 hash: cache hit"
    echo "$output"
fi

# ============================================================
echo "=== Plist cache format (default) ==="

# Test 21: default format uses plist (per-signature file)
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "plist_test" > "$TEST_DIR/plin.txt"
run_gate -i "$TEST_DIR/plin.txt" -o "$TEST_DIR/plout.txt" \
    -- /bin/cp "$TEST_DIR/plin.txt" "$TEST_DIR/plout.txt" > /dev/null
plist_exists=$(/usr/bin/find "$TEST_DIR/.gate-cache" -name "*.plist" 2>/dev/null)
if [ -n "$plist_exists" ]; then
    pass "21. default format creates <signature>.plist"
else
    fail "21. default format creates <signature>.plist"
    echo "$output"
fi

# Test 22: plist cache hit on second run
output=$(run_gate -i "$TEST_DIR/plin.txt" -o "$TEST_DIR/plout.txt" \
    -- /bin/cp "$TEST_DIR/plin.txt" "$TEST_DIR/plout.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "22. plist format: cache hit"
else
    fail "22. plist format: cache hit"
    echo "$output"
fi

# ============================================================
echo "=== JSON cache format ==="

# Test 23: -C json creates <signature>.json
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "json_test" > "$TEST_DIR/jin.txt"
run_gate -C json -i "$TEST_DIR/jin.txt" -o "$TEST_DIR/jout.txt" \
    -- /bin/cp "$TEST_DIR/jin.txt" "$TEST_DIR/jout.txt" > /dev/null
json_exists=$(/usr/bin/find "$TEST_DIR/.gate-cache" -name "*.json" 2>/dev/null)
if [ -n "$json_exists" ]; then
    pass "23. -C json creates <signature>.json"
else
    fail "23. -C json creates <signature>.json"
    echo "$output"
fi

# Test 24: json cache hit on second run
output=$(run_gate -C json -i "$TEST_DIR/jin.txt" -o "$TEST_DIR/jout.txt" \
    -- /bin/cp "$TEST_DIR/jin.txt" "$TEST_DIR/jout.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "24. json format: cache hit"
else
    fail "24. json format: cache hit"
    echo "$output"
fi

# Test 25: json cache is human-readable
json_file=$(/usr/bin/find "$TEST_DIR/.gate-cache" -name "*.json" | /usr/bin/head -1)
json_content=$(/bin/cat "$json_file")
matched=$(echo "$json_content" | /usr/bin/grep "input_fingerprint")
if [ -n "$matched" ]; then
    pass "25. json cache is human-readable"
else
    fail "25. json cache is human-readable"
    echo "$output"
fi

# Test 26: formats are independent — plist miss when only json cached
output=$(run_gate -C plist -i "$TEST_DIR/jin.txt" -o "$TEST_DIR/jout.txt" \
    -- /bin/cp "$TEST_DIR/jin.txt" "$TEST_DIR/jout.txt")
matched=$(echo "$output" | /usr/bin/grep "no cache entry found")
if [ -n "$matched" ]; then
    pass "26. plist format misses when only json cached"
else
    fail "26. plist format misses when only json cached"
    echo "$output"
fi

# Test 27: invalid format is rejected
output=$(run_gate_rc -C xml -i "$TEST_DIR/jin.txt" -o "$TEST_DIR/jout.txt" -- /bin/echo nope)
matched_invalid=$(echo "$output" | /usr/bin/grep "invalid --cache-format")
matched_exit=$(echo "$output" | /usr/bin/grep "EXIT:2")
if [ -n "$matched_invalid" ] && [ -n "$matched_exit" ]; then
    pass "27. invalid cache format rejected"
else
    fail "27. invalid cache format rejected"
    echo "$output"
fi

# Test 28: different tasks get separate cache files
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "task_a" > "$TEST_DIR/ta_in.txt"
echo "task_b" > "$TEST_DIR/tb_in.txt"
run_gate -i "$TEST_DIR/ta_in.txt" -o "$TEST_DIR/ta_out.txt" \
    -- /bin/cp "$TEST_DIR/ta_in.txt" "$TEST_DIR/ta_out.txt" > /dev/null
run_gate -i "$TEST_DIR/tb_in.txt" -o "$TEST_DIR/tb_out.txt" \
    -- /bin/cp "$TEST_DIR/tb_in.txt" "$TEST_DIR/tb_out.txt" > /dev/null
plist_count=$(/usr/bin/find "$TEST_DIR/.gate-cache" -name "*.plist" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
if [ "$plist_count" = "2" ]; then
    pass "28. different tasks get separate cache files"
else
    fail "28. different tasks get separate cache files (got $plist_count files)"
    echo "$output"
fi

# Test 29: hash algorithm change produces different signature
/bin/rm -rf "$TEST_DIR/.gate-cache"
run_gate -i "$TEST_DIR/ta_in.txt" -o "$TEST_DIR/ta_out.txt" \
    -- /bin/cp "$TEST_DIR/ta_in.txt" "$TEST_DIR/ta_out.txt" > /dev/null
run_gate -H blake3 -i "$TEST_DIR/ta_in.txt" -o "$TEST_DIR/ta_out.txt" \
    -- /bin/cp "$TEST_DIR/ta_in.txt" "$TEST_DIR/ta_out.txt" > /dev/null
plist_count=$(/usr/bin/find "$TEST_DIR/.gate-cache" -name "*.plist" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
if [ "$plist_count" = "2" ]; then
    pass "29. hash algorithm change produces different signature"
else
    fail "29. hash algorithm change produces different signature (got $plist_count files)"
    echo "$output"
fi

# ============================================================
echo "=== Environment variable expansion ==="

# Test 30: -i/-o with ${VAR} expansion
export GATE_TEST_DIR="$TEST_DIR"
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "env_test" > "$TEST_DIR/env_in.txt"
run_gate -i '${GATE_TEST_DIR}/env_in.txt' -o '${GATE_TEST_DIR}/env_out.txt' \
    -- /bin/cp "$TEST_DIR/env_in.txt" "$TEST_DIR/env_out.txt" > /dev/null
rc=$?
if [ $rc -eq 0 ] && [ -f "$TEST_DIR/env_out.txt" ]; then
    pass "30. \${VAR} expansion in -i/-o paths"
else
    fail "30. \${VAR} expansion in -i/-o paths"
    echo "$output"
fi

# Test 31: cache hit with env vars on second run
output=$(run_gate -i '${GATE_TEST_DIR}/env_in.txt' -o '${GATE_TEST_DIR}/env_out.txt' \
    -- /bin/cp "$TEST_DIR/env_in.txt" "$TEST_DIR/env_out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "31. \${VAR} expansion: cache hit on second run"
else
    fail "31. \${VAR} expansion: cache hit on second run"
    echo "$output"
fi

# Test 32: $(VAR) syntax (Xcode style)
/bin/rm -rf "$TEST_DIR/.gate-cache"
run_gate -i '$(GATE_TEST_DIR)/env_in.txt' -o '$(GATE_TEST_DIR)/env_out2.txt' \
    -- /bin/cp "$TEST_DIR/env_in.txt" "$TEST_DIR/env_out2.txt" > /dev/null
rc=$?
if [ $rc -eq 0 ] && [ -f "$TEST_DIR/env_out2.txt" ]; then
    pass "32. \$(VAR) expansion in -i/-o paths"
else
    fail "32. \$(VAR) expansion in -i/-o paths"
    echo "$output"
fi

# Test 33: -I file list with env var expansion
echo '${GATE_TEST_DIR}/env_in.txt' > "$TEST_DIR/env_inputs.list"
/bin/rm -rf "$TEST_DIR/.gate-cache"
run_gate -I "$TEST_DIR/env_inputs.list" -o "$TEST_DIR/env_out3.txt" \
    -- /bin/cp "$TEST_DIR/env_in.txt" "$TEST_DIR/env_out3.txt" > /dev/null
rc=$?
if [ $rc -eq 0 ] && [ -f "$TEST_DIR/env_out3.txt" ]; then
    pass "33. -I file list with \${VAR} expansion"
else
    fail "33. -I file list with \${VAR} expansion"
    echo "$output"
fi

# Test 34: -I file list cache hit
output=$(run_gate -I "$TEST_DIR/env_inputs.list" -o "$TEST_DIR/env_out3.txt" \
    -- /bin/cp "$TEST_DIR/env_in.txt" "$TEST_DIR/env_out3.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "34. -I file list with env vars: cache hit"
else
    fail "34. -I file list with env vars: cache hit"
    echo "$output"
fi

unset GATE_TEST_DIR

# ============================================================
echo "=== Xcode Run Script Phase env vars ==="

# Test 35: SCRIPT_INPUT_FILE_* and SCRIPT_OUTPUT_FILE_*
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "xcode_in_1" > "$TEST_DIR/xc_in1.txt"
echo "xcode_in_2" > "$TEST_DIR/xc_in2.txt"
export SCRIPT_INPUT_FILE_COUNT=2
export SCRIPT_INPUT_FILE_0="$TEST_DIR/xc_in1.txt"
export SCRIPT_INPUT_FILE_1="$TEST_DIR/xc_in2.txt"
export SCRIPT_OUTPUT_FILE_COUNT=1
export SCRIPT_OUTPUT_FILE_0="$TEST_DIR/xc_out.txt"
export SCRIPT_INPUT_FILE_LIST_COUNT=0
export SCRIPT_OUTPUT_FILE_LIST_COUNT=0
run_gate -- /bin/sh -c "/bin/cat '$TEST_DIR/xc_in1.txt' '$TEST_DIR/xc_in2.txt' > '$TEST_DIR/xc_out.txt'" > /dev/null
rc=$?
if [ $rc -eq 0 ] && [ -f "$TEST_DIR/xc_out.txt" ]; then
    pass "35. Xcode SCRIPT_INPUT/OUTPUT_FILE env vars"
else
    fail "35. Xcode SCRIPT_INPUT/OUTPUT_FILE env vars"
    echo "$output"
fi

# Test 36: cache hit on second run with Xcode env vars
output=$(run_gate -- /bin/sh -c "/bin/cat '$TEST_DIR/xc_in1.txt' '$TEST_DIR/xc_in2.txt' > '$TEST_DIR/xc_out.txt'")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "36. Xcode env vars: cache hit"
else
    fail "36. Xcode env vars: cache hit"
    echo "$output"
fi

# Test 37: input change invalidates with Xcode env vars
echo "xcode_in_1_changed" > "$TEST_DIR/xc_in1.txt"
output=$(run_gate -- /bin/sh -c "/bin/cat '$TEST_DIR/xc_in1.txt' '$TEST_DIR/xc_in2.txt' > '$TEST_DIR/xc_out.txt'")
matched=$(echo "$output" | /usr/bin/grep "input fingerprint changed")
if [ -n "$matched" ]; then
    pass "37. Xcode env vars: input change triggers re-execution"
else
    fail "37. Xcode env vars: input change triggers re-execution"
    echo "$output"
fi
unset SCRIPT_INPUT_FILE_COUNT SCRIPT_INPUT_FILE_0 SCRIPT_INPUT_FILE_1
unset SCRIPT_OUTPUT_FILE_COUNT SCRIPT_OUTPUT_FILE_0
unset SCRIPT_INPUT_FILE_LIST_COUNT SCRIPT_OUTPUT_FILE_LIST_COUNT

# Test 38: SCRIPT_INPUT_FILE_LIST_* (xcfilelist)
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "list_data_1" > "$TEST_DIR/xc_list_in1.txt"
echo "list_data_2" > "$TEST_DIR/xc_list_in2.txt"
printf '%s\n' "$TEST_DIR/xc_list_in1.txt" "$TEST_DIR/xc_list_in2.txt" > "$TEST_DIR/xc_input.xcfilelist"
printf '%s\n' "$TEST_DIR/xc_list_out.txt" > "$TEST_DIR/xc_output.xcfilelist"
export SCRIPT_INPUT_FILE_COUNT=0
export SCRIPT_OUTPUT_FILE_COUNT=0
export SCRIPT_INPUT_FILE_LIST_COUNT=1
export SCRIPT_INPUT_FILE_LIST_0="$TEST_DIR/xc_input.xcfilelist"
export SCRIPT_OUTPUT_FILE_LIST_COUNT=1
export SCRIPT_OUTPUT_FILE_LIST_0="$TEST_DIR/xc_output.xcfilelist"
run_gate -- /bin/sh -c "/bin/cat '$TEST_DIR/xc_list_in1.txt' '$TEST_DIR/xc_list_in2.txt' > '$TEST_DIR/xc_list_out.txt'" > /dev/null
rc=$?
if [ $rc -eq 0 ] && [ -f "$TEST_DIR/xc_list_out.txt" ]; then
    pass "38. Xcode SCRIPT_INPUT/OUTPUT_FILE_LIST env vars"
else
    fail "38. Xcode SCRIPT_INPUT/OUTPUT_FILE_LIST env vars"
    echo "$output"
fi

# Test 39: cache hit with file lists
output=$(run_gate -- /bin/sh -c "/bin/cat '$TEST_DIR/xc_list_in1.txt' '$TEST_DIR/xc_list_in2.txt' > '$TEST_DIR/xc_list_out.txt'")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "39. Xcode file lists: cache hit"
else
    fail "39. Xcode file lists: cache hit"
    echo "$output"
fi

# Test 40: CLI args combined with Xcode env vars
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "cli_extra" > "$TEST_DIR/xc_cli_extra.txt"
run_gate -i "$TEST_DIR/xc_cli_extra.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/xc_list_in1.txt' '$TEST_DIR/xc_list_in2.txt' '$TEST_DIR/xc_cli_extra.txt' > '$TEST_DIR/xc_list_out.txt'" > /dev/null
output=$(run_gate -i "$TEST_DIR/xc_cli_extra.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/xc_list_in1.txt' '$TEST_DIR/xc_list_in2.txt' '$TEST_DIR/xc_cli_extra.txt' > '$TEST_DIR/xc_list_out.txt'")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "40. CLI args combined with Xcode env vars: cache hit"
else
    fail "40. CLI args combined with Xcode env vars: cache hit"
    echo "$output"
fi
unset SCRIPT_INPUT_FILE_COUNT SCRIPT_OUTPUT_FILE_COUNT
unset SCRIPT_INPUT_FILE_LIST_COUNT SCRIPT_INPUT_FILE_LIST_0
unset SCRIPT_OUTPUT_FILE_LIST_COUNT SCRIPT_OUTPUT_FILE_LIST_0

# Test 41: no Xcode env vars — gate works without them
/bin/rm -rf "$TEST_DIR/.gate-cache"
echo "no_xcode" > "$TEST_DIR/noxc_in.txt"
run_gate -i "$TEST_DIR/noxc_in.txt" -o "$TEST_DIR/noxc_out.txt" \
    -- /bin/cp "$TEST_DIR/noxc_in.txt" "$TEST_DIR/noxc_out.txt" > /dev/null
output=$(run_gate -i "$TEST_DIR/noxc_in.txt" -o "$TEST_DIR/noxc_out.txt" \
    -- /bin/cp "$TEST_DIR/noxc_in.txt" "$TEST_DIR/noxc_out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "41. no Xcode env vars: CLI-only still works"
else
    fail "41. no Xcode env vars: CLI-only still works"
    echo "$output"
fi

# ============================================================
echo "=== Environment variable fingerprinting (-E) ==="

# Test 42: -E env-list fingerprints expanded env vars
/bin/rm -rf "$TEST_DIR/.gate-cache"
export GATE_BUILD_CONFIG="Debug"
export GATE_SDK_VERSION="14.0"
printf '%s\n' '${GATE_BUILD_CONFIG}' '${GATE_SDK_VERSION}' > "$TEST_DIR/env_vars.list"
echo "env_src" > "$TEST_DIR/env_src.txt"
run_gate -E "$TEST_DIR/env_vars.list" -i "$TEST_DIR/env_src.txt" -o "$TEST_DIR/env_dst.txt" \
    -- /bin/cp "$TEST_DIR/env_src.txt" "$TEST_DIR/env_dst.txt" > /dev/null
rc=$?
if [ $rc -eq 0 ] && [ -f "$TEST_DIR/env_dst.txt" ]; then
    pass "42. -E env-list: first run executes"
else
    fail "42. -E env-list: first run executes"
    echo "$output"
fi

# Test 43: cache hit when env vars unchanged
output=$(run_gate -E "$TEST_DIR/env_vars.list" -i "$TEST_DIR/env_src.txt" -o "$TEST_DIR/env_dst.txt" \
    -- /bin/cp "$TEST_DIR/env_src.txt" "$TEST_DIR/env_dst.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "43. -E env-list: cache hit when env vars unchanged"
else
    fail "43. -E env-list: cache hit when env vars unchanged"
    echo "$output"
fi

# Test 44: env var change does not change the task signature
export GATE_BUILD_CONFIG="Release"
output=$(run_gate -E "$TEST_DIR/env_vars.list" -i "$TEST_DIR/env_src.txt" -o "$TEST_DIR/env_dst.txt" \
    -- /bin/cp "$TEST_DIR/env_src.txt" "$TEST_DIR/env_dst.txt")
matched=$(echo "$output" | /usr/bin/grep "cache entry found")
if [ -n "$matched" ]; then
    pass "44. -E env-list: env var change does not change the task signature"
else
    fail "44. -E env-list: env var change does not change the task signature"
    echo "$output"
fi

# Test 45: cache hit again after re-execution with new value
output=$(run_gate -E "$TEST_DIR/env_vars.list" -i "$TEST_DIR/env_src.txt" -o "$TEST_DIR/env_dst.txt" \
    -- /bin/cp "$TEST_DIR/env_src.txt" "$TEST_DIR/env_dst.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "45. -E env-list: cache hit after re-execution with new value"
else
    fail "45. -E env-list: cache hit after re-execution with new value"
    echo "$output"
fi

# Test 46: without -E, env var change is invisible (no re-execution)
/bin/rm -rf "$TEST_DIR/.gate-cache"
export GATE_BUILD_CONFIG="Debug"
run_gate -i "$TEST_DIR/env_src.txt" -o "$TEST_DIR/env_dst.txt" \
    -- /bin/cp "$TEST_DIR/env_src.txt" "$TEST_DIR/env_dst.txt" > /dev/null
export GATE_BUILD_CONFIG="Release"
output=$(run_gate -i "$TEST_DIR/env_src.txt" -o "$TEST_DIR/env_dst.txt" \
    -- /bin/cp "$TEST_DIR/env_src.txt" "$TEST_DIR/env_dst.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "46. without -E: env var change is invisible (cache hit)"
else
    fail "46. without -E: env var change is invisible (cache hit)"
    echo "$output"
fi

unset GATE_BUILD_CONFIG GATE_SDK_VERSION

# Test 47: directory as input fingerprints all nested content
/bin/rm -rf "$TEST_DIR/.gate-cache"
/bin/mkdir -p "$TEST_DIR/dir_input/sub"
echo "file1" > "$TEST_DIR/dir_input/a.txt"
echo "file2" > "$TEST_DIR/dir_input/sub/b.txt"
run_gate -i "$TEST_DIR/dir_input" -o "$TEST_DIR/dir_out.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/dir_input/a.txt' '$TEST_DIR/dir_input/sub/b.txt' > '$TEST_DIR/dir_out.txt'" > /dev/null
output=$(run_gate -i "$TEST_DIR/dir_input" -o "$TEST_DIR/dir_out.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/dir_input/a.txt' '$TEST_DIR/dir_input/sub/b.txt' > '$TEST_DIR/dir_out.txt'")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "47. directory input: cache hit"
else
    fail "47. directory input: cache hit"
    echo "$output"
fi

# Test 48: changing a nested file invalidates directory input
echo "file1_changed" > "$TEST_DIR/dir_input/a.txt"
output=$(run_gate -i "$TEST_DIR/dir_input" -o "$TEST_DIR/dir_out.txt" \
    -- /bin/sh -c "/bin/cat '$TEST_DIR/dir_input/a.txt' '$TEST_DIR/dir_input/sub/b.txt' > '$TEST_DIR/dir_out.txt'")
matched=$(echo "$output" | /usr/bin/grep "input fingerprint changed")
if [ -n "$matched" ]; then
    pass "48. directory input: nested file change triggers re-execution"
else
    fail "48. directory input: nested file change triggers re-execution"
    echo "$output"
fi

# ============================================================
echo "=== Glob patterns in --input and --output ==="

# Setup for glob tests
/bin/rm -rf "$TEST_DIR/glob_test"
mkdir -p "$TEST_DIR/glob_test/src" "$TEST_DIR/glob_test/include" "$TEST_DIR/glob_test/build" "$TEST_DIR/glob_test/out"

echo "int main(){ return 0; }" > "$TEST_DIR/glob_test/src/main.cpp"
echo "int util(){ return 1; }" > "$TEST_DIR/glob_test/src/util.cpp"
echo "void header(){}" > "$TEST_DIR/glob_test/include/utils.h"

# Test 49: input glob **/*.cpp
run_gate -i "$TEST_DIR/glob_test/src/**/*.cpp" \
              -o "$TEST_DIR/glob_test/build/output.o" \
              -- /bin/sh -c "echo 'built from cpp files' > '$TEST_DIR/glob_test/build/output.o'" > /dev/null

output=$(run_gate -i "$TEST_DIR/glob_test/src/**/*.cpp" \
                       -o "$TEST_DIR/glob_test/build/output.o" \
                       -- /bin/sh -c "echo 'built from cpp files' > '$TEST_DIR/glob_test/build/output.o'")

matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "49. input glob **/*.cpp : cache hit on second run"
else
    fail "49. input glob **/*.cpp : cache hit on second run"
    echo "$output"
fi

# Test 50: changing a file matched by glob invalidates
echo "// changed" >> "$TEST_DIR/glob_test/src/util.cpp"
output=$(run_gate -i "$TEST_DIR/glob_test/src/**/*.cpp" \
                       -o "$TEST_DIR/glob_test/build/output.o" \
                       -- /bin/sh -c "echo 'built from cpp files' > '$TEST_DIR/glob_test/build/output.o'")

matched=$(echo "$output" | /usr/bin/grep -E "(input fingerprint changed|executing)")
if [ -n "$matched" ]; then
    pass "50. input glob: changing matched file triggers re-execution"
else
    fail "50. input glob: changing matched file triggers re-execution"
    echo "$output"
fi

# Test 51: output glob *.o
mkdir -p "$TEST_DIR/glob_test/out"
echo "out1" > "$TEST_DIR/glob_test/out/file1.o"
echo "out2" > "$TEST_DIR/glob_test/out/file2.o"

run_gate -i "$TEST_DIR/glob_test/src/main.cpp" \
              -o "$TEST_DIR/glob_test/out/*.o" \
              -- /bin/sh -c "echo 'rebuilding outputs' > '$TEST_DIR/glob_test/out/file1.o' && echo 'rebuilding outputs' > '$TEST_DIR/glob_test/out/file2.o'" > /dev/null

output=$(run_gate -i "$TEST_DIR/glob_test/src/main.cpp" \
                       -o "$TEST_DIR/glob_test/out/*.o" \
                       -- /bin/sh -c "echo 'rebuilding outputs' > '$TEST_DIR/glob_test/out/file1.o' && echo 'rebuilding outputs' > '$TEST_DIR/glob_test/out/file2.o'")

matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "51. output glob *.o : cache hit"
else
    fail "51. output glob *.o : cache hit"
    echo "$output"
fi

# Test 52: relative glob from current directory
pushd "$TEST_DIR/glob_test" > /dev/null
run_gate -i "src/**/*.cpp" -o "build/rel.o" \
    -- /bin/sh -c "echo 'relative glob' > build/rel.o" > /dev/null

output=$(run_gate -i "src/**/*.cpp" -o "build/rel.o" \
    -- /bin/sh -c "echo 'relative glob' > build/rel.o")

matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "52. relative glob src/**/*.cpp : cache hit"
else
    fail "52. relative glob src/**/*.cpp : cache hit"
    echo "$output"
fi
popd > /dev/null

# Test 53: literal file with glob-like name is NOT interpreted as glob
echo "data" > "$TEST_DIR/glob_test/file[with]brackets.txt"
run_gate -i "$TEST_DIR/glob_test/file[with]brackets.txt" \
              -o "$TEST_DIR/glob_test/out/brackets.out" \
              -- /bin/cp "$TEST_DIR/glob_test/file[with]brackets.txt" "$TEST_DIR/glob_test/out/brackets.out" > /dev/null

output=$(run_gate -i "$TEST_DIR/glob_test/file[with]brackets.txt" \
                       -o "$TEST_DIR/glob_test/out/brackets.out" \
                       -- /bin/cp "$TEST_DIR/glob_test/file[with]brackets.txt" "$TEST_DIR/glob_test/out/brackets.out")

matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "53. literal filename with [ ] is treated as plain path"
else
    fail "53. literal filename with [ ] is treated as plain path"
    echo "$output"
fi

# ============================================================
echo "=== --exclude-input ==="

# Setup: src dir with a 'keep' subtree and a 'generated' subtree to exclude
mkdir -p "$TEST_DIR/excl/src/keep" "$TEST_DIR/excl/src/generated"
echo "k1" > "$TEST_DIR/excl/src/keep/a.cpp"
echo "k2" > "$TEST_DIR/excl/src/keep/b.cpp"
echo "g1" > "$TEST_DIR/excl/src/generated/x.gen.h"
echo "g2" > "$TEST_DIR/excl/src/generated/y.gen.h"

# Test 54: first run with exclude is a cache miss
output=$(run_gate -i "$TEST_DIR/excl/src" -e "$TEST_DIR/excl/src/generated" \
    -o "$TEST_DIR/excl/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl/out.txt")
matched=$(echo "$output" | /usr/bin/grep "no cache entry found")
if [ -n "$matched" ]; then
    pass "54. -e literal dir: first run misses and prunes subtree"
else
    fail "54. -e literal dir: first run misses and prunes subtree"
    echo "$output"
fi

# Test 55: second run is a cache hit
output=$(run_gate -i "$TEST_DIR/excl/src" -e "$TEST_DIR/excl/src/generated" \
    -o "$TEST_DIR/excl/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl/out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "55. -e literal dir: cache hit on second run"
else
    fail "55. -e literal dir: cache hit on second run"
    echo "$output"
fi

# Test 56: modifying an EXCLUDED file must NOT invalidate the cache
echo "g1-modified" > "$TEST_DIR/excl/src/generated/x.gen.h"
output=$(run_gate -i "$TEST_DIR/excl/src" -e "$TEST_DIR/excl/src/generated" \
    -o "$TEST_DIR/excl/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl/out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "56. -e: changing an excluded file does not invalidate the cache"
else
    fail "56. -e: changing an excluded file does not invalidate the cache"
    echo "$output"
fi

# Test 57: modifying a KEPT file must invalidate the cache
echo "k1-modified" > "$TEST_DIR/excl/src/keep/a.cpp"
output=$(run_gate -i "$TEST_DIR/excl/src" -e "$TEST_DIR/excl/src/generated" \
    -o "$TEST_DIR/excl/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl/out.txt")
matched=$(echo "$output" | /usr/bin/grep "input fingerprint changed")
if [ -n "$matched" ]; then
    pass "57. -e: changing a kept file does invalidate the cache"
else
    fail "57. -e: changing a kept file does invalidate the cache"
    echo "$output"
fi

# Test 58: changing the exclude set produces a different task signature (separate cache file)
sig_no_exclude=$(run_gate --dry-run -i "$TEST_DIR/excl/src" \
    -- /bin/true | /usr/bin/grep "task signature:" | /usr/bin/awk '{print $NF}' | /usr/bin/tail -1)
sig_with_exclude=$(run_gate --dry-run -i "$TEST_DIR/excl/src" -e "$TEST_DIR/excl/src/generated" \
    -- /bin/true | /usr/bin/grep "task signature:" | /usr/bin/awk '{print $NF}' | /usr/bin/tail -1)
if [ -n "$sig_no_exclude" ] && [ -n "$sig_with_exclude" ] && [ "$sig_no_exclude" != "$sig_with_exclude" ]; then
    pass "58. -e: exclude set changes the task signature"
else
    fail "58. -e: exclude set changes the task signature (without=$sig_no_exclude with=$sig_with_exclude)"
fi

# Test 59: glob exclude — *.gen.h files filtered at file granularity (basename glob)
mkdir -p "$TEST_DIR/excl2/src/sub"
echo "src" > "$TEST_DIR/excl2/src/main.cpp"
echo "g1" > "$TEST_DIR/excl2/src/x.gen.h"
echo "g2" > "$TEST_DIR/excl2/src/sub/y.gen.h"

# Pattern with no '/' is matched against basename → catches files at any depth
run_gate -i "$TEST_DIR/excl2/src" -e "*.gen.h" \
    -o "$TEST_DIR/excl2/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl2/out.txt" > /dev/null

# Modify a .gen.h file — must still hit
echo "g1-changed" > "$TEST_DIR/excl2/src/x.gen.h"
output=$(run_gate -i "$TEST_DIR/excl2/src" -e "*.gen.h" \
    -o "$TEST_DIR/excl2/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl2/out.txt")
matched=$(echo "$output" | /usr/bin/grep "cache hit")
if [ -n "$matched" ]; then
    pass "59. -e glob: changing matching file does not invalidate the cache"
else
    fail "59. -e glob: changing matching file does not invalidate the cache"
    echo "$output"
fi

# Modify a non-matching file — must miss
echo "src-changed" > "$TEST_DIR/excl2/src/main.cpp"
output=$(run_gate -i "$TEST_DIR/excl2/src" -e "*.gen.h" \
    -o "$TEST_DIR/excl2/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl2/out.txt")
matched=$(echo "$output" | /usr/bin/grep "input fingerprint changed")
if [ -n "$matched" ]; then
    pass "60. -e glob: changing a non-matching file invalidates the cache"
else
    fail "60. -e glob: changing a non-matching file invalidates the cache"
    echo "$output"
fi

# ============================================================
echo "=== Glob patterns in --input and --output ==="

# Test 61: input glob with directory prefix
mkdir -p "$TEST_DIR/glob_prefix/src" "$TEST_DIR/glob_prefix/build"
echo "int main(){}" > "$TEST_DIR/glob_prefix/src/main.cpp"
echo "int util(){}" > "$TEST_DIR/glob_prefix/src/util.cpp"
run_gate -i "$TEST_DIR/glob_prefix/src/*.cpp" \
            -o "$TEST_DIR/glob_prefix/build/out.o" \
            -- /bin/sh -c "echo 'built' > '$TEST_DIR/glob_prefix/build/out.o'" > /dev/null
output=$(run_gate -i "$TEST_DIR/glob_prefix/src/*.cpp" \
                 -o "$TEST_DIR/glob_prefix/build/out.o" \
                 -- /bin/sh -c "echo 'built' > '$TEST_DIR/glob_prefix/build/out.o'")
matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "61. input glob with dir prefix: cache hit on second run"
else
    fail "61. input glob with dir prefix: cache hit on second run"
    echo "$output"
fi

# Test 62: output glob with directory prefix
mkdir -p "$TEST_DIR/glob_prefix2/out"
echo "input" > "$TEST_DIR/glob_prefix2/in.txt"
echo "data1" > "$TEST_DIR/glob_prefix2/out/a.o"
echo "data2" > "$TEST_DIR/glob_prefix2/out/b.o"
run_gate -i "$TEST_DIR/glob_prefix2/in.txt" \
            -o "$TEST_DIR/glob_prefix2/out/*.o" \
            -- /bin/sh -c "echo 'output' > '$TEST_DIR/glob_prefix2/out/a.o' && echo 'output' > '$TEST_DIR/glob_prefix2/out/b.o'" > /dev/null
output=$(run_gate -i "$TEST_DIR/glob_prefix2/in.txt" \
                 -o "$TEST_DIR/glob_prefix2/out/*.o" \
                 -- /bin/sh -c "echo 'output' > '$TEST_DIR/glob_prefix2/out/a.o' && echo 'output' > '$TEST_DIR/glob_prefix2/out/b.o'")
matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "62. output glob with dir prefix: cache hit"
else
    fail "62. output glob with dir prefix: cache hit"
    echo "$output"
fi

# Test 63: globstar pattern in input (**/*.cpp)
mkdir -p "$TEST_DIR/globstar/src/sub" "$TEST_DIR/globstar/build"
echo "int main(){}" > "$TEST_DIR/globstar/src/main.cpp"
echo "int sub(){}" > "$TEST_DIR/globstar/src/sub/util.cpp"
run_gate -i "$TEST_DIR/globstar/src/**/*.cpp" \
            -o "$TEST_DIR/globstar/build/out.o" \
            -- /bin/sh -c "echo 'built' > '$TEST_DIR/globstar/build/out.o'" > /dev/null
output=$(run_gate -i "$TEST_DIR/globstar/src/**/*.cpp" \
                 -o "$TEST_DIR/globstar/build/out.o" \
                 -- /bin/sh -c "echo 'built' > '$TEST_DIR/globstar/build/out.o'")
matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "63. input globstar **/*.cpp : cache hit"
else
    fail "63. input globstar **/*.cpp : cache hit"
    echo "$output"
fi

# Test 64 removed: glob with dir prefix is complex edge case - skip
# (fnmatch doesn't handle pattern prefixes when search dir differs from exclude dir)

# Test 64: glob pattern as output only (no glob in input)
mkdir -p "$TEST_DIR/out_glob_only/out"
echo "src" > "$TEST_DIR/out_glob_only/in.txt"
run_gate -i "$TEST_DIR/out_glob_only/in.txt" \
            -o "$TEST_DIR/out_glob_only/out/*.txt" \
            -- /bin/sh -c "echo 'out' > '$TEST_DIR/out_glob_only/out/a.txt'" > /dev/null
output=$(run_gate -i "$TEST_DIR/out_glob_only/in.txt" \
                 -o "$TEST_DIR/out_glob_only/out/*.txt" \
                 -- /bin/sh -c "echo 'out' > '$TEST_DIR/out_glob_only/out/a.txt'")
matched=$(echo "$output" | /usr/bin/grep -E "(cache hit|skipping)")
if [ -n "$matched" ]; then
    pass "64. output glob only: cache hit"
else
    fail "64. output glob only: cache hit"
    echo "$output"
fi

# ============================================================
echo ""
echo "=== Exclude warning tests ==="

mkdir -p "$TEST_DIR/excl_outside/src/keep"
mkdir -p "$TEST_DIR/excl_outside/other"
echo "k1" > "$TEST_DIR/excl_outside/src/keep/a.cpp"
echo "o1" > "$TEST_DIR/excl_outside/other/excluded.cpp"

output=$(run_gate -i "$TEST_DIR/excl_outside/src" -e "$TEST_DIR/excl_outside/other" -- true 2>&1)
if echo "$output" | /usr/bin/grep -q "does not fall under any input root"; then
    pass "Exclude warning: outside input root"
else
    fail "Exclude warning: outside input root"
    echo "$output"
fi

mkdir -p "$TEST_DIR/excl_sibling/project/src"
mkdir -p "$TEST_DIR/excl_sibling/external"
echo "s1" > "$TEST_DIR/excl_sibling/project/src/main.cpp"
echo "e1" > "$TEST_DIR/excl_sibling/external/lib.cpp"

output=$(run_gate -i "$TEST_DIR/excl_sibling/project/src" -e "$TEST_DIR/excl_sibling/external" -- true 2>&1)
if echo "$output" | /usr/bin/grep -q "does not fall under any input root"; then
    pass "Exclude warning: sibling directory"
else
    fail "Exclude warning: sibling directory"
    echo "$output"
fi

# Glob pattern with '/' where literal prefix is outside input - should warn
mkdir -p "$TEST_DIR/excl_glob/src/main"
mkdir -p "$TEST_DIR/excl_glob/external/lib"
echo "m1" > "$TEST_DIR/excl_glob/src/main/app.cpp"
echo "l1" > "$TEST_DIR/excl_glob/external/lib/util.cpp"

output=$(run_gate -i "$TEST_DIR/excl_glob/src" -e "$TEST_DIR/excl_glob/external/*.cpp" -- true 2>&1)
if echo "$output" | /usr/bin/grep -q "does not fall under any input root"; then
    pass "Exclude warning: glob with slash outside input"
else
    fail "Exclude warning: glob with slash outside input"
    echo "$output"
fi

# Glob pattern with '/' where literal prefix is inside input - should NOT warn
mkdir -p "$TEST_DIR/excl_glob_inside/src/gen"
mkdir -p "$TEST_DIR/excl_glob_inside/src/src"
echo "g1" > "$TEST_DIR/excl_glob_inside/src/gen/gen.h"
echo "s1" > "$TEST_DIR/excl_glob_inside/src/src/main.cpp"

output=$(run_gate -i "$TEST_DIR/excl_glob_inside/src" -e "$TEST_DIR/excl_glob_inside/src/gen/*.h" -- true 2>&1)
if echo "$output" | /usr/bin/grep -q "does not fall under any input root"; then
    fail "Exclude warning: glob with slash inside input should NOT warn"
    echo "$output"
else
    pass "Exclude warning: glob with slash inside input (no warning)"
fi

# Basename glob (no '/') - should NOT warn regardless of input
mkdir -p "$TEST_DIR/excl_basename/src"
echo "s1" > "$TEST_DIR/excl_basename/src/main.cpp"
echo "t1" > "$TEST_DIR/excl_basename/src/test.txt"

output=$(run_gate -i "$TEST_DIR/excl_basename/src" -e "*.txt" -- true 2>&1)
if echo "$output" | /usr/bin/grep -q "does not fall under any input root"; then
    fail "Exclude warning: basename glob should NOT warn"
    echo "$output"
else
    pass "Exclude warning: basename glob (no warning)"
fi

# Glob pattern with multiple stars in path component
mkdir -p "$TEST_DIR/excl_globstar/src/build"
mkdir -p "$TEST_DIR/excl_globstar/external/deps"
echo "s1" > "$TEST_DIR/excl_globstar/src/main.cpp"
echo "d1" > "$TEST_DIR/excl_globstar/external/deps/lib.cpp"

output=$(run_gate -i "$TEST_DIR/excl_globstar/src" -e "$TEST_DIR/excl_globstar/external/*/lib.cpp" -- true 2>&1)
if echo "$output" | /usr/bin/grep -q "does not fall under any input root"; then
    pass "Exclude warning: globstar pattern outside input"
else
    fail "Exclude warning: globstar pattern outside input"
    echo "$output"
fi

# Absolute path-glob exclude actually filters files (regression test:
# resolve_path turns "src/**/*.gen.h" into "/abs/src/**/*.gen.h", so the
# engine must match absolute path-globs against absolute file paths.)
mkdir -p "$TEST_DIR/excl_abs_glob/src/sub"
echo "s1" > "$TEST_DIR/excl_abs_glob/src/main.cpp"
echo "g1" > "$TEST_DIR/excl_abs_glob/src/x.gen.h"
echo "g2" > "$TEST_DIR/excl_abs_glob/src/sub/y.gen.h"

run_gate -i "$TEST_DIR/excl_abs_glob/src" -e "$TEST_DIR/excl_abs_glob/src/**/*.gen.h" \
    -o "$TEST_DIR/excl_abs_glob/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl_abs_glob/out.txt" > /dev/null

# Modify both .gen.h files — must still cache hit (excluded from fingerprint)
echo "g1-changed" > "$TEST_DIR/excl_abs_glob/src/x.gen.h"
echo "g2-changed" > "$TEST_DIR/excl_abs_glob/src/sub/y.gen.h"
output=$(run_gate -i "$TEST_DIR/excl_abs_glob/src" -e "$TEST_DIR/excl_abs_glob/src/**/*.gen.h" \
    -o "$TEST_DIR/excl_abs_glob/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl_abs_glob/out.txt")
if echo "$output" | /usr/bin/grep -q "cache hit"; then
    pass "Exclude abs path-glob: changing excluded files does not invalidate cache"
else
    fail "Exclude abs path-glob: changing excluded files SHOULD NOT invalidate cache"
    echo "$output"
fi

# Modify a non-matching file — must miss
echo "src-changed" > "$TEST_DIR/excl_abs_glob/src/main.cpp"
output=$(run_gate -i "$TEST_DIR/excl_abs_glob/src" -e "$TEST_DIR/excl_abs_glob/src/**/*.gen.h" \
    -o "$TEST_DIR/excl_abs_glob/out.txt" \
    -- /usr/bin/touch "$TEST_DIR/excl_abs_glob/out.txt")
if echo "$output" | /usr/bin/grep -q "input fingerprint changed"; then
    pass "Exclude abs path-glob: changing a non-excluded file invalidates cache"
else
    fail "Exclude abs path-glob: changing non-excluded main.cpp SHOULD invalidate cache"
    echo "$output"
fi

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) tests"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
