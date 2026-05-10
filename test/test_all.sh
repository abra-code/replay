#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
BUILD_DIR="${1:-$REPO_DIR/build/Release}"

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

SUITES_PASS=0
SUITES_FAIL=0

declare -a TEST_NAMES
declare -a TEST_RESULTS

run_suite() {
    local script="$1"
    shift
    local name
    name="$(basename "$script")"
    printf '\n'
    printf "${BOLD}${CYAN}========================================${NC}\n"
    printf "${BOLD}${CYAN}  %s${NC}\n" "$name"
    printf "${BOLD}${CYAN}========================================${NC}\n"
    local result=0
    if "$script" "$@"; then
        SUITES_PASS=$((SUITES_PASS + 1))
        printf "${GREEN}  PASSED: %s${NC}\n" "$name"
        TEST_RESULTS+=("PASS")
    else
        SUITES_FAIL=$((SUITES_FAIL + 1))
        printf "${RED}  FAILED: %s${NC}\n" "$name"
        TEST_RESULTS+=("FAIL")
    fi
    TEST_NAMES+=("$name")
}

run_suite "$SCRIPT_DIR/test_fingerprint.sh"        "$BUILD_DIR/fingerprint"
run_suite "$SCRIPT_DIR/test_gate.sh"               "$BUILD_DIR/gate"
run_suite "$SCRIPT_DIR/test_gate_auto_sandbox.sh" "$BUILD_DIR/gate"
run_suite "$SCRIPT_DIR/test_glob_pattern_overlap.sh" "$BUILD_DIR/globoverlap"
run_suite "$SCRIPT_DIR/test_replay.sh"             "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_glob.sh"        "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_glob_action.sh" "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_info.sh"        "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_list_tree.sh"   "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_read.sh"        "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_edit.sh"        "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_concurrency_stress.sh" "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_sandbox.sh"     "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_auto_sandbox.sh" "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_dispatch.sh"           "$BUILD_DIR/replay"

printf '\n'
printf "${BOLD}========================================${NC}\n"
printf "${BOLD}  Summary${NC}\n"
printf "${BOLD}========================================${NC}\n"
printf '\n'
printf "%-45s %s\n" "Test" "Result"
printf "%-45s %s\n" "----" "------"
for i in "${!TEST_NAMES[@]}"; do
    name="${TEST_NAMES[$i]}"
    result="${TEST_RESULTS[$i]}"
    color="${GREEN}"
    if [ "$result" = "FAIL" ]; then
        color="${RED}"
    fi
    printf "%-45s ${color}%s${NC}\n" "$name" "$result"
done
printf '\n'

if [ "$SUITES_FAIL" -eq 0 ]; then
    printf "${BOLD}${GREEN}========================================${NC}\n"
    printf "${BOLD}${GREEN}  Suites: %d passed, %d failed${NC}\n" "$SUITES_PASS" "$SUITES_FAIL"
    printf "${BOLD}${GREEN}========================================${NC}\n"
else
    printf "${BOLD}${RED}========================================${NC}\n"
    printf "${BOLD}${RED}  Suites: %d passed, %d failed${NC}\n" "$SUITES_PASS" "$SUITES_FAIL"
    printf "${BOLD}${RED}========================================${NC}\n"
fi

[ "$SUITES_FAIL" -eq 0 ]
