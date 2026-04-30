#!/bin/bash


# ============================================================================
# Test 31: Snapshot - TSV format
# ============================================================================
test_snapshot_tsv() {
    log_test "Snapshot - TSV format"
    
    # Create test files
    echo "content1" > "$TEST_DIR/file1.txt"
    echo "content2" > "$TEST_DIR/file2.txt"
    
    log_cmd "${FINGERPRINT_BIN} -s \"$TEST_DIR/snapshot.tsv\" \"$TEST_DIR\""
    local output=$(${FINGERPRINT_BIN} -s "$TEST_DIR/snapshot.tsv" "$TEST_DIR" 2>&1)
    
    if [ -f "$TEST_DIR/snapshot.tsv" ]; then
        log_pass "TSV snapshot file created"
    else
        log_fail "Failed to create TSV snapshot"
        return
    fi
    
    # Check header
    local head_result=$(head -1 "$TEST_DIR/snapshot.tsv")
    if output_contains "$head_result" "path"; then
        log_pass "TSV has correct header"
    else
        log_fail "TSV header incorrect"
    fi
    
    # Check content contains file paths
    local grep_result1=$(/usr/bin/grep "file1.txt" "$TEST_DIR/snapshot.tsv")
    local grep_result2=$(/usr/bin/grep "file2.txt" "$TEST_DIR/snapshot.tsv")
    if [ -n "$grep_result1" ] && [ -n "$grep_result2" ]; then
        log_pass "TSV contains file entries"
    else
        log_fail "TSV missing file entries"
    fi
}

# ============================================================================
# Test 32: Snapshot - JSON format
# ============================================================================
test_snapshot_json() {
    log_test "Snapshot - JSON format"
    
    log_cmd "${FINGERPRINT_BIN} -s \"$TEST_DIR/snapshot.json\" \"$TEST_DIR\""
    local output=$(${FINGERPRINT_BIN} -s "$TEST_DIR/snapshot.json" "$TEST_DIR" 2>&1)
    
    if [ -f "$TEST_DIR/snapshot.json" ]; then
        log_pass "JSON snapshot file created"
    else
        log_fail "Failed to create JSON snapshot"
        return
    fi
    
    # Check valid JSON
    if python3 -c "import json; json.load(open('$TEST_DIR/snapshot.json'))" 2>/dev/null; then
        log_pass "JSON is valid"
    else
        log_fail "JSON is invalid"
    fi
    
    # Check contains expected keys
    if python3 -c "import json; d=json.load(open('$TEST_DIR/snapshot.json')); assert 'files' in d and 'fingerprint_params' in d" 2>/dev/null; then
        log_pass "JSON has required keys"
    else
        log_fail "JSON missing required keys"
    fi
}

# ============================================================================
# Test 33: Snapshot - plist format
# ============================================================================
test_snapshot_plist() {
    log_test "Snapshot - plist format"
    
    log_cmd "${FINGERPRINT_BIN} -s \"$TEST_DIR/snapshot.plist\" \"$TEST_DIR\""
    local output=$(${FINGERPRINT_BIN} -s "$TEST_DIR/snapshot.plist" "$TEST_DIR" 2>&1)
    
    if [ -f "$TEST_DIR/snapshot.plist" ]; then
        log_pass "plist snapshot file created"
    else
        log_fail "Failed to create plist snapshot"
        return
    fi
    
    # Check valid plist
    if plutil -p "$TEST_DIR/snapshot.plist" > /dev/null 2>&1; then
        log_pass "plist is valid"
    else
        log_fail "plist is invalid"
    fi
}

