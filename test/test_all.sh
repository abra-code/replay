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
SUITES_SKIP=0

declare -a TEST_NAMES
declare -a TEST_RESULTS

HOST_OS="$(/usr/bin/uname -s)"

if [ "$HOST_OS" = "Linux" ]; then
    # On kernels with 16 KiB or 64 KiB pages the Swift runtime, which CoreFoundation
    # loads, prints two "unable to protect ... swift-backtrace" lines on stderr at every
    # start. They land in output the suites compare. Turning the backtracer off stops
    # them; it only affects crash reports. A value set by the caller is kept.
    export SWIFT_BACKTRACE="${SWIFT_BACKTRACE:-enable=no}"

    # Sections of otherwise passing suites that cannot pass on Linux yet. Each suite
    # skips its section when the variable is set and prints the reason, which names
    # the plan phase (private/linux_port_plan.md) that removes it.
    export REPLAY_TEST_SKIP_IPC="IPC between dispatch and replay is not ported to Linux (Phase 4)"
fi

# Whole suites that cannot pass on Linux yet, with the reason and the plan phase
# (private/linux_port_plan.md) that removes the entry. Prints nothing for a suite
# that runs.
linux_skip_reason() {
    case "$1" in
        test_dispatch.sh)
            echo "IPC between dispatch and replay is not ported (Phase 4)" ;;
        test_replay_sandbox.sh|test_replay_auto_sandbox.sh|test_gate_auto_sandbox.sh|test_replay_cache_sandbox.py)
            echo "the sandbox is not ported and fails closed (Phase 5a)" ;;
        test_mcp_server.py)
            echo "MCP server mode starts sandboxed, and the sandbox fails closed (Phase 5a)" ;;
        test_sandbox_discover.py)
            echo "sandbox-discover.py is macOS only (later, not in the plan)" ;;
    esac
}

run_suite() {
    local script="$1"
    shift
    local name
    name="$(basename "$script")"
    if [ "$HOST_OS" = "Linux" ]; then
        local reason
        reason="$(linux_skip_reason "$name")"
        if [ -n "$reason" ]; then
            printf "${YELLOW}  SKIPPED on Linux: %s: %s${NC}\n" "$name" "$reason"
            SUITES_SKIP=$((SUITES_SKIP + 1))
            TEST_RESULTS+=("SKIP")
            TEST_NAMES+=("$name")
            return
        fi
    fi
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
run_suite "$SCRIPT_DIR/test_gate_env_list.sh"      "$BUILD_DIR/gate"
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
run_suite "$SCRIPT_DIR/test_dispatch_errors.sh"    "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_mcp_server.py"         "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_errors.py"      "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_stress_playlist.py" "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_execute_stress.py"  "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_cache_manifest.py"  "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_cache.py"           "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_clone.py"           "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_fs_semantics.py"    "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_cache_sandbox.py"   "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_replay_fingerprint_store.py" "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_readme_help_sync.py"       "$BUILD_DIR/replay"
run_suite "$SCRIPT_DIR/test_sandbox_discover.py"       "$BUILD_DIR/replay"

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
    elif [ "$result" = "SKIP" ]; then
        color="${YELLOW}"
    fi
    printf "%-45s ${color}%s${NC}\n" "$name" "$result"
done
printf '\n'

if [ "$SUITES_FAIL" -eq 0 ]; then
    printf "${BOLD}${GREEN}========================================${NC}\n"
    printf "${BOLD}${GREEN}  Suites: %d passed, %d failed, %d skipped${NC}\n" "$SUITES_PASS" "$SUITES_FAIL" "$SUITES_SKIP"
    printf "${BOLD}${GREEN}========================================${NC}\n"
else
    printf "${BOLD}${RED}========================================${NC}\n"
    printf "${BOLD}${RED}  Suites: %d passed, %d failed, %d skipped${NC}\n" "$SUITES_PASS" "$SUITES_FAIL" "$SUITES_SKIP"
    printf "${BOLD}${RED}========================================${NC}\n"
fi

[ "$SUITES_FAIL" -eq 0 ]
