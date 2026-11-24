#!/bin/bash

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
    local output1=$(${FINGERPRINT_BIN} -v --xattr=on "$TEST_DIR/xattr_file.txt" 2>&1)
    local time1=$(echo "$output1" | /usr/bin/grep "Total execution time:" | /usr/bin/awk '{print $4}')
    
    # Second run - should use cached hash
    log_info "Second run: should use cached hash from xattr"
    log_cmd "${FINGERPRINT_BIN} -v --xattr=on \"$TEST_DIR/xattr_file.txt\" (cached run)"
    local output2=$(${FINGERPRINT_BIN} -v --xattr=on "$TEST_DIR/xattr_file.txt" 2>&1)
    local time2=$(echo "$output2" | /usr/bin/grep "Total execution time:" | /usr/bin/awk '{print $4}')
    
    local fingerprint1=$(echo "$output1" | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    local fingerprint2=$(echo "$output2" | /usr/bin/grep "Fingerprint:" | /usr/bin/awk '{print $2}')
    
    assert_equal "$fingerprint1" "$fingerprint2" "Cached fingerprint should match original"
    log_info "First run: ${time1}ms, Second run: ${time2}ms"
    
    # Check if xattr was written
    local xattr_result=$(list_xattr_names "$TEST_DIR/xattr_file.txt" | /usr/bin/grep "public.fingerprint")
    if [ -n "$xattr_result" ]; then
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
    local output=$(${FINGERPRINT_BIN} -v --xattr=refresh "$TEST_DIR/refresh_file.txt" 2>&1)
    
    local xattr_result=$(list_xattr_names "$TEST_DIR/refresh_file.txt" | /usr/bin/grep "public.fingerprint")
    if [ -n "$xattr_result" ]; then
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
    
    local xattr_result=$(list_xattr_names "$TEST_DIR/clear_file.txt" | /usr/bin/grep "public.fingerprint")
    if [ -n "$xattr_result" ]; then
        log_fail "Xattr should be cleared"
    else
        log_pass "Xattr successfully cleared"
    fi
}


# The fingerprint xattr is written only on files of the user running fingerprint: another user's
# file keeps its attributes and its mode. Needs root to give a file away; skipped
# otherwise.
test_xattr_not_owned() {
    log_test "Xattr written only on own files"
    local own_uid
    own_uid=$(/usr/bin/id -u)
    if [ "$own_uid" != "0" ]; then
        log_info "SKIP: needs root to give a file to another user"
        return
    fi
    echo "not owned" > "$TEST_DIR/not_owned.txt"
    /bin/chmod 444 "$TEST_DIR/not_owned.txt"
    local chown_bin=/bin/chown
    if [ -x /usr/sbin/chown ]; then
        chown_bin=/usr/sbin/chown
    fi
    "$chown_bin" 12345 "$TEST_DIR/not_owned.txt"
    local chown_status=$?
    if [ "$chown_status" -ne 0 ]; then
        log_fail "Could not give $TEST_DIR/not_owned.txt to uid 12345 with $chown_bin (status $chown_status)"
        return
    fi
    local mode_before
    mode_before=$(/bin/ls -l "$TEST_DIR/not_owned.txt" | /usr/bin/cut -c1-10)
    local output
    output=$(${FINGERPRINT_BIN} --xattr=on "$TEST_DIR/not_owned.txt" 2>&1)
    local status=$?
    local names
    names=$(list_xattr_names "$TEST_DIR/not_owned.txt" | /usr/bin/grep "public.fingerprint")
    local mode_after
    mode_after=$(/bin/ls -l "$TEST_DIR/not_owned.txt" | /usr/bin/cut -c1-10)
    if [ "$status" -eq 0 ] && [ -z "$names" ] && [ "$mode_before" = "$mode_after" ]; then
        log_pass "Another user's file gets no fingerprint xattr and keeps its mode ($mode_after)"
    else
        log_fail "Another user's file gets no fingerprint xattr and keeps its mode (status $status, attributes \"$names\", mode $mode_before -> $mode_after): $output"
    fi
}
