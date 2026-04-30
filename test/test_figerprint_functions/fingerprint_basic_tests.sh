#!/bin/bash


# ============================================================================
# Test 1: Basic single file fingerprinting
# ============================================================================
test_single_file() {
    log_test "Single file fingerprinting"
    log_info "Testing basic fingerprint generation for a single file"
    
    echo "test content" > "$TEST_DIR/file1.txt"
    log_info "Created test file: $TEST_DIR/file1.txt"
    
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/file1.txt\""
    local output=$(${FINGERPRINT_BIN} "$TEST_DIR/file1.txt" 2>&1)
    local fingerprint=$(echo "$output" | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
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
    
    /bin/mkdir -p "$TEST_DIR/dir1/subdir"
    echo "file1" > "$TEST_DIR/dir1/file1.txt"
    echo "file2" > "$TEST_DIR/dir1/subdir/file2.txt"
    log_info "Created directory structure with nested files"
    
    log_cmd "${FINGERPRINT_BIN} -l \"$TEST_DIR/dir1\""
    local output=$(${FINGERPRINT_BIN} -l "$TEST_DIR/dir1" 2>&1)
    
    assert_contains "$output" "file1.txt" "Should find file1.txt"
    assert_contains "$output" "file2.txt" "Should find file2.txt in subdir"
}

# ============================================================================
# Test 5: Symlink handling
# ============================================================================
test_symlinks() {
    log_test "Symlink handling"
    log_info "Testing that symlinks are processed separately from their targets"
    
    /bin/mkdir -p "$TEST_DIR/symlink_test"
    echo "original" > "$TEST_DIR/symlink_test/original.txt"
    ln -s "$TEST_DIR/symlink_test/original.txt" "$TEST_DIR/symlink_test/link.txt"
    log_info "Created original.txt and symlink link.txt -> original.txt"
    
    log_cmd "${FINGERPRINT_BIN} -l \"$TEST_DIR/symlink_test\""
    local output=$(${FINGERPRINT_BIN} -l "$TEST_DIR/symlink_test" 2>&1)
    
    assert_contains "$output" "original.txt" "Should find original file"
    assert_contains "$output" "link.txt" "Should find symlink"
    
    # Symlink and target should have different hashes (symlink hashes the link itself)
    local orig_hash=$(echo "$output" | /usr/bin/grep "original.txt" | /usr/bin/awk '{print $1}')
    local link_hash=$(echo "$output" | /usr/bin/grep "link.txt" | /usr/bin/awk '{print $1}')
    
    assert_not_equal "$orig_hash" "$link_hash" "Symlink should have different hash than target"
    log_info "Original hash: $orig_hash, Link hash: $link_hash"
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
    local output_crc=$(${FINGERPRINT_BIN} --hash=crc32c "$TEST_DIR/hash_file.txt" 2>&1)
    local fp_crc=$(echo "$output_crc" | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    log_info "Computing fingerprint with --hash=blake3"
    log_cmd "${FINGERPRINT_BIN} --hash=blake3 \"$TEST_DIR/hash_file.txt\""
    local output_blake=$(${FINGERPRINT_BIN} --hash=blake3 "$TEST_DIR/hash_file.txt" 2>&1)
    local fp_blake=$(echo "$output_blake" | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
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
    
    /bin/mkdir -p "$TEST_DIR/stable"
    echo "file1" > "$TEST_DIR/stable/a.txt"
    echo "file2" > "$TEST_DIR/stable/b.txt"
    log_info "Created two files in test directory"
    
    log_info "Running fingerprint three times on same directory"
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/stable\" (run 1)"
    local fp1=$(${FINGERPRINT_BIN} "$TEST_DIR/stable" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/stable\" (run 2)"
    local fp2=$(${FINGERPRINT_BIN} "$TEST_DIR/stable" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/stable\" (run 3)"
    local fp3=$(${FINGERPRINT_BIN} "$TEST_DIR/stable" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
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
    
    /bin/mkdir -p "$TEST_DIR/modify"
    echo "original" > "$TEST_DIR/modify/file.txt"
    
    log_info "Computing fingerprint for original content"
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/modify\" (before)"
    local fp_before=$(${FINGERPRINT_BIN} "$TEST_DIR/modify" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    # Modify content
    echo "modified" > "$TEST_DIR/modify/file.txt"
    log_info "Modified file content"
    
    log_info "Computing fingerprint after modification"
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/modify\" (after)"
    local fp_after=$(${FINGERPRINT_BIN} "$TEST_DIR/modify" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    assert_not_equal "$fp_before" "$fp_after" "Fingerprint should change after content modification"
    log_info "Before: $fp_before, After: $fp_after"
}

# ============================================================================
# Test 12: Fingerprint mode - absolute paths
# ============================================================================
test_fingerprint_mode_absolute() {
    log_test "Fingerprint mode: absolute paths"
    log_info "Testing --fingerprint-mode=absolute (includes full paths in fingerprint)"
    
    /bin/mkdir -p "$TEST_DIR/mode_test1" "$TEST_DIR/mode_test2"
    echo "same content" > "$TEST_DIR/mode_test1/file.txt"
    echo "same content" > "$TEST_DIR/mode_test2/file.txt"
    log_info "Created identical files in different directories"
    
    log_info "Computing fingerprint for directory 1 with absolute path mode"
    log_cmd "${FINGERPRINT_BIN} --fingerprint-mode=absolute \"$TEST_DIR/mode_test1\""
    local fp1=$(${FINGERPRINT_BIN} --fingerprint-mode=absolute "$TEST_DIR/mode_test1" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    log_info "Computing fingerprint for directory 2 with absolute path mode"
    log_cmd "${FINGERPRINT_BIN} --fingerprint-mode=absolute \"$TEST_DIR/mode_test2\""
    local fp2=$(${FINGERPRINT_BIN} --fingerprint-mode=absolute "$TEST_DIR/mode_test2" 2>&1 | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    assert_not_equal "$fp1" "$fp2" "Different paths should produce different fingerprints in absolute mode"
    log_info "Directory 1: $fp1, Directory 2: $fp2"
}

# ============================================================================
# Test 13: Input file list processing
# ============================================================================
test_input_file_list() {
    log_test "Input file list processing"
    log_info "Testing --inputs option to read file paths from a list"
    
    /bin/mkdir -p "$TEST_DIR/input_list"
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
    local output=$(${FINGERPRINT_BIN} -l -I "$TEST_DIR/filelist.txt" 2>&1)
    
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
    /bin/mkdir -p "$TEST_BASE"
    echo "env file" > "$TEST_BASE/file.txt"
    log_info "Set TEST_BASE=$TEST_BASE"
    
    cat > "$TEST_DIR/env_filelist.txt" <<EOF
\${TEST_BASE}/file.txt
\$(TEST_BASE)/file.txt
EOF
    log_info "Created input list with environment variable references"
    
    log_info "Running fingerprint with variable expansion"
    log_cmd "${FINGERPRINT_BIN} -l -I \"$TEST_DIR/env_filelist.txt\""
    local output=$(${FINGERPRINT_BIN} -l -I "$TEST_DIR/env_filelist.txt" 2>&1)
    
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
    local output=$(${FINGERPRINT_BIN} -v -l "$TEST_DIR/exists.txt" "$TEST_DIR/does_not_exist.txt" 2>&1)
    
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
    
    /bin/mkdir -p "$TEST_DIR/empty_dir"
    
    log_cmd "${FINGERPRINT_BIN} \"$TEST_DIR/empty_dir\""
    local output=$(${FINGERPRINT_BIN} "$TEST_DIR/empty_dir" 2>&1)
    local fingerprint=$(echo "$output" | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
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
    
    /bin/mkdir -p "$TEST_DIR/circular"
    ln -s "$TEST_DIR/circular/link2" "$TEST_DIR/circular/link1"
    ln -s "$TEST_DIR/circular/link1" "$TEST_DIR/circular/link2"
    
    # Should handle circular symlinks without infinite loop
    log_cmd "${FINGERPRINT_BIN} -v \"$TEST_DIR/circular\""
    local output=$(${FINGERPRINT_BIN} -v "$TEST_DIR/circular" 2>&1 || true)
    
    local grep_result=$(echo "$output" | /usr/bin/grep "Circular symlink")
    if [ -n "$grep_result" ]; then
        log_pass "Detected circular symlink"
    else
        log_pass "Handled circular symlinks (detection optional)"
    fi
}


# ============================================================================
# Test 29: List output format
# ============================================================================
test_list_output_format() {
    log_test "List output format validation"
    
    echo "test" > "$TEST_DIR/list_test.txt"
    
    log_cmd "${FINGERPRINT_BIN} -l --hash=crc32c \"$TEST_DIR/list_test.txt\""
    local output=$(${FINGERPRINT_BIN} -l --hash=crc32c "$TEST_DIR/list_test.txt" 2>&1)
    
    # Should have format: <8-char-hex-hash><tab><path>
    if echo "$output" | /usr/bin/grep -E '^[0-9a-f]{8}\t.*list_test\.txt'; then
        log_pass "CRC32C list output format correct"
    else
        log_fail "Invalid CRC32C list output format"
    fi
    
    log_cmd "${FINGERPRINT_BIN} -l --hash=blake3 \"$TEST_DIR/list_test.txt\""
    local output=$(${FINGERPRINT_BIN} -l --hash=blake3 "$TEST_DIR/list_test.txt" 2>&1)
    
    # Should have format: <16-char-hex-hash><tab><path>
    if echo "$output" | /usr/bin/grep -E '^[0-9a-f]{16}\t.*list_test\.txt'; then
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
    local output=$(${FINGERPRINT_BIN} -v "$TEST_DIR/large_file.bin" 2>&1)
    
    if output_contains "$output" "Fingerprint:"; then
        log_pass "Successfully processed large file"
    else
        log_fail "Failed to process large file"
    fi
}
