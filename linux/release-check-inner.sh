#!/bin/bash
# Runs inside a plain distribution container, started by linux/release.sh: installs the
# release tarballs the way a user would and runs linux/runtime-check-inner.sh on them.
#
# Usage: release-check-inner.sh bundled <tools.tar.gz> <swift-runtime.tar.gz>
#        release-check-inner.sh debian|fedora <tools.tar.gz>
#   bundled        a system without any Swift runtime (Ubuntu 24.04): the runtime tarball is
#                  unpacked into the same prefix, and the tools must load it from there.
#   debian|fedora  first installs the distribution's runtime package (libswiftlang,
#                  swift-lang-runtime); the tools must load it from the system.

MODE="$1"
TOOLS_TARBALL="$2"
RUNTIME_TARBALL="$3"
TAR="/bin/tar"
INNER="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)/runtime-check-inner.sh"

if [ -z "$MODE" ] || [ ! -f "$TOOLS_TARBALL" ] || [ ! -f "$INNER" ]; then
    echo "Error: usage: $0 bundled|debian|fedora <tools.tar.gz> [<swift-runtime.tar.gz>]" >&2
    exit 2
fi

case "$MODE" in
    bundled)
        if [ ! -f "$RUNTIME_TARBALL" ]; then
            echo "Error: bundled needs the runtime tarball" >&2
            exit 2
        fi
        # The point of this mode: nothing Swift on the system.
        for folder in /usr/libexec/swift/lib/swift/linux /usr/lib/swift/linux; do
            if [ -e "$folder/libFoundation.so" ]; then
                echo "Error: this container already has a Swift runtime in $folder" >&2
                exit 2
            fi
        done
        ;;
    debian)
        echo "== Installing libswiftlang"
        DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q update > /tmp/runtime-install.log 2>&1
        status=$?
        if [ "$status" -eq 0 ]; then
            DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q install -y --no-install-recommends libswiftlang >> /tmp/runtime-install.log 2>&1
            status=$?
        fi
        ;;
    fedora)
        echo "== Installing swift-lang-runtime"
        # Also bsdtar: Fedora 44's GNU tar fails to open any file it unpacks ("Function not
        # implemented") under the x86_64 emulator of Docker on Apple silicon; libarchive's tar
        # works there. Native Fedora is not affected.
        /usr/bin/dnf -q install -y swift-lang-runtime bsdtar > /tmp/runtime-install.log 2>&1
        status=$?
        TAR="/usr/bin/bsdtar"
        ;;
    *)
        echo "Error: unknown mode '$MODE'" >&2
        exit 2
        ;;
esac
if [ "$MODE" != "bundled" ] && [ "$status" -ne 0 ]; then
    echo "Error: installing the runtime package failed with status $status:" >&2
    /usr/bin/tail -5 /tmp/runtime-install.log >&2
    exit 2
fi

PREFIX="$(/usr/bin/mktemp -d /tmp/prefix.XXXXXX)"
status=$?
if [ "$status" -ne 0 ] || [ -z "$PREFIX" ]; then
    echo "Error: mktemp -d failed" >&2
    exit 2
fi
"$TAR" -xzf "$TOOLS_TARBALL" -C "$PREFIX" --strip-components=1 --no-same-owner
status=$?
if [ "$status" -eq 0 ] && [ "$MODE" = "bundled" ]; then
    "$TAR" -xzf "$RUNTIME_TARBALL" -C "$PREFIX" --strip-components=1 --no-same-owner
    status=$?
fi
if [ "$status" -ne 0 ]; then
    echo "Error: unpacking the tarballs into $PREFIX failed with status $status" >&2
    exit 2
fi

failures=0
for tool in replay dispatch fingerprint gate; do
    libs="$(/usr/bin/ldd "$PREFIX/bin/$tool" 2>&1)"
    foundation="$(printf '%s\n' "$libs" | /usr/bin/sed -n 's/^[[:space:]]*libFoundation\.so => \([^ ]*\) .*/\1/p')"
    if [ -z "$foundation" ] || [ ! -f "$foundation" ]; then
        echo "FAIL: $tool does not find libFoundation.so: $libs"
        failures=$((failures + 1))
        continue
    fi
    resolved="$(/usr/bin/readlink -f "$foundation")"
    case "$MODE:$resolved" in
        "bundled:$PREFIX/lib/abracode/swift/linux/libFoundation.so") ;;
        bundled:*)
            echo "FAIL: $tool loads $resolved, not the runtime in $PREFIX/lib/abracode/swift/linux"
            failures=$((failures + 1))
            continue
            ;;
        "debian:$PREFIX/"* | "fedora:$PREFIX/"*)
            echo "FAIL: $tool loads $resolved from the prefix, not the system's runtime"
            failures=$((failures + 1))
            continue
            ;;
    esac
    echo "ok   $tool loads $resolved"
done

/bin/bash "$INNER" "$PREFIX/bin"
status=$?
if [ "$status" -ne 0 ]; then
    failures=$((failures + 1))
fi
/bin/rm -rf "${PREFIX:?}"

if [ "$failures" -ne 0 ]; then
    exit 1
fi
exit 0
