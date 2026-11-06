#!/bin/bash
# Runs inside a plain distribution container, started by linux/release.sh: installs the
# release tarballs the way a user would and runs linux/runtime-check-inner.sh on them.
#
# Usage: release-check-inner.sh bundled|debian|fedora <tools.tar.gz> <swift-runtime.tar.gz>
#   bundled  a system without any Swift runtime (Ubuntu 24.04). As a user without root,
#            linux/install.sh --from the release folder installs into ~/.local, and the
#            tools must load the runtime tarball's copy from ~/.local/lib/abracode. Then:
#            the same install again (the runtime is kept), the install.sh inside an
#            unpacked tools tarball into another prefix, and --uninstall.
#   debian   installs libswiftlang (Swift 6.0.3), then linux/install.sh as root into
#            /usr/local: the tools must load the system's runtime, and no copy is added.
#   fedora   installs swift-lang-runtime (Swift 6.3.2) and unpacks the tools tarball here,
#            without install.sh: Fedora 44's GNU tar fails to open any file it unpacks
#            ("Function not implemented") under the x86_64 emulator of Docker on Apple
#            silicon, so this mode unpacks with libarchive's bsdtar. Native Fedora is not
#            affected.
# Expects linux/install.sh and linux/runtime-check-inner.sh beside this script, and the
# tarballs in one folder (the release folder).

MODE="$1"
TOOLS_TARBALL="$2"
RUNTIME_TARBALL="$3"
CHECK_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
INNER="$CHECK_DIR/runtime-check-inner.sh"
INSTALL="$CHECK_DIR/install.sh"

if [ -z "$MODE" ] || [ ! -f "$TOOLS_TARBALL" ] || [ ! -f "$RUNTIME_TARBALL" ] || [ ! -f "$INNER" ] || [ ! -f "$INSTALL" ]; then
    echo "Error: usage: $0 bundled|debian|fedora <tools.tar.gz> <swift-runtime.tar.gz> (with install.sh and runtime-check-inner.sh beside it)" >&2
    exit 2
fi
RELEASE_DIR="$(/usr/bin/dirname -- "$TOOLS_TARBALL")"
TOOLS_NAME="$(/usr/bin/basename -- "$TOOLS_TARBALL" .tar.gz)"

failures=0
fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

# Checks that every tool in $1 loads libFoundation.so from the folder $2 ("system": from
# anywhere but $3).
check_loads() {
    local bin_dir="$1"
    local expected="$2"
    local not_under="$3"
    local tool
    for tool in replay dispatch fingerprint gate; do
        local libs
        libs="$(/usr/bin/ldd "$bin_dir/$tool" 2>&1)"
        local foundation
        foundation="$(printf '%s\n' "$libs" | /usr/bin/sed -n 's/^[[:space:]]*libFoundation\.so => \([^ ]*\) .*/\1/p')"
        if [ -z "$foundation" ] || [ ! -f "$foundation" ]; then
            fail "$tool does not find libFoundation.so: $libs"
            continue
        fi
        local resolved
        resolved="$(/usr/bin/dirname -- "$(/usr/bin/readlink -f "$foundation")")"
        if [ "$expected" = "system" ]; then
            case "$resolved/" in
                "$not_under/"*)
                    fail "$tool loads libFoundation.so from $resolved, not from the system"
                    continue
                    ;;
            esac
        elif [ "$resolved" != "$expected" ]; then
            fail "$tool loads libFoundation.so from $resolved, not from $expected"
            continue
        fi
        echo "ok   $tool loads libFoundation.so from $resolved"
    done
}

# Runs a command as the user "tester", from its home folder, with a login-like environment.
as_tester() {
    /usr/sbin/runuser -u tester -- /usr/bin/env -i HOME=/home/tester PATH=/usr/bin:/bin USER=tester "$@"
}

case "$MODE" in
    bundled)
        # The point of this mode: nothing Swift on the system.
        for folder in /usr/libexec/swift/lib/swift/linux /usr/lib/swift/linux; do
            if [ -e "$folder/libFoundation.so" ]; then
                echo "Error: this container already has a Swift runtime in $folder" >&2
                exit 2
            fi
        done
        /usr/sbin/useradd -m -s /bin/bash tester
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: useradd failed with status $status" >&2
            exit 2
        fi
        TESTER_HOME="/home/tester"
        OUR_RUNTIME="$TESTER_HOME/.local/lib/abracode/swift/linux"

        echo "== install.sh with another program called gate in ~/.local/bin: refused, nothing changed"
        as_tester /bin/mkdir -p "$TESTER_HOME/.local/bin"
        printf '#!/bin/sh\necho other gate\n' > "$TESTER_HOME/.local/bin/gate"
        /bin/chmod 755 "$TESTER_HOME/.local/bin/gate"
        /bin/chown tester "$TESTER_HOME/.local/bin/gate"
        output="$(as_tester /bin/bash "$INSTALL" --from "$RELEASE_DIR" 2>&1)"
        status=$?
        gate_now="$(/bin/cat "$TESTER_HOME/.local/bin/gate")"
        if [ "$status" -ne 0 ] && [ "$gate_now" = "$(printf '#!/bin/sh\necho other gate')" ] && [ ! -e "$TESTER_HOME/.local/bin/replay" ] && [ ! -e "$TESTER_HOME/.local/lib" ]; then
            echo "ok   refused, and the other gate, bin and lib are untouched"
        else
            fail "install.sh over another gate (status $status): $output"
        fi
        /bin/rm -f "$TESTER_HOME/.local/bin/gate"

        echo "== install.sh --from a folder without the runtime tarball: refused, no download"
        as_tester /bin/mkdir -p "$TESTER_HOME/tools-only"
        /bin/cp "$TOOLS_TARBALL" "$TOOLS_TARBALL.sha256" "$TESTER_HOME/tools-only/"
        /bin/chown -R tester "$TESTER_HOME/tools-only"
        output="$(as_tester /usr/bin/env REPLAY_RELEASE_URL=file:///nonexistent /bin/bash "$INSTALL" --from "$TESTER_HOME/tools-only" 2>&1)"
        status=$?
        case "$status:$output" in
            1:*"is not in $TESTER_HOME/tools-only"*)
                if [ -e "$TESTER_HOME/.local/bin/replay" ]; then
                    fail "the refused install left tools behind"
                else
                    echo "ok   refused without downloading, nothing installed"
                fi
                ;;
            *) fail "install.sh --from without the runtime (status $status): $output" ;;
        esac

        echo "== install.sh --from $RELEASE_DIR, as a user without root"
        output="$(as_tester /bin/bash "$INSTALL" --from "$RELEASE_DIR" 2>&1)"
        status=$?
        printf '%s\n' "$output" | /usr/bin/sed 's/^/   | /'
        if [ "$status" -ne 0 ]; then
            fail "install.sh exited with $status"
        fi
        check_loads "$TESTER_HOME/.local/bin" "$OUR_RUNTIME"
        case "$output" in
            *"is not on PATH"*) echo "ok   install.sh says ~/.local/bin is not on PATH" ;;
            *) fail "install.sh did not say that $TESTER_HOME/.local/bin is not on PATH" ;;
        esac
        as_tester /bin/bash "$INNER" "$TESTER_HOME/.local/bin"
        status=$?
        if [ "$status" -ne 0 ]; then
            fail "runtime-check-inner.sh on the installed tools"
        fi

        echo "== install.sh again: the runtime copy stays"
        output="$(as_tester /bin/bash "$INSTALL" --from "$RELEASE_DIR" 2>&1)"
        status=$?
        case "$status:$output" in
            0:*"is already this one"*) echo "ok   the second install keeps the runtime" ;;
            *) fail "the second install (status $status): $output" ;;
        esac

        echo "== The install.sh inside an unpacked tools tarball, into another prefix"
        as_tester /bin/mkdir -p "$TESTER_HOME/Downloads"
        /bin/cp "$TOOLS_TARBALL" "$RUNTIME_TARBALL" "$RUNTIME_TARBALL.sha256" "$TESTER_HOME/Downloads/"
        /bin/chown -R tester "$TESTER_HOME/Downloads"
        as_tester /bin/tar -xzf "$TESTER_HOME/Downloads/$TOOLS_NAME.tar.gz" -C "$TESTER_HOME/Downloads"
        status=$?
        if [ "$status" -ne 0 ]; then
            fail "unpacking the tools tarball as the user (status $status)"
        else
            output="$(as_tester "$TESTER_HOME/Downloads/$TOOLS_NAME/install.sh" --prefix "$TESTER_HOME/other" 2>&1)"
            status=$?
            # It must take the tools beside it, not download a release.
            case "$status:$output" in
                "0:"*"== Installing from $TESTER_HOME/Downloads/$TOOLS_NAME"*) echo "ok   the unpacked install.sh installed its own tools into ~/other" ;;
                *) fail "the unpacked install.sh (status $status): $output" ;;
            esac
            check_loads "$TESTER_HOME/other/bin" "$TESTER_HOME/other/lib/abracode/swift/linux"
        fi

        echo "== install.sh --uninstall"
        output="$(as_tester /bin/bash "$INSTALL" --uninstall 2>&1)"
        status=$?
        left=""
        for tool in replay dispatch fingerprint gate; do
            if [ -e "$TESTER_HOME/.local/bin/$tool" ]; then
                left="$left $tool"
            fi
        done
        if [ "$status" -ne 0 ] || [ -n "$left" ] || [ ! -f "$OUR_RUNTIME/libFoundation.so" ]; then
            fail "uninstall (status $status, left:${left:- none}): $output"
        else
            echo "ok   --uninstall removed the tools and kept the runtime folder"
        fi
        ;;
    debian)
        echo "== Installing libswiftlang"
        DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q update > /tmp/runtime-install.log 2>&1
        status=$?
        if [ "$status" -eq 0 ]; then
            DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q install -y --no-install-recommends libswiftlang >> /tmp/runtime-install.log 2>&1
            status=$?
        fi
        if [ "$status" -ne 0 ]; then
            echo "Error: installing libswiftlang failed with status $status:" >&2
            /usr/bin/tail -5 /tmp/runtime-install.log >&2
            exit 2
        fi
        echo "== install.sh --from $RELEASE_DIR, as root"
        output="$(/bin/bash "$INSTALL" --from "$RELEASE_DIR" 2>&1)"
        status=$?
        printf '%s\n' "$output" | /usr/bin/sed 's/^/   | /'
        if [ "$status" -ne 0 ]; then
            fail "install.sh exited with $status"
        fi
        check_loads /usr/local/bin system /usr/local
        if [ -e /usr/local/lib/abracode/swift ]; then
            fail "install.sh added a runtime copy although the system has one"
        fi
        /bin/bash "$INNER" /usr/local/bin
        status=$?
        if [ "$status" -ne 0 ]; then
            fail "runtime-check-inner.sh on the installed tools"
        fi
        ;;
    fedora)
        echo "== Installing swift-lang-runtime and bsdtar"
        /usr/bin/dnf -q install -y swift-lang-runtime bsdtar > /tmp/runtime-install.log 2>&1
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: installing swift-lang-runtime failed with status $status:" >&2
            /usr/bin/tail -5 /tmp/runtime-install.log >&2
            exit 2
        fi
        PREFIX="$(/usr/bin/mktemp -d /tmp/prefix.XXXXXX)"
        status=$?
        if [ "$status" -ne 0 ] || [ -z "$PREFIX" ]; then
            echo "Error: mktemp -d failed" >&2
            exit 2
        fi
        /usr/bin/bsdtar -xzf "$TOOLS_TARBALL" -C "$PREFIX" --strip-components=1 --no-same-owner
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "Error: unpacking $TOOLS_TARBALL failed with status $status" >&2
            exit 2
        fi
        check_loads "$PREFIX/bin" system "$PREFIX"
        /bin/bash "$INNER" "$PREFIX/bin"
        status=$?
        if [ "$status" -ne 0 ]; then
            fail "runtime-check-inner.sh on the unpacked tools"
        fi
        ;;
    *)
        echo "Error: unknown mode '$MODE'" >&2
        exit 2
        ;;
esac

if [ "$failures" -ne 0 ]; then
    echo "release check ($MODE): $failures failure(s)"
    exit 1
fi
echo "release check ($MODE): all passed"
exit 0
