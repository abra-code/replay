#!/bin/bash
# Makes the Linux release: the tools and Swift runtime tarballs for aarch64 and x86_64,
# checked on clean systems, ready to attach to the GitHub release. Runs on the development
# Mac with Docker (Colima); plan Phase 6.
#
# Usage: linux/release.sh [--aarch64 SOURCE] [--x86_64 SOURCE] [--allow-dirty] [--no-check]
#   SOURCE for each architecture:
#     docker  build with linux/package.sh in the image pinned in linux/swift-image (default),
#             from scratch in a build folder inside the container.
#             On Apple silicon x86_64 runs emulated: slower (about 10 minutes here), but no
#             second machine is needed.
#     DIR     a folder with that architecture's tarballs and .sha256 files, made elsewhere,
#             such as the dist folder of linux/x86-check.sh --package on an Intel Mac.
#     skip    leave the architecture out.
#   --allow-dirty  build although the working tree has changes (the build info says so)
#   --no-check     skip the checks on clean systems
#
# Output: .build-linux/release/<version>/ with the tarballs, their .sha256 files and a
# SHA256SUMS file, then the gh command that uploads them (printed, not run).
#
# Checks, for each architecture, each in a fresh container of that architecture (x86_64 ones
# emulated on Apple silicon), all through linux/release-check-inner.sh:
#   Ubuntu 24.04, no Swift: the tools with the runtime tarball in the same prefix.
#   Debian 13 with libswiftlang (Swift 6.0.3, the oldest runtime replay supports).
#   Fedora 44 with swift-lang-runtime (Swift 6.3.2).
# Base images are run with --platform, never built: without buildx, Colima's docker build
# makes an arm64 image whatever --platform says.

AARCH64_SOURCE="docker"
X86_64_SOURCE="docker"
ALLOW_DIRTY=0
CHECK=1

while [ $# -gt 0 ]; do
    case "$1" in
        --aarch64|--x86_64)
            if [ $# -lt 2 ]; then
                echo "Error: $1 needs docker, skip or a folder" >&2
                exit 1
            fi
            if [ "$1" = "--aarch64" ]; then
                AARCH64_SOURCE="$2"
            else
                X86_64_SOURCE="$2"
            fi
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            ;;
        --no-check)
            CHECK=0
            ;;
        -h|--help)
            /usr/bin/sed -n '2,27p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unrecognized argument: $1 (see --help)" >&2
            exit 1
            ;;
    esac
    shift
done

LINUX_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
REPO_DIR="$(CDPATH= cd -P -- "$LINUX_DIR/.." && pwd)"
if [ -z "$LINUX_DIR" ] || [ ! -f "$REPO_DIR/Package.swift" ]; then
    echo "Error: cannot find the repository root above linux/" >&2
    exit 1
fi

DOCKER="${DOCKER:-}"
if [ -z "$DOCKER" ]; then
    for candidate in /opt/homebrew/bin/docker /usr/local/bin/docker /usr/bin/docker; do
        if [ -x "$candidate" ]; then
            DOCKER="$candidate"
            break
        fi
    done
fi
if [ -z "$DOCKER" ] || [ ! -x "$DOCKER" ]; then
    echo "Error: docker not found. Install Docker or Colima, or set DOCKER=/path/to/docker." >&2
    exit 1
fi

IMAGE="$(/usr/bin/grep -v '^#' "$LINUX_DIR/swift-image" | /usr/bin/head -n 1)"
if [ -z "$IMAGE" ]; then
    echo "Error: no image in linux/swift-image" >&2
    exit 1
fi
VERSION="$(/usr/bin/sed -n 's/^#define REPLAY_VERSION[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*$/\1/p' "$REPO_DIR/common/include/replay_version.h")"
if [ -z "$VERSION" ]; then
    echo "Error: no REPLAY_VERSION in common/include/replay_version.h" >&2
    exit 1
fi

# The source: the commit, and whether the tree has changes. Untracked files count: SwiftPM
# compiles every source file in a target's folder, tracked or not.
COMMIT="$(/usr/bin/git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)"
FULL_COMMIT="$(/usr/bin/git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
if [ -z "$COMMIT" ] || [ -z "$FULL_COMMIT" ]; then
    echo "Error: cannot read the commit (git rev-parse failed in $REPO_DIR)" >&2
    exit 1
fi
CHANGES="$(/usr/bin/git -C "$REPO_DIR" status --porcelain 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: git status failed: $CHANGES" >&2
    exit 1
fi
if [ -n "$CHANGES" ]; then
    if [ "$ALLOW_DIRTY" -ne 1 ]; then
        echo "Error: the working tree has changes; commit them, or pass --allow-dirty for a test build:" >&2
        printf '%s\n' "$CHANGES" >&2
        exit 1
    fi
    SOURCE_INFO="commit $COMMIT, working tree with changes"
else
    SOURCE_INFO="commit $COMMIT"
fi

OUT_DIR="$REPO_DIR/.build-linux/release/$VERSION"
/bin/mkdir -p "$OUT_DIR"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: cannot create $OUT_DIR" >&2
    exit 1
fi
SWIFT_VERSION="$(printf '%s\n' "$IMAGE" | /usr/bin/sed -n 's/^swift:\([0-9][0-9.]*\)-.*/\1/p')"
if [ -z "$SWIFT_VERSION" ]; then
    echo "Error: cannot read the Swift version from the image '$IMAGE'" >&2
    exit 1
fi

failures=0
ARCHS=()
# The files of the architectures produced in this run, for SHA256SUMS and the upload: the
# folder may still hold another architecture's tarballs from an earlier run.
RELEASE_FILES=()

# Checks one tarball against its .sha256 file. $1: tarball.
verify_sum() {
    local tarball="$1"
    local expected_line
    expected_line="$(/bin/cat "$tarball.sha256" 2>/dev/null)"
    local actual_line
    actual_line="$(/usr/bin/shasum -a 256 "$tarball")"
    if [ -z "$expected_line" ] || [ "${expected_line%% *}" != "${actual_line%% *}" ]; then
        echo "Error: $tarball does not match its .sha256 file" >&2
        return 1
    fi
    return 0
}

# Builds or collects one architecture. $1: aarch64 or x86_64; $2: its source.
produce() {
    local arch="$1"
    local source="$2"
    local platform="linux/arm64"
    if [ "$arch" = "x86_64" ]; then
        platform="linux/amd64"
    fi
    local tools="replay_${VERSION}_linux_$arch.tar.gz"
    local runtime="swift-runtime_${SWIFT_VERSION}_linux_$arch.tar.gz"
    # Where the tarballs are checked: a folder's are checked there and copied only when they
    # pass, so a rejected folder leaves the release folder as it was.
    local from_dir="$OUT_DIR"
    case "$source" in
        skip)
            echo "== $arch: skipped"
            return 0
            ;;
        docker)
            echo "== $arch: building in $IMAGE ($platform)"
            "$DOCKER" run --rm --platform "$platform" -e "REPLAY_SOURCE_COMMIT=$SOURCE_INFO" \
                -v "$REPO_DIR:/src" -w /src "$IMAGE" \
                /bin/bash /src/linux/package.sh --out "/src/.build-linux/release/$VERSION" \
                --scratch-path /tmp/replay-release-build
            local build_status=$?
            if [ "$build_status" -ne 0 ]; then
                echo "Error: building and packing $arch failed with status $build_status" >&2
                return 1
            fi
            ;;
        *)
            if [ ! -d "$source" ]; then
                echo "Error: --$arch takes docker, skip or an existing folder, not '$source'" >&2
                return 1
            fi
            echo "== $arch: taking the tarballs from $source"
            local file
            for file in "$tools" "$tools.sha256" "$runtime" "$runtime.sha256"; do
                if [ ! -f "$source/$file" ]; then
                    echo "Error: $source/$file is missing (the version or the Swift release may differ)" >&2
                    return 1
                fi
            done
            from_dir="$source"
            ;;
    esac
    verify_sum "$from_dir/$tools" || return 1
    verify_sum "$from_dir/$runtime" || return 1
    # The build info names the source; a tarball made elsewhere must come from this commit
    # (its short hash may be longer or shorter than this clone's), and from a clean tree
    # unless --allow-dirty. "commit <hash>", or "commit <hash>, working tree ..." as
    # linux/x86-check-send.sh and this script write it.
    local info
    info="$(/usr/bin/tar -xzOf "$from_dir/$tools" "replay_${VERSION}_linux_$arch/BUILD-INFO.txt" 2>/dev/null)"
    local info_source
    info_source="$(printf '%s\n' "$info" | /usr/bin/sed -n 's/^source: //p')"
    echo "   source: $info_source"
    local info_hash
    info_hash="$(printf '%s\n' "$info_source" | /usr/bin/sed -n 's/^commit \([0-9a-f]\{7,\}\)\(,.*\)\{0,1\}$/\1/p')"
    local info_commit
    if [ -n "$info_hash" ]; then
        info_commit="$(/usr/bin/git -C "$REPO_DIR" rev-parse --verify -q "$info_hash^{commit}" 2>/dev/null)"
    fi
    if [ -z "$info_commit" ] || [ "$info_commit" != "$FULL_COMMIT" ]; then
        echo "Error: the $arch tarball was built from '$info_source', not commit $COMMIT" >&2
        return 1
    fi
    case "$info_source" in
        "commit $info_hash"|"commit $info_hash, working tree clean"*) ;;
        *)
            if [ "$ALLOW_DIRTY" -ne 1 ]; then
                echo "Error: the $arch tarball was built from a working tree with changes ('$info_source'); rebuild it from the committed tree, or pass --allow-dirty for a test release" >&2
                return 1
            fi
            ;;
    esac
    if [ ! "$from_dir" -ef "$OUT_DIR" ]; then
        local file
        for file in "$tools" "$tools.sha256" "$runtime" "$runtime.sha256"; do
            /bin/cp "$from_dir/$file" "$OUT_DIR/$file"
            local copy_status=$?
            if [ "$copy_status" -ne 0 ]; then
                echo "Error: cannot copy $from_dir/$file" >&2
                return 1
            fi
        done
    fi
    ARCHS+=("$arch")
    RELEASE_FILES+=("$tools" "$runtime")
    return 0
}

produce aarch64 "$AARCH64_SOURCE"
if [ $? -ne 0 ]; then
    failures=$((failures + 1))
fi
produce x86_64 "$X86_64_SOURCE"
if [ $? -ne 0 ]; then
    failures=$((failures + 1))
fi
if [ ${#ARCHS[@]} -eq 0 ]; then
    echo "Error: no architecture was produced" >&2
    exit 1
fi

check_results=""
if [ "$CHECK" -eq 1 ]; then
    for arch in "${ARCHS[@]}"; do
        platform="linux/arm64"
        if [ "$arch" = "x86_64" ]; then
            platform="linux/amd64"
        fi
        tools="/release/replay_${VERSION}_linux_$arch.tar.gz"
        runtime="/release/swift-runtime_${SWIFT_VERSION}_linux_$arch.tar.gz"
        for system in "bundled ubuntu:24.04" "debian debian:trixie" "fedora fedora:44"; do
            mode="${system%% *}"
            base="${system#* }"
            echo ""
            echo "== $arch: checking on $base ($mode)"
            "$DOCKER" run --rm --platform "$platform" \
                -v "$OUT_DIR:/release:ro" \
                -v "$LINUX_DIR/release-check-inner.sh:/check/release-check-inner.sh:ro" \
                -v "$LINUX_DIR/runtime-check-inner.sh:/check/runtime-check-inner.sh:ro" \
                "$base" /bin/bash /check/release-check-inner.sh "$mode" "$tools" "$runtime"
            status=$?
            if [ "$status" -eq 0 ]; then
                check_results="$check_results
  PASS: $arch on $base ($mode)"
            else
                check_results="$check_results
  FAIL: $arch on $base ($mode), status $status"
                failures=$((failures + 1))
            fi
        done
    done
fi

# SHA256SUMS over the tarballs of this run.
SUMS="$(CDPATH= cd -P -- "$OUT_DIR" && /usr/bin/shasum -a 256 "${RELEASE_FILES[@]}")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$SUMS" ]; then
    echo "Error: cannot compute SHA256SUMS in $OUT_DIR" >&2
    exit 1
fi
printf '%s\n' "$SUMS" > "$OUT_DIR/SHA256SUMS"

echo ""
echo "== Linux release $VERSION ($SOURCE_INFO) in $OUT_DIR:"
/bin/ls -l "$OUT_DIR" | /usr/bin/sed 1d
if [ -n "$check_results" ]; then
    echo "== Checks:$check_results"
fi
if [ "$failures" -ne 0 ]; then
    echo "== $failures step(s) failed; do not publish"
    exit 1
fi
if [ "$CHECK" -ne 1 ]; then
    echo "Warning: the checks on clean systems were skipped (--no-check)"
fi
if [ ${#ARCHS[@]} -lt 2 ]; then
    echo "Warning: only ${ARCHS[*]} was produced; a release needs aarch64 and x86_64"
fi
echo "== To attach to the GitHub release v$VERSION (create it first if needed):"
upload_paths=""
for file in "${RELEASE_FILES[@]}" SHA256SUMS; do
    upload_paths="$upload_paths $OUT_DIR/$file"
done
echo "   gh release upload v$VERSION$upload_paths -R abra-code/replay"
exit 0
