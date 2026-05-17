#!/bin/bash
# Don't exit on error - we want to run all tests and report failures
set -uo pipefail

# Functional tests for fingerprint tool
# This script (fingerprint_functional_tests.sh) should be placed in the "test" directory
# next to the "build" directory

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# First positional arg (if not a flag) is the binary path; env var FINGERPRINT_BIN also works.
if [ $# -gt 0 ] && [ "${1:0:1}" != "-" ]; then
    FINGERPRINT_BIN="$1"
    shift
else
    FINGERPRINT_BIN="${FINGERPRINT_BIN:-${SCRIPT_DIR}/../build/Release/fingerprint}"
fi

TEST_DIR=$(/usr/bin/mktemp -d -t fingerprint_tests)
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
    /bin/rm -rf "$TEST_DIR"
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
    
    local grep_result=$(echo "$haystack" | /usr/bin/grep "$needle")
    if [ -n "$grep_result" ]; then
        log_pass "$message"
    else
        log_fail "$message"
        echo "  Looking for: $needle"
        echo "  In: $haystack"
    fi
}

output_contains() {
    local output="$1"
    local pattern="$2"
    local result=$(echo "$output" | /usr/bin/grep "$pattern")
    [ -n "$result" ]
}

output_not_contains() {
    local output="$1"
    local pattern="$2"
    local result=$(echo "$output" | /usr/bin/grep "$pattern")
    [ -z "$result" ]
}

source "${SCRIPT_DIR}/test_fingerprint_functions/fingerprint_basic_tests.sh"
source "${SCRIPT_DIR}/test_fingerprint_functions/fingerprint_xattr_tests.sh"
source "${SCRIPT_DIR}/test_fingerprint_functions/fingerprint_glob_tests.sh"
source "${SCRIPT_DIR}/test_fingerprint_functions/fingerprint_snapshot_tests.sh"
source "${SCRIPT_DIR}/test_fingerprint_functions/fingerprint_compare_tests.sh"
source "${SCRIPT_DIR}/test_fingerprint_functions/fingerprint_exclude_tests.sh"

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
test_glob_case_insensitive
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
test_snapshot_tsv
test_snapshot_json
test_snapshot_plist
test_compare_previous_identical
test_compare_previous_modified
test_compare_previous_added_removed
test_compare_two_snapshots_identical
test_compare_two_snapshots_different
test_compare_two_snapshots_plist
test_compare_single_no_snapshot_tsv
test_compare_single_no_snapshot_json
test_compare_single_no_snapshot_plist
test_compare_single_no_snapshot_identical
test_compare_different_hash_algorithm

test_exclude_basic_glob
test_exclude_literal_dir
test_exclude_changing_excluded_file
test_exclude_changing_kept_file
test_exclude_relative_to_search_dir
test_exclude_relative_glob_in_search_dir

echo ""

# ============================================================================
# Test Results
# ============================================================================

echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"
else
    echo "Failed: $FAILED_TESTS"
fi
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi

