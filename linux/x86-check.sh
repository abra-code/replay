#!/bin/bash
# Run the Linux build and test suites on x86_64 (plan Phase 3, private/linux_port_plan.md),
# on an Intel Mac with macOS 13 or newer, in a Lima virtual machine (Ubuntu 24.04, Apple's
# Virtualization framework). Run it from a copy of the sources on that Mac, such as the one
# linux/x86-check-send.sh puts there; it needs no Homebrew and no administrator rights.
#
# Usage: linux/x86-check.sh [--vm NAME] [--cpus N] [--memory GIB] [--disk GIB]
#                           [--stop | --delete | --keep] [--package] [debug|release|both]
#   --vm      the virtual machine's name (default replay-x86)
#   --cpus    its CPUs (default: all of the Mac's)
#   --memory  its memory in GiB (default: half of the Mac's, from 4 to 8)
#   --disk    its disk in GiB (default 40; used only when the machine is created)
#   --stop    stop the machine when done (default), --delete delete it, --keep leave it running
#   --package when every step passed, also pack the x86_64 release tarballs (linux/package.sh)
#             into the results folder's dist/; copy that folder to the development Mac for
#             linux/release.sh --x86_64 <folder>. Needs release or both.
#   debug|release|both   the configurations to build and test (default both)
#
# Steps:
#   1. Downloads Lima (pinned below, checked against its SHA-256 checksum) into
#      ~/.replay-x86-check/lima, once. Lima's own state (LIMA_HOME) goes to
#      ~/.replay-x86-check/lima-home, apart from any Lima or Colima already on the Mac.
#   2. Creates the machine from linux/x86-check.yaml (Lima downloads the Ubuntu image, about
#      700 MB, once), or starts it if it exists.
#   3. Copies these sources into the machine (/var/tmp/replay-x86/src), replacing the last copy.
#   4. Runs linux/x86-check-guest.sh there: the packages and the pinned swift.org toolchain are
#      installed once, then for each configuration a clean build, test_sandbox_linux.sh and
#      test_all.sh.
#   5. Stops the machine (see --stop).
# Everything printed also goes to ~/.replay-x86-check/results/<date-time>/x86-check.log.
# The Mac is kept awake while the script runs (caffeinate). On battery a closed lid still
# makes it sleep: keep it on power.
#
# Time: on a dual-core 2019 MacBook Air the first run took about 10 minutes (downloads of
# about 2 GB, two builds, four suite runs); later runs skip the downloads, not the builds.
#
# Notes:
# - Inside a command sandbox (such as an agent's) this script needs to run outside it: Lima
#   starts the Virtualization framework and listens on Unix sockets.
# - Remove everything: LIMA_HOME=~/.replay-x86-check/lima-home ~/.replay-x86-check/lima/bin/limactl delete --force replay-x86,
#   then rm -rf ~/.replay-x86-check. The Ubuntu image stays in Lima's download cache, ~/Library/Caches/lima.

LIMA_VERSION="2.2.1"
LIMA_SHA256="6b776e4bc41f358e6ee01fefcc78e2eb26f11635a0fcff632234af77a566c6c4"
LIMA_ARCHIVE="lima-$LIMA_VERSION-Darwin-x86_64.tar.gz"
LIMA_URL="https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/$LIMA_ARCHIVE"

VM="replay-x86"
CPUS=""
MEMORY=""
DISK="40"
WHEN_DONE="stop"
CONFIG="both"
PACKAGE=0
GUEST_DIR="/var/tmp/replay-x86"

need_value() {
    # $1: option; $2: the number of arguments left
    if [ "$2" -lt 2 ]; then
        echo "Error: $1 needs a value (see --help)" >&2
        exit 1
    fi
}

is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vm)
            need_value "$1" $#
            VM="$2"
            shift
            ;;
        --cpus)
            need_value "$1" $#
            CPUS="$2"
            shift
            ;;
        --memory)
            need_value "$1" $#
            MEMORY="$2"
            shift
            ;;
        --disk)
            need_value "$1" $#
            DISK="$2"
            shift
            ;;
        --stop)
            WHEN_DONE="stop"
            ;;
        --delete)
            WHEN_DONE="delete"
            ;;
        --keep)
            WHEN_DONE="keep"
            ;;
        --package)
            PACKAGE=1
            ;;
        debug|Debug|release|Release|both)
            CONFIG="$1"
            ;;
        -h|--help)
            /usr/bin/sed -n '2,41p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1' (see --help)" >&2
            exit 1
            ;;
    esac
    shift
done

case "$VM" in
    ''|*[!A-Za-z0-9-]*)
        echo "Error: --vm takes letters, digits and dashes only" >&2
        exit 1
        ;;
esac
case "$PACKAGE:$CONFIG" in
    1:debug|1:Debug)
        echo "Error: --package packs the release build; run release or both" >&2
        exit 1
        ;;
esac

HOST_OS="$(/usr/bin/uname -s)"
HOST_MACHINE="$(/usr/bin/uname -m)"
if [ "$HOST_OS" != "Darwin" ] || [ "$HOST_MACHINE" != "x86_64" ]; then
    echo "Error: this script is for an Intel Mac ($HOST_OS $HOST_MACHINE here). On Apple silicon use linux/kernel-check.sh." >&2
    exit 1
fi
MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if ! is_number "$MACOS_MAJOR" || [ "$MACOS_MAJOR" -lt 13 ]; then
    echo "Error: Lima's Virtualization framework machines need macOS 13 or newer (this Mac: $MACOS_VERSION)" >&2
    exit 1
fi

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ] || [ ! -f "$LINUX_DIR/x86-check-guest.sh" ]; then
    echo "Error: cannot find the replay sources above linux/" >&2
    exit 1
fi

if [ -z "$CPUS" ]; then
    CPUS="$(/usr/sbin/sysctl -n hw.ncpu)"
fi
if [ -z "$MEMORY" ]; then
    MEM_BYTES="$(/usr/sbin/sysctl -n hw.memsize)"
    if ! is_number "$MEM_BYTES"; then
        echo "Error: cannot read the Mac's memory size (sysctl hw.memsize: '$MEM_BYTES')" >&2
        exit 1
    fi
    MEMORY=$((MEM_BYTES / 1073741824 / 2))
    if [ "$MEMORY" -lt 4 ]; then
        MEMORY=4
    elif [ "$MEMORY" -gt 8 ]; then
        MEMORY=8
    fi
fi
for value in "$CPUS" "$MEMORY" "$DISK"; do
    if ! is_number "$value" || [ "$value" -lt 1 ]; then
        echo "Error: --cpus, --memory and --disk take whole numbers ('$value')" >&2
        exit 1
    fi
done

STATE_DIR="$HOME/.replay-x86-check"
LIMA_DIR="$STATE_DIR/lima"
LIMACTL="$LIMA_DIR/bin/limactl"
export LIMA_HOME="$STATE_DIR/lima-home"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
RESULTS_DIR="$STATE_DIR/results/$STAMP"
/bin/mkdir -p "$STATE_DIR/downloads" "$LIMA_HOME" "$RESULTS_DIR"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: cannot create the folders under $STATE_DIR" >&2
    exit 1
fi
LOG="$RESULTS_DIR/x86-check.log"

# Everything from here on goes to the screen and to the log.
exec > >(/usr/bin/tee -a "$LOG") 2>&1

# Keep the Mac awake (idle and system sleep) for as long as this script runs.
/usr/bin/caffeinate -i -s -w $$ &

echo "== $(/bin/date '+%Y-%m-%d %H:%M:%S'), log: $LOG"
echo "== Mac: macOS $MACOS_VERSION, $(/usr/sbin/sysctl -n machdep.cpu.brand_string), $(/usr/sbin/sysctl -n hw.ncpu) threads, $(( $(/usr/sbin/sysctl -n hw.memsize) / 1073741824 )) GiB"
CPU_FEATURES="$(/usr/sbin/sysctl -n machdep.cpu.features machdep.cpu.leaf7_features 2>/dev/null | /usr/bin/tr '\n' ' ')"
echo "== Mac CPU features (the ones the CRC32C and BLAKE3 code chooses between):"
present=""
for flag in SSE4.2 PCLMULQDQ AVX1.0 AVX2 AVX512F AVX512VL VPCLMULQDQ; do
    case " $CPU_FEATURES " in
        *" $flag "*) present="$present $flag" ;;
        *) present="$present (no $flag)" ;;
    esac
done
echo "  $present"
if [ -f "$REPO_DIR/SOURCE-INFO.txt" ]; then
    echo "== Sources: $(/bin/cat "$REPO_DIR/SOURCE-INFO.txt")"
fi

FREE_KB="$(/bin/df -k "$HOME" | /usr/bin/awk 'NR == 2 { print $4 }')"
if is_number "$FREE_KB" && [ "$FREE_KB" -lt $((DISK * 1048576 / 2)) ]; then
    echo "Warning: $((FREE_KB / 1048576)) GiB free in $HOME; the machine's disk grows up to $DISK GiB (about 15 GiB used after a run)"
fi

# 1. Lima
if [ ! -x "$LIMACTL" ] || [ ! -f "$LIMA_DIR/VERSION-$LIMA_VERSION" ]; then
    echo "== Downloading Lima $LIMA_VERSION"
    ARCHIVE="$STATE_DIR/downloads/$LIMA_ARCHIVE"
    /usr/bin/curl -fL --retry 3 -o "$ARCHIVE" "$LIMA_URL"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: downloading $LIMA_URL failed with status $status" >&2
        exit 1
    fi
    SUM_LINE="$(/usr/bin/shasum -a 256 "$ARCHIVE")"
    SUM="${SUM_LINE%% *}"
    if [ "$SUM" != "$LIMA_SHA256" ]; then
        echo "Error: $ARCHIVE has SHA-256 $SUM, expected $LIMA_SHA256; not installing it" >&2
        exit 1
    fi
    /bin/rm -rf "${LIMA_DIR:?}"
    /bin/mkdir -p "$LIMA_DIR"
    /usr/bin/tar -xzf "$ARCHIVE" -C "$LIMA_DIR"
    status=$?
    if [ "$status" -ne 0 ] || [ ! -x "$LIMACTL" ]; then
        echo "Error: unpacking $ARCHIVE into $LIMA_DIR failed (status $status)" >&2
        exit 1
    fi
    /usr/bin/touch "$LIMA_DIR/VERSION-$LIMA_VERSION"
fi
echo "== $("$LIMACTL" --version)"

# 2. The machine
VM_STATUS="$("$LIMACTL" list --format '{{.Status}}' "$VM" 2>/dev/null)"
if [ -z "$VM_STATUS" ]; then
    echo "== Creating the machine $VM ($CPUS CPUs, $MEMORY GiB memory, $DISK GiB disk)"
    "$LIMACTL" create --tty=false --name="$VM" --cpus="$CPUS" --memory="$MEMORY" --disk="$DISK" "$LINUX_DIR/x86-check.yaml"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: creating the machine $VM failed with status $status" >&2
        exit 1
    fi
    VM_STATUS="Stopped"
fi
if [ "$VM_STATUS" != "Running" ]; then
    echo "== Starting the machine $VM"
    "$LIMACTL" start --tty=false "$VM"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: starting the machine $VM failed with status $status (logs: $LIMA_HOME/$VM/*.log)" >&2
        exit 1
    fi
fi

# Runs a command in the machine, from its root folder (not the Mac's current folder).
guest() {
    "$LIMACTL" shell --workdir / "$VM" "$@"
}

# 3. The sources: everything here but build products, without macOS metadata files.
echo "== Copying the sources into the machine ($GUEST_DIR/src)"
# With sudo, so nothing in the copy can block its removal (a test cut short may leave folders
# without write permission).
guest /usr/bin/sudo -n /bin/rm -rf "${GUEST_DIR:?}/src"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: cannot remove the last copy of the sources, $GUEST_DIR/src, in the machine (status $status)" >&2
    exit 1
fi
guest /bin/mkdir -p "$GUEST_DIR/src"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: cannot create $GUEST_DIR/src in the machine" >&2
    exit 1
fi
COPYFILE_DISABLE=1 /usr/bin/tar -C "$REPO_DIR" --no-mac-metadata --no-xattrs \
    --exclude ./.build --exclude ./.build-linux --exclude ./.build-linux-review --exclude ./build \
    --exclude ./private --exclude ./.git --exclude .DS_Store -cf - . \
    | guest /usr/bin/tar -C "$GUEST_DIR/src" -xf - --no-same-owner --warning=no-unknown-keyword
copy_status=("${PIPESTATUS[@]}")
if [ "${copy_status[0]}" -ne 0 ] || [ "${copy_status[1]}" -ne 0 ]; then
    echo "Error: copying the sources failed (tar on the Mac: ${copy_status[0]}, in the machine: ${copy_status[1]})" >&2
    exit 1
fi

# 4. The tests
GUEST_ARGS=()
if [ "$PACKAGE" -eq 1 ]; then
    guest /bin/rm -rf "${GUEST_DIR:?}/dist"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Error: cannot remove the last release tarballs, $GUEST_DIR/dist, in the machine (status $status)" >&2
        exit 1
    fi
    GUEST_ARGS+=(--package "$GUEST_DIR/dist")
fi
GUEST_ARGS+=("$CONFIG")
echo "== Running linux/x86-check-guest.sh ${GUEST_ARGS[*]} in the machine"
# Without a terminal on stdin, so the log gets no carriage returns.
guest /bin/bash "$GUEST_DIR/src/linux/x86-check-guest.sh" "${GUEST_ARGS[@]}" < /dev/null
TEST_STATUS=$?

# The release tarballs, out of the machine (only when the guest packed them).
if [ "$PACKAGE" -eq 1 ] && [ "$TEST_STATUS" -eq 0 ]; then
    DIST_DIR="$RESULTS_DIR/dist"
    /bin/mkdir -p "$DIST_DIR"
    guest /usr/bin/tar -C "$GUEST_DIR/dist" -cf - . | /usr/bin/tar -xf - -C "$DIST_DIR"
    copy_status=("${PIPESTATUS[@]}")
    if [ "${copy_status[0]}" -ne 0 ] || [ "${copy_status[1]}" -ne 0 ]; then
        echo "Error: copying the release tarballs out of the machine failed (in the machine: ${copy_status[0]}, on the Mac: ${copy_status[1]})" >&2
        TEST_STATUS=1
    else
        echo "== Release tarballs for x86_64 in $DIST_DIR:"
        /bin/ls -l "$DIST_DIR" | /usr/bin/sed 1d
        echo "== Copy that folder to the development Mac, then run there: linux/release.sh --x86_64 <that folder>"
    fi
fi

# 5. Done
case "$WHEN_DONE" in
    stop)
        echo "== Stopping the machine $VM (start it again with: LIMA_HOME=$LIMA_HOME $LIMACTL start $VM)"
        "$LIMACTL" stop "$VM"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Warning: stopping the machine $VM failed with status $status; it may still be running (stop it with: LIMA_HOME=$LIMA_HOME $LIMACTL stop --force $VM)"
        fi
        ;;
    delete)
        echo "== Deleting the machine $VM"
        "$LIMACTL" delete --force "$VM"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Warning: deleting the machine $VM failed with status $status (retry: LIMA_HOME=$LIMA_HOME $LIMACTL delete --force $VM)"
        fi
        ;;
    keep)
        echo "== The machine $VM keeps running. Shell: LIMA_HOME=$LIMA_HOME $LIMACTL shell $VM"
        ;;
esac

echo "== Log: $LOG"
if [ "$TEST_STATUS" -ne 0 ]; then
    echo "== linux/x86-check-guest.sh exited with status $TEST_STATUS"
    exit 1
fi
exit 0
