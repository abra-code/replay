#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
BUILD_DIR="${1:-$REPO_DIR/build/Release}"

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SUITES_PASS=0
SUITES_FAIL=0

run_suite() {
    local script="$1"
    shift
    local name
    name="$(basename "$script")"
    printf '\n'
    printf "${BOLD}${CYAN}========================================${NC}\n"
    printf "${BOLD}${CYAN}  %s${NC}\n" "$name"
    printf "${BOLD}${CYAN}========================================${NC}\n"
    if "$script" "$@"; then
        SUITES_PASS=$((SUITES_PASS + 1))
        printf "${GREEN}  PASSED: %s${NC}\n" "$name"
    else
        SUITES_FAIL=$((SUITES_FAIL + 1))
        printf "${RED}  FAILED: %s${NC}\n" "$name"
    fi
}

run_suite "$SCRIPT_DIR/test_fingerprint.sh"        "$BUILD_DIR/fingerprint"
run_suite "$SCRIPT_DIR/test_gate.sh"               "$BUILD_DIR/gate"
run_suite "$SCRIPT_DIR/test_glob_pattern_overlap.sh" "$BUILD_DIR/globoverlap"
run_suite "$SCRIPT_DIR/test_replay.sh"             "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_glob.sh"        "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_glob_action.sh" "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_info.sh"        "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_list_tree.sh"   "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_read.sh"        "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_dispatch.sh"           "$BUILD_DIR/replay"

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
