#!/bin/bash
# Install a swift.org Swift toolchain into /usr, the layout of the official Swift images, so
# build-linux.sh finds /usr/bin/swift and the runtime lands in /usr/lib/swift/linux, which is
# on the replay tools' RUNPATH.
#
# Usage: install-swift.sh <version> <platform> <sha256>
#   version   e.g. 6.2.4
#   platform  swift.org's platform folder, e.g. debian12-aarch64
#   sha256    the tarball's SHA-256; the download is refused when it differs
#
# Run as root. The checksum was taken from a download whose swift.org signature was checked
# (gpg, "Swift 6.x Release Signing Key"), so it stands in for that signature here.

VERSION="$1"
PLATFORM="$2"
EXPECTED_SHA256="$3"

if [ -z "$VERSION" ] || [ -z "$PLATFORM" ] || [ -z "$EXPECTED_SHA256" ]; then
    echo "Usage: $0 <version> <platform> <sha256>" >&2
    exit 64
fi
case "$VERSION" in
    *[!0-9.]*|.*|*.)
        echo "Error: '$VERSION' is not a version number" >&2
        exit 64
        ;;
esac
case "$PLATFORM" in
    *[!a-z0-9.-]*)
        echo "Error: '$PLATFORM' is not a swift.org platform name" >&2
        exit 64
        ;;
esac

TAG="swift-$VERSION-RELEASE"
PLATFORM_DIR="$(printf '%s' "$PLATFORM" | /usr/bin/tr -d '.')"
URL="https://download.swift.org/swift-$VERSION-release/$PLATFORM_DIR/$TAG/$TAG-$PLATFORM.tar.gz"

# The version is read from stdout only: on a kernel with 16 KiB pages the Swift runtime
# first warns on stderr ("unable to protect path to swift-backtrace").
INSTALLED="$(/usr/bin/swift --version 2>/dev/null | /usr/bin/head -n 1)"
case "$INSTALLED" in
    *"($TAG)"*)
        echo "Swift $VERSION is already installed: $INSTALLED"
        exit 0
        ;;
esac

WORK="$(/usr/bin/mktemp -d)"
status=$?
if [ "$status" -ne 0 ] || [ -z "$WORK" ]; then
    echo "Error: mktemp -d failed" >&2
    exit 1
fi
TARBALL="$WORK/swift.tar.gz"

echo "Downloading $URL"
/usr/bin/curl -fsSL --retry 3 -o "$TARBALL" "$URL"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: downloading $URL failed (curl status $status)" >&2
    /bin/rm -rf "$WORK"
    exit 1
fi

ACTUAL_SHA256="$(/usr/bin/sha256sum "$TARBALL" | /usr/bin/cut -d ' ' -f 1)"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "Error: $URL has SHA-256 $ACTUAL_SHA256, expected $EXPECTED_SHA256" >&2
    /bin/rm -rf "$WORK"
    exit 1
fi

/usr/bin/tar -xzf "$TARBALL" --directory / --strip-components=1 --no-same-owner
status=$?
/bin/rm -rf "$WORK"
if [ "$status" -ne 0 ]; then
    echo "Error: unpacking the toolchain into /usr failed (tar status $status)" >&2
    exit 1
fi

# The tarball's folders keep swift.org's modes; make the toolchain readable by every user.
for folder in /usr/lib/swift /usr/lib/swift_static; do
    if [ -d "$folder" ]; then
        /bin/chmod -R o+rX "$folder"
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: making $folder readable failed (chmod status $status)" >&2
            exit 1
        fi
    fi
done

INSTALLED="$(/usr/bin/swift --version 2>/dev/null | /usr/bin/head -n 1)"
case "$INSTALLED" in
    *"($TAG)"*)
        echo "Installed: $INSTALLED"
        ;;
    *)
        echo "Error: after unpacking, swift --version says: $INSTALLED" >&2
        exit 1
        ;;
esac
