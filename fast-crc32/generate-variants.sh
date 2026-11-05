#!/bin/bash
# Regenerate the vendored CRC32C variants with corsix/fast-crc32's generator.
#
# Usage: fast-crc32/generate-variants.sh [--latest] [--check]
#   (no option)  download the pinned generate.c, build it in a temporary folder, generate
#                every variant listed below, write it into this folder, and run
#                test/test_crc32c_variants.sh when a file changed.
#   --latest     use upstream's newest commit (main) instead of the pinned one. When the
#                variant test passes (or no file changed), the pin below moves to that
#                commit and its SHA-256, so committing the script and the files records
#                exactly what was used.
#   --check      generate into the temporary folder only and compare with the files here;
#                exit 1 if any file is missing or differs. Writes nothing. With --latest:
#                would upstream's newest commit change anything?
#
# The generator is pinned to one upstream commit and checked against its SHA-256, so a
# rerun builds exactly the same tool. Upstream: https://github.com/corsix/fast-crc32
# Each variant is a file named ab_<isa>_crc32c_<algorithm>.c; the generator writes its own
# command line into the file's first lines, which is why it runs as ./generate.
#
# Needs: curl, a C compiler at /usr/bin/cc or /usr/bin/clang, shasum (macOS) or sha256sum
# (Linux); with --latest also git; for the variant test, clang.

GENERATOR_COMMIT="13f5289ceb6065d014f9e1e64f161ea7a926c3b7"
GENERATOR_SHA256="d6980f19f0d814ffb9cf2a48692c13b2ae36d04325ff93f411498e5aa2329bf1"
UPSTREAM_REPO="https://github.com/corsix/fast-crc32"

# isa:algorithm, polynomial crc32c for all. Fastest first per architecture; the run-time
# choice between them lives in crc32c_arch.c and crc32c_select.c.
#   neon_eor3  aarch64 with CRC, PMULL and EOR3 (the SHA3 extension): Apple silicon, Graviton3+
#   neon       aarch64 with CRC and PMULL, no EOR3: Graviton2, Ampere Altra, Raspberry Pi 5
#   sse        x86_64 with SSE4.2 and PCLMULQDQ
VARIANTS=(
    "neon_eor3:v9s3x2e_s3"
    "neon:v3s4x2e_v2"
    "sse:v4s3x3k4096e"
)

CHECK_ONLY=0
LATEST=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --latest) LATEST=1 ;;
        -h|--help)
            /usr/bin/sed -n -e '2,/^$/{' -e '/^$/d' -e 's/^# \{0,1\}//' -e 'p' -e '}' "$0"
            exit 0
            ;;
        *)
            echo "Error: unknown option '$arg' (use --latest, --check or --help)" >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/generate-variants.sh"
if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/crc32c_arch.c" ] || [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: cannot find crc32c_arch.c and generate-variants.sh next to $0" >&2
    exit 1
fi
VARIANT_TEST="$SCRIPT_DIR/../test/test_crc32c_variants.sh"

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

COMMIT="$GENERATOR_COMMIT"
if [ "$LATEST" -eq 1 ]; then
    if [ ! -x /usr/bin/git ]; then
        echo "Error: --latest needs git at /usr/bin/git to find upstream's newest commit" >&2
        exit 1
    fi
    # No prompt: if the repository ever moves or turns private, fail instead of waiting.
    ls_remote="$(GIT_TERMINAL_PROMPT=0 /usr/bin/git ls-remote "$UPSTREAM_REPO" refs/heads/main 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: git ls-remote $UPSTREAM_REPO failed (status $status):" >&2
        echo "$ls_remote" >&2
        exit 1
    fi
    COMMIT="${ls_remote%%[[:space:]]*}"
    case "$COMMIT" in
        ""|*[!0-9a-f]*)
            echo "Error: unexpected answer from git ls-remote: $ls_remote" >&2
            exit 1
            ;;
    esac
    if [ "${#COMMIT}" -ne 40 ]; then
        echo "Error: unexpected commit id from git ls-remote: $COMMIT" >&2
        exit 1
    fi
    if [ "$COMMIT" = "$GENERATOR_COMMIT" ]; then
        echo "Upstream main is the pinned commit $GENERATOR_COMMIT"
    else
        echo "Upstream main is $COMMIT (pinned: $GENERATOR_COMMIT)"
        echo "Upstream changes: $UPSTREAM_REPO/compare/$GENERATOR_COMMIT...$COMMIT"
    fi
fi
GENERATOR_URL="https://raw.githubusercontent.com/corsix/fast-crc32/$COMMIT/generate.c"

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

echo "Downloading generate.c at $COMMIT"
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
if [ "$COMMIT" = "$GENERATOR_COMMIT" ]; then
    if [ "$actual_sha" != "$GENERATOR_SHA256" ]; then
        echo "Error: generate.c has SHA-256 $actual_sha, expected $GENERATOR_SHA256." >&2
        echo "The download does not match the pinned commit; nothing was built." >&2
        exit 1
    fi
else
    # A commit not pinned yet has no recorded hash to compare with; this one becomes the
    # pin once the variants pass their test.
    case "$actual_sha" in
        ""|*[!0-9a-f]*)
            echo "Error: unexpected SHA-256 output: $sha_line" >&2
            exit 1
            ;;
    esac
    if [ "${#actual_sha}" -ne 64 ]; then
        echo "Error: unexpected SHA-256 output: $sha_line" >&2
        exit 1
    fi
    echo "generate.c at $COMMIT has SHA-256 $actual_sha"
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
        echo "$changed file(s) differ from what the generator at $COMMIT produces."
        exit 1
    fi
    echo "All variants match the generator at $COMMIT."
    exit 0
fi

if [ "$changed" -gt 0 ]; then
    echo ""
    echo "Testing the variants: $VARIANT_TEST"
    "$VARIANT_TEST"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "" >&2
        echo "Error: the variant test failed (status $status). The new files are in place for" >&2
        echo "inspection, but the pin was not moved; restore with: git checkout -- 'fast-crc32/ab_*.c'" >&2
        echo "(a variant file that is new, untracked, has to be deleted by hand)" >&2
        exit 1
    fi
fi

# Move the pin last, and only after the test passed. The new script is written beside the
# old one and moved over it, so the copy bash is reading from stays intact.
if [ "$COMMIT" != "$GENERATOR_COMMIT" ]; then
    new_script="$SCRIPT_DIR/.generate-variants.sh.new"
    /bin/cp -p "$SCRIPT_PATH" "$new_script"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: could not create $new_script to move the pin" >&2
        exit 1
    fi
    /usr/bin/sed -e "s/^GENERATOR_COMMIT=\"[0-9a-f]*\"\$/GENERATOR_COMMIT=\"$COMMIT\"/" \
        -e "s/^GENERATOR_SHA256=\"[0-9a-f]*\"\$/GENERATOR_SHA256=\"$actual_sha\"/" \
        "$SCRIPT_PATH" > "$new_script"
    status=$?
    pinned_lines="$(/usr/bin/grep -c -e "^GENERATOR_COMMIT=\"$COMMIT\"\$" -e "^GENERATOR_SHA256=\"$actual_sha\"\$" "$new_script")"
    if [ "$status" -ne 0 ] || [ "$pinned_lines" != "2" ]; then
        /bin/rm -f "${new_script:?}"
        echo "Error: could not rewrite the pin in $SCRIPT_PATH; set it by hand:" >&2
        echo "  GENERATOR_COMMIT=\"$COMMIT\"" >&2
        echo "  GENERATOR_SHA256=\"$actual_sha\"" >&2
        exit 1
    fi
    /bin/mv -f "$new_script" "$SCRIPT_PATH"
    status=$?
    if [ "$status" -ne 0 ]; then
        /bin/rm -f "${new_script:?}"
        echo "Error: could not replace $SCRIPT_PATH to move the pin" >&2
        exit 1
    fi
    echo "Pin moved to $COMMIT"
fi

echo "Done: $changed file(s) written in $SCRIPT_DIR. Review with: git diff -- fast-crc32"
exit 0
