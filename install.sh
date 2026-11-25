#!/bin/zsh
# replay tools installer for macOS zsh
# Usage: source <(/usr/bin/curl -fsSL 'https://raw.githubusercontent.com/abra-code/replay/refs/heads/master/install.sh')
# This installs replay, dispatch, fingerprint & gate tools to ~/.local/bin and ensures that path is present in PATH var
#
# It builds the latest release: the tag that https://github.com/abra-code/replay/releases/latest
# leads to. Set REPLAY_INSTALL_REF to a branch or tag to build that instead (master for the
# newest code):
#   REPLAY_INSTALL_REF=master source <(/usr/bin/curl -fsSL '...install.sh')
#
# This builds with Swift Package Manager, which targets this machine's
# architecture only. That is deliberate: the build happens on the machine that
# will run the tools, so a universal binary would be dead weight. Use build.sh
# in a clone for universal binaries, which is what a release ships.
#
# The file is sourced into the user's shell, so everything runs inside functions: they run
# with zsh's own options (pipefail added), whatever the user's shell has set, and the
# anonymous function at the end removes them again. What stays is the PATH entry.

# Plain sh syntax up to here, so that another shell stops with a message before it defines
# anything or reaches the zsh-only syntax below.
if [ -z "${ZSH_VERSION:-}" ]; then
    echo "This installer runs in zsh: source it from a zsh prompt." >&2
    return 1 2>/dev/null || exit 1
fi

# ------------------------------------------------------------------
# Check for Xcode command line tools
# ------------------------------------------------------------------
replay_install_check_xcode_cli() {
    /usr/bin/xcode-select -p > /dev/null 2>&1
    local is_installed=$?

    if [ ${is_installed} != 0 ]; then
        echo "Xcode command line tools are not installed."
        echo "Installing Xcode command line tools..."
        /usr/bin/xcode-select --install
        echo "After installation completes, re-run this installer."
        return 1
    fi
    echo "Xcode command line tools detected."
    return 0
}

# ------------------------------------------------------------------
# The tag of the latest release, printed. GitHub redirects .../releases/latest to
# .../releases/tag/<tag>; linux/install.sh finds it the same way.
# ------------------------------------------------------------------
replay_install_latest_release_tag() {
    local latest_url="https://github.com/abra-code/replay/releases/latest"
    local effective_url
    effective_url="$(/usr/bin/curl -fsSLI --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' "$latest_url")"
    local curl_status=$?
    local tag="${effective_url##*/tag/}"
    tag="${tag%%\?*}"
    tag="${tag%/}"
    if [ ${curl_status} != 0 ] || [ "$tag" = "$effective_url" ] || [ -z "$tag" ]; then
        echo "ERROR: cannot find the latest release at $latest_url (curl status $curl_status)." >&2
        echo "Set REPLAY_INSTALL_REF to a branch or tag to build that instead." >&2
        return 1
    fi
    echo "$tag"
    return 0
}

# ------------------------------------------------------------------
# 1. Generic tool installer
# ------------------------------------------------------------------
replay_install_tools() {
    local repo_name="$1"
    local source_url="$2"      # git URL or direct .zip URL
    local build_type="$3"      # "git" or "zip"
    local ref="$4"             # for git: the branch or tag to build

    echo "=== Installing $repo_name ==="

    local tmp_dir
    tmp_dir=$(/usr/bin/mktemp -d -t "${repo_name}-build-XXXXXX")
    local mktemp_status=$?
    if [ ${mktemp_status} != 0 ] || [ -z "$tmp_dir" ]; then
        echo "ERROR: could not make a temporary build folder (mktemp status $mktemp_status)" >&2
        return 1
    fi

    if [[ "$build_type" == "git" ]]; then
        replay_install_build_from_git "$source_url" "$tmp_dir" "$repo_name" "$ref"
    else
        replay_install_build_from_zip "$source_url" "$tmp_dir" "$repo_name"
    fi

    local build_result=$?

    # Final install step
    if [ ${build_result} = 0 ] && [ "${BUILD_DIR}" != "" ]; then
        local install_failed=0
        local tool
        local install_result
        for tool in replay dispatch fingerprint gate; do
            /usr/bin/install -v "$BUILD_DIR/release/$tool" "$INSTALL_DIR/"
            install_result=$?
            if [ ${install_result} != 0 ]; then
                echo "ERROR: failed to install $tool to $INSTALL_DIR/" >&2
                install_failed=1
            fi
        done

        if [ ${install_failed} != 0 ]; then
            /bin/rm -rf "$tmp_dir"
            return 1
        fi

        echo "✅ Installed replay, dispatch, fingerprint & gate to $INSTALL_DIR/"
    else
        echo "❌ Build failed for replay tools" >&2
        /bin/rm -rf "$tmp_dir"
        return 1
    fi

    # Explicit: without it the function returns the status of the cleanup rm,
    # so a temp directory that would not delete would report the whole install
    # as failed after every tool had been installed correctly.
    /bin/rm -rf "$tmp_dir"
    return 0
}

# ------------------------------------------------------------------
# 2. Build from git repository
# ------------------------------------------------------------------
replay_install_build_from_git() {
    local repo_url="$1"
    local dest_dir="$2"
    local repo_name="$3"
    local ref="$4"

    echo "Cloning $repo_url at $ref"
    /usr/bin/git clone --depth 1 --branch "$ref" "$repo_url" "$dest_dir/$repo_name"
    local clone_result=$?
    if [ ${clone_result} != 0 ]; then
        echo "ERROR: could not clone $repo_url at $ref" >&2
        return 1
    fi

    # --package-path, not pushd: this runs in the user's shell, and a Ctrl-C during the build
    # would leave it sitting in the temporary clone with an extra directory stack entry.
    # The products are placed in .build there.
    /usr/bin/swift build -c release --package-path "$dest_dir/$repo_name"
    local build_result=$?
    if [ $build_result = 0 ]; then
        BUILD_DIR="$dest_dir/$repo_name/.build"
    fi

    return $build_result
}

# ------------------------------------------------------------------
# 3. Alternative: Download .zip (GitHub release, source archive, etc.)
# ------------------------------------------------------------------
replay_install_build_from_zip() {
    local zip_url="$1"
    local dest_dir="$2"
    local repo_name="$3"

    echo "Downloading $zip_url"
    /usr/bin/curl -fsSL --proto '=https' --tlsv1.2 -o "$dest_dir/archive.zip" "$zip_url"

    echo "Unpacking"
    /usr/bin/unzip -q "$dest_dir/archive.zip" -d "$dest_dir/unpacked"

    pushd "$dest_dir/unpacked" > /dev/null
    local pushd_result=$?
    if [ ${pushd_result} != 0 ]; then
        echo "ERROR: could not enter $dest_dir/unpacked" >&2
        return 1
    fi

    # cd into a child dir starting with repo name
    cd ${repo_name}*/
    local cd_result=$?
    if [ ${cd_result} != 0 ]; then
        echo "ERROR: no ${repo_name}* directory in the archive" >&2
        popd > /dev/null
        return 1
    fi

    # products placed in .build
    /usr/bin/swift build -c release
    local build_result=$?
    if [ $build_result = 0 ]; then
        BUILD_DIR=$(pwd)/.build
    fi

    popd > /dev/null
    return $build_result
}

# ------------------------------------------------------------------
# 4. Final PATH handling (run once after all tools are installed)
# ------------------------------------------------------------------
replay_install_finalize_path() {
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        # Case 1: Not in current PATH: add now + make permanent
        export PATH="$INSTALL_DIR:$PATH"
        echo "✅ Added $INSTALL_DIR to current session PATH"

        echo "" >> "$HOME/.zshrc"
        echo "# Added by replay installer" >> "$HOME/.zshrc"
        echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$HOME/.zshrc"
        echo "✅ Added permanent PATH entry to ~/.zshrc"
    else
        # Case 2: Already in current PATH: do NOTHING to .zshrc
        echo "ℹ️  $INSTALL_DIR is already in your current PATH"
        echo "    No changes made to ~/.zshrc"
    fi
}

replay_install_main() {
    # zsh's own options, with pipefail, for this function and the ones it calls only: the
    # user's settings (err_exit, no_clobber and the like) neither leak in nor get changed.
    emulate -L zsh
    setopt pipe_fail

    # On Linux the tools come from a release, through linux/install.sh.
    local system_name
    system_name="$(/usr/bin/uname -s)"
    if [ "$system_name" = "Linux" ]; then
        echo "On Linux, install a release with:"
        echo "  /usr/bin/curl -fsSL https://raw.githubusercontent.com/abra-code/replay/refs/heads/master/linux/install.sh | /bin/bash"
        return 1
    fi

    replay_install_check_xcode_cli
    local xcode_status=$?
    if [ ${xcode_status} != 0 ]; then
        return 1
    fi

    # Read by the functions above (zsh locals are visible to the functions called from here).
    local INSTALL_DIR="$HOME/.local/bin"
    local BUILD_DIR=""
    /bin/mkdir -p "$INSTALL_DIR"
    local mkdir_status=$?
    if [ ${mkdir_status} != 0 ]; then
        echo "ERROR: could not make $INSTALL_DIR" >&2
        return 1
    fi

    local ref="${REPLAY_INSTALL_REF:-}"
    if [ -z "$ref" ]; then
        ref="$(replay_install_latest_release_tag)"
        local tag_status=$?
        if [ ${tag_status} != 0 ]; then
            return 1
        fi
        echo "Latest release: $ref"
    fi

    replay_install_tools "replay" "https://github.com/abra-code/replay.git" "git" "$ref"
    # replay_install_tools "replay" "https://github.com/abra-code/replay/archive/refs/tags/v.1.2.zip" "zip"
    local install_status=$?

    if [ ${install_status} != 0 ]; then
        echo ""
        echo "Installation did not complete. Nothing was added to PATH." >&2
        return 1
    fi

    replay_install_finalize_path

    echo ""
    echo "All tools installed successfully!"
    return 0
}

# Runs the installer, then removes every function this file defined, and gives its status to
# "source". The "always" block runs even when the user presses Ctrl-C during the build.
() {
    emulate -L zsh
    local main_status=1
    {
        replay_install_main
        main_status=$?
    } always {
        unfunction replay_install_main replay_install_check_xcode_cli replay_install_latest_release_tag \
            replay_install_tools replay_install_build_from_git replay_install_build_from_zip \
            replay_install_finalize_path
    }
    return $main_status
}
