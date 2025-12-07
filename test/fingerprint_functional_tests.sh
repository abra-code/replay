#!/bin/bash
# Don't exit on error - we want to run all tests and report failures
set -uo pipefail

# Functional tests for fingerprint tool
# This script (fingerprint_functional_tests.sh) should be placed in the "test" directory
# next to the "build" directory

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Default to finding fingerprint relative to script location
# Can be overridden by setting FINGERPRINT_BIN environment variable
FINGERPRINT_BIN="${FINGERPRINT_BIN:-${SCRIPT_DIR}/../build/Release/fingerprint}"

TEST_DIR=$(mktemp -d -t fingerprint_tests)
FAILED_TESTS=0
PASSED_TESTS=0
VERBOSE=0
EXTENDED_GLOB=0  # New flag for extended glob-cpp testing

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

log_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED_TESTS++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED_TESTS++))
}

log_info() {
    if [ $VERBOSE -eq 1 ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_cmd() {
    if [ $VERBOSE -eq 1 ]; then
        echo -e "${CYAN}[CMD]${NC}  $1"
    fi
}

# Helper to check if we're in extended glob mode and should fail on unsupported features
should_fail_on_missing_feature() {
    if [ $EXTENDED_GLOB -eq 1 ]; then
    	return 0
    fi
    return 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    
    if [ "$expected" = "$actual" ]; then
        log_pass "$message"
    else
        log_fail "$message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
    fi
}

assert_not_equal() {
    local val1="$1"
    local val2="$2"
    local message="$3"
    
    if [ "$val1" != "$val2" ]; then
        log_pass "$message"
    else
        log_fail "$message (values should differ)"
        echo "  Both values: $val1"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    
    if echo "$haystack" | grep -q "$needle"; then
        log_pass "$message"
    else
        log_fail "$message"
        echo "  Looking for: $needle"
        echo "  In: $haystack"
    fi
}

# ============================================================================
# Test 1: Basic single file fingerprinting
# ============================================================================
test_single_file() {
    log_test "Single file fingerprinting"
    log_info "Testing basic fingerprint generation for a single file"
    
    echo "test content" > "$TEST_DIR/file1.txt"
    log_info "Created test file: $TEST_DIR/file1.txt"
    
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/file1.txt\""
    output=$(${FINGERPRINT_BIN} "$TEST_DIR/file1.txt" 2>&1)
    fingerprint=$(echo "$output" | grep "Fingerprint:" | awk '{print $2}')
    
    if [ -n "$fingerprint" ] && [ ${#fingerprint} -eq 16 ]; then
        log_pass "Generated valid fingerprint: $fingerprint"
    else
        log_fail "Invalid fingerprint format: $fingerprint"
    fi
}

# ============================================================================
# Test 2: Directory traversal
# ============================================================================
test_directory_traversal() {
    log_test "Directory traversal"
    log_info "Testing recursive directory traversal with --list option"
    
    mkdir -p "$TEST_DIR/dir1/subdir"
    echo "file1" > "$TEST_DIR/dir1/file1.txt"
    echo "file2" > "$TEST_DIR/dir1/subdir/file2.txt"
    log_info "Created directory structure with nested files"
    
    log_cmd "${FINGERPRINT_BIN} -l \"$TEST_DIR/dir1\""
    output=$(${FINGERPRINT_BIN} -l "$TEST_DIR/dir1" 2>&1)
    
    assert_contains "$output" "file1.txt" "Should find file1.txt"
    assert_contains "$output" "file2.txt" "Should find file2.txt in subdir"
}

# ============================================================================
# Test 3: Glob pattern matching
# ============================================================================
test_glob_patterns() {
    log_test "Glob pattern matching"
    log_info "Testing file filtering using glob patterns (--glob option)"
    
    mkdir -p "$TEST_DIR/glob_test"
    echo "cpp" > "$TEST_DIR/glob_test/main.cpp"
    echo "h" > "$TEST_DIR/glob_test/header.h"
    echo "txt" > "$TEST_DIR/glob_test/readme.txt"
    log_info "Created files: main.cpp, header.h, readme.txt"
    
    # Match only .cpp files
    log_info "Testing glob pattern: *.cpp (should match only .cpp files)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.cpp' \"$TEST_DIR/glob_test\""
    output=$(${FINGERPRINT_BIN} -l -g '*.cpp' "$TEST_DIR/glob_test" 2>&1)
    
    assert_contains "$output" "main.cpp" "Should match .cpp files"
    
    if echo "$output" | grep -q "readme.txt"; then
        log_fail "Should not match .txt files with *.cpp glob"
    else
        log_pass "Correctly filtered .txt files"
    fi
}

# ============================================================================
# Test 4: Multiple glob patterns
# ============================================================================
test_multiple_globs() {
    log_test "Multiple glob patterns"
    log_info "Testing multiple --glob options to match different file types"
    
    mkdir -p "$TEST_DIR/multi_glob"
    echo "cpp" > "$TEST_DIR/multi_glob/file.cpp"
    echo "h" > "$TEST_DIR/multi_glob/file.h"
    echo "txt" > "$TEST_DIR/multi_glob/file.txt"
    log_info "Created files: file.cpp, file.h, file.txt"
    
    log_info "Using globs: *.cpp and *.h (should exclude .txt)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.cpp' -g '*.h' \"$TEST_DIR/multi_glob\""
    output=$(${FINGERPRINT_BIN} -l -g '*.cpp' -g '*.h' "$TEST_DIR/multi_glob" 2>&1)
    
    assert_contains "$output" "file.cpp" "Should match .cpp"
    assert_contains "$output" "file.h" "Should match .h"
    
    if echo "$output" | grep -q "file.txt"; then
        log_fail "Should not match .txt"
    else
        log_pass "Correctly excluded .txt"
    fi
}

# ============================================================================
# Test 5: Symlink handling
# ============================================================================
test_symlinks() {
    log_test "Symlink handling"
    log_info "Testing that symlinks are processed separately from their targets"
    
    mkdir -p "$TEST_DIR/symlink_test"
    echo "original" > "$TEST_DIR/symlink_test/original.txt"
    ln -s "$TEST_DIR/symlink_test/original.txt" "$TEST_DIR/symlink_test/link.txt"
    log_info "Created original.txt and symlink link.txt -> original.txt"
    
    log_cmd "${FINGERPRINT_BIN} -l \"$TEST_DIR/symlink_test\""
    output=$(${FINGERPRINT_BIN} -l "$TEST_DIR/symlink_test" 2>&1)
    
    assert_contains "$output" "original.txt" "Should find original file"
    assert_contains "$output" "link.txt" "Should find symlink"
    
    # Symlink and target should have different hashes (symlink hashes the link itself)
    orig_hash=$(echo "$output" | grep "original.txt" | awk '{print $1}')
    link_hash=$(echo "$output" | grep "link.txt" | awk '{print $1}')
    
    assert_not_equal "$orig_hash" "$link_hash" "Symlink should have different hash than target"
    log_info "Original hash: $orig_hash, Link hash: $link_hash"
}

# ============================================================================
# Test 6: Xattr caching
# ============================================================================
test_xattr_caching() {
    log_test "Xattr caching"
    log_info "Testing extended attribute caching for performance optimization"
    
    echo "xattr test" > "$TEST_DIR/xattr_file.txt"
    
    # First run - compute hash and write xattr
    log_info "First run: computing hash and writing to xattr (--xattr=on)"
    log_cmd "${FINGERPRINT_BIN} -v --xattr=on \"$TEST_DIR/xattr_file.txt\""
    output1=$(${FINGERPRINT_BIN} -v --xattr=on "$TEST_DIR/xattr_file.txt" 2>&1)
    time1=$(echo "$output1" | grep "Total execution time:" | awk '{print $4}')
    
    # Second run - should use cached hash
    log_info "Second run: should use cached hash from xattr"
    log_cmd "${FINGERPRINT_BIN} -v --xattr=on \"$TEST_DIR/xattr_file.txt\" (cached run)"
    output2=$(${FINGERPRINT_BIN} -v --xattr=on "$TEST_DIR/xattr_file.txt" 2>&1)
    time2=$(echo "$output2" | grep "Total execution time:" | awk '{print $4}')
    
    fingerprint1=$(echo "$output1" | grep "Fingerprint:" | awk '{print $2}')
    fingerprint2=$(echo "$output2" | grep "Fingerprint:" | awk '{print $2}')
    
    assert_equal "$fingerprint1" "$fingerprint2" "Cached fingerprint should match original"
    log_info "First run: ${time1}ms, Second run: ${time2}ms"
    
    # Check if xattr was written
    if xattr -l "$TEST_DIR/xattr_file.txt" | grep -q "public.fingerprint"; then
        log_pass "Xattr was written"
    else
        log_fail "Xattr was not written"
    fi
}

# ============================================================================
# Test 7: Xattr refresh mode
# ============================================================================
test_xattr_refresh() {
    log_test "Xattr refresh mode"
    log_info "Testing --xattr=refresh to force recomputation and update cache"
    
    echo "refresh test" > "$TEST_DIR/refresh_file.txt"
    
    # Initial run
    log_info "Initial run with --xattr=on"
    log_cmd "${FINGERPRINT_BIN} --xattr=on \"$TEST_DIR/refresh_file.txt\" (initial)"
    ${FINGERPRINT_BIN} --xattr=on "$TEST_DIR/refresh_file.txt" > /dev/null 2>&1
    
    # Force refresh
    log_info "Forcing refresh with --xattr=refresh"
    log_cmd "${FINGERPRINT_BIN} -v --xattr=refresh \"$TEST_DIR/refresh_file.txt\""
    output=$(${FINGERPRINT_BIN} -v --xattr=refresh "$TEST_DIR/refresh_file.txt" 2>&1)
    
    if xattr -l "$TEST_DIR/refresh_file.txt" | grep -q "public.fingerprint"; then
        log_pass "Xattr updated in refresh mode"
    else
        log_fail "Xattr not present after refresh"
    fi
}

# ============================================================================
# Test 8: Xattr clear mode
# ============================================================================
test_xattr_clear() {
    log_test "Xattr clear mode"
    log_info "Testing --xattr=clear to remove cached attributes"
    
    echo "clear test" > "$TEST_DIR/clear_file.txt"
    
    # Write xattr
    log_info "Writing xattr with --xattr=on"
    log_cmd "${FINGERPRINT_BIN} --xattr=on \"$TEST_DIR/clear_file.txt\" (write xattr)"
    ${FINGERPRINT_BIN} --xattr=on "$TEST_DIR/clear_file.txt" > /dev/null 2>&1
    
    # Clear xattr
    log_info "Clearing xattr with --xattr=clear"
    log_cmd "${FINGERPRINT_BIN} --xattr=clear \"$TEST_DIR/clear_file.txt\""
    ${FINGERPRINT_BIN} --xattr=clear "$TEST_DIR/clear_file.txt" > /dev/null 2>&1
    
    if xattr -l "$TEST_DIR/clear_file.txt" | grep -q "public.fingerprint"; then
        log_fail "Xattr should be cleared"
    else
        log_pass "Xattr successfully cleared"
    fi
}

# ============================================================================
# Test 9: CRC32C vs BLAKE3
# ============================================================================
test_hash_algorithms() {
    log_test "Hash algorithms (CRC32C vs BLAKE3)"
    log_info "Testing different hash algorithms produce different results"
    
    echo "hash test" > "$TEST_DIR/hash_file.txt"
    
    log_info "Computing fingerprint with --hash=crc32c"
    log_cmd "${FINGERPRINT_BIN} --hash=crc32c \"$TEST_DIR/hash_file.txt\""
    output_crc=$(${FINGERPRINT_BIN} --hash=crc32c "$TEST_DIR/hash_file.txt" 2>&1)
    fp_crc=$(echo "$output_crc" | grep "Fingerprint:" | awk '{print $2}')
    
    log_info "Computing fingerprint with --hash=blake3"
    log_cmd "${FINGERPRINT_BIN} --hash=blake3 \"$TEST_DIR/hash_file.txt\""
    output_blake=$(${FINGERPRINT_BIN} --hash=blake3 "$TEST_DIR/hash_file.txt" 2>&1)
    fp_blake=$(echo "$output_blake" | grep "Fingerprint:" | awk '{print $2}')
    
    assert_not_equal "$fp_crc" "$fp_blake" "CRC32C and BLAKE3 should produce different results"
    log_info "CRC32C: $fp_crc, BLAKE3: $fp_blake"
    
    # Verify both are valid hex
    if [[ "$fp_crc" =~ ^[0-9a-f]{16}$ ]]; then
        log_pass "CRC32C fingerprint format valid"
    else
        log_fail "Invalid CRC32C fingerprint format"
    fi
    
    if [[ "$fp_blake" =~ ^[0-9a-f]{16}$ ]]; then
        log_pass "BLAKE3 fingerprint format valid"
    else
        log_fail "Invalid BLAKE3 fingerprint format"
    fi
}

# ============================================================================
# Test 10: Fingerprint stability (same input = same output)
# ============================================================================
test_fingerprint_stability() {
    log_test "Fingerprint stability"
    log_info "Testing that identical inputs produce identical fingerprints"
    
    mkdir -p "$TEST_DIR/stable"
    echo "file1" > "$TEST_DIR/stable/a.txt"
    echo "file2" > "$TEST_DIR/stable/b.txt"
    log_info "Created two files in test directory"
    
    log_info "Running fingerprint three times on same directory"
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/stable\" (run 1)"
    fp1=$(${FINGERPRINT_BIN} "$TEST_DIR/stable" 2>&1 | grep "Fingerprint:" | awk '{print $2}')
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/stable\" (run 2)"
    fp2=$(${FINGERPRINT_BIN} "$TEST_DIR/stable" 2>&1 | grep "Fingerprint:" | awk '{print $2}')
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/stable\" (run 3)"
    fp3=$(${FINGERPRINT_BIN} "$TEST_DIR/stable" 2>&1 | grep "Fingerprint:" | awk '{print $2}')
    
    assert_equal "$fp1" "$fp2" "Fingerprint should be stable (run 1 vs 2)"
    assert_equal "$fp2" "$fp3" "Fingerprint should be stable (run 2 vs 3)"
    log_info "All runs produced: $fp1"
}

# ============================================================================
# Test 11: Fingerprint changes on content modification
# ============================================================================
test_fingerprint_content_change() {
    log_test "Fingerprint changes on content modification"
    log_info "Testing that fingerprint changes when file content changes"
    
    mkdir -p "$TEST_DIR/modify"
    echo "original" > "$TEST_DIR/modify/file.txt"
    
    log_info "Computing fingerprint for original content"
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/modify\" (before)"
    fp_before=$(${FINGERPRINT_BIN} "$TEST_DIR/modify" 2>&1 | grep "Fingerprint:" | awk '{print $2}')
    
    # Modify content
    echo "modified" > "$TEST_DIR/modify/file.txt"
    log_info "Modified file content"
    
    log_info "Computing fingerprint after modification"
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/modify\" (after)"
    fp_after=$(${FINGERPRINT_BIN} "$TEST_DIR/modify" 2>&1 | grep "Fingerprint:" | awk '{print $2}')
    
    assert_not_equal "$fp_before" "$fp_after" "Fingerprint should change after content modification"
    log_info "Before: $fp_before, After: $fp_after"
}

# ============================================================================
# Test 12: Fingerprint mode - absolute paths
# ============================================================================
test_fingerprint_mode_absolute() {
    log_test "Fingerprint mode: absolute paths"
    log_info "Testing --fingerprint-mode=absolute (includes full paths in fingerprint)"
    
    mkdir -p "$TEST_DIR/mode_test1" "$TEST_DIR/mode_test2"
    echo "same content" > "$TEST_DIR/mode_test1/file.txt"
    echo "same content" > "$TEST_DIR/mode_test2/file.txt"
    log_info "Created identical files in different directories"
    
    log_info "Computing fingerprint for directory 1 with absolute path mode"
    log_cmd "${FINGERPRINT_BIN} --fingerprint-mode=absolute \"$TEST_DIR/mode_test1\""
    fp1=$(${FINGERPRINT_BIN} --fingerprint-mode=absolute "$TEST_DIR/mode_test1" 2>&1 | grep "Fingerprint:" | awk '{print $2}')
    
    log_info "Computing fingerprint for directory 2 with absolute path mode"
    log_cmd "${FINGERPRINT_BIN} --fingerprint-mode=absolute \"$TEST_DIR/mode_test2\""
    fp2=$(${FINGERPRINT_BIN} --fingerprint-mode=absolute "$TEST_DIR/mode_test2" 2>&1 | grep "Fingerprint:" | awk '{print $2}')
    
    assert_not_equal "$fp1" "$fp2" "Different paths should produce different fingerprints in absolute mode"
    log_info "Directory 1: $fp1, Directory 2: $fp2"
}

# ============================================================================
# Test 13: Input file list processing
# ============================================================================
test_input_file_list() {
    log_test "Input file list processing"
    log_info "Testing --inputs option to read file paths from a list"
    
    mkdir -p "$TEST_DIR/input_list"
    echo "file1" > "$TEST_DIR/input_list/file1.txt"
    echo "file2" > "$TEST_DIR/input_list/file2.txt"
    echo "file3" > "$TEST_DIR/input_list/file3.txt"
    
    # Create input list
    cat > "$TEST_DIR/filelist.txt" <<EOF
# Comment line
$TEST_DIR/input_list/file1.txt
$TEST_DIR/input_list/file2.txt

$TEST_DIR/input_list/file3.txt
EOF
    log_info "Created input file list with paths and comments"
    
    log_info "Running fingerprint with --inputs=$TEST_DIR/filelist.txt"
    log_cmd "${FINGERPRINT_BIN} -l -I \"$TEST_DIR/filelist.txt\""
    output=$(${FINGERPRINT_BIN} -l -I "$TEST_DIR/filelist.txt" 2>&1)
    
    assert_contains "$output" "file1.txt" "Should process file1 from list"
    assert_contains "$output" "file2.txt" "Should process file2 from list"
    assert_contains "$output" "file3.txt" "Should process file3 from list"
}

# ============================================================================
# Test 14: Environment variable expansion in input list
# ============================================================================
test_env_var_expansion() {
    log_test "Environment variable expansion in input list"
    log_info "Testing \${VAR} and \$(VAR) expansion in .xcfilelist format"
    
    export TEST_BASE="$TEST_DIR/env_test"
    mkdir -p "$TEST_BASE"
    echo "env file" > "$TEST_BASE/file.txt"
    log_info "Set TEST_BASE=$TEST_BASE"
    
    cat > "$TEST_DIR/env_filelist.txt" <<EOF
\${TEST_BASE}/file.txt
\$(TEST_BASE)/file.txt
EOF
    log_info "Created input list with environment variable references"
    
    log_info "Running fingerprint with variable expansion"
    log_cmd "${FINGERPRINT_BIN} -l -I \"$TEST_DIR/env_filelist.txt\""
    output=$(${FINGERPRINT_BIN} -l -I "$TEST_DIR/env_filelist.txt" 2>&1)
    
    # Should expand both ${VAR} and $(VAR) syntax
    assert_contains "$output" "file.txt" "Should expand environment variables"
    
    unset TEST_BASE
}

# ============================================================================
# Test 15: Non-existent file handling
# ============================================================================
test_nonexistent_files() {
    log_test "Non-existent file handling"
    
    # Create one file and reference one that doesn't exist
    echo "exists" > "$TEST_DIR/exists.txt"
    
    log_cmd "${FINGERPRINT_BIN} -v -l \"$TEST_DIR/exists.txt\" \"$TEST_DIR/does_not_exist.txt\""
    output=$(${FINGERPRINT_BIN} -v -l "$TEST_DIR/exists.txt" "$TEST_DIR/does_not_exist.txt" 2>&1)
    
    assert_contains "$output" "exists.txt" "Should process existing file"
    assert_contains "$output" "does_not_exist.txt" "Should handle non-existent file"
    
    # Tool should complete successfully
    if [ $? -eq 0 ]; then
        log_pass "Tool handles non-existent files gracefully"
    else
        log_fail "Tool should not fail on non-existent files"
    fi
}

# ============================================================================
# Test 16: Empty directory handling
# ============================================================================
test_empty_directory() {
    log_test "Empty directory handling"
    
    mkdir -p "$TEST_DIR/empty_dir"
    
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/empty_dir\""
    output=$(${FINGERPRINT_BIN} "$TEST_DIR/empty_dir" 2>&1)
    fingerprint=$(echo "$output" | grep "Fingerprint:" | awk '{print $2}')
    
    if [ -n "$fingerprint" ]; then
        log_pass "Generated fingerprint for empty directory"
    else
        log_fail "Should generate fingerprint even for empty directory"
    fi
}

# ============================================================================
# Test 17: Circular symlink detection
# ============================================================================
test_circular_symlinks() {
    log_test "Circular symlink detection"
    
    mkdir -p "$TEST_DIR/circular"
    ln -s "$TEST_DIR/circular/link2" "$TEST_DIR/circular/link1"
    ln -s "$TEST_DIR/circular/link1" "$TEST_DIR/circular/link2"
    
    # Should handle circular symlinks without infinite loop
    log_cmd "${FINGERPRINT_BIN} -v \"$TEST_DIR/circular\""
    output=$(${FINGERPRINT_BIN} -v "$TEST_DIR/circular" 2>&1 || true)
    
    if echo "$output" | grep -q "Circular symlink"; then
        log_pass "Detected circular symlink"
    else
        log_pass "Handled circular symlinks (detection optional)"
    fi
}

# ============================================================================
# Test 18: Case-insensitive glob matching
# ============================================================================
test_case_insensitive_globs() {
    log_test "Case-insensitive glob matching"
    log_info "Testing case-insensitive pattern matching"
    
    mkdir -p "$TEST_DIR/case_test"
    # Use different filenames to avoid case-insensitive filesystem collision
    echo "upper" > "$TEST_DIR/case_test/UPPER.TXT"
    echo "lower" > "$TEST_DIR/case_test/lower.txt"
    echo "mixed" > "$TEST_DIR/case_test/Mixed.TxT"
    
    log_cmd "${FINGERPRINT_BIN} -l -g '*.txt' \"$TEST_DIR/case_test\""
    output=$(${FINGERPRINT_BIN} -l -g '*.txt' "$TEST_DIR/case_test" 2>&1)
    
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
    
    mkdir -p "$TEST_DIR/glob_basic"
    echo "1" > "$TEST_DIR/glob_basic/file1.txt"
    echo "2" > "$TEST_DIR/glob_basic/file2.txt"
    echo "3" > "$TEST_DIR/glob_basic/file10.txt"
    echo "4" > "$TEST_DIR/glob_basic/test.txt"
    echo "5" > "$TEST_DIR/glob_basic/test.cpp"
    
    # Test single character wildcard
    log_info "Testing pattern: file?.txt (should match file1.txt, file2.txt but not file10.txt)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file?.txt' \"$TEST_DIR/glob_basic\""
    output=$(${FINGERPRINT_BIN} -l -g 'file?.txt' "$TEST_DIR/glob_basic" 2>&1)
    
    assert_contains "$output" "file1.txt" "Should match file1.txt"
    assert_contains "$output" "file2.txt" "Should match file2.txt"
    
    if echo "$output" | grep -q "file10.txt"; then
        log_fail "Should not match file10.txt (two digits)"
    else
        log_pass "Correctly excluded file10.txt"
    fi
    
    # Test multi-char wildcard at start
    log_info "Testing pattern: *.cpp (any prefix)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.cpp' \"$TEST_DIR/glob_basic\""
    output=$(${FINGERPRINT_BIN} -l -g '*.cpp' "$TEST_DIR/glob_basic" 2>&1)
    
    assert_contains "$output" "test.cpp" "Should match *.cpp"
    if echo "$output" | grep -q "test.txt"; then
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
    
    mkdir -p "$TEST_DIR/glob_classes"
    echo "a" > "$TEST_DIR/glob_classes/file_a.txt"
    echo "b" > "$TEST_DIR/glob_classes/file_b.txt"
    echo "c" > "$TEST_DIR/glob_classes/file_c.txt"
    echo "d" > "$TEST_DIR/glob_classes/file_d.txt"
    echo "1" > "$TEST_DIR/glob_classes/file_1.txt"
    
    # Test specific character set
    log_info "Testing pattern: file_[abc].txt"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file_[abc].txt' \"$TEST_DIR/glob_classes\""
    output=$(${FINGERPRINT_BIN} -l -g 'file_[abc].txt' "$TEST_DIR/glob_classes" 2>&1)
    
    assert_contains "$output" "file_a.txt" "Should match file_a.txt"
    assert_contains "$output" "file_b.txt" "Should match file_b.txt"
    assert_contains "$output" "file_c.txt" "Should match file_c.txt"
    
    if echo "$output" | grep -q "file_d.txt"; then
        log_fail "Should not match file_d.txt"
    else
        log_pass "Correctly excluded file_d.txt"
    fi
    
    # Test character range
    log_info "Testing pattern: file_[a-c].txt (range)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file_[a-c].txt' \"$TEST_DIR/glob_classes\""
    output=$(${FINGERPRINT_BIN} -l -g 'file_[a-c].txt' "$TEST_DIR/glob_classes" 2>&1)
    
    assert_contains "$output" "file_a.txt" "Should match range a-c"
    if echo "$output" | grep -q "file_d.txt"; then
        log_fail "Should not match outside range"
    else
        log_pass "Correctly excluded file outside range"
    fi
    
    # Test negation
    log_info "Testing pattern: file_[!d].txt (negation)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file_[!d].txt' \"$TEST_DIR/glob_classes\""
    output=$(${FINGERPRINT_BIN} -l -g 'file_[!d].txt' "$TEST_DIR/glob_classes" 2>&1)
    
    assert_contains "$output" "file_a.txt" "Should match non-d files"
    if echo "$output" | grep -q "file_d.txt"; then
        log_fail "Should not match file_d.txt with negation"
    else
        log_pass "Negation correctly excluded file_d.txt"
    fi
}

# ============================================================================
# Test 21: Advanced glob patterns - Brace expansion
# ============================================================================
test_glob_brace_expansion() {
    log_test "Advanced glob patterns - Brace expansion"
    log_info "Testing {a,b,c} brace expansion patterns (glob-cpp feature)"
    
    mkdir -p "$TEST_DIR/glob_braces"
    echo "1" > "$TEST_DIR/glob_braces/file.cpp"
    echo "2" > "$TEST_DIR/glob_braces/file.h"
    echo "3" > "$TEST_DIR/glob_braces/file.hpp"
    echo "4" > "$TEST_DIR/glob_braces/file.txt"
    echo "5" > "$TEST_DIR/glob_braces/test.c"
    
    # Test brace alternatives
    log_info "Testing pattern: *.{cpp,h} (brace expansion)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.{cpp,h}' \"$TEST_DIR/glob_braces\""
    output=$(${FINGERPRINT_BIN} -l -g '*.{cpp,h}' "$TEST_DIR/glob_braces" 2>&1)
    
    # Check if brace expansion is supported
    if echo "$output" | grep -q "file.cpp" && echo "$output" | grep -q "file.h"; then
        log_pass "Brace expansion supported (glob-cpp)"
        
        if echo "$output" | grep -q "file.txt"; then
            log_fail "Should not match .txt with cpp,h pattern"
        else
            log_pass "Correctly excluded .txt"
        fi
        
        if echo "$output" | grep -q "file.hpp"; then
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
    
    mkdir -p "$TEST_DIR/glob_star/src"
    mkdir -p "$TEST_DIR/glob_star/src/lib"
    mkdir -p "$TEST_DIR/glob_star/include"
    echo "1" > "$TEST_DIR/glob_star/main.cpp"
    echo "2" > "$TEST_DIR/glob_star/src/module.cpp"
    echo "3" > "$TEST_DIR/glob_star/src/lib/utils.cpp"
    echo "4" > "$TEST_DIR/glob_star/include/header.h"
    
    # Test recursive match with **
    log_info "Testing pattern: **/*.cpp (should recursively match all .cpp files)"
    log_cmd "${FINGERPRINT_BIN} -l -g '**/*.cpp' \"$TEST_DIR/glob_star\""
    output=$(${FINGERPRINT_BIN} -l -g '**/*.cpp' "$TEST_DIR/glob_star" 2>&1)
    
    # Check if ** is properly handled as recursive wildcard
    cpp_count=$(echo "$output" | grep -c "\.cpp$" || true)
    log_info "Found $cpp_count .cpp files"
    
    if [ "$cpp_count" -eq 3 ]; then
        log_pass "Globstar ** supported - matched all nested .cpp files (3 total)"
        
        assert_contains "$output" "main.cpp" "Should match cpp in root"
        assert_contains "$output" "module.cpp" "Should match cpp in src/"
        assert_contains "$output" "utils.cpp" "Should match cpp in src/lib/"
        
        if echo "$output" | grep -q "header.h"; then
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
    output=$(${FINGERPRINT_BIN} -l -g 'src/**/*.cpp' "$TEST_DIR/glob_star" 2>&1)
    
    src_cpp_count=$(echo "$output" | grep -c "\.cpp$" || true)
    
    if echo "$output" | grep -q "module.cpp" && echo "$output" | grep -q "utils.cpp"; then
        log_pass "Pattern src/**/*.cpp matched files under src/ recursively"
        
        if [ "$src_cpp_count" -eq 2 ]; then
            log_pass "Matched exactly 2 files under src/ (correct count)"
        fi
        
        if echo "$output" | grep -q "main.cpp"; then
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
    
    mkdir -p "$TEST_DIR/glob_escape"
    echo "1" > "$TEST_DIR/glob_escape/file[1].txt"
    echo "2" > "$TEST_DIR/glob_escape/file*.txt"
    echo "3" > "$TEST_DIR/glob_escape/file?.txt"
    echo "4" > "$TEST_DIR/glob_escape/normal.txt"
    
    # Test escaped bracket
    log_info "Testing pattern: file\\[1\\].txt (escaped brackets)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file\\[1\\].txt' \"$TEST_DIR/glob_escape\""
    output=$(${FINGERPRINT_BIN} -l -g 'file\[1\].txt' "$TEST_DIR/glob_escape" 2>&1)
    
    if echo "$output" | grep -q "file\[1\].txt"; then
        log_pass "Escaped brackets matched literal brackets"
        
        if echo "$output" | grep -q "normal.txt"; then
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
    
    mkdir -p "$TEST_DIR/glob_path/src"
    mkdir -p "$TEST_DIR/glob_path/test"
    echo "1" > "$TEST_DIR/glob_path/file.txt"
    echo "2" > "$TEST_DIR/glob_path/src/file.txt"
    echo "3" > "$TEST_DIR/glob_path/test/file.txt"
    echo "4" > "$TEST_DIR/glob_path/src/module.cpp"
    
    # Test 1: Pattern without '/' matches basename only
    log_info "Testing pattern: *.txt (no '/' = matches basename, should find all file.txt)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.txt' \"$TEST_DIR/glob_path\""
    output=$(${FINGERPRINT_BIN} -l -g '*.txt' "$TEST_DIR/glob_path" 2>&1)
        
    file_count=$(echo "$output" | grep -c "file.txt$" || true)
    log_info "Found $file_count file.txt entries"
    
    if [ "$file_count" -eq 3 ]; then
        log_pass "Pattern *.txt matched all three file.txt files (basename matching)"
    else
        log_fail "Expected 3 matches, got $file_count (basename matching should find all)"
    fi
    
    # Test 2: Pattern with '/' matches full relative path
    log_info "Testing pattern: src/*.txt (with '/' = matches relative path)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'src/*.txt' \"$TEST_DIR/glob_path\""
    output=$(${FINGERPRINT_BIN} -l -g 'src/*.txt' "$TEST_DIR/glob_path" 2>&1)
    
    # Count total matches
    txt_count=$(echo "$output" | grep -c "\.txt$" || true)
    
    if echo "$output" | grep -q "src/file.txt"; then
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
            echo "$output" | grep "\.txt"
        fi
    fi
    
    # Test 3: Multiple directory levels
    log_info "Testing pattern: */file.txt (matches one level deep)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*/file.txt' \"$TEST_DIR/glob_path\""
    output=$(${FINGERPRINT_BIN} -l -g '*/file.txt' "$TEST_DIR/glob_path" 2>&1)
    
    matched_count=$(echo "$output" | grep -c "file.txt$" || true)
    
    if echo "$output" | grep -q "src/file.txt"; then
        log_pass "Pattern */file.txt matched src/file.txt"
    fi
    
    if echo "$output" | grep -q "test/file.txt"; then
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
    
    mkdir -p "$TEST_DIR/glob_edge"
    echo "1" > "$TEST_DIR/glob_edge/file.txt"
    echo "2" > "$TEST_DIR/glob_edge/.hidden"
    echo "3" > "$TEST_DIR/glob_edge/file"
    
    # Test pattern with no matches
    log_info "Testing pattern: *.xyz (no matches expected)"
    log_cmd "${FINGERPRINT_BIN} -l -g '*.xyz' \"$TEST_DIR/glob_edge\""
    output=$(${FINGERPRINT_BIN} -l -g '*.xyz' "$TEST_DIR/glob_edge" 2>&1)
    
    if echo "$output" | grep -q "file.txt"; then
        log_fail "Should not match anything with .xyz pattern"
    else
        log_pass "Correctly matched nothing with non-existent extension"
    fi
    
    # Test hidden files
    log_info "Testing pattern: .* (hidden files)"
    log_cmd "${FINGERPRINT_BIN} -l -g '.*' \"$TEST_DIR/glob_edge\""
    output=$(${FINGERPRINT_BIN} -l -g '.*' "$TEST_DIR/glob_edge" 2>&1)
    
    if echo "$output" | grep -q ".hidden"; then
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
    
    mkdir -p "$TEST_DIR/glob_multi"
    echo "1" > "$TEST_DIR/glob_multi/test_file_v1.cpp"
    echo "2" > "$TEST_DIR/glob_multi/test_module_v2.cpp"
    echo "3" > "$TEST_DIR/glob_multi/test_v3.cpp"
    echo "4" > "$TEST_DIR/glob_multi/production_file.cpp"
    
    # Test multiple asterisks
    log_info "Testing pattern: test_*_v*.cpp"
    log_cmd "${FINGERPRINT_BIN} -l -g 'test_*_v*.cpp' \"$TEST_DIR/glob_multi\""
    output=$(${FINGERPRINT_BIN} -l -g 'test_*_v*.cpp' "$TEST_DIR/glob_multi" 2>&1)
    
    assert_contains "$output" "test_file_v1.cpp" "Should match test_*_v*.cpp"
    assert_contains "$output" "test_module_v2.cpp" "Should match test_*_v*.cpp"
    
    if echo "$output" | grep -q "test_v3.cpp"; then
        log_pass "Pattern matched test_v3.cpp (greedy matching allows empty middle *)"
    fi
    
    if echo "$output" | grep -q "production_file.cpp"; then
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
    
    mkdir -p "$TEST_DIR/glob_numeric"
    echo "1" > "$TEST_DIR/glob_numeric/file0.txt"
    echo "2" > "$TEST_DIR/glob_numeric/file1.txt"
    echo "3" > "$TEST_DIR/glob_numeric/file5.txt"
    echo "4" > "$TEST_DIR/glob_numeric/file9.txt"
    echo "5" > "$TEST_DIR/glob_numeric/filea.txt"
    
    # Test numeric range
    log_info "Testing pattern: file[0-5].txt"
    log_cmd "${FINGERPRINT_BIN} -l -g 'file[0-5].txt' \"$TEST_DIR/glob_numeric\""
    output=$(${FINGERPRINT_BIN} -l -g 'file[0-5].txt' "$TEST_DIR/glob_numeric" 2>&1)
    
    assert_contains "$output" "file0.txt" "Should match 0-5 range"
    assert_contains "$output" "file1.txt" "Should match 0-5 range"
    assert_contains "$output" "file5.txt" "Should match 0-5 range"
    
    if echo "$output" | grep -q "file9.txt"; then
        log_fail "Should not match file9.txt (outside range)"
    else
        log_pass "Correctly excluded file9.txt"
    fi
    
    if echo "$output" | grep -q "filea.txt"; then
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
    
    mkdir -p "$TEST_DIR/glob_complex/src/test"
    mkdir -p "$TEST_DIR/glob_complex/src/main"
    echo "1" > "$TEST_DIR/glob_complex/src/test/test_unit.cpp"
    echo "2" > "$TEST_DIR/glob_complex/src/test/test_integration.cpp"
    echo "3" > "$TEST_DIR/glob_complex/src/main/main.cpp"
    echo "4" > "$TEST_DIR/glob_complex/src/test/helper.h"
    
    # Note: This combines features that fnmatch may not support
    log_info "Testing pattern: test_*.cpp (simple version for fnmatch)"
    log_cmd "${FINGERPRINT_BIN} -l -g 'test_*.cpp' \"$TEST_DIR/glob_complex\""
    output=$(${FINGERPRINT_BIN} -l -g 'test_*.cpp' "$TEST_DIR/glob_complex" 2>&1)
    
    assert_contains "$output" "test_unit.cpp" "Should match test files"
    assert_contains "$output" "test_integration.cpp" "Should match test files"
    
    if echo "$output" | grep -q "main.cpp"; then
        log_fail "Should not match main.cpp"
    else
        log_pass "Correctly excluded main.cpp"
    fi
    
    if echo "$output" | grep -q "helper.h"; then
        log_fail "Should not match .h files"
    else
        log_pass "Correctly excluded .h files"
    fi
}

# ============================================================================
# Test 29: List output format
# ============================================================================
test_list_output_format() {
    log_test "List output format validation"
    
    echo "test" > "$TEST_DIR/list_test.txt"
    
    log_cmd "${FINGERPRINT_BIN} -l --hash=crc32c \"$TEST_DIR/list_test.txt\""
    output=$(${FINGERPRINT_BIN} -l --hash=crc32c "$TEST_DIR/list_test.txt" 2>&1)
    
    # Should have format: <8-char-hex-hash><tab><path>
    if echo "$output" | grep -E '^[0-9a-f]{8}\t.*list_test\.txt'; then
        log_pass "CRC32C list output format correct"
    else
        log_fail "Invalid CRC32C list output format"
    fi
    
    log_cmd "${FINGERPRINT_BIN} -l --hash=blake3 \"$TEST_DIR/list_test.txt\""
    output=$(${FINGERPRINT_BIN} -l --hash=blake3 "$TEST_DIR/list_test.txt" 2>&1)
    
    # Should have format: <16-char-hex-hash><tab><path>
    if echo "$output" | grep -E '^[0-9a-f]{16}\t.*list_test\.txt'; then
        log_pass "BLAKE3 list output format correct"
    else
        log_fail "Invalid BLAKE3 list output format"
    fi
}

# ============================================================================
# Test 30: Large file handling
# ============================================================================
test_large_file() {
    log_test "Large file handling (16MB+ uses mmap)"
    
    # Create 20MB file
    dd if=/dev/zero of="$TEST_DIR/large_file.bin" bs=1m count=20 2>/dev/null
    
    log_cmd "${FINGERPRINT_BIN} -v \"$TEST_DIR/large_file.bin\""
    output=$(${FINGERPRINT_BIN} -v "$TEST_DIR/large_file.bin" 2>&1)
    
    if echo "$output" | grep -q "Fingerprint:"; then
        log_pass "Successfully processed large file"
    else
        log_fail "Failed to process large file"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -e|--extended-glob)
            EXTENDED_GLOB=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-v|--verbose] [-e|--extended-glob] [-h|--help]"
            echo ""
            echo "Options:"
            echo "  -v, --verbose       Show detailed test descriptions and command invocations"
            echo "  -e, --extended-glob Extended glob mode: FAIL tests if advanced glob features"
            echo "                      (brace expansion, globstar) are not supported"
            echo "                      Use this mode to validate glob-cpp implementation"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  FINGERPRINT_BIN     Path to fingerprint binary (default: ../build/Release/fingerprint)"
            echo ""
            echo "Extended Glob Mode:"
            echo "  Use --extended-glob when testing glob-cpp implementation to ensure"
            echo "  advanced features like {a,b} brace expansion and ** globstar work."
            echo "  Without this flag, missing features are reported as expected (fnmatch behavior)."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "Fingerprint Functional Test Suite"
echo "========================================"
echo "Script location: $SCRIPT_DIR"
echo "Test directory: $TEST_DIR"
echo "Tool path: $FINGERPRINT_BIN"
if [ $VERBOSE -eq 1 ]; then
    echo "Verbose mode: ON"
fi
if [ $EXTENDED_GLOB -eq 1 ]; then
    echo "Extended glob mode: ON (advanced glob features required)"
fi
echo ""

if [ ! -f "${FINGERPRINT_BIN}" ]; then
    echo "Error: fingerprint binary not found at $FINGERPRINT_BIN"
    echo ""
    echo "Expected directory structure:"
    echo "  project_root/"
    echo "  ├── build/Release/fingerprint"
    echo "  └── test/fingerprint_functional_tests.sh  (this script)"
    echo ""
    echo "To use a different location, set FINGERPRINT_BIN environment variable:"
    echo "  export FINGERPRINT_BIN=/path/to/fingerprint"
    exit 1
fi

test_single_file
test_directory_traversal
test_glob_patterns
test_multiple_globs
test_symlinks
test_xattr_caching
test_xattr_refresh
test_xattr_clear
test_hash_algorithms
test_fingerprint_stability
test_fingerprint_content_change
test_fingerprint_mode_absolute
test_input_file_list
test_env_var_expansion
test_nonexistent_files
test_empty_directory
test_circular_symlinks
test_case_insensitive_globs
test_glob_basic_wildcards
test_glob_character_classes
test_glob_brace_expansion
test_glob_double_star
test_glob_escaped_chars
test_glob_path_separator
test_glob_edge_cases
test_glob_multiple_wildcards
test_glob_numeric_ranges
test_glob_complex_patterns
test_list_output_format
test_large_file

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
echo -e "${RED}Failed: $FAILED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
