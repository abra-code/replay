#!/bin/bash
# Builds fast-crc32 with every CRC32C variant and checks each one this CPU can run
# (test/crc32c_variants_check.c): published check values, agreement with the portable
# variant over many lengths and alignments, continuing a checksum, and which variant each
# set of CPU features selects.
#
# On an Apple silicon Mac all aarch64 variants run natively; the x86_64 ones also run when
# Rosetta is installed. On Linux, the variants of the machine's own architecture.
#
# Usage: test_crc32c_variants.sh   (it builds its own binaries from the sources, so it needs
#        no build folder; arguments are ignored)
# Exit:  0 = all checks passed, 1 = a check or a build failed, 2 = no clang or no temporary folder

SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
SRC_DIR="$REPO_DIR/fast-crc32"

# Clang, not cc: the sources use #pragma clang attribute, and on Linux /usr/bin/cc is
# often GCC.
if [ -x /usr/bin/clang ]; then
    C_COMPILER=/usr/bin/clang
else
    echo "Error: no clang at /usr/bin/clang" >&2
    exit 2
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/crc32c-variants.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "Error: could not create a temporary folder" >&2
    exit 2
fi

cleanup() {
    /bin/rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT

SOURCES=(
    "$SRC_DIR/crc32c_arch.c"
    "$SRC_DIR/crc32c_select.c"
    "$SRC_DIR/crc32c_portable.c"
    "$SRC_DIR/crc32c_hw.c"
    "$SRC_DIR/crc32c_neon_eor3.c"
    "$SRC_DIR/crc32c_neon.c"
    "$SRC_DIR/crc32c_sse.c"
    "$SCRIPT_DIR/crc32c_variants_check.c"
)

failures=0
runs=0

# Builds for one architecture and runs the result. $1: a label; $2: the run prefix
# ("" or "/usr/bin/arch -x86_64"); the rest: extra compiler flags.
build_and_run() {
    local label="$1"
    local run_prefix="$2"
    shift 2
    local binary="$WORK_DIR/check-$label"
    local build_log
    build_log="$("$C_COMPILER" -std=c11 -O2 -Wall -Wextra -Werror -DCRC32C_ALL_VARIANTS -I "$SRC_DIR" "$@" \
        -o "$binary" "${SOURCES[@]}" -lpthread 2>&1)"
    local build_status=$?
    if [ "$build_status" -ne 0 ]; then
        echo "Error: building the $label check failed (status $build_status):" >&2
        echo "$build_log" >&2
        failures=$((failures + 1))
        return
    fi

    echo ""
    echo "=== $label ==="
    if [ -n "$run_prefix" ]; then
        $run_prefix "$binary"
    else
        "$binary"
    fi
    local run_status=$?
    runs=$((runs + 1))
    if [ "$run_status" -ne 0 ]; then
        failures=$((failures + 1))
    fi
}

HOST_OS="$(/usr/bin/uname -s)"
HOST_ARCH="$(/usr/bin/uname -m)"

build_and_run "native-$HOST_ARCH" ""

# On an Apple silicon Mac, the x86_64 build as well, under Rosetta when it is installed.
if [ "$HOST_OS" = "Darwin" ] && [ "$HOST_ARCH" = "arm64" ]; then
    /usr/bin/arch -x86_64 /usr/bin/true > /dev/null 2>&1
    rosetta_status=$?
    if [ "$rosetta_status" -eq 0 ]; then
        build_and_run "x86_64-rosetta" "/usr/bin/arch -x86_64" -arch x86_64
    else
        echo ""
        echo "  skipped: x86_64 variants (Rosetta is not installed)"
    fi
fi

echo ""
if [ "$failures" -ne 0 ]; then
    echo "FAILED: $failures of the builds or runs failed"
    exit 1
fi
echo "All $runs run(s) passed"
exit 0
