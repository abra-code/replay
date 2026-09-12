#!/bin/zsh
# replay tools installer for macOS zsh
# Usage: source <(/usr/bin/curl -fsSL 'https://raw.githubusercontent.com/abra-code/replay/refs/heads/master/install.sh')
# This installs replay, dispatch, fingerprint & gate tools to ~/.local/bin and ensures that path is present in PATH var
#
# This builds with Swift Package Manager, which targets this machine's
# architecture only. That is deliberate: the build happens on the machine that
# will run the tools, so a universal binary would be dead weight. Use build.sh
# in a clone for universal binaries, which is what a release ships.

set -o pipefail

INSTALL_DIR="$HOME/.local/bin"
/bin/mkdir -p "$INSTALL_DIR"
BUILD_DIR=""

# ------------------------------------------------------------------
# Check for Xcode command line tools
# ------------------------------------------------------------------
check_xcode_cli() {
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

if ! check_xcode_cli; then
    return 1
fi

# ------------------------------------------------------------------
# 1. Generic tool installer
# ------------------------------------------------------------------
install_tools() {
    local repo_name="$1"
    local source_url="$2"      # git URL or direct .zip URL
    local build_type="$3"      # "git" or "zip"

    echo "=== Installing $repo_name ==="

    local tmp_dir=$(/usr/bin/mktemp -d -t "${repo_name}-build-XXXXXX")
	
    if [[ "$build_type" == "git" ]]; then
        build_from_git "$source_url" "$tmp_dir" "$repo_name"
    else
        build_from_zip "$source_url" "$tmp_dir" "$repo_name"
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
build_from_git() {
    local repo_url="$1"
    local dest_dir="$2"
    local repo_name="$3"

    echo "Cloning $repo_url"
    /usr/bin/git clone --depth 1 "$repo_url" "$dest_dir/$repo_name"
    local clone_result=$?
    if [ ${clone_result} != 0 ]; then
        echo "ERROR: could not clone $repo_url" >&2
        return 1
    fi

    # Without the status check above and this one, a failed clone leaves the
    # directory missing, pushd fails, and "swift build" then runs in whatever
    # directory the user was sitting in when they sourced this - building their
    # project instead of this one.
    pushd "$dest_dir/$repo_name" > /dev/null
    local pushd_result=$?
    if [ ${pushd_result} != 0 ]; then
        echo "ERROR: could not enter $dest_dir/$repo_name" >&2
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
# 3. Alternative: Download .zip (GitHub release, source archive, etc.)
# ------------------------------------------------------------------
build_from_zip() {
    local zip_url="$1"
    local dest_dir="$2"
    local repo_name="$3"

    echo "Downloading $zip_url"
    /usr/bin/curl -fsSL -o "$dest_dir/archive.zip" "$zip_url"

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
finalize_path() {
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

install_tools "replay" "https://github.com/abra-code/replay.git" "git"
# install_tools "replay" "https://github.com/abra-code/replay/archive/refs/tags/v.1.2.zip" "zip"
install_status=$?

if [ ${install_status} != 0 ]; then
    echo ""
    echo "Installation did not complete. Nothing was added to PATH." >&2
    return 1
fi

finalize_path

echo ""
echo "All tools installed successfully!"
