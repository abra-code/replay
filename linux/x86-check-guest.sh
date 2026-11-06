#!/bin/bash
# Runs inside the Lima virtual machine of linux/x86-check.sh (Ubuntu 24.04, x86_64), as the
# guest's user, from the copy of the sources that linux/x86-check.sh puts there. Plan Phase 3
# (private/linux_port_plan.md): the build and the test suites on x86_64.
#
# Usage: linux/x86-check-guest.sh [--package DIR] [debug|release|both]   (default both)
#   --package DIR  when every step passed, also pack the release build with linux/package.sh
#                  into DIR (the release tarballs for x86_64; needs release or both)
#
# Steps:
#   1. Installs (once, with sudo) what the Swift toolchain links against, the test tools, and
#      gcc-multilib, which lets test_sandbox_linux.sh build a 32-bit probe for the system call
#      filter's i386 entry.
#   2. Installs (once) the swift.org toolchain pinned below into /usr, with the script of the
#      agent-vm recipe (linux/agent-vm/swift-toolchain/files/install-swift.sh), checked
#      against its SHA-256. Ubuntu 24.04 is the system release builds are made on (plan D3).
#   3. For each configuration: builds the tools (build-linux.sh, .build-linux/x86_64/<config>),
#      then runs test_sandbox_linux.sh and test_all.sh (which includes
#      test_crc32c_variants.sh, the x86_64 CRC32C variants this CPU can run).
#
# Exit: 0 = every step passed, 1 = a step failed, 2 = setup failed

# The swift.org toolchain: the release of linux/swift-image (checked below), swift.org's
# Ubuntu 24.04 x86_64 build. The SHA-256 was taken on 2026-11-05 from a download whose
# swift.org signature was checked with gpg ("Swift 6.x Release Signing Key", key
# 52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F). Bump all three together.
SWIFT_VERSION="6.2.4"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_SHA256="15608c4fa0364ef906014343d81639cf58169e8a40de2b2d3503c3f35a8bb66d"

# What swift.org's Ubuntu 24.04 toolchain needs (the packages of the official Swift image),
# and the test suite's tools: attr (xattr tests), zip (a test playlist runs /usr/bin/zip),
# curl (test_replay_sandbox.sh), python3 with jsonschema (test_mcp_server.py). No Ubuntu
# clang: the toolchain's own clang lands in /usr/bin.
PACKAGES=(binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev
    libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata
    zlib1g-dev attr zip curl ca-certificates python3 python3-jsonschema gcc-multilib)

CONFIGS="debug release"
PACKAGE_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --package)
            if [ $# -lt 2 ]; then
                echo "Error: --package needs a folder" >&2
                exit 2
            fi
            PACKAGE_DIR="$2"
            shift
            ;;
        debug|Debug)
            CONFIGS="debug"
            ;;
        release|Release)
            CONFIGS="release"
            ;;
        both)
            CONFIGS="debug release"
            ;;
        -h|--help)
            /usr/bin/sed -n '2,21p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1' (see --help)" >&2
            exit 2
            ;;
    esac
    shift
done
if [ -n "$PACKAGE_DIR" ] && [ "$CONFIGS" = "debug" ]; then
    echo "Error: --package packs the release build; run release or both" >&2
    exit 2
fi

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find the repository root above linux/" >&2
    exit 2
fi
MACHINE="$(/usr/bin/uname -m)"
if [ "$MACHINE" != "x86_64" ]; then
    echo "Error: this script is for the x86_64 guest of linux/x86-check.sh, not $MACHINE" >&2
    exit 2
fi

# The Docker pin names the release too (swift:<version>-noble@sha256:...); the two must agree.
PINNED_IMAGE="$(/usr/bin/grep -v '^#' "$LINUX_DIR/swift-image" | /usr/bin/head -n 1)"
case "$PINNED_IMAGE" in
    "swift:$SWIFT_VERSION-"*) ;;
    *)
        echo "Error: linux/swift-image pins '$PINNED_IMAGE', but this script installs Swift $SWIFT_VERSION; bump SWIFT_VERSION, SWIFT_PLATFORM and SWIFT_SHA256 here" >&2
        exit 2
        ;;
esac

echo "== Guest: $(/usr/bin/uname -srm)"
OS_NAME="$(. /etc/os-release && echo "$PRETTY_NAME")"
echo "== Distribution: $OS_NAME"
# The CPU features the CRC32C and BLAKE3 code chooses between, as the guest sees them.
CPU_FLAGS="$(/usr/bin/grep -m 1 '^flags' /proc/cpuinfo)"
CPU_MODEL="$(/usr/bin/grep -m 1 '^model name' /proc/cpuinfo)"
echo "== CPU: ${CPU_MODEL#*: }, $(/usr/bin/nproc) threads"
present=""
for flag in sse4_2 pclmulqdq avx avx2 avx512f avx512vl vpclmulqdq; do
    case " ${CPU_FLAGS#*: } " in
        *" $flag "*) present="$present $flag" ;;
        *) present="$present (no $flag)" ;;
    esac
done
echo "== CPU features:$present"

APT_LOG="/var/tmp/replay-x86-apt.log"
echo "== Installing the packages (once; log: $APT_LOG)"
# Soon after a new machine boots, Ubuntu's own apt timers may hold apt's locks. apt-get
# update never waits for its lock, so it is tried again; install waits (Lock::Timeout).
: > "$APT_LOG"
for attempt in 1 2 3 4 5 6; do
    /usr/bin/sudo -n /usr/bin/env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0 update >> "$APT_LOG" 2>&1
    status=$?
    if [ "$status" -eq 0 ]; then
        break
    fi
    if [ "$attempt" -lt 6 ]; then
        echo "  apt-get update failed with status $status (attempt $attempt of 6); trying again in 20 seconds"
        /bin/sleep 20
    fi
done
if [ "$status" -ne 0 ]; then
    echo "Error: apt-get update failed with status $status (log: $APT_LOG):" >&2
    /usr/bin/tail -5 "$APT_LOG" >&2
    exit 2
fi
/usr/bin/sudo -n /usr/bin/env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0 \
    -o DPkg::Lock::Timeout=600 install --no-install-recommends "${PACKAGES[@]}" >> "$APT_LOG" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: installing the packages failed with status $status (log: $APT_LOG):" >&2
    /usr/bin/tail -5 "$APT_LOG" >&2
    exit 2
fi

echo "== Installing Swift $SWIFT_VERSION from swift.org (once, about 1 GB)"
/usr/bin/sudo -n /bin/bash "$LINUX_DIR/agent-vm/swift-toolchain/files/install-swift.sh" \
    "$SWIFT_VERSION" "$SWIFT_PLATFORM" "$SWIFT_SHA256"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: installing the Swift toolchain failed with status $status" >&2
    exit 2
fi

failures=0
results=""

# Records one step's result. $1: status; $2: what.
record() {
    if [ "$1" -eq 0 ]; then
        results="$results
  PASS: $2"
    else
        results="$results
  FAIL: $2 (status $1)"
        failures=$((failures + 1))
    fi
}

for config in $CONFIGS; do
    BUILD_DIR="$REPO_DIR/.build-linux/x86_64/$config"

    echo ""
    echo "== [$config] Building"
    "$REPO_DIR/build-linux.sh" "$config"
    status=$?
    record "$status" "[$config] build"
    if [ "$status" -ne 0 ] || [ ! -x "$BUILD_DIR/replay" ]; then
        echo "Error: the $config build failed; skipping its tests" >&2
        continue
    fi

    echo ""
    echo "== [$config] test_sandbox_linux.sh"
    "$REPO_DIR/test/test_sandbox_linux.sh" "$BUILD_DIR/replay"
    record $? "[$config] test_sandbox_linux.sh"

    echo ""
    echo "== [$config] test_all.sh"
    "$REPO_DIR/test/test_all.sh" "$BUILD_DIR"
    record $? "[$config] test_all.sh"
done

echo ""
echo "== Summary on $(/usr/bin/uname -r):$results"
if [ "$failures" -ne 0 ]; then
    echo "== $failures step(s) failed"
    if [ -n "$PACKAGE_DIR" ]; then
        echo "== Not packing the release: a step failed"
    fi
    exit 1
fi
echo "== All steps passed"

if [ -n "$PACKAGE_DIR" ]; then
    echo ""
    echo "== Packing the release build into $PACKAGE_DIR"
    "$LINUX_DIR/package.sh" --no-build --out "$PACKAGE_DIR"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: linux/package.sh failed with status $status" >&2
        exit 1
    fi
fi
exit 0
