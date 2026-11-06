#!/bin/bash
# Installs the replay tools (replay, dispatch, fingerprint, gate) on Linux from a release:
# the tools tarball, and the Swift runtime tarball only where the system has no Swift
# runtime. Needs no root for a per-user install.
#
# Usage:
#   From GitHub (the latest release, or --version):
#     /usr/bin/curl -fsSL https://raw.githubusercontent.com/abra-code/replay/refs/heads/master/linux/install.sh | /bin/bash -s -- [options]
#   From an unpacked tools tarball (it contains this script):
#     replay_<version>_linux_<arch>/install.sh [options]
#   From a folder holding the tarballs:
#     linux/install.sh --from DIR [options]
#
# Options:
#   --prefix DIR    install into DIR/bin (and the runtime into DIR/lib/abracode/swift/linux).
#                   Default: /usr/local when run as root, ~/.local otherwise.
#   --version V     the release to download (default: the latest)
#   --from DIR      take the tarballs from DIR instead of downloading them (nothing is
#                   downloaded then)
#   --with-runtime  also install the runtime tarball when the system has a Swift runtime: it
#                   stays unused while the system's is there, and takes over if that one
#                   is removed later
#   --no-runtime    never install the runtime tarball
#   --uninstall     remove the tools this script installed into the prefix (the shared
#                   runtime folder stays)
#   --force         replace, or with --uninstall remove, files named like the tools that this
#                   script did not install (another program called gate or dispatch, or a
#                   copy unpacked by hand)
#
# The tools look for the Swift runtime in /usr/libexec/swift/lib/swift/linux (libswiftlang,
# Debian 13 and Ubuntu 26.04), /usr/lib/swift/linux (a swift.org toolchain in /usr), then
# <prefix>/lib/abracode/swift/linux, and in the system's default library folders (Fedora's
# swift-lang-runtime). Before changing anything, this script asks the system's loader
# whether it finds libFoundation.so; only if not does it fetch the runtime tarball (74 MB
# unpacked). The prefix changes only after every download is checked and every new tool has
# started against the runtime it will use; the runtime goes in before the tools. The tools
# it installed are listed in <prefix>/lib/abracode/replay-installed.txt, which --uninstall
# reads.
#
# REPLAY_RELEASE_URL overrides https://github.com/abra-code/replay/releases/download (for
# tests, for example a file:// URL).

# One block, so bash reads the whole script before running any of it: a download cut short
# runs nothing, and no command started here can read the rest of the script from a pipe.
{

# Folders and files are made readable by everyone (a root umask of 077 would hide the
# runtime in /usr/local from every other user).
umask 022

PREFIX=""
VERSION=""
FROM_DIR=""
FROM_GIVEN=0
RUNTIME_MODE="auto"
UNINSTALL=0
FORCE=0
TOOLS="replay dispatch fingerprint gate"
RELEASE_URL="${REPLAY_RELEASE_URL:-https://github.com/abra-code/replay/releases/download}"
LATEST_URL="https://github.com/abra-code/replay/releases/latest"

need_value() {
    # $1: option; $2: the number of arguments left
    if [ "$2" -lt 2 ]; then
        echo "Error: $1 needs a value (see --help)" >&2
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            need_value "$1" $#
            PREFIX="$2"
            shift
            ;;
        --version)
            need_value "$1" $#
            VERSION="${2#v}"
            shift
            ;;
        --from)
            need_value "$1" $#
            FROM_DIR="$2"
            FROM_GIVEN=1
            shift
            ;;
        --force)
            FORCE=1
            ;;
        --with-runtime)
            RUNTIME_MODE="always"
            ;;
        --no-runtime)
            RUNTIME_MODE="never"
            ;;
        --uninstall)
            UNINSTALL=1
            ;;
        -h|--help)
            if [ -f "$0" ]; then
                /usr/bin/sed -n '2,41p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            else
                echo "See the comments at the top of https://github.com/abra-code/replay/blob/master/linux/install.sh"
            fi
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1' (see --help)" >&2
            exit 1
            ;;
    esac
    shift
done

OS_NAME="$(/usr/bin/uname -s)"
if [ "$OS_NAME" != "Linux" ]; then
    echo "Error: this installer is for Linux (this is $OS_NAME). On macOS use install.sh at the top of the repository." >&2
    exit 1
fi

USER_ID="$(/usr/bin/id -u)"
if [ -z "$PREFIX" ]; then
    if [ "$USER_ID" = "0" ]; then
        PREFIX="/usr/local"
    elif [ -n "$HOME" ]; then
        PREFIX="$HOME/.local"
    else
        echo "Error: HOME is not set; pass --prefix" >&2
        exit 1
    fi
fi
case "$PREFIX" in
    /*) ;;
    *)
        echo "Error: --prefix needs an absolute path, not '$PREFIX'" >&2
        exit 1
        ;;
esac
PREFIX="${PREFIX%/}"
if [ -z "$PREFIX" ]; then
    echo "Error: --prefix / is not allowed" >&2
    exit 1
fi
BIN_DIR="$PREFIX/bin"
# The tools find the runtime through $ORIGIN/.., and the loader takes $ORIGIN from the
# executable's path with every symbolic link resolved: when bin is a link to another folder,
# the runtime goes beside that folder, not into the prefix.
RUNTIME_PREFIX="$PREFIX"
if [ -d "$BIN_DIR" ]; then
    resolved_bin="$(CDPATH= cd -P -- "$BIN_DIR" 2>/dev/null && pwd)"
    if [ -n "$resolved_bin" ]; then
        RUNTIME_PREFIX="$(/usr/bin/dirname -- "$resolved_bin")"
        RUNTIME_PREFIX="${RUNTIME_PREFIX%/}"
    fi
fi
RUNTIME_DIR="$RUNTIME_PREFIX/lib/abracode/swift/linux"
# The tools this script installed, one name per line: only those are replaced or removed
# without --force.
RECORD="$PREFIX/lib/abracode/replay-installed.txt"

# Whether $1 (a tool name) is listed in the record.
is_recorded() {
    if [ ! -f "$RECORD" ]; then
        return 1
    fi
    local line
    while read -r line; do
        if [ "$line" = "$1" ]; then
            return 0
        fi
    done < "$RECORD"
    return 1
}

if [ "$UNINSTALL" -eq 1 ]; then
    removed=""
    skipped=""
    for tool in $TOOLS; do
        if [ ! -e "$BIN_DIR/$tool" ] && [ ! -L "$BIN_DIR/$tool" ]; then
            continue
        fi
        if [ "$FORCE" -ne 1 ] && ! is_recorded "$tool"; then
            skipped="$skipped $tool"
            continue
        fi
        if [ -e "$BIN_DIR/$tool" ] || [ -L "$BIN_DIR/$tool" ]; then
            /bin/rm -f "$BIN_DIR/$tool"
            status=$?
            if [ "$status" -ne 0 ]; then
                echo "Error: cannot remove $BIN_DIR/$tool" >&2
                exit 1
            fi
            removed="$removed $tool"
        fi
    done
    if [ -z "$removed" ]; then
        echo "Nothing removed from $BIN_DIR"
    else
        echo "Removed from $BIN_DIR:$removed"
    fi
    if [ -n "$skipped" ]; then
        echo "Left in place, not installed by this script:$skipped (pass --force to remove them too)"
    fi
    /bin/rm -f "$RECORD"
    if [ -d "$RUNTIME_DIR" ]; then
        echo "The Swift runtime copy in $RUNTIME_DIR stays, since other tools may use it. Remove it with: /bin/rm -rf $RUNTIME_DIR"
    fi
    exit 0
fi

# The machine: architecture, and a glibc new enough for the release builds (Ubuntu 24.04's).
MACHINE="$(/usr/bin/uname -m)"
case "$MACHINE" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *)
        echo "Error: no release for the $MACHINE architecture (only x86_64 and aarch64)" >&2
        exit 1
        ;;
esac
LDD_VERSION="$(/usr/bin/ldd --version 2>&1 | /usr/bin/head -n 1)"
case "$LDD_VERSION" in
    *musl*)
        echo "Error: this system uses musl, not glibc (Alpine?); the releases need glibc 2.39 or newer" >&2
        exit 1
        ;;
esac
GLIBC="$(printf '%s\n' "$LDD_VERSION" | /usr/bin/sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')"
GLIBC_MAJOR="${GLIBC%%.*}"
GLIBC_MINOR="${GLIBC#*.}"
case "$GLIBC_MAJOR:$GLIBC_MINOR" in
    *[!0-9:]*|:*|*:)
        echo "Warning: cannot read the glibc version from '$LDD_VERSION'; the releases need 2.39 or newer"
        ;;
    *)
        if [ "$GLIBC_MAJOR" -lt 2 ] || { [ "$GLIBC_MAJOR" -eq 2 ] && [ "$GLIBC_MINOR" -lt 39 ]; }; then
            echo "Error: this system has glibc $GLIBC; the releases need 2.39 or newer (Ubuntu 24.04, Debian 13, Fedora, RHEL 10)" >&2
            exit 1
        fi
        ;;
esac

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/replay-install.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "Error: cannot create a temporary folder" >&2
    exit 1
fi
cleanup() {
    /bin/rm -rf "${WORK_DIR:?}"
}
trap cleanup EXIT

# Downloads $1 (a URL) to $2. curl or wget, whichever the system has.
fetch() {
    if [ -x /usr/bin/curl ]; then
        /usr/bin/curl -fsSL --retry 3 -o "$2" "$1"
        return $?
    fi
    if [ -x /usr/bin/wget ]; then
        /usr/bin/wget -q -O "$2" "$1"
        return $?
    fi
    echo "Error: neither curl nor wget is installed" >&2
    return 1
}

# Checks $1 against the .sha256 file beside it.
verify_sum() {
    local expected_line
    expected_line="$(/bin/cat "$1.sha256" 2>/dev/null)"
    local actual_line
    actual_line="$(/usr/bin/sha256sum "$1")"
    if [ -z "$expected_line" ] || [ "${expected_line%% *}" != "${actual_line%% *}" ]; then
        echo "Error: $1 does not match its SHA-256 checksum file" >&2
        return 1
    fi
    return 0
}

# Where the tarballs come from: the unpacked tools folder this script sits in, a folder
# given with --from, or the GitHub release.
SCRIPT_DIR=""
case "$0" in
    install.sh|*/install.sh) SCRIPT_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" 2>/dev/null && pwd)" ;;
esac
TOOLS_SRC=""
if [ -z "$FROM_DIR" ] && [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/BUILD-INFO.txt" ] && [ -x "$SCRIPT_DIR/bin/replay" ]; then
    TOOLS_SRC="$SCRIPT_DIR"
    # The runtime tarball, if needed, is looked for beside the unpacked folder, then in the
    # release (FROM_GIVEN stays 0, so a download is allowed).
    FROM_DIR="$(/usr/bin/dirname -- "$SCRIPT_DIR")"
    UNPACKED_VERSION="$(/usr/bin/sed -n 's/^replay \([0-9][0-9.]*\) for Linux .*/\1/p' "$SCRIPT_DIR/BUILD-INFO.txt")"
    if [ -n "$VERSION" ] && [ "$VERSION" != "$UNPACKED_VERSION" ]; then
        echo "Error: --version $VERSION, but this unpacked folder holds replay $UNPACKED_VERSION; run the install.sh of that release, or this one without --version" >&2
        exit 1
    fi
    echo "== Installing from $TOOLS_SRC"
else
    if [ -z "$VERSION" ] && [ -n "$FROM_DIR" ]; then
        # The newest tools tarball for this architecture in the folder.
        found="$(/bin/ls "$FROM_DIR" 2>/dev/null | /usr/bin/sed -n "s/^replay_\([0-9][0-9.]*\)_linux_${ARCH}\.tar\.gz$/\1/p" | /usr/bin/sort -t. -k1,1n -k2,2n -k3,3n | /usr/bin/tail -n 1)"
        VERSION="$found"
        if [ -z "$VERSION" ]; then
            echo "Error: no replay_<version>_linux_$ARCH.tar.gz in $FROM_DIR" >&2
            exit 1
        fi
    fi
    if [ -z "$VERSION" ]; then
        # GitHub redirects .../releases/latest to .../releases/tag/<tag>.
        if [ -x /usr/bin/curl ]; then
            LATEST="$(/usr/bin/curl -fsSLI -o /dev/null -w '%{url_effective}' "$LATEST_URL")"
            status=$?
        elif [ -x /usr/bin/wget ]; then
            # Without following the redirect: its Location header names the tag. wget exits
            # with a nonzero status when it stops at a redirect, so the header decides.
            LATEST="$(/usr/bin/wget -q -S --max-redirect=0 -O /dev/null "$LATEST_URL" 2>&1 | /usr/bin/sed -n 's/^ *[Ll]ocation: *\([^ ]*\).*/\1/p' | /usr/bin/tr -d '\r' | /usr/bin/tail -n 1)"
            status=0
        else
            echo "Error: neither curl nor wget is installed" >&2
            exit 1
        fi
        TAG="${LATEST##*/tag/}"
        if [ "$status" -ne 0 ] || [ "$TAG" = "$LATEST" ] || [ -z "$TAG" ]; then
            echo "Error: cannot find the latest release at $LATEST_URL (status $status); pass --version" >&2
            exit 1
        fi
        VERSION="${TAG#v}"
    fi
    case "$VERSION" in
        ''|*[!0-9.]*)
            echo "Error: '$VERSION' is not a release version (such as 2.3.0)" >&2
            exit 1
            ;;
    esac
    TOOLS_TARBALL="replay_${VERSION}_linux_$ARCH.tar.gz"
    if [ -n "$FROM_DIR" ]; then
        for file in "$TOOLS_TARBALL" "$TOOLS_TARBALL.sha256"; do
            /bin/cp "$FROM_DIR/$file" "$WORK_DIR/$file"
            status=$?
            if [ "$status" -ne 0 ]; then
                echo "Error: cannot read $FROM_DIR/$file" >&2
                exit 1
            fi
        done
        echo "== Installing replay $VERSION from $FROM_DIR"
    else
        echo "== Downloading replay $VERSION for $ARCH"
        for file in "$TOOLS_TARBALL" "$TOOLS_TARBALL.sha256"; do
            fetch "$RELEASE_URL/v$VERSION/$file" "$WORK_DIR/$file"
            status=$?
            if [ "$status" -ne 0 ]; then
                echo "Error: cannot download $RELEASE_URL/v$VERSION/$file (status $status). Release $VERSION may have no Linux build for $ARCH." >&2
                exit 1
            fi
        done
    fi
    verify_sum "$WORK_DIR/$TOOLS_TARBALL" || exit 1
    /bin/tar -xzf "$WORK_DIR/$TOOLS_TARBALL" -C "$WORK_DIR" --no-same-owner
    status=$?
    TOOLS_SRC="$WORK_DIR/replay_${VERSION}_linux_$ARCH"
    if [ "$status" -ne 0 ] || [ ! -f "$TOOLS_SRC/BUILD-INFO.txt" ]; then
        echo "Error: unpacking $TOOLS_TARBALL failed (status $status)" >&2
        exit 1
    fi
fi

for tool in $TOOLS; do
    if [ ! -x "$TOOLS_SRC/bin/$tool" ]; then
        echo "Error: $TOOLS_SRC/bin/$tool is missing" >&2
        exit 1
    fi
done
RUNTIME_TARBALL="$(/usr/bin/sed -n 's/^runtime-tarball: //p' "$TOOLS_SRC/BUILD-INFO.txt")"
if [ -z "$RUNTIME_TARBALL" ]; then
    echo "Error: $TOOLS_SRC/BUILD-INFO.txt names no runtime tarball" >&2
    exit 1
fi
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/bin/sed -n 's/^replay \([0-9][0-9.]*\) for Linux .*/\1/p' "$TOOLS_SRC/BUILD-INFO.txt")"
fi

# 1. Whether the system has a Swift runtime, asked of the loader with the new replay where it
# was unpacked: from there its $ORIGIN entry leads to no copy of ours, so only a system
# runtime is found (the first two search folders, or the default library folders).
# LD_LIBRARY_PATH is left out: a runtime found only through it is gone in the next shell.
LDD_OUT="$(/usr/bin/env -u LD_LIBRARY_PATH /usr/bin/ldd "$TOOLS_SRC/bin/replay" 2>&1)"
# Only an absolute path: a missing library reads "libFoundation.so => not found".
FOUNDATION="$(printf '%s\n' "$LDD_OUT" | /usr/bin/sed -n 's/^[[:space:]]*libFoundation\.so => \(\/[^ ]*\) .*/\1/p')"
SYSTEM_RUNTIME=""
if [ -n "$FOUNDATION" ] && [ -f "$FOUNDATION" ]; then
    SYSTEM_RUNTIME="$(/usr/bin/dirname -- "$(/usr/bin/readlink -f "$FOUNDATION")")"
    case "$SYSTEM_RUNTIME/" in
        "$TOOLS_SRC/"*) SYSTEM_RUNTIME="" ;;
    esac
fi
NEED_RUNTIME=0
case "$RUNTIME_MODE" in
    always)
        NEED_RUNTIME=1
        ;;
    auto)
        if [ -z "$SYSTEM_RUNTIME" ]; then
            NEED_RUNTIME=1
        else
            echo "== Using the system's Swift runtime in $SYSTEM_RUNTIME"
        fi
        ;;
esac

# 2. The runtime tarball, fetched and unpacked here first, so a failed download changes
# nothing in the prefix. Not fetched when the prefix already has the copy this release was
# built with (its VERSION names the same compiler as BUILD-INFO.txt).
NEW_RUNTIME=""
if [ "$NEED_RUNTIME" -eq 1 ]; then
    WANTED_VERSION="$(/usr/bin/sed -n 's/^compiler: //p' "$TOOLS_SRC/BUILD-INFO.txt")"
    INSTALLED_VERSION=""
    if [ -f "$RUNTIME_DIR/VERSION" ] && [ -f "$RUNTIME_DIR/libFoundation.so" ]; then
        INSTALLED_VERSION="$(/usr/bin/head -n 1 "$RUNTIME_DIR/VERSION")"
    fi
    if [ -n "$WANTED_VERSION" ] && [ "$INSTALLED_VERSION" = "$WANTED_VERSION" ]; then
        echo "== The Swift runtime in $RUNTIME_DIR is already this one ($INSTALLED_VERSION)"
    else
        if [ -n "$FROM_DIR" ] && [ -f "$FROM_DIR/$RUNTIME_TARBALL" ]; then
            for file in "$RUNTIME_TARBALL" "$RUNTIME_TARBALL.sha256"; do
                /bin/cp "$FROM_DIR/$file" "$WORK_DIR/$file"
                status=$?
                if [ "$status" -ne 0 ]; then
                    echo "Error: cannot read $FROM_DIR/$file" >&2
                    exit 1
                fi
            done
        elif [ "$FROM_GIVEN" -eq 1 ]; then
            # An explicit --from stays offline.
            echo "Error: the system has no Swift runtime, and $RUNTIME_TARBALL (with its .sha256 file) is not in $FROM_DIR" >&2
            exit 1
        elif [ -n "$VERSION" ]; then
            echo "== Downloading the Swift runtime ($RUNTIME_TARBALL, about 25 MB) from release $VERSION"
            for file in "$RUNTIME_TARBALL" "$RUNTIME_TARBALL.sha256"; do
                fetch "$RELEASE_URL/v$VERSION/$file" "$WORK_DIR/$file"
                status=$?
                if [ "$status" -ne 0 ]; then
                    echo "Error: cannot download $RELEASE_URL/v$VERSION/$file (status $status)" >&2
                    exit 1
                fi
            done
        else
            echo "Error: the system has no Swift runtime, and $RUNTIME_TARBALL is not in ${FROM_DIR:-the current folder}" >&2
            exit 1
        fi
        verify_sum "$WORK_DIR/$RUNTIME_TARBALL" || exit 1
        RUNTIME_NAME="${RUNTIME_TARBALL%.tar.gz}"
        /bin/tar -xzf "$WORK_DIR/$RUNTIME_TARBALL" -C "$WORK_DIR" --no-same-owner
        status=$?
        NEW_RUNTIME="$WORK_DIR/$RUNTIME_NAME/lib/abracode/swift/linux"
        if [ "$status" -ne 0 ] || [ ! -f "$NEW_RUNTIME/libFoundation.so" ] || [ ! -f "$NEW_RUNTIME/VERSION" ]; then
            echo "Error: unpacking $RUNTIME_TARBALL failed (status $status)" >&2
            exit 1
        fi
    fi
fi


# 3. Before anything in the prefix changes: every new tool must start, where it was
# unpacked, against the runtime it will use (the staged copy, our current copy, or the
# system's), and no file of another program may be in the way.
PRECHECK_LIB=""
if [ -z "$SYSTEM_RUNTIME" ]; then
    if [ -n "$NEW_RUNTIME" ]; then
        PRECHECK_LIB="$NEW_RUNTIME"
    elif [ -f "$RUNTIME_DIR/libFoundation.so" ]; then
        PRECHECK_LIB="$RUNTIME_DIR"
    fi
fi
failures=0
for tool in $TOOLS; do
    if [ -n "$PRECHECK_LIB" ]; then
        output="$(LD_BIND_NOW=1 LD_LIBRARY_PATH="$PRECHECK_LIB" "$TOOLS_SRC/bin/$tool" --version 2>&1 < /dev/null)"
        status=$?
    else
        output="$(LD_BIND_NOW=1 /usr/bin/env -u LD_LIBRARY_PATH "$TOOLS_SRC/bin/$tool" --version 2>&1 < /dev/null)"
        status=$?
    fi
    if [ "$status" -ne 0 ]; then
        echo "FAIL: $tool --version: $output" >&2
        failures=$((failures + 1))
    fi
done
if [ "$failures" -ne 0 ]; then
    echo "Error: $failures new tool(s) do not start; nothing was installed." >&2
    if [ "$RUNTIME_MODE" = "never" ] && [ -z "$SYSTEM_RUNTIME" ]; then
        echo "  The system has no Swift runtime and --no-runtime was given: install the distribution's package (libswiftlang, swift-lang-runtime) or rerun without --no-runtime." >&2
    elif [ -n "$SYSTEM_RUNTIME" ]; then
        echo "  They use the system's Swift runtime in $SYSTEM_RUNTIME, which may be too old (6.0.3 or newer is needed)." >&2
    fi
    exit 1
fi
conflicts=""
for tool in $TOOLS; do
    if [ -e "$BIN_DIR/$tool" ] || [ -L "$BIN_DIR/$tool" ]; then
        if ! is_recorded "$tool"; then
            conflicts="$conflicts $tool"
        fi
    fi
done
if [ -n "$conflicts" ] && [ "$FORCE" -ne 1 ]; then
    echo "Error: $BIN_DIR already has$conflicts, which this script did not install (another program, or a copy unpacked by hand). Pass --force to replace them, or --prefix for another folder." >&2
    exit 1
fi

# 4. The runtime, before the tools, so a failure here leaves the old installation whole:
# copied next to the old folder, then swapped in, so the old one stays usable until the new
# one is complete.
if [ -n "$NEW_RUNTIME" ]; then
    NEW_VERSION="$(/usr/bin/head -n 1 "$NEW_RUNTIME/VERSION")"
    PARENT="$(/usr/bin/dirname -- "$RUNTIME_DIR")"
    /bin/mkdir -p "$PARENT"
    status=$?
    if [ "$status" -eq 0 ]; then
        /bin/rm -rf "${RUNTIME_DIR:?}.new"
        /bin/cp -R "$NEW_RUNTIME" "$RUNTIME_DIR.new"
        status=$?
    fi
    if [ "$status" -eq 0 ] && [ -d "$RUNTIME_DIR" ]; then
        /bin/rm -rf "${RUNTIME_DIR:?}.old"
        /bin/mv "$RUNTIME_DIR" "$RUNTIME_DIR.old"
        status=$?
    fi
    if [ "$status" -eq 0 ]; then
        /bin/mv "$RUNTIME_DIR.new" "$RUNTIME_DIR"
        status=$?
    fi
    if [ "$status" -ne 0 ]; then
        echo "Error: cannot install the Swift runtime into $RUNTIME_DIR; nothing else was changed" >&2
        if [ -d "$RUNTIME_DIR.old" ] && [ ! -d "$RUNTIME_DIR" ]; then
            /bin/mv "$RUNTIME_DIR.old" "$RUNTIME_DIR"
        fi
        /bin/rm -rf "${RUNTIME_DIR:?}.new"
        exit 1
    fi
    /bin/rm -rf "${RUNTIME_DIR:?}.old"
    echo "== Installed the Swift runtime ($NEW_VERSION) into $RUNTIME_DIR"
fi

# 5. The tools: each copied beside its final name, then renamed over it, so a running copy
# keeps working and a failed copy leaves the old tool in place. The record lists them.
/bin/mkdir -p "$BIN_DIR" "$(/usr/bin/dirname -- "$RECORD")"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: cannot create $BIN_DIR and $(/usr/bin/dirname -- "$RECORD") (for a per-user install, pass --prefix ~/.local)" >&2
    exit 1
fi
for tool in $TOOLS; do
    /bin/cp "$TOOLS_SRC/bin/$tool" "$BIN_DIR/.$tool.new"
    status=$?
    if [ "$status" -eq 0 ]; then
        /bin/chmod 755 "$BIN_DIR/.$tool.new"
        status=$?
    fi
    if [ "$status" -eq 0 ]; then
        /bin/mv -f "$BIN_DIR/.$tool.new" "$BIN_DIR/$tool"
        status=$?
    fi
    if [ "$status" -ne 0 ]; then
        /bin/rm -f "$BIN_DIR/.$tool.new"
        echo "Error: cannot install $tool into $BIN_DIR" >&2
        exit 1
    fi
    if ! is_recorded "$tool"; then
        printf '%s\n' "$tool" >> "$RECORD"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: cannot write $RECORD" >&2
            exit 1
        fi
    fi
done
echo "== Installed $TOOLS into $BIN_DIR"

# 6. Check: every installed tool starts, with every function it needs bound at start.
failures=0
for tool in $TOOLS; do
    output="$(LD_BIND_NOW=1 /usr/bin/env -u LD_LIBRARY_PATH "$BIN_DIR/$tool" --version 2>&1 < /dev/null)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "FAIL: $tool --version: $output" >&2
        failures=$((failures + 1))
    fi
done
if [ "$failures" -ne 0 ]; then
    echo "Error: $failures tool(s) do not start." >&2
    if [ "$RUNTIME_MODE" = "never" ]; then
        echo "  No Swift runtime was installed (--no-runtime); install the distribution's package or rerun without --no-runtime." >&2
    elif [ -n "$SYSTEM_RUNTIME" ] && [ -z "$NEW_RUNTIME" ]; then
        echo "  They use the system's Swift runtime in $SYSTEM_RUNTIME, which may be too old (6.0.3 or newer is needed)." >&2
    fi
    exit 1
fi
LDD_OUT="$(/usr/bin/env -u LD_LIBRARY_PATH /usr/bin/ldd "$BIN_DIR/replay" 2>&1)"
FOUNDATION="$(printf '%s\n' "$LDD_OUT" | /usr/bin/sed -n 's/^[[:space:]]*libFoundation\.so => \(\/[^ ]*\) .*/\1/p')"
echo "== All four tools start (replay $VERSION; Swift runtime from $(/usr/bin/dirname -- "$(/usr/bin/readlink -f "$FOUNDATION")"))"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo ""
        echo "$BIN_DIR is not on PATH. Add it, for example in ~/.profile:"
        echo "  export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac
exit 0
}
