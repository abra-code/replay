#!/bin/bash
# Regenerate the vendored CRC32C variants with corsix/fast-crc32's generator.
#
# Usage: fast-crc32/generate-variants.sh [--check]
#   (no option)  download the pinned generate.c, build it in a temporary folder, generate
#                every variant listed below and write it into this folder.
#   --check      generate into the temporary folder only and compare with the files here;
#                exit 1 if any file is missing or differs. Writes nothing.
#
# The generator is pinned to one upstream commit and checked against its SHA-256, so a
# rerun builds exactly the same tool. Upstream: https://github.com/corsix/fast-crc32
# Each variant is a file named ab_<isa>_crc32c_<algorithm>.c; the generator writes its own
# command line into the file's first lines, which is why it runs as ./generate.
#
# Needs: curl, a C compiler at /usr/bin/cc or /usr/bin/clang, and shasum (macOS) or sha256sum (Linux).

GENERATOR_COMMIT="13f5289ceb6065d014f9e1e64f161ea7a926c3b7"
GENERATOR_SHA256="d6980f19f0d814ffb9cf2a48692c13b2ae36d04325ff93f411498e5aa2329bf1"
GENERATOR_URL="https://raw.githubusercontent.com/corsix/fast-crc32/$GENERATOR_COMMIT/generate.c"

# isa:algorithm, polynomial crc32c for all. Fastest first per architecture; the run-time
# choice between them lives in crc32c_arch.c.
#   neon_eor3  aarch64 with CRC, PMULL and EOR3 (the SHA3 extension): Apple silicon, Graviton3+
#   neon       aarch64 with CRC and PMULL, no EOR3: Graviton2, Ampere Altra, Raspberry Pi 5
#   sse        x86_64 with SSE4.2 and PCLMULQDQ
VARIANTS=(
    "neon_eor3:v9s3x2e_s3"
    "neon:v3s4x2e_v2"
    "sse:v4s3x3k4096e"
)

CHECK_ONLY=0
case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help)
        /usr/bin/sed -n '2,15p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "Error: unknown option '$1' (use --check or --help)" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/crc32c_arch.c" ]; then
    echo "Error: cannot find crc32c_arch.c next to $0" >&2
    exit 1
fi

if [ -x /usr/bin/shasum ]; then
    SHA256_TOOL=(/usr/bin/shasum -a 256)
elif [ -x /usr/bin/sha256sum ]; then
    SHA256_TOOL=(/usr/bin/sha256sum)
else
    echo "Error: neither /usr/bin/shasum nor /usr/bin/sha256sum is available to verify the download" >&2
    exit 1
fi

# /usr/bin/cc on macOS and most Linux systems; the Swift Linux images ship only clang.
if [ -x /usr/bin/cc ]; then
    C_COMPILER=/usr/bin/cc
elif [ -x /usr/bin/clang ]; then
    C_COMPILER=/usr/bin/clang
else
    echo "Error: no C compiler at /usr/bin/cc or /usr/bin/clang (macOS: xcode-select --install; Debian/Ubuntu: apt-get install gcc)" >&2
    exit 1
fi

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/fast-crc32-gen.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "Error: could not create a temporary folder" >&2
    exit 1
fi

cleanup() {
    /bin/rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT

echo "Downloading generate.c at $GENERATOR_COMMIT"
/usr/bin/curl -fsSL -o "$WORK_DIR/generate.c" "$GENERATOR_URL"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: download failed (curl status $status): $GENERATOR_URL" >&2
    exit 1
fi

sha_line="$("${SHA256_TOOL[@]}" "$WORK_DIR/generate.c")"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: could not hash the downloaded generate.c" >&2
    exit 1
fi
actual_sha="${sha_line%% *}"
if [ "$actual_sha" != "$GENERATOR_SHA256" ]; then
    echo "Error: generate.c has SHA-256 $actual_sha, expected $GENERATOR_SHA256." >&2
    echo "The download does not match the pinned commit; nothing was built." >&2
    exit 1
fi

echo "Building the generator"
build_log="$( cd "$WORK_DIR" && "$C_COMPILER" -O2 -o generate generate.c 2>&1 )"
status=$?
if [ "$status" -ne 0 ] || [ ! -x "$WORK_DIR/generate" ]; then
    echo "Error: building generate.c failed (status $status):" >&2
    echo "$build_log" >&2
    exit 1
fi

changed=0
for variant in "${VARIANTS[@]}"; do
    isa="${variant%%:*}"
    algorithm="${variant#*:}"
    name="ab_${isa}_crc32c_${algorithm}.c"

    gen_log="$( cd "$WORK_DIR" && ./generate -i "$isa" -p crc32c -a "$algorithm" -o "$name" 2>&1 )"
    status=$?
    if [ "$status" -ne 0 ] || [ ! -s "$WORK_DIR/$name" ]; then
        echo "Error: generating $name failed (status $status):" >&2
        echo "$gen_log" >&2
        exit 1
    fi

    target="$SCRIPT_DIR/$name"
    if [ ! -f "$target" ]; then
        state="new"
    else
        /usr/bin/cmp -s "$WORK_DIR/$name" "$target"
        status=$?
        if [ "$status" -eq 0 ]; then
            state="unchanged"
        else
            # The first three lines are the generator's comment header (command line and
            # license); a difference only there leaves the code as it was.
            /usr/bin/tail -n +4 "$WORK_DIR/$name" > "$WORK_DIR/$name.body"
            status=$?
            if [ "$status" -ne 0 ]; then
                echo "Error: could not strip the header of the generated $name" >&2
                exit 1
            fi
            /usr/bin/tail -n +4 "$target" > "$WORK_DIR/$name.oldbody"
            status=$?
            if [ "$status" -ne 0 ]; then
                echo "Error: could not read $target" >&2
                exit 1
            fi
            /usr/bin/cmp -s "$WORK_DIR/$name.body" "$WORK_DIR/$name.oldbody"
            status=$?
            if [ "$status" -eq 0 ]; then
                state="header only"
            else
                state="code changed"
            fi
        fi
    fi

    if [ "$state" != "unchanged" ]; then
        changed=$((changed + 1))
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        printf '  %-40s %s\n' "$name" "$state"
        continue
    fi

    if [ "$state" != "unchanged" ]; then
        /bin/cp "$WORK_DIR/$name" "$target"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: could not write $target" >&2
            exit 1
        fi
    fi
    printf '  %-40s %s\n' "$name" "$state"
done

if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ "$changed" -ne 0 ]; then
        echo "$changed file(s) differ from what the pinned generator produces."
        exit 1
    fi
    echo "All variants match the pinned generator."
    exit 0
fi

echo "Done: $changed file(s) written in $SCRIPT_DIR. Review with: git diff -- fast-crc32"
exit 0
