#!/bin/bash


# ============================================================================
# Test 34: Compare mode 1 - current run vs baseline (identical directory)
# ============================================================================
test_compare_previous_identical() {
    log_test "Compare mode 1: current run vs previous snapshot (identical directory)"
    log_info "Fingerprint a directory, compare a second run against the saved snapshot"

    /bin/mkdir -p "$TEST_DIR/cmp1_base"
    echo "alpha"   > "$TEST_DIR/cmp1_base/a.txt"
    echo "beta"    > "$TEST_DIR/cmp1_base/b.txt"
    echo "gamma"   > "$TEST_DIR/cmp1_base/c.cpp"

    # Create baseline snapshot
    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp1_baseline.tsv" "$TEST_DIR/cmp1_base" > /dev/null 2>&1

    # Re-fingerprint same directory, compare against baseline
    log_cmd "${FINGERPRINT_BIN} --xattr=off -s \"$TEST_DIR/cmp1_current.tsv\" -c \"$TEST_DIR/cmp1_baseline.tsv\" \"$TEST_DIR/cmp1_base\""
    local output=$(${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp1_current.tsv" -c "$TEST_DIR/cmp1_baseline.tsv" "$TEST_DIR/cmp1_base" 2>&1)

    if output_contains "$output" "identical"; then
        log_pass "Identical directory snapshots detected"
    else
        log_fail "Failed to detect identical directory snapshots"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 35: Compare mode 1 - current run vs baseline (modified file)
# ============================================================================
test_compare_previous_modified() {
    log_test "Compare mode 1: current run vs previous snapshot (modified file)"
    log_info "Modify one file in a directory, verify it is detected"

    /bin/mkdir -p "$TEST_DIR/cmp1_mod"
    echo "original_a" > "$TEST_DIR/cmp1_mod/a.txt"
    echo "original_b" > "$TEST_DIR/cmp1_mod/b.txt"
    echo "stable"     > "$TEST_DIR/cmp1_mod/c.txt"

    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp1_mod_baseline.tsv" "$TEST_DIR/cmp1_mod" > /dev/null 2>&1

    # Modify one file
    echo "changed_content" > "$TEST_DIR/cmp1_mod/a.txt"

    log_cmd "${FINGERPRINT_BIN} --xattr=off -s \"$TEST_DIR/cmp1_mod_current.tsv\" -c \"$TEST_DIR/cmp1_mod_baseline.tsv\" \"$TEST_DIR/cmp1_mod\""
    local output=$(${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp1_mod_current.tsv" -c "$TEST_DIR/cmp1_mod_baseline.tsv" "$TEST_DIR/cmp1_mod" 2>&1)

    if output_contains "$output" "hash:"; then
        log_pass "Detected modified file in directory"
    else
        log_fail "Failed to detect modified file"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 36: Compare mode 1 - current run vs baseline (added and removed files)
# ============================================================================
test_compare_previous_added_removed() {
    log_test "Compare mode 1: current run vs previous snapshot (added/removed files)"
    log_info "Add and remove files in a directory, verify both changes are detected"

    /bin/mkdir -p "$TEST_DIR/cmp1_ar"
    echo "keep"   > "$TEST_DIR/cmp1_ar/keep.txt"
    echo "remove" > "$TEST_DIR/cmp1_ar/remove.txt"

    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp1_ar_baseline.tsv" "$TEST_DIR/cmp1_ar" > /dev/null 2>&1

    /bin/rm "$TEST_DIR/cmp1_ar/remove.txt"
    echo "new_file" > "$TEST_DIR/cmp1_ar/added.txt"

    log_cmd "${FINGERPRINT_BIN} --xattr=off -s \"$TEST_DIR/cmp1_ar_current.tsv\" -c \"$TEST_DIR/cmp1_ar_baseline.tsv\" \"$TEST_DIR/cmp1_ar\""
    local output=$(${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp1_ar_current.tsv" -c "$TEST_DIR/cmp1_ar_baseline.tsv" "$TEST_DIR/cmp1_ar" 2>&1)

    local added_result=$(echo "$output" | /usr/bin/grep $'\tadded')
    local removed_result=$(echo "$output" | /usr/bin/grep $'\tremoved')
    if [ -n "$added_result" ] && [ -n "$removed_result" ]; then
        log_pass "Detected added and removed files"
    else
        log_fail "Failed to detect added/removed files"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 37: Compare mode 2 - two pre-built snapshots (identical)
# ============================================================================
test_compare_two_snapshots_identical() {
    log_test "Compare mode 2: two pre-built snapshots (identical directory)"
    log_info "Save two snapshots of the same unchanged directory, compare them directly"

    /bin/mkdir -p "$TEST_DIR/cmp2_id"
    echo "alpha" > "$TEST_DIR/cmp2_id/alpha.txt"
    echo "beta"  > "$TEST_DIR/cmp2_id/beta.txt"
    echo "gamma" > "$TEST_DIR/cmp2_id/gamma.cpp"

    # Save two snapshots of the same directory state
    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp2_snap1.tsv" "$TEST_DIR/cmp2_id" > /dev/null 2>&1
    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp2_snap2.tsv" "$TEST_DIR/cmp2_id" > /dev/null 2>&1

    log_cmd "${FINGERPRINT_BIN} -c \"$TEST_DIR/cmp2_snap1.tsv\" -c \"$TEST_DIR/cmp2_snap2.tsv\""
    local output=$(${FINGERPRINT_BIN} -c "$TEST_DIR/cmp2_snap1.tsv" -c "$TEST_DIR/cmp2_snap2.tsv" 2>&1)

    if output_contains "$output" "identical"; then
        log_pass "Two identical snapshots compared correctly"
    else
        log_fail "Failed to detect identical snapshots in mode 2"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 38: Compare mode 2 - two pre-built snapshots (different content)
# ============================================================================
test_compare_two_snapshots_different() {
    log_test "Compare mode 2: two pre-built snapshots (added/removed/modified)"
    log_info "Snapshot the same directory before and after changes, compare the two snapshots"

    /bin/mkdir -p "$TEST_DIR/cmp2_evolve"

    # "v1" state: three files
    echo "stable_content"   > "$TEST_DIR/cmp2_evolve/stable.txt"
    echo "original_content" > "$TEST_DIR/cmp2_evolve/changed.txt"
    echo "will_be_removed"  > "$TEST_DIR/cmp2_evolve/removed.txt"

    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp2_v1.tsv" "$TEST_DIR/cmp2_evolve" > /dev/null 2>&1

    # Mutate the directory: modify one file, remove one, add one
    echo "modified_content" > "$TEST_DIR/cmp2_evolve/changed.txt"
    /bin/rm "$TEST_DIR/cmp2_evolve/removed.txt"
    echo "brand_new"        > "$TEST_DIR/cmp2_evolve/added.txt"

    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp2_v2.tsv" "$TEST_DIR/cmp2_evolve" > /dev/null 2>&1

    log_cmd "${FINGERPRINT_BIN} -c \"$TEST_DIR/cmp2_v1.tsv\" -c \"$TEST_DIR/cmp2_v2.tsv\""
    local output=$(${FINGERPRINT_BIN} -c "$TEST_DIR/cmp2_v1.tsv" -c "$TEST_DIR/cmp2_v2.tsv" 2>&1)

    assert_contains "$output" "hash:" "Should detect modified file"
    assert_contains "$output" $'\tadded'   "Should detect added file"
    assert_contains "$output" $'\tremoved' "Should detect removed file"
}

# ============================================================================
# Test 39: Compare mode 2 - two pre-built plist snapshots (different content)
# ============================================================================
test_compare_two_snapshots_plist() {
    log_test "Compare mode 2: two pre-built plist snapshots (modified file)"
    log_info "Save plist snapshots before and after a file modification, compare them"

    /bin/mkdir -p "$TEST_DIR/cmp2_plist"
    echo "data1"    > "$TEST_DIR/cmp2_plist/file1.txt"
    echo "data2"    > "$TEST_DIR/cmp2_plist/file2.txt"
    echo "data3"    > "$TEST_DIR/cmp2_plist/file3.cpp"

    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp2_v1.plist" "$TEST_DIR/cmp2_plist" > /dev/null 2>&1

    # Modify one file
    echo "data2_modified" > "$TEST_DIR/cmp2_plist/file2.txt"

    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/cmp2_v2.plist" "$TEST_DIR/cmp2_plist" > /dev/null 2>&1

    log_cmd "${FINGERPRINT_BIN} -c \"$TEST_DIR/cmp2_v1.plist\" -c \"$TEST_DIR/cmp2_v2.plist\""
    local output=$(${FINGERPRINT_BIN} -c "$TEST_DIR/cmp2_v1.plist" -c "$TEST_DIR/cmp2_v2.plist" 2>&1)

    if output_contains "$output" "hash:"; then
        log_pass "Detected modification via plist snapshot comparison"
    else
        log_fail "Failed to detect modification in plist snapshots"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 40: Compare mode 1 - single -c without -s (auto temp snapshot TSV)
# ============================================================================
test_compare_single_no_snapshot_tsv() {
    log_test "Compare mode 1: single -c without -s (TSV auto temp snapshot)"
    log_info "Using -c without -s should create temp snapshot with same format as compare path"

    /bin/mkdir -p "$TEST_DIR/cmp_no_s"
    echo "alpha" > "$TEST_DIR/cmp_no_s/file1.txt"
    echo "beta"  > "$TEST_DIR/cmp_no_s/file2.txt"

    # Create baseline snapshot
    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/baseline.tsv" "$TEST_DIR/cmp_no_s" > /dev/null 2>&1

    # Modify one file
    echo "beta_modified" > "$TEST_DIR/cmp_no_s/file2.txt"

    # Compare without -s - should auto-create temp snapshot in same format
    log_cmd "${FINGERPRINT_BIN} --xattr=off -c \"$TEST_DIR/baseline.tsv\" \"$TEST_DIR/cmp_no_s\""
    local output=$(${FINGERPRINT_BIN} --xattr=off -c "$TEST_DIR/baseline.tsv" "$TEST_DIR/cmp_no_s" 2>&1)

    if output_contains "$output" "hash:"; then
        log_pass "Single -c without -s (TSV) detected modification"
    else
        log_fail "Single -c without -s (TSV) failed to detect modification"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 41: Compare mode 1 - single -c without -s (auto temp snapshot JSON)
# ============================================================================
test_compare_single_no_snapshot_json() {
    log_test "Compare mode 1: single -c without -s (JSON auto temp snapshot)"
    log_info "Using -c without -s should create temp snapshot matching compare path format"

    /bin/mkdir -p "$TEST_DIR/cmp_no_s_json"
    echo "content_a" > "$TEST_DIR/cmp_no_s_json/fileA.txt"
    echo "content_b" > "$TEST_DIR/cmp_no_s_json/fileB.txt"

    # Create baseline snapshot in JSON format
    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/baseline.json" "$TEST_DIR/cmp_no_s_json" > /dev/null 2>&1

    # Modify one file
    echo "content_b_changed" > "$TEST_DIR/cmp_no_s_json/fileB.txt"

    # Compare without -s using JSON compare path
    log_cmd "${FINGERPRINT_BIN} --xattr=off -c \"$TEST_DIR/baseline.json\" \"$TEST_DIR/cmp_no_s_json\""
    local output=$(${FINGERPRINT_BIN} --xattr=off -c "$TEST_DIR/baseline.json" "$TEST_DIR/cmp_no_s_json" 2>&1)

    if output_contains "$output" "hash:"; then
        log_pass "Single -c without -s (JSON) detected modification"
    else
        log_fail "Single -c without -s (JSON) failed to detect modification"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 42: Compare mode 1 - single -c without -s (auto temp snapshot plist)
# ============================================================================
test_compare_single_no_snapshot_plist() {
    log_test "Compare mode 1: single -c without -s (plist auto temp snapshot)"
    log_info "Using -c without -s should create temp snapshot matching compare path format"

    /bin/mkdir -p "$TEST_DIR/cmp_no_s_plist"
    echo "data_x" > "$TEST_DIR/cmp_no_s_plist/dataX.txt"
    echo "data_y" > "$TEST_DIR/cmp_no_s_plist/dataY.txt"

    # Create baseline snapshot in plist format
    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/baseline.plist" "$TEST_DIR/cmp_no_s_plist" > /dev/null 2>&1

    # Modify one file
    echo "data_y_updated" > "$TEST_DIR/cmp_no_s_plist/dataY.txt"

    # Compare without -s using plist compare path
    log_cmd "${FINGERPRINT_BIN} --xattr=off -c \"$TEST_DIR/baseline.plist\" \"$TEST_DIR/cmp_no_s_plist\""
    local output=$(${FINGERPRINT_BIN} --xattr=off -c "$TEST_DIR/baseline.plist" "$TEST_DIR/cmp_no_s_plist" 2>&1)

    if output_contains "$output" "hash:"; then
        log_pass "Single -c without -s (plist) detected modification"
    else
        log_fail "Single -c without -s (plist) failed to detect modification"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 43: Compare mode 1 - single -c without -s (identical files)
# ============================================================================
test_compare_single_no_snapshot_identical() {
    log_test "Compare mode 1: single -c without -s (identical directory)"
    log_info "Verify -c without -s works for identical directories (no changes)"

    /bin/mkdir -p "$TEST_DIR/cmp_no_s_ident"
    echo "same_content" > "$TEST_DIR/cmp_no_s_ident/file.txt"

    # Create baseline snapshot
    ${FINGERPRINT_BIN} --xattr=off -s "$TEST_DIR/identical_baseline.tsv" "$TEST_DIR/cmp_no_s_ident" > /dev/null 2>&1

    # Re-run fingerprint on same directory (no changes)
    log_cmd "${FINGERPRINT_BIN} --xattr=off -c \"$TEST_DIR/identical_baseline.tsv\" \"$TEST_DIR/cmp_no_s_ident\""
    local output=$(${FINGERPRINT_BIN} --xattr=off -c "$TEST_DIR/identical_baseline.tsv" "$TEST_DIR/cmp_no_s_ident" 2>&1)

    if output_contains "$output" "identical"; then
        log_pass "Single -c without -s detected identical directory"
    else
        log_fail "Single -c without -s failed to detect identical directory"
        log_info "Output: $output"
    fi
}

# ============================================================================
# Test 44: Compare mode - different hash algorithm (crc32c vs blake3)
# ============================================================================
test_compare_different_hash_algorithm() {
    log_test "Compare mode: different hash algorithm (crc32c vs blake3)"
    log_info "Verify warning is shown when hash algorithms differ between snapshots"

    /bin/mkdir -p "$TEST_DIR/cmp_hash_diff"
    echo "same_content" > "$TEST_DIR/cmp_hash_diff/file1.txt"
    echo "another_file" > "$TEST_DIR/cmp_hash_diff/file2.txt"

    # Create baseline with crc32c
    ${FINGERPRINT_BIN} --xattr=off --hash=crc32c -s "$TEST_DIR/baseline_crc32c.json" "$TEST_DIR/cmp_hash_diff" > /dev/null 2>&1

    # Create current snapshot with blake3
    ${FINGERPRINT_BIN} --xattr=off --hash=blake3 -s "$TEST_DIR/current_blake3.json" "$TEST_DIR/cmp_hash_diff" > /dev/null 2>&1

    # Compare the two snapshots
    log_cmd "${FINGERPRINT_BIN} -c \"$TEST_DIR/baseline_crc32c.json\" -c \"$TEST_DIR/current_blake3.json\""
    local output=$(${FINGERPRINT_BIN} -c "$TEST_DIR/baseline_crc32c.json" -c "$TEST_DIR/current_blake3.json" 2>&1)

    if output_contains "$output" "WARNING: Hash algorithms differ"; then
        log_pass "Warning shown for different hash algorithms"
    else
        log_fail "Missing warning for different hash algorithms"
        log_info "Output: $output"
    fi

    if output_contains "$output" "hash:"; then
        log_fail "Hash differences should not be reported when algorithms differ"
        log_info "Output: $output"
    else
        log_pass "Hash differences correctly ignored when algorithms differ"
    fi

    # Should still detect file modifications based on size/mtime even with different hashes
    # Add a file and compare again
    echo "new_file_content" > "$TEST_DIR/cmp_hash_diff/file3.txt"

    ${FINGERPRINT_BIN} --xattr=off --hash=blake3 -s "$TEST_DIR/current_blake3_v2.json" "$TEST_DIR/cmp_hash_diff" > /dev/null 2>&1

    log_cmd "${FINGERPRINT_BIN} -c \"$TEST_DIR/baseline_crc32c.json\" -c \"$TEST_DIR/current_blake3_v2.json\""
    local output=$(${FINGERPRINT_BIN} -c "$TEST_DIR/baseline_crc32c.json" -c "$TEST_DIR/current_blake3_v2.json" 2>&1)

    if output_contains "$output" $'\tadded'; then
        log_pass "Detected added file even with different hash algorithms"
    else
        log_fail "Failed to detect added file with different hash algorithms"
        log_info "Output: $output"
    fi
}


