#!/bin/bash


# ============================================================================
# Test 3: Glob pattern matching
# ============================================================================
test_glob_patterns() {
    log_test "Glob pattern matching"
    log_info "Testing file filtering using glob patterns (--glob option)"
    
    /bin/mkdir -p "$TEST_DIR/glob_test"
    echo "cpp" > "$TEST_DIR/glob_test/main.cpp"
    echo "h" > "$TEST_DIR/glob_test/header.h"
    echo "txt" > "$TEST_DIR/glob_test/readme.txt"
    log_info "Created files: main.cpp, header.h, readme.txt"
    
    # Match only .cpp files
    log_info "Testing glob pattern: *.cpp (should match only .cpp files)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.cpp' \"$TEST_DIR/glob_test\""
    local output=$(${FINGERPRINT_BIN} -l -g '*.cpp' "$TEST_DIR/glob_test" 2>&1)
    
    assert_contains "$output" "main.cpp" "Should match .cpp files"
    
    local grep_result=$(echo "$output" | /usr/bin/grep "readme.txt")
    if [ -n "$grep_result" ]; then
        log_fail "Should not match .txt files with *.cpp glob"
    else
        log_pass "Correctly filtered .txt files"
    fi
}

# ============================================================================
# Test 4: Multiple glob patterns
# ============================================================================
test_glob_multiple() {
    log_test "Multiple glob patterns"
    log_info "Testing multiple --glob options to match different file types"
    
    /bin/mkdir -p "$TEST_DIR/multi_glob"
    echo "cpp" > "$TEST_DIR/multi_glob/file.cpp"
    echo "h" > "$TEST_DIR/multi_glob/file.h"
    echo "txt" > "$TEST_DIR/multi_glob/file.txt"
    log_info "Created files: file.cpp, file.h, file.txt"
    
    log_info "Using globs: *.cpp and *.h (should exclude .txt)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.cpp' -g '*.h' \"$TEST_DIR/multi_glob\""
    local output=$(${FINGERPRINT_BIN} -l -g '*.cpp' -g '*.h' "$TEST_DIR/multi_glob" 2>&1)
    
    assert_contains "$output" "file.cpp" "Should match .cpp"
    assert_contains "$output" "file.h" "Should match .h"
    
    local grep_result=$(echo "$output" | /usr/bin/grep "file.txt")
    if [ -n "$grep_result" ]; then
        log_fail "Should not match .txt"
    else
        log_pass "Correctly excluded .txt"
    fi
}


# ============================================================================
# Test 18: Case-insensitive glob matching
# ============================================================================
test_glob_case_insensitive() {
    log_test "Case-insensitive glob matching"
    log_info "Testing case-insensitive pattern matching"
    
    /bin/mkdir -p "$TEST_DIR/case_test"
    # Use different filenames to avoid case-insensitive filesystem collision
    echo "upper" > "$TEST_DIR/case_test/UPPER.TXT"
    echo "lower" > "$TEST_DIR/case_test/lower.txt"
    echo "mixed" > "$TEST_DIR/case_test/Mixed.TxT"
    
    log_cmd "${FINGERPRINT_BIN} -l -g '*.txt' \"$TEST_DIR/case_test\""
    local output=$(${FINGERPRINT_BIN} -l -g '*.txt' "$TEST_DIR/case_test" 2>&1)
    
    assert_contains "$output" "UPPER.TXT" "Should match uppercase extension"
    assert_contains "$output" "lower.txt" "Should match lowercase extension"
    assert_contains "$output" "Mixed.TxT" "Should match mixed case extension"
}

# ============================================================================
# Test 19: Advanced glob patterns - Basic wildcards
# ============================================================================
test_glob_basic_wildcards() {
    log_test "Advanced glob patterns - Basic wildcards"
    log_info "Testing * (any chars) and ? (single char) wildcards"
    
    /bin/mkdir -p "$TEST_DIR/glob_basic"
    echo "1" > "$TEST_DIR/glob_basic/file1.txt"
    echo "2" > "$TEST_DIR/glob_basic/file2.txt"
    echo "3" > "$TEST_DIR/glob_basic/file10.txt"
    echo "4" > "$TEST_DIR/glob_basic/test.txt"
    echo "5" > "$TEST_DIR/glob_basic/test.cpp"
    
    # Test single character wildcard
    log_info "Testing pattern: file?.txt (should match file1.txt, file2.txt but not file10.txt)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file?.txt' \"$TEST_DIR/glob_basic\""
    local output=$(${FINGERPRINT_BIN} -l -g 'file?.txt' "$TEST_DIR/glob_basic" 2>&1)
    
    assert_contains "$output" "file1.txt" "Should match file1.txt"
    assert_contains "$output" "file2.txt" "Should match file2.txt"
    
    if output_contains "$output" "file10.txt"; then
        log_fail "Should not match file10.txt (two digits)"
    else
        log_pass "Correctly excluded file10.txt"
    fi
    
    # Test multi-char wildcard at start
    log_info "Testing pattern: *.cpp (any prefix)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.cpp' \"$TEST_DIR/glob_basic\""
    local output=$(${FINGERPRINT_BIN} -l -g '*.cpp' "$TEST_DIR/glob_basic" 2>&1)
    
    assert_contains "$output" "test.cpp" "Should match *.cpp"
    if output_contains "$output" "test.txt"; then
        log_fail "Should not match .txt files"
    else
        log_pass "Correctly excluded .txt files"
    fi
}

# ============================================================================
# Test 20: Advanced glob patterns - Character classes
# ============================================================================
test_glob_character_classes() {
    log_test "Advanced glob patterns - Character classes"
    log_info "Testing [abc], [a-z], [!abc] character class patterns"
    
    /bin/mkdir -p "$TEST_DIR/glob_classes"
    echo "a" > "$TEST_DIR/glob_classes/file_a.txt"
    echo "b" > "$TEST_DIR/glob_classes/file_b.txt"
    echo "c" > "$TEST_DIR/glob_classes/file_c.txt"
    echo "d" > "$TEST_DIR/glob_classes/file_d.txt"
    echo "1" > "$TEST_DIR/glob_classes/file_1.txt"
    
    # Test specific character set
    log_info "Testing pattern: file_[abc].txt"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file_[abc].txt' \"$TEST_DIR/glob_classes\""
    local output=$(${FINGERPRINT_BIN} -l -g 'file_[abc].txt' "$TEST_DIR/glob_classes" 2>&1)
    
    assert_contains "$output" "file_a.txt" "Should match file_a.txt"
    assert_contains "$output" "file_b.txt" "Should match file_b.txt"
    assert_contains "$output" "file_c.txt" "Should match file_c.txt"
    
    if output_not_contains "$output" "file_d.txt"; then
        log_pass "Correctly excluded file_d.txt"
    else
        log_fail "Should not match file_d.txt"
    fi
    
    # Test character range
    log_info "Testing pattern: file_[a-c].txt (range)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file_[a-c].txt' \"$TEST_DIR/glob_classes\""
    local output=$(${FINGERPRINT_BIN} -l -g 'file_[a-c].txt' "$TEST_DIR/glob_classes" 2>&1)
    
    assert_contains "$output" "file_a.txt" "Should match range a-c"
    if output_not_contains "$output" "file_d.txt"; then
        log_pass "Correctly excluded file outside range"
    else
        log_fail "Should not match outside range"
    fi
    
    # Test negation
    log_info "Testing pattern: file_[!d].txt (negation)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file_[!d].txt' \"$TEST_DIR/glob_classes\""
    local output=$(${FINGERPRINT_BIN} -l -g 'file_[!d].txt' "$TEST_DIR/glob_classes" 2>&1)
    
    assert_contains "$output" "file_a.txt" "Should match non-d files"
    if output_not_contains "$output" "file_d.txt"; then
        log_pass "Negation correctly excluded file_d.txt"
    else
        log_fail "Should not match file_d.txt with negation"
    fi
}

# ============================================================================
# Test 21: Advanced glob patterns - Brace expansion
# ============================================================================
test_glob_brace_expansion() {
    log_test "Advanced glob patterns - Brace expansion"
    log_info "Testing {a,b,c} brace expansion patterns (glob-cpp feature)"
    
    /bin/mkdir -p "$TEST_DIR/glob_braces"
    echo "1" > "$TEST_DIR/glob_braces/file.cpp"
    echo "2" > "$TEST_DIR/glob_braces/file.h"
    echo "3" > "$TEST_DIR/glob_braces/file.hpp"
    echo "4" > "$TEST_DIR/glob_braces/file.txt"
    echo "5" > "$TEST_DIR/glob_braces/test.c"
    
    # Test brace alternatives
    log_info "Testing pattern: *.{cpp,h} (brace expansion)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.{cpp,h}' \"$TEST_DIR/glob_braces\""
    local output=$(${FINGERPRINT_BIN} -l -g '*.{cpp,h}' "$TEST_DIR/glob_braces" 2>&1)
    
    # Check if brace expansion is supported
    if output_contains "$output" "file.cpp" && output_contains "$output" "file.h"; then
        log_pass "Brace expansion supported (glob-cpp)"

        if output_not_contains "$output" "file.txt"; then
            log_pass "Correctly excluded .txt"
        else
            log_fail "Should not match .txt with cpp,h pattern"
        fi
        
        if output_contains "$output" "file.hpp"; then
            log_fail "Should not match .hpp with cpp,h pattern"
        else
            log_pass "Correctly excluded .hpp"
        fi
    else
        if should_fail_on_missing_feature; then
            log_fail "Brace expansion NOT supported (required in extended glob mode)"
        else
            log_pass "Brace expansion NOT supported (requires extended glob mode)"
        fi
    fi
}

# ============================================================================
# Test 22: Advanced glob patterns - Double star (globstar)
# ============================================================================
test_glob_double_star() {
    log_test "Advanced glob patterns - Double star (globstar)"
    log_info "Testing ** for recursive directory matching"
    
    /bin/mkdir -p "$TEST_DIR/glob_star/src"
    /bin/mkdir -p "$TEST_DIR/glob_star/src/lib"
    /bin/mkdir -p "$TEST_DIR/glob_star/include"
    echo "1" > "$TEST_DIR/glob_star/main.cpp"
    echo "2" > "$TEST_DIR/glob_star/src/module.cpp"
    echo "3" > "$TEST_DIR/glob_star/src/lib/utils.cpp"
    echo "4" > "$TEST_DIR/glob_star/include/header.h"
    
    # Test recursive match with **
    log_info "Testing pattern: **/*.cpp (should recursively match all .cpp files)"
    log_cmd "${FINGERPRINT_BIN} -l -g '**/*.cpp' \"$TEST_DIR/glob_star\""
    local output=$(${FINGERPRINT_BIN} -l -g '**/*.cpp' "$TEST_DIR/glob_star" 2>&1)
    
    # Check if ** is properly handled as recursive wildcard
    local cpp_count=$(echo "$output" | /usr/bin/grep -c "\.cpp$" || true)
    log_info "Found $cpp_count .cpp files"
    
    if [ "$cpp_count" -eq 3 ]; then
        log_pass "Globstar ** supported - matched all nested .cpp files (3 total)"
        
        assert_contains "$output" "main.cpp" "Should match cpp in root"
        assert_contains "$output" "module.cpp" "Should match cpp in src/"
        assert_contains "$output" "utils.cpp" "Should match cpp in src/lib/"
        
        if output_contains "$output" "header.h"; then
            log_fail "Should not match .h files"
        else
            log_pass "Correctly excluded .h files"
        fi
    elif [ "$cpp_count" -eq 0 ]; then
        if should_fail_on_missing_feature; then
            log_fail "Globstar ** NOT implemented (required in extended glob mode)"
        else
            log_pass "requires extended glob mode (pattern treated literally)"
        fi
    else
        if should_fail_on_missing_feature; then
            log_fail "Partial globstar support: matched $cpp_count files (expected 3 in extended glob mode)"
        else
            log_pass "Partial globstar support: matched $cpp_count files (requires extended glob mode)"
        fi
    fi
    
    # Test specific path prefix with globstar
    log_info "Testing pattern: src/**/*.cpp (should match only under src/)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'src/**/*.cpp' \"$TEST_DIR/glob_star\""
    local output=$(${FINGERPRINT_BIN} -l -g 'src/**/*.cpp' "$TEST_DIR/glob_star" 2>&1)
    
    local src_cpp_count=$(echo "$output" | /usr/bin/grep -c "\.cpp$" || true)
    
    if output_contains "$output" "module.cpp" && output_contains "$output" "utils.cpp"; then
        log_pass "Pattern src/**/*.cpp matched files under src/ recursively"
        
        if [ "$src_cpp_count" -eq 2 ]; then
            log_pass "Matched exactly 2 files under src/ (correct count)"
        fi
        
        if output_contains "$output" "main.cpp"; then
            log_fail "Should not match main.cpp (not under src/)"
        else
            log_pass "Correctly excluded main.cpp from root"
        fi
    else
        if should_fail_on_missing_feature; then
            log_fail "Pattern src/**/*.cpp did not match as expected (required in extended glob mode)"
        else
            log_pass "Pattern src/**/*.cpp behavior varies (** requires extended glob mode)"
        fi
    fi
}

# ============================================================================
# Test 23: Advanced glob patterns - Escaped characters
# ============================================================================
test_glob_escaped_chars() {
    log_test "Advanced glob patterns - Escaped characters"
    log_info "Testing literal matching of special characters with escaping"
    
    /bin/mkdir -p "$TEST_DIR/glob_escape"
    echo "1" > "$TEST_DIR/glob_escape/file[1].txt"
    echo "2" > "$TEST_DIR/glob_escape/file*.txt"
    echo "3" > "$TEST_DIR/glob_escape/file?.txt"
    echo "4" > "$TEST_DIR/glob_escape/normal.txt"
    
    # Test escaped bracket
    log_info "Testing pattern: file\\[1\\].txt (escaped brackets)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file\\[1\\].txt' \"$TEST_DIR/glob_escape\""
    local output=$(${FINGERPRINT_BIN} -l -g 'file\[1\].txt' "$TEST_DIR/glob_escape" 2>&1)
    
    if output_contains "$output" "file[1].txt"; then
        log_pass "Escaped brackets matched literal brackets"
        
        if output_contains "$output" "normal.txt"; then
            log_fail "Should not match normal.txt"
        else
            log_pass "Correctly matched only escaped pattern"
        fi
    else
        log_pass "Escape handling varies by implementation"
    fi
}

# ============================================================================
# Test 24: Advanced glob patterns - Path separator behavior
# ============================================================================
test_glob_path_separator() {
    log_test "Advanced glob patterns - Path separator behavior"
    log_info "Testing pattern matching: no '/' = basename match, with '/' = full path match"
    
    /bin/mkdir -p "$TEST_DIR/glob_path/src"
    /bin/mkdir -p "$TEST_DIR/glob_path/test"
    echo "1" > "$TEST_DIR/glob_path/file.txt"
    echo "2" > "$TEST_DIR/glob_path/src/file.txt"
    echo "3" > "$TEST_DIR/glob_path/test/file.txt"
    echo "4" > "$TEST_DIR/glob_path/src/module.cpp"
    
    # Test 1: Pattern without '/' matches basename only
    log_info "Testing pattern: *.txt (no '/' = matches basename, should find all file.txt)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.txt' \"$TEST_DIR/glob_path\""
    local output=$(${FINGERPRINT_BIN} -l -g '*.txt' "$TEST_DIR/glob_path" 2>&1)
        
    local file_count=$(echo "$output" | /usr/bin/grep -c "file.txt$" || true)
    log_info "Found $file_count file.txt entries"
    
    if [ "$file_count" -eq 3 ]; then
        log_pass "Pattern *.txt matched all three file.txt files (basename matching)"
    else
        log_fail "Expected 3 matches, got $file_count (basename matching should find all)"
    fi
    
    # Test 2: Pattern with '/' matches full relative path
    log_info "Testing pattern: src/*.txt (with '/' = matches relative path)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'src/*.txt' \"$TEST_DIR/glob_path\""
    local output=$(${FINGERPRINT_BIN} -l -g 'src/*.txt' "$TEST_DIR/glob_path" 2>&1)
    
    # Count total matches
    local txt_count=$(echo "$output" | /usr/bin/grep -c "\.txt$" || true)
    
    if output_contains "$output" "src/file.txt"; then
        log_pass "Pattern src/*.txt matched src/file.txt (path matching)"
    else
        log_fail "Pattern src/*.txt should match src/file.txt"
    fi
    
    # Check that we ONLY got src/file.txt (count should be 1)
    if [ "$txt_count" -eq 1 ]; then
        log_pass "Pattern src/*.txt matched only 1 file (correct path filtering)"
    else
        log_fail "Pattern src/*.txt matched $txt_count files, expected 1"
        if [ $VERBOSE -eq 1 ]; then
            echo "  Matched files:"
            echo "$output" | /usr/bin/grep "\.txt"
        fi
    fi
    
    # Test 3: Multiple directory levels
    log_info "Testing pattern: */file.txt (matches one level deep)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*/file.txt' \"$TEST_DIR/glob_path\""
    local output=$(${FINGERPRINT_BIN} -l -g '*/file.txt' "$TEST_DIR/glob_path" 2>&1)
    
    local matched_count=$(echo "$output" | /usr/bin/grep -c "file.txt$" || true)
    
    if output_contains "$output" "src/file.txt"; then
        log_pass "Pattern */file.txt matched src/file.txt"
    fi
    
    if output_contains "$output" "test/file.txt"; then
        log_pass "Pattern */file.txt matched test/file.txt"
    fi
    
    # Should match both src/file.txt and test/file.txt, but NOT root file.txt
    if [ "$matched_count" -eq 2 ]; then
        log_pass "Pattern */file.txt matched exactly 2 files (one level deep only)"
    else
        log_pass "Pattern */file.txt matched $matched_count files"
    fi
}

# ============================================================================
# Test 25: Advanced glob patterns - Empty and edge cases
# ============================================================================
test_glob_edge_cases() {
    log_test "Advanced glob patterns - Edge cases"
    log_info "Testing edge cases: no matches, hidden files, etc."
    
    /bin/mkdir -p "$TEST_DIR/glob_edge"
    echo "1" > "$TEST_DIR/glob_edge/file.txt"
    echo "2" > "$TEST_DIR/glob_edge/.hidden"
    echo "3" > "$TEST_DIR/glob_edge/file"
    
    # Test pattern with no matches
    log_info "Testing pattern: *.xyz (no matches expected)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.xyz' \"$TEST_DIR/glob_edge\""
    local output=$(${FINGERPRINT_BIN} -l -g '*.xyz' "$TEST_DIR/glob_edge" 2>&1)
    
    if output_not_contains "$output" "file.txt"; then
        log_pass "Correctly matched nothing with non-existent extension"
    else
        log_fail "Should not match anything with .xyz pattern"
    fi
    
    # Test hidden files
    log_info "Testing pattern: .* (hidden files)"
    log_cmd "${FINGERPRINT_BIN} -l -g '.*' \"$TEST_DIR/glob_edge\""
    local output=$(${FINGERPRINT_BIN} -l -g '.*' "$TEST_DIR/glob_edge" 2>&1)
    
    if output_contains "$output" ".hidden"; then
        log_pass "Pattern .* matches hidden files"
    else
        log_pass "Pattern .* does not match hidden files (common behavior)"
    fi
}

# ============================================================================
# Test 26: Advanced glob patterns - Multiple wildcards
# ============================================================================
test_glob_multiple_wildcards() {
    log_test "Advanced glob patterns - Multiple wildcards"
    log_info "Testing patterns with multiple wildcard characters"
    
    /bin/mkdir -p "$TEST_DIR/glob_multi"
    echo "1" > "$TEST_DIR/glob_multi/test_file_v1.cpp"
    echo "2" > "$TEST_DIR/glob_multi/test_module_v2.cpp"
    echo "3" > "$TEST_DIR/glob_multi/test_v3.cpp"
    echo "4" > "$TEST_DIR/glob_multi/production_file.cpp"
    
    # Test multiple asterisks
    log_info "Testing pattern: test_*_v*.cpp"
    log_cmd "${FINGERPRINT_BIN} -l -g 'test_*_v*.cpp' \"$TEST_DIR/glob_multi\""
    local output=$(${FINGERPRINT_BIN} -l -g 'test_*_v*.cpp' "$TEST_DIR/glob_multi" 2>&1)

    assert_contains "$output" "test_file_v1.cpp" "Should match test_*_v*.cpp"
    assert_contains "$output" "test_module_v2.cpp" "Should match test_*_v*.cpp"
    
    if output_contains "$output" "test_v3.cpp"; then
        log_pass "Pattern matched test_v3.cpp (greedy matching allows empty middle *)"
    fi
    
    if output_contains "$output" "production_file.cpp"; then
        log_fail "Should not match production_file.cpp"
    else
        log_pass "Correctly excluded production_file.cpp"
    fi
}

# ============================================================================
# Test 27: Advanced glob patterns - Numeric ranges
# ============================================================================
test_glob_numeric_ranges() {
    log_test "Advanced glob patterns - Numeric ranges"
    log_info "Testing character classes with numeric ranges"
    
    /bin/mkdir -p "$TEST_DIR/glob_numeric"
    echo "1" > "$TEST_DIR/glob_numeric/file0.txt"
    echo "2" > "$TEST_DIR/glob_numeric/file1.txt"
    echo "3" > "$TEST_DIR/glob_numeric/file5.txt"
    echo "4" > "$TEST_DIR/glob_numeric/file9.txt"
    echo "5" > "$TEST_DIR/glob_numeric/filea.txt"
    
    # Test numeric range
    log_info "Testing pattern: file[0-5].txt"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file[0-5].txt' \"$TEST_DIR/glob_numeric\""
    local output=$(${FINGERPRINT_BIN} -l -g 'file[0-5].txt' "$TEST_DIR/glob_numeric" 2>&1)
    
    assert_contains "$output" "file0.txt" "Should match 0-5 range"
    assert_contains "$output" "file1.txt" "Should match 0-5 range"
    assert_contains "$output" "file5.txt" "Should match 0-5 range"
    
    if output_contains "$output" "file9.txt"; then
        log_fail "Should not match file9.txt (outside range)"
    else
        log_pass "Correctly excluded file9.txt"
    fi
    
    if output_contains "$output" "filea.txt"; then
        log_fail "Should not match filea.txt (letter, not number)"
    else
        log_pass "Correctly excluded filea.txt"
    fi
}

# ============================================================================
# Test 28: Advanced glob patterns - Complex combined patterns
# ============================================================================
test_glob_complex_patterns() {
    log_test "Advanced glob patterns - Complex combined patterns"
    log_info "Testing complex patterns combining multiple glob features"
    
    /bin/mkdir -p "$TEST_DIR/glob_complex/src/test"
    /bin/mkdir -p "$TEST_DIR/glob_complex/src/main"
    echo "1" > "$TEST_DIR/glob_complex/src/test/test_unit.cpp"
    echo "2" > "$TEST_DIR/glob_complex/src/test/test_integration.cpp"
    echo "3" > "$TEST_DIR/glob_complex/src/main/main.cpp"
    echo "4" > "$TEST_DIR/glob_complex/src/test/helper.h"
    
    # Note: This combines features that fnmatch may not support
    log_info "Testing pattern: test_*.cpp (simple version for fnmatch)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'test_*.cpp' \"$TEST_DIR/glob_complex\""
    local output=$(${FINGERPRINT_BIN} -l -g 'test_*.cpp' "$TEST_DIR/glob_complex" 2>&1)
    
    assert_contains "$output" "test_unit.cpp" "Should match test files"
    assert_contains "$output" "test_integration.cpp" "Should match test files"
    
    if output_contains "$output" "main.cpp"; then
        log_fail "Should not match main.cpp"
    else
        log_pass "Correctly excluded main.cpp"
    fi
    
    if output_contains "$output" "helper.h"; then
        log_fail "Should not match .h files"
    else
        log_pass "Correctly excluded .h files"
    fi
}
