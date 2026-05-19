#!/bin/bash

# ============================================================================
# Fingerprint -r / --regex tests and invalid-option error paths
# ============================================================================
# Sourced by test_fingerprint.sh which defines: FINGERPRINT_BIN, TEST_DIR,
# log_test, log_pass, log_fail, assert_contains, assert_equal, assert_not_equal,
# output_contains, output_not_contains

# ============================================================================
# Test: basic ECMAScript regex pattern
# ============================================================================
test_regex_basic_pattern() {
    log_test "Regex basic pattern matching"

    /bin/mkdir -p "$TEST_DIR/regex_basic"
    echo "cpp" > "$TEST_DIR/regex_basic/main.cpp"
    echo "h"   > "$TEST_DIR/regex_basic/header.h"
    echo "txt" > "$TEST_DIR/regex_basic/readme.txt"

    local output
    output=$(${FINGERPRINT_BIN} -l -r '.*\.cpp' "$TEST_DIR/regex_basic" 2>&1)

    assert_contains "$output" "main.cpp" "Regex .*\\.cpp should match main.cpp"

    if output_not_contains "$output" "readme.txt"; then
        log_pass "Regex .*\\.cpp correctly excludes readme.txt"
    else
        log_fail "Regex .*\\.cpp should not match readme.txt"
    fi

    if output_not_contains "$output" "header.h"; then
        log_pass "Regex .*\\.cpp correctly excludes header.h"
    else
        log_fail "Regex .*\\.cpp should not match header.h"
    fi
}

# ============================================================================
# Test: ECMAScript alternation group  .*\.(h|cpp)
# ============================================================================
test_regex_alternation() {
    log_test "Regex alternation pattern"

    /bin/mkdir -p "$TEST_DIR/regex_alt"
    echo "cpp"  > "$TEST_DIR/regex_alt/source.cpp"
    echo "h"    > "$TEST_DIR/regex_alt/header.h"
    echo "txt"  > "$TEST_DIR/regex_alt/notes.txt"
    echo "json" > "$TEST_DIR/regex_alt/config.json"

    local output
    output=$(${FINGERPRINT_BIN} -l -r '.*\.(h|cpp)' "$TEST_DIR/regex_alt" 2>&1)

    assert_contains "$output" "source.cpp" "Alternation should match .cpp"
    assert_contains "$output" "header.h"   "Alternation should match .h"

    if output_not_contains "$output" "notes.txt"; then
        log_pass "Alternation correctly excludes .txt"
    else
        log_fail "Alternation should not match .txt"
    fi

    if output_not_contains "$output" "config.json"; then
        log_pass "Alternation correctly excludes .json"
    else
        log_fail "Alternation should not match .json"
    fi
}

# ============================================================================
# Test: path-anchored regex  src/.*
# ============================================================================
test_regex_path_pattern() {
    log_test "Regex path-anchored pattern"

    /bin/mkdir -p "$TEST_DIR/regex_path/src" "$TEST_DIR/regex_path/gen"
    echo "a" > "$TEST_DIR/regex_path/src/a.cpp"
    echo "b" > "$TEST_DIR/regex_path/gen/b.cpp"
    echo "c" > "$TEST_DIR/regex_path/root.cpp"

    local output
    output=$(${FINGERPRINT_BIN} -l -r 'src/.*' "$TEST_DIR/regex_path" 2>&1)

    assert_contains "$output" "a.cpp" "Path regex should match file under src/"

    if output_not_contains "$output" "gen/b.cpp"; then
        log_pass "Path regex correctly excludes gen/ file"
    else
        log_fail "Path regex should not match gen/ file"
    fi

    if output_not_contains "$output" "root.cpp"; then
        log_pass "Path regex correctly excludes root-level file"
    else
        log_fail "Path regex should not match root-level file"
    fi
}

# ============================================================================
# Test: multiple -r flags are ORed together
# ============================================================================
test_regex_multiple_patterns() {
    log_test "Multiple regex patterns (OR semantics)"

    /bin/mkdir -p "$TEST_DIR/regex_multi"
    echo "a" > "$TEST_DIR/regex_multi/file.swift"
    echo "b" > "$TEST_DIR/regex_multi/file.m"
    echo "c" > "$TEST_DIR/regex_multi/file.py"
    echo "d" > "$TEST_DIR/regex_multi/file.json"

    local output
    output=$(${FINGERPRINT_BIN} -l -r '.*\.swift' -r '.*\.m' "$TEST_DIR/regex_multi" 2>&1)

    assert_contains "$output" "file.swift" "First regex should match .swift"
    assert_contains "$output" "file.m"     "Second regex should match .m"

    if output_not_contains "$output" "file.py"; then
        log_pass "Multiple regex correctly excludes .py"
    else
        log_fail "Multiple regex should not match .py"
    fi

    if output_not_contains "$output" "file.json"; then
        log_pass "Multiple regex correctly excludes .json"
    else
        log_fail "Multiple regex should not match .json"
    fi
}

# ============================================================================
# Test: regex that matches nothing returns empty result (exit 0)
# ============================================================================
test_regex_no_match() {
    log_test "Regex with no matching files exits 0"

    /bin/mkdir -p "$TEST_DIR/regex_nomatch"
    echo "a" > "$TEST_DIR/regex_nomatch/file.txt"

    ${FINGERPRINT_BIN} -r '.*\.nonexistent_extension' "$TEST_DIR/regex_nomatch" > /dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log_pass "Exit 0 when regex matches nothing"
    else
        log_fail "Should exit 0 when regex matches nothing (got $rc)"
    fi
}

# ============================================================================
# Test: regex is case-insensitive (ECMAScript icase flag)
# ============================================================================
test_regex_case_insensitive() {
    log_test "Regex is case-insensitive"

    /bin/mkdir -p "$TEST_DIR/regex_icase"
    echo "a" > "$TEST_DIR/regex_icase/Main.CPP"

    local output
    output=$(${FINGERPRINT_BIN} -l -r '.*\.cpp' "$TEST_DIR/regex_icase" 2>&1)

    assert_contains "$output" "Main.CPP" "Regex .*\\.cpp should match .CPP case-insensitively"
}

# ============================================================================
# Test: regex combined with glob (both applied)
# ============================================================================
test_regex_combined_with_glob() {
    log_test "Regex and glob patterns combined"

    /bin/mkdir -p "$TEST_DIR/regex_glob"
    echo "a" > "$TEST_DIR/regex_glob/file.swift"
    echo "b" > "$TEST_DIR/regex_glob/file.cpp"
    echo "c" > "$TEST_DIR/regex_glob/file.h"
    echo "d" > "$TEST_DIR/regex_glob/file.txt"

    # Glob matches .h; regex matches .swift — union should include both
    local output
    output=$(${FINGERPRINT_BIN} -l -g '*.h' -r '.*\.swift' "$TEST_DIR/regex_glob" 2>&1)

    assert_contains "$output" "file.swift" "Union should include regex match"
    assert_contains "$output" "file.h"     "Union should include glob match"

    if output_not_contains "$output" "file.cpp"; then
        log_pass "Union correctly excludes .cpp"
    else
        log_fail "Union should not include .cpp"
    fi
}

# ============================================================================
# Error path: invalid --fingerprint-mode
# ============================================================================
test_invalid_fingerprint_mode() {
    log_test "Invalid --fingerprint-mode is rejected"

    echo "x" > "$TEST_DIR/fp_mode_err.txt"
    local output
    output=$(${FINGERPRINT_BIN} --fingerprint-mode=bogus "$TEST_DIR/fp_mode_err.txt" 2>&1)
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        log_pass "Exit non-zero for invalid --fingerprint-mode"
    else
        log_fail "Should exit non-zero for invalid --fingerprint-mode (got $rc)"
    fi

    if output_contains "$output" "invalid\|error\|Error"; then
        log_pass "Error message printed for invalid --fingerprint-mode"
    else
        log_fail "Expected error message for invalid --fingerprint-mode"
        echo "  output: $output"
    fi
}

# ============================================================================
# Error path: invalid --hash
# ============================================================================
test_invalid_hash_algo() {
    log_test "Invalid --hash algorithm is rejected"

    echo "x" > "$TEST_DIR/hash_err.txt"
    local output
    output=$(${FINGERPRINT_BIN} --hash=bogusalgo "$TEST_DIR/hash_err.txt" 2>&1)
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        log_pass "Exit non-zero for invalid --hash"
    else
        log_fail "Should exit non-zero for invalid --hash (got $rc)"
    fi

    if output_contains "$output" "[Ii]nvalid\|[Ee]rror"; then
        log_pass "Error message printed for invalid --hash"
    else
        log_fail "Expected error message for invalid --hash"
        echo "  output: $output"
    fi
}

# ============================================================================
# Error path: invalid --xattr
# ============================================================================
test_invalid_xattr_mode() {
    log_test "Invalid --xattr mode is rejected"

    echo "x" > "$TEST_DIR/xattr_err.txt"
    local output
    output=$(${FINGERPRINT_BIN} --xattr=bogus "$TEST_DIR/xattr_err.txt" 2>&1)
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        log_pass "Exit non-zero for invalid --xattr"
    else
        log_fail "Should exit non-zero for invalid --xattr (got $rc)"
    fi

    if output_contains "$output" "[Ii]nvalid\|[Ee]rror"; then
        log_pass "Error message printed for invalid --xattr"
    else
        log_fail "Expected error message for invalid --xattr"
        echo "  output: $output"
    fi
}

# ============================================================================
# Error path: -I with nonexistent file
# ============================================================================
test_missing_inputs_file() {
    log_test "Missing -I inputs file is rejected"

    local output
    output=$(${FINGERPRINT_BIN} -I "/nonexistent/does/not/exist.xcfilelist" 2>&1)
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        log_pass "Exit non-zero for missing -I file"
    else
        log_fail "Should exit non-zero for missing -I file (got $rc)"
    fi

    if output_contains "$output" "[Ee]rror\|[Cc]annot\|open"; then
        log_pass "Error message printed for missing -I file"
    else
        log_fail "Expected error message for missing -I file"
        echo "  output: $output"
    fi
}

# ============================================================================
# Error path: no paths specified at all
# ============================================================================
test_no_paths_specified() {
    log_test "No paths specified exits non-zero"

    local output
    output=$(${FINGERPRINT_BIN} 2>&1)
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        log_pass "Exit non-zero when no paths given"
    else
        log_fail "Should exit non-zero when no paths given (got $rc)"
    fi
}
