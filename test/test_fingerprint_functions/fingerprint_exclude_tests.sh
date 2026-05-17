#!/bin/bash


# ============================================================================
# Exclusion Test Functions
# ============================================================================
test_exclude_basic_glob() {
    log_test "Exclude: basic glob pattern (*.gen.h)"
    log_info "Testing --exclude with bare glob pattern"
    
    /bin/mkdir -p "$TEST_DIR/excl_basic/src/keep"
    /bin/mkdir -p "$TEST_DIR/excl_basic/src/gen"
    echo "k1" > "$TEST_DIR/excl_basic/src/keep/a.cpp"
    echo "k2" > "$TEST_DIR/excl_basic/src/keep/b.cpp"
    echo "g1" > "$TEST_DIR/excl_basic/src/gen/x.gen.h"
    echo "g2" > "$TEST_DIR/excl_basic/src/gen/y.gen.h"
    log_info "Created src/keep/ and src/gen/ directories"
    
    log_cmd "${FINGERPRINT_BIN} -l --exclude='*.gen.h' \"$TEST_DIR/excl_basic/src\""
    local output=$(${FINGERPRINT_BIN} -l --exclude='*.gen.h' "$TEST_DIR/excl_basic/src" 2>&1)
    
    assert_contains "$output" "a.cpp" "Should include kept files"
    assert_contains "$output" "b.cpp" "Should include kept files"
    
    if output_not_contains "$output" "x.gen.h"; then
        log_pass "Glob exclude *.gen.h correctly excluded x.gen.h"
    else
        log_fail "Should exclude x.gen.h"
    fi
    
    if output_not_contains "$output" "y.gen.h"; then
        log_pass "Glob exclude correctly excluded y.gen.h"
    else
        log_fail "Should exclude y.gen.h"
    fi
}

test_exclude_literal_dir() {
    log_test "Exclude: literal directory path"
    log_info "Testing --exclude with absolute directory path"
    
    /bin/mkdir -p "$TEST_DIR/excl_lit/src/keep"
    /bin/mkdir -p "$TEST_DIR/excl_lit/src/generated"
    echo "k1" > "$TEST_DIR/excl_lit/src/keep/a.cpp"
    echo "g1" > "$TEST_DIR/excl_lit/src/generated/x.gen.h"
    log_info "Created src/keep/ and src/generated/"
    
    log_cmd "${FINGERPRINT_BIN} -l --exclude='$TEST_DIR/excl_lit/src/generated' \"$TEST_DIR/excl_lit/src\""
    local output=$(${FINGERPRINT_BIN} -l --exclude="$TEST_DIR/excl_lit/src/generated" "$TEST_DIR/excl_lit/src" 2>&1)
    
    assert_contains "$output" "a.cpp" "Should include kept file"
    
    if output_not_contains "$output" "x.gen.h"; then
        log_pass "Literal directory exclude correctly pruned subtree"
    else
        log_fail "Should exclude entire generated subtree"
    fi
}

test_exclude_changing_excluded_file() {
    log_test "Exclude: changing excluded file does NOT change fingerprint"
    log_info "Verifying that modifying an excluded file does not affect the fingerprint"
    
    /bin/mkdir -p "$TEST_DIR/excl_change/src/keep"
    /bin/mkdir -p "$TEST_DIR/excl_change/src/gen"
    echo "k1" > "$TEST_DIR/excl_change/src/keep/a.cpp"
    echo "g1" > "$TEST_DIR/excl_change/src/gen/x.gen.h"
    
    log_info "First run with --exclude=*.gen.h"
    log_cmd "${FINGERPRINT_BIN} --exclude='*.gen.h' \"$TEST_DIR/excl_change/src\""
    local fp1=$(${FINGERPRINT_BIN} --exclude='*.gen.h' "$TEST_DIR/excl_change/src" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    echo "g1-modified" > "$TEST_DIR/excl_change/src/gen/x.gen.h"
    log_info "Modified excluded file x.gen.h"
    
    log_info "Second run after modifying excluded file"
    log_cmd "${FINGERPRINT_BIN} --exclude='*.gen.h' \"$TEST_DIR/excl_change/src\""
    local fp2=$(${FINGERPRINT_BIN} --exclude='*.gen.h' "$TEST_DIR/excl_change/src" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    assert_equal "$fp1" "$fp2" "Fingerprint unchanged after modifying excluded file"
}

test_exclude_changing_kept_file() {
    log_test "Exclude: changing kept file DOES change fingerprint"
    log_info "Verifying that modifying a non-excluded file changes the fingerprint"
    
    /bin/mkdir -p "$TEST_DIR/excl_keep/src/keep"
    /bin/mkdir -p "$TEST_DIR/excl_keep/src/gen"
    echo "k1" > "$TEST_DIR/excl_keep/src/keep/a.cpp"
    echo "g1" > "$TEST_DIR/excl_keep/src/gen/x.gen.h"
    
    log_info "First run"
    local fp1=$(${FINGERPRINT_BIN} --exclude='*.gen.h' "$TEST_DIR/excl_keep/src" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    echo "k1-modified" > "$TEST_DIR/excl_keep/src/keep/a.cpp"
    log_info "Modified kept file a.cpp"
    
    log_info "Second run after modifying kept file"
    local fp2=$(${FINGERPRINT_BIN} --exclude='*.gen.h' "$TEST_DIR/excl_keep/src" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    assert_not_equal "$fp1" "$fp2" "Fingerprint changed after modifying kept file"
}

test_exclude_relative_to_search_dir() {
    log_test "Exclude: relative patterns work relative to search dir, not cwd"
    log_info "Demonstrates that -e 'gen' matches gen/ inside search dir"
    
    /bin/mkdir -p "$TEST_DIR/rel_excl/project/src"
    /bin/mkdir -p "$TEST_DIR/rel_excl/project/gen"
    /bin/mkdir -p "$TEST_DIR/rel_excl/other"
    echo "main" > "$TEST_DIR/rel_excl/project/src/main.cpp"
    echo "gen1" > "$TEST_DIR/rel_excl/project/gen/output.gen"
    echo "other" > "$TEST_DIR/rel_excl/other/unrelated.txt"
    log_info "Created project with src/ and gen/, plus other/"
    
    log_info "Test: exclude pattern 'gen' relative to project should work"
    cd "$TEST_DIR"
    log_cmd "cd $TEST_DIR && ${FINGERPRINT_BIN} -l -e 'gen' rel_excl/project"
    local output=$(${FINGERPRINT_BIN} -l -e 'gen' "$TEST_DIR/rel_excl/project" 2>&1)
    
    assert_contains "$output" "main.cpp" "Should include main.cpp"
    
    if output_not_contains "$output" "output.gen"; then
        log_pass "Relative exclude 'gen' correctly excluded gen/output.gen"
    else
        log_fail "Should exclude gen/output.gen"
    fi
    
    if output_not_contains "$output" "unrelated.txt"; then
        log_pass "Did not include files from sibling directory"
    else
        log_fail "Should not include unrelated.txt from other/"
    fi
    
    log_info "Test: exclude from different cwd, pattern relative to search dir"
    cd /tmp
    log_cmd "cd /tmp && ${FINGERPRINT_BIN} -l -e 'gen' '$TEST_DIR/rel_excl/project'"
    local output2=$(${FINGERPRINT_BIN} -l -e 'gen' "$TEST_DIR/rel_excl/project" 2>&1)
    cd - > /dev/null
    
    if output_not_contains "$output2" "output.gen"; then
        log_pass "Exclude works regardless of cwd"
    else
        log_fail "Exclude should work from any cwd"
    fi
}

test_exclude_relative_glob_in_search_dir() {
    log_test "Exclude: relative glob pattern works relative to search dir"
    log_info "Testing -e 'gen/*.gen' when run from different cwd"
    
    /bin/mkdir -p "$TEST_DIR/rel_glob/src"
    /bin/mkdir -p "$TEST_DIR/rel_glob/gen"
    echo "source" > "$TEST_DIR/rel_glob/src/main.cpp"
    echo "g1" > "$TEST_DIR/rel_glob/gen/file1.gen"
    echo "g2" > "$TEST_DIR/rel_glob/gen/file2.gen"
    echo "txt" > "$TEST_DIR/rel_glob/gen/readme.txt"
    log_info "Created src/ and gen/ with .gen and .txt files"
    
    log_info "Run from /tmp to prove pattern is relative to search dir"
    cd /tmp
    log_cmd "cd /tmp && ${FINGERPRINT_BIN} -l -e 'gen/*.gen' '$TEST_DIR/rel_glob'"
    local output=$(${FINGERPRINT_BIN} -l -e 'gen/*.gen' "$TEST_DIR/rel_glob" 2>&1)
    cd - > /dev/null
    
    assert_contains "$output" "main.cpp" "Should include main.cpp"
    
    if output_not_contains "$output" "file1.gen"; then
        log_pass "Relative glob pattern gen/*.gen excluded file1.gen"
    else
        log_fail "Should exclude file1.gen"
    fi
    
    if output_not_contains "$output" "file2.gen"; then
        log_pass "Relative glob pattern excluded file2.gen"
    else
        log_fail "Should exclude file2.gen"
    fi
    
    if output_contains "$output" "readme.txt"; then
        log_pass "Did not exclude non-matching .txt file"
    else
        log_fail "readme.txt should be present (only gen/*.gen is excluded)"
    fi
}
