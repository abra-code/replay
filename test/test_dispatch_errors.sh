#!/bin/bash
# test_dispatch_errors.sh — tests for dispatch parameter validation and error paths
#
# Coverage:
#   - wait on a non-existent batch (warning + non-zero exit)
#   - invalid action name
#   - per-action missing-argument validation for every action type

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
REPLAY="${1:-$REPO_DIR/build/Release/replay}"

if [ ! -x "$REPLAY" ]; then
    echo "error: replay not found at $REPLAY"
    echo "usage: $0 [path/to/replay]"
    exit 1
fi

DISPATCH="$(dirname "$REPLAY")/dispatch"
if [ ! -x "$DISPATCH" ]; then
    echo "error: dispatch not found at $DISPATCH"
    exit 1
fi

PASS=0
FAIL=0
BATCH="dispatch-err-test-$$"
TEST_DIR=$(/usr/bin/mktemp -d)
trap "/bin/rm -rf '$TEST_DIR'" EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ============================================================
echo "=== wait on non-existent batch ==="

# Use a batch name that no server has ever started
GHOST_BATCH="no-such-batch-$$-ghost"
output=$("$DISPATCH" "$GHOST_BATCH" wait 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
    pass "1. wait on non-existent batch exits non-zero"
else
    fail "1. wait on non-existent batch should exit non-zero (got $rc)"
fi

if echo "$output" | /usr/bin/grep -qi "warning\|not running"; then
    pass "2. wait on non-existent batch prints a warning"
else
    fail "2. wait on non-existent batch should print a warning"
    echo "   output: $output"
fi

# ============================================================
echo "=== action parameter validation (server must be running) ==="

# Start a server so subsequent dispatches can connect without starting a new one.
# Using --dry-run so the server doesn't actually touch the filesystem.
"$DISPATCH" "$BATCH" start --dry-run
/bin/sleep 0.3

# ---- invalid action name ----
output=$("$DISPATCH" "$BATCH" bogusaction_xyz 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "3. invalid action name exits non-zero"
else
    fail "3. invalid action name should exit non-zero (got $rc)"
fi
if echo "$output" | /usr/bin/grep -qi "invalid\|error"; then
    pass "4. invalid action name prints an error message"
else
    fail "4. invalid action name should print an error message"
    echo "   output: $output"
fi

# ---- clone: only one path (missing 'to') ----
output=$("$DISPATCH" "$BATCH" clone /only/one/path 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "5. clone with missing 'to' path exits non-zero"
else
    fail "5. clone with missing 'to' path should exit non-zero (got $rc)"
fi

# ---- copy: only one path ----
output=$("$DISPATCH" "$BATCH" copy /only/one/path 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "6. copy with missing 'to' path exits non-zero"
else
    fail "6. copy with missing 'to' path should exit non-zero (got $rc)"
fi

# ---- move: only one path ----
output=$("$DISPATCH" "$BATCH" move /only/one/path 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "7. move with missing 'to' path exits non-zero"
else
    fail "7. move with missing 'to' path should exit non-zero (got $rc)"
fi

# ---- delete: no paths ----
output=$("$DISPATCH" "$BATCH" delete 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "8. delete with no paths exits non-zero"
else
    fail "8. delete with no paths should exit non-zero (got $rc)"
fi

# ---- read: no paths ----
output=$("$DISPATCH" "$BATCH" read 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "9. read with no paths exits non-zero"
else
    fail "9. read with no paths should exit non-zero (got $rc)"
fi

# ---- list: no directory ----
output=$("$DISPATCH" "$BATCH" list 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "10. list with no directory exits non-zero"
else
    fail "10. list with no directory should exit non-zero (got $rc)"
fi

# ---- tree: no directory ----
output=$("$DISPATCH" "$BATCH" tree 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "11. tree with no directory exits non-zero"
else
    fail "11. tree with no directory should exit non-zero (got $rc)"
fi

# ---- info: no path ----
output=$("$DISPATCH" "$BATCH" info 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "12. info with no path exits non-zero"
else
    fail "12. info with no path should exit non-zero (got $rc)"
fi

# ---- execute: no tool ----
output=$("$DISPATCH" "$BATCH" execute 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "13. execute with no tool exits non-zero"
else
    fail "13. execute with no tool should exit non-zero (got $rc)"
fi

# ---- echo: no text ----
output=$("$DISPATCH" "$BATCH" echo 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "14. echo with no text exits non-zero"
else
    fail "14. echo with no text should exit non-zero (got $rc)"
fi

# ---- glob: root only, no pattern ----
output=$("$DISPATCH" "$BATCH" glob /tmp 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "15. glob with root but no pattern exits non-zero"
else
    fail "15. glob with no pattern should exit non-zero (got $rc)"
fi

# ---- glob: no args at all ----
output=$("$DISPATCH" "$BATCH" glob 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "16. glob with no args exits non-zero"
else
    fail "16. glob with no args should exit non-zero (got $rc)"
fi

# ---- create: no type or path ----
output=$("$DISPATCH" "$BATCH" create 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "17. create with no arguments exits non-zero"
else
    fail "17. create with no arguments should exit non-zero (got $rc)"
fi

# ---- create: unknown type keyword ----
output=$("$DISPATCH" "$BATCH" create bogustype /some/path 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "18. create with unknown type exits non-zero"
else
    fail "18. create with unknown type should exit non-zero (got $rc)"
fi

# ---- create file blob: missing base64 ----
output=$("$DISPATCH" "$BATCH" create file "$TEST_DIR/out.bin" blob 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "19. create file blob with no base64 exits non-zero"
else
    fail "19. create file blob missing base64 should exit non-zero (got $rc)"
fi

# ---- edit: missing all args ----
output=$("$DISPATCH" "$BATCH" edit 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "20. edit with no args exits non-zero"
else
    fail "20. edit with no args should exit non-zero (got $rc)"
fi

# ---- edit: path and oldText only (missing newText) ----
output=$("$DISPATCH" "$BATCH" edit /some/path "oldText" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "21. edit with only path+oldText (missing newText) exits non-zero"
else
    fail "21. edit missing newText should exit non-zero (got $rc)"
fi

# Clean up: send wait so the server shuts down before we delete the temp dir
"$DISPATCH" "$BATCH" wait 2>/dev/null || true

# ============================================================
echo ""
echo "========================================"
printf "  Dispatch error tests: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ]
