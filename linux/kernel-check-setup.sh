#!/bin/bash
# Runs as root inside the agent-vm box of linux/kernel-check.sh: installs what the test suites
# need from the distribution, on Ubuntu or Debian. Safe to run again: apt skips what is installed.
#   libswiftlang        the Swift runtime, in /usr/libexec/swift/lib/swift/linux (on the tools' RUNPATH)
#   clang               test_sandbox_linux.sh builds its system call probe, test_sandbox_threads.sh and
#                       test_crc32c_variants.sh build their programs
#   attr, zip, curl, ca-certificates, python3, python3-jsonschema   as in linux/Dockerfile
# No plutil: the one in Ubuntu 26.04's swiftlang package (Swift 6.1.3) answers "No files specified" to
# every file, so the plutil checks of test_replay.sh (2) and test_fingerprint.sh (1) fail in the box.

USER_ID="$(/usr/bin/id -u)"
if [ "$USER_ID" != "0" ]; then
    echo "Error: $0 must run as root" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/replay-kernel-check-setup.log"

/usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0 update > "$LOG" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: apt-get update failed with status $status (log: $LOG); the box needs network mode allowlist (not off) with pack:ubuntu or pack:debian (agent-vm box network)" >&2
    /usr/bin/tail -5 "$LOG" >&2
    exit 1
fi

/usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0 install --no-install-recommends \
    libswiftlang clang attr zip curl ca-certificates python3 python3-jsonschema >> "$LOG" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: apt-get install failed with status $status (log: $LOG)" >&2
    /usr/bin/tail -5 "$LOG" >&2
    exit 1
fi

echo "Installed: $(/usr/bin/dpkg-query -W -f '${Package} ${Version}\n' libswiftlang clang | /usr/bin/tr '\n' ' ')"
exit 0
