#!/bin/sh
# makepkg.sh - build and sign the replay installer package
#
# Written by PackageBuilder.app from "replay.pkgbld" on 2026-09-12.
#
# Self-contained: Apple's command line tools are the only requirement, so
# this same step runs on a CI machine with no GUI session. The pipeline is a
# transcription of the app's own: verify the payload, stage it, pkgbuild,
# patch PackageInfo, productbuild, productsign, and land the signed package
# in the output folder. It ends at a signed package: notarization is a
# separate step, and the command to run is printed at the end.
#
# Usage: sh makepkg.sh [options]
#   --version <v>        Package version. Default: 2.2.1
#   --artifacts-dir <d>  Where the payload artifacts are. Default: /Users/tkukielk/git/replay/build/Release
#   --output-dir <d>     Where the signed package lands. Default: /Users/tkukielk/git/replay/installer/dist
#   --identity <i>       Installer signing identity. Default: (none)
#   --project-dir <d>    Folder the installer resources are read from.
#                        Default: the folder holding this script.
#   --unsigned           Skip the identity check and productsign; the result is a
#                        test-only package that macOS will not install elsewhere.
#   -h, --help           Show this help.

set -u

# --- The document, frozen at export time --------------------------------------
project_name='replay'
package_version='2.2.1'
installer_identity=''
artifacts_dir='/Users/tkukielk/git/replay/build/Release'
output_dir='/Users/tkukielk/git/replay/installer/dist'
project_dir="$(cd "$(/usr/bin/dirname "$0")" 2>/dev/null && pwd)"
[ -n "$project_dir" ] || project_dir="$(pwd)"
do_codesign='1'
needs_artifacts=1
build_date="$(/bin/date +%Y-%m-%d)"

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

announce() {
    printf '\n== %s ==\n' "$*"
}

require_option_value() {
    case "$2" in
        ''|-*) fail "$1 requires a value, got: '$2'" ;;
    esac
}

# A relative flag value is resolved against the caller's directory.
invocation_dir="$(pwd)"
absolute_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$invocation_dir" "$1" ;;
    esac
}

usage() {
    /usr/bin/sed -n '2,/^$/p' "$0" | /usr/bin/sed 's/^#//; s/^ //'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)       require_option_value "$1" "${2-}"; package_version="$2"; shift 2 ;;
        --artifacts-dir) require_option_value "$1" "${2-}"; artifacts_dir="$(absolute_path "$2")"; shift 2 ;;
        --output-dir)    require_option_value "$1" "${2-}"; output_dir="$(absolute_path "$2")"; shift 2 ;;
        --project-dir)   require_option_value "$1" "${2-}"; project_dir="$(absolute_path "$2")"; shift 2 ;;
        --identity)      require_option_value "$1" "${2-}"; installer_identity="$2"; do_codesign=1; shift 2 ;;
        --unsigned)      do_codesign=0; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; fail "Unknown option: $1" ;;
    esac
done

# The same value rules the app enforces (its design section 4.4): these are
# spliced into a filename and into XML, so they are constrained before they go
# anywhere.
case "$project_name" in
    ''|*[!A-Za-z0-9._-]*) fail "Project name '$project_name' is not usable in a filename" ;;
esac
case "$package_version" in
    ''|[!0-9]*) fail "Version '$package_version' must start with a digit" ;;
esac
case "$package_version" in
    *[!0-9A-Za-z.+_-]*) fail "Version '$package_version' may hold only letters, digits, . + _ or -" ;;
esac

if [ "$needs_artifacts" = "1" ] && [ -z "$artifacts_dir" ]; then
    fail "The payload references its artifacts folder - pass --artifacts-dir"
fi
[ -n "$output_dir" ] || fail "No output folder - pass --output-dir"

if [ "$do_codesign" = "1" ]; then
    [ -n "$installer_identity" ] || fail "No signing identity - pass --identity, or --unsigned for a test build"
    case "$(/usr/bin/security find-identity -p basic -v 2>/dev/null)" in
        *"$installer_identity"*) ;;
        *) fail "Identity not in this keychain: $installer_identity" ;;
    esac
fi

staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/makepkg-XXXXXXXX")" || fail "mktemp failed"
cleanup() { /bin/rm -rf "$staging_dir"; }
trap cleanup EXIT

component_dir="$staging_dir/component"
# Every destination staged so far, normalized - read back by stage_entry's
# nesting check. Inside the scratch, so it goes away with the trap.
# Shared by every component, deliberately: two components installing to one
# path, or one inside another, is refused here for the same reason it is refused
# within a single component. The two component packages are built independently
# and nothing downstream objects - the later one just wins at install time.
staged_destinations="$staging_dir/staged_destinations"
/bin/mkdir -p "$component_dir" || fail "Could not create the staging directory"

# --- Verify -------------------------------------------------------------------
# The checks the document asserts about each artifact, transcribed from the
# app's verify stage. The messages name the mistake, not the symptom: a binary
# from "xcodebuild build" is signed with --timestamp=none and no hardened
# runtime, one from a machine missing its distribution xcconfig is ad-hoc
# signed, and a stale artifacts folder has no symptom at all except the
# version cross-check.

# The bundle's Info.plist, or nothing. A .framework is a versioned bundle and
# keeps its Info.plist under Versions/<v>/Resources with no Contents directory
# at all, so a Contents-only test reports that a framework is not a bundle and
# every check the entry asserts is silently skipped.
info_plist_of() {
    [ -d "$1" ] || return 1
    if [ -f "$1/Contents/Info.plist" ]; then printf '%s/Contents/Info.plist' "$1"; return 0; fi
    # Current first, so a framework with several versions answers for the one
    # it publishes.
    for ip_candidate in "$1"/Versions/Current/Resources/Info.plist \
                        "$1"/Versions/*/Resources/Info.plist \
                        "$1"/Resources/Info.plist "$1"/Info.plist; do
        if [ -f "$ip_candidate" ]; then printf '%s' "$ip_candidate"; return 0; fi
    done
    return 1
}

executable_of() {
    if [ -f "$1" ]; then printf '%s' "$1"; return 0; fi
    exe_info="$(info_plist_of "$1")" || return 1
    exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$exe_info" 2>/dev/null)" || exe_name=""
    if [ -z "$exe_name" ]; then
        exe_name="$(/usr/bin/basename "$1")"
        exe_name="${exe_name%.*}"
    fi
    # Contents/MacOS for an ordinary bundle; for a framework the executable
    # sits in the version directory beside Resources, which is two levels up
    # from the Info.plist.
    exe_version_dir="$(/usr/bin/dirname "$(/usr/bin/dirname "$exe_info")")"
    for exe_candidate in "$1/Contents/MacOS/$exe_name" \
                         "$exe_version_dir/$exe_name" \
                         "$1/$exe_name"; do
        if [ -f "$exe_candidate" ]; then printf '%s' "$exe_candidate"; return 0; fi
    done
    return 1
}

# codesign report for one slice ("" = whatever codesign picks) into $1.
# verify first: what --display prints about a signature that does not validate
# is not evidence of anything.
check_signature() {
    sig_report="$1"; sig_path="$2"; sig_arch="$3"; sig_label="$4"
    sig_signed_by="$5"; sig_hardened="$6"; sig_timestamp="$7"
    if [ -n "$sig_arch" ]; then
        /usr/bin/codesign --verify --strict --verbose=2 --arch "$sig_arch" "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: the code signature does not verify: $(/bin/cat "$sig_report")"
        /usr/bin/codesign --display --verbose=4 --arch "$sig_arch" "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: codesign could not read the signature"
    else
        /usr/bin/codesign --verify --strict --verbose=2 "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: the code signature does not verify: $(/bin/cat "$sig_report")"
        /usr/bin/codesign --display --verbose=4 "$sig_path" >"$sig_report" 2>&1 \
            || fail "$sig_label: codesign could not read the signature"
    fi
    if [ -n "$sig_signed_by" ]; then
        # The leaf certificate only, as a prefix, exactly as the app matches it.
        found_authority="$(/usr/bin/sed -n 's/^Authority=//p' "$sig_report" | /usr/bin/head -n 1)"
        case "$found_authority" in
            "$sig_signed_by"*) ;;
            *) fail "$sig_label: expected a signature from '$sig_signed_by', found ${found_authority:-nothing - the signature is ad-hoc}" ;;
        esac
    fi
    if [ "$sig_timestamp" = "1" ] && ! /usr/bin/grep -q '^Timestamp=' "$sig_report"; then
        fail "$sig_label: signed without a secure timestamp - notarization will reject it. A binary built with 'xcodebuild build' is signed this way; rebuild with 'xcodebuild archive'."
    fi
    if [ "$sig_hardened" = "1" ]; then
        case "$(/usr/bin/grep '^CodeDirectory ' "$sig_report" | /usr/bin/head -n 1)" in
            *"(runtime)"*|*"(runtime,"*|*",runtime)"*|*",runtime,"*) ;;
            *) fail "$sig_label: not signed with the hardened runtime - notarization will reject it. Rebuild with 'xcodebuild archive', or sign with codesign --options runtime." ;;
        esac
    fi
}

# verify_entry <source> <archs> <signed_by> <hardened> <timestamp> <version_flag>
verify_entry() {
    v_source="$1"; v_archs="$2"; v_signed_by="$3"
    v_hardened="$4"; v_timestamp="$5"; v_version_flag="$6"
    v_label="$(/usr/bin/basename "$v_source")"
    [ -e "$v_source" ] || fail "$v_label is not on disk: $v_source"
    [ -r "$v_source" ] || fail "$v_label cannot be read: $v_source"

    if [ -z "$v_archs" ] && [ -z "$v_signed_by" ] && [ "$v_hardened" != "1" ] \
        && [ "$v_timestamp" != "1" ] && [ -z "$v_version_flag" ]; then
        printf '  %s: nothing asserted, nothing checked\n' "$v_label"
        return 0
    fi

    v_executable="$(executable_of "$v_source")" || v_executable=""

    if [ -n "$v_archs" ]; then
        [ -n "$v_executable" ] || fail "$v_label: no Mach-O executable to read architectures from"
        v_found="$(/usr/bin/lipo -archs "$v_executable" 2>/dev/null)" || v_found=""
        # Globbing off around the loop: architecture names are bare tokens, but
        # a glob character in a hand-edited list would otherwise produce one
        # refusal per matching filename in the working directory.
        set -f
        for v_arch in $v_archs; do
            case " $v_found " in
                *" $v_arch "*) ;;
                *) set +f; fail "$v_label: not built for $v_arch - lipo reports [$v_found]. arm64e is a separate architecture, not a superset of arm64." ;;
            esac
        done
        set +f
        printf '  %s: built for %s\n' "$v_label" "$v_found"
    fi

    if [ -n "$v_signed_by" ] || [ "$v_hardened" = "1" ] || [ "$v_timestamp" = "1" ]; then
        v_report="$staging_dir/codesign.txt"
        v_slices=""
        [ -z "$v_executable" ] || v_slices="$(/usr/bin/lipo -archs "$v_executable" 2>/dev/null)" || v_slices=""
        case "$v_slices" in
            *' '*) ;;
            *) v_slices="" ;;
        esac
        if [ -z "$v_slices" ]; then
            check_signature "$v_report" "$v_source" "" "$v_label" "$v_signed_by" "$v_hardened" "$v_timestamp"
        else
            set -f
            # The whole file first, then every slice: an --arch pass validates
            # the slice it is aimed at and nothing else, so data appended after
            # the signed region passes every per-slice check and is refused
            # only by the whole-file strict validation.
            /usr/bin/codesign --verify --strict --verbose=2 "$v_source" >"$v_report" 2>&1 \
                || fail "$v_label: the code signature does not verify: $(/bin/cat "$v_report")"
            for v_arch in $v_slices; do
                set +f
                check_signature "$v_report" "$v_source" "$v_arch" "$v_label" "$v_signed_by" "$v_hardened" "$v_timestamp"
                set -f
            done
            set +f
        fi
        printf '  %s: signature ok\n' "$v_label"
    fi

    if [ -n "$v_version_flag" ]; then
        v_info="$(info_plist_of "$v_source")" || v_info=""
        if [ -n "$v_info" ]; then
            # A bundle answers from its Info.plist rather than by being run.
            v_reported="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$v_info" 2>/dev/null)" || v_reported=""
        else
            v_line="$("$v_source" "$v_version_flag" </dev/null 2>/dev/null | /usr/bin/head -n 1)" || v_line=""
            v_reported="$(printf '%s' "$v_line" | /usr/bin/grep -oE '[0-9]+(\.[0-9]+)+([0-9A-Za-z.+_-]*)?' 2>/dev/null | /usr/bin/head -n 1)" || v_reported=""
        fi
        [ -n "$v_reported" ] || fail "$v_label: reports no version to compare against $component_version"
        if [ "$v_reported" != "$component_version" ]; then
            fail "$v_label: reports version $v_reported, but this is being built as $component_version. The artifacts folder may be stale."
        fi
        printf '  %s: reports version %s\n' "$v_label" "$v_reported"
    fi
    return 0
}

# pb_normalize_path <path>
#
# Collapse runs of slashes, drop "." components, and drop any trailing slash.
# Deliberately does NOT resolve "..", which is refused outright instead:
# resolving it lexically is wrong wherever a symlink is involved.
#
# The trailing slash is not cosmetic. Without this, "dirname" on a destination
# ending in "/" returns the symlink's PARENT rather than the symlink, so the
# containment test below inspects the wrong node and passes; and "[ -L x/ ]" is
# FALSE, because a trailing slash makes the kernel resolve the link - while
# "ditto" still writes straight through it.
pb_normalize_path() {
    n_path="$1"; n_leading=""; n_rest="$n_path"; n_result=""
    case "$n_path" in
        /*) n_leading="/" ;;
    esac
    while [ -n "$n_rest" ]; do
        n_part="${n_rest%%/*}"
        case "$n_rest" in
            */*) n_rest="${n_rest#*/}" ;;
            *) n_rest="" ;;
        esac
        case "$n_part" in
            ''|.) continue ;;
        esac
        n_result="$n_result/$n_part"
    done
    if [ -z "$n_result" ]; then
        printf '%s' "${n_leading:-.}"
    elif [ -n "$n_leading" ]; then
        printf '%s' "$n_result"
    else
        printf '%s' "${n_result#/}"
    fi
}

# pb_assert_inside <path-that-must-exist> <root> <destination-for-the-message>
pb_assert_inside() {
    a_real="$(cd -P "$1" 2>/dev/null && /bin/pwd -P)"
    a_root="$(cd -P "$2" 2>/dev/null && /bin/pwd -P)"
    if [ -z "$a_real" ] || [ -z "$a_root" ]; then
        fail "Could not resolve the staging path for $3"
    fi
    case "$a_real" in
        "$a_root"|"$a_root"/*) ;;
        *) fail "Destination $3 resolves outside the payload root" ;;
    esac
}

# stage_entry <source> <destination> <mode>
#
# This carries its own copy of the app's payload-root containment guard rather
# than calling into a library, because it runs on a build machine where no
# library exists. It must stay in step with stage_payload_root in
# lib.packagebuilder.build.sh: a document the app refuses to build must not be
# buildable by the script the app exported from it.
stage_entry() {
    s_source="$1"; s_destination="$2"; s_mode="$3"
    # Refused outright rather than resolved: resolving ".." lexically is wrong
    # wherever a symlink is involved.
    case "/$s_destination/" in
        */../*) fail "Destination $s_destination must not contain \"..\"" ;;
    esac
    # A newline would be recorded as its first line only in the line-oriented
    # record file below, so the nesting check would compare a truncated string
    # and let a nesting document through - which is exactly the invariant this
    # helper's header promises. Refused rather than escaped: a newline in an
    # install path is not something to guess the intent of.
    if [ "$s_destination" != "$(printf '%s' "$s_destination" | /usr/bin/tr -d '\n')" ]; then
        fail "Destination contains a line break, which cannot be installed"
    fi
    s_destination="$(pb_normalize_path "$s_destination")"
    case "$s_destination" in
        "$install_location"|"${install_location%/}/"*) ;;
        *) fail "Destination $s_destination is not under the install location $install_location" ;;
    esac
    s_relative="${s_destination#"${install_location%/}"}"
    s_relative="${s_relative#/}"
    [ -n "$s_relative" ] || fail "Destination $s_destination stages to nothing"

    # Two destinations may not nest, and neither may repeat - the same
    # precondition the app applies before it stages anything. This was the last
    # guard the app had and this copy did not, which made the comment above
    # false: the app refused a nesting document and then handed you a script
    # that built it. Compared against the destinations already staged in THIS
    # run, read from a file so the loop does not run in a subshell.
    if [ -f "$staged_destinations" ]; then
        while IFS= read -r s_prev; do
            [ -n "$s_prev" ] || continue
            if [ "$s_prev" = "$s_destination" ]; then
                fail "Destination $s_destination is installed to twice"
            fi
            case "$s_destination/" in
                "$s_prev"/*) fail "Destination $s_destination installs inside $s_prev" ;;
            esac
            case "$s_prev/" in
                "$s_destination"/*) fail "Destination $s_prev installs inside $s_destination" ;;
            esac
        done < "$staged_destinations"
    fi
    printf '%s\n' "$s_destination" >> "$staged_destinations"

    s_target="$payload_root/$s_relative"
    s_parent="$(/usr/bin/dirname "$s_target")"

    # BEFORE mkdir, not after. "mkdir -p" follows symlink components, so by the
    # time the parent exists the escape has already happened - the refusal would
    # be accurate and too late, with directories already created outside. Climb
    # to the deepest ancestor that exists and check that one; if it resolves
    # outside, everything mkdir would create beneath it does too.
    s_ancestor="$s_parent"
    while [ ! -d "$s_ancestor" ]; do
        s_next="$(/usr/bin/dirname "$s_ancestor")"
        [ "$s_next" != "$s_ancestor" ] || break
        s_ancestor="$s_next"
    done
    pb_assert_inside "$s_ancestor" "$payload_root" "$s_destination"

    /bin/mkdir -p "$s_parent" || fail "Could not create the staging path for $s_relative"
    # And again once it exists, as the backstop. This is the check that sees what
    # the file system sees, and the reason the string comparisons above are not
    # enough on their own: APFS folds case and folds NFD to NFC, so two
    # destinations that compare unequal as strings can name one directory.
    pb_assert_inside "$s_parent" "$payload_root" "$s_destination"

    # And the leaf, which the parent check cannot cover: "ditto" of a directory
    # onto an existing symlink writes through it, and "chmod" without -h follows
    # it. The payload root is this script's own, so a symlink already sitting
    # here was put there by an earlier entry.
    if [ -L "$s_target" ]; then
        fail "Destination $s_destination is a symlink staged by an earlier item"
    fi
    /usr/bin/ditto "$s_source" "$s_target" || fail "Could not copy $s_source"
    /bin/chmod "$s_mode" "$s_target" || fail "Could not set mode $s_mode on $s_relative"
    printf '  staged %s\n' "$s_relative"
}

identifier='com.abracode.pkg.replay'
component_version="$package_version"
install_location='/'
overwrite_permissions='false'
payload_root="$staging_dir"/'root'
/bin/mkdir -p "$payload_root" || fail "Could not create the staging directory"

announce "VERIFY the payload against what the document asserts"
verify_entry ''"$artifacts_dir"'/replay' 'x86_64 arm64 ' 'Developer ID Application' '1' '1' '--version'
verify_entry ''"$artifacts_dir"'/dispatch' 'x86_64 arm64 ' 'Developer ID Application' '1' '1' '--version'
verify_entry ''"$artifacts_dir"'/fingerprint' 'x86_64 arm64 ' 'Developer ID Application' '1' '1' '--version'
verify_entry ''"$artifacts_dir"'/gate' 'x86_64 arm64 ' 'Developer ID Application' '1' '1' '--version'

announce "STAGE the payload"
stage_entry ''"$artifacts_dir"'/replay' '/usr/local/bin/replay' '0755'
stage_entry ''"$artifacts_dir"'/dispatch' '/usr/local/bin/dispatch' '0755'
stage_entry ''"$artifacts_dir"'/fingerprint' '/usr/local/bin/fingerprint' '0755'
stage_entry ''"$artifacts_dir"'/gate' '/usr/local/bin/gate' '0755'

announce "PKGBUILD component package"
component_package="$component_dir"/'replay.pkg'
# Bundles must not be relocatable (the app's design 8.2): pkgbuild marks them
# relocatable, which makes Installer follow Spotlight to any existing copy of
# the bundle identifier - a stale copy in ~/Downloads silently becomes the
# install target. pkgbuild --analyze writes a component plist; every entry's
# BundleIsRelocatable is forced false. No entries means no bundles, and the
# plist is not passed at all.
component_plist="$staging_dir/component.plist"
/usr/bin/pkgbuild --analyze --root "$payload_root" "$component_plist" >/dev/null 2>&1 \
    || fail "pkgbuild --analyze failed"
# A non-zero PlistBuddy answers two different questions the same way: "that key
# is not there" and "this file could not be read". Treating both as "no bundles"
# would drop --component-plist and ship pkgbuild's default
# BundleIsRelocatable=true - the exact hazard this block exists to prevent, with
# nothing printed. So the file is proved readable first, and only then is an
# absent :0 taken to mean there are no bundles.
/usr/libexec/PlistBuddy -c 'Print' "$component_plist" >/dev/null 2>&1
plist_readable=$?
if [ "$plist_readable" -ne 0 ]; then
    fail "Could not read the component plist that pkgbuild --analyze wrote: $component_plist"
fi

/usr/libexec/PlistBuddy -c 'Print :0' "$component_plist" >/dev/null 2>&1
has_bundles=$?
if [ "$has_bundles" -eq 0 ]; then
    reloc_index=0
    while true; do
        /usr/libexec/PlistBuddy -c "Print :$reloc_index" "$component_plist" >/dev/null 2>&1
        entry_present=$?
        if [ "$entry_present" -ne 0 ]; then
            break
        fi
        /usr/libexec/PlistBuddy -c "Set :$reloc_index:BundleIsRelocatable false" "$component_plist" \
            || fail "Could not mark bundle $reloc_index non-relocatable"
        reloc_index=$((reloc_index + 1))
    done
else
    component_plist=""
fi
if [ -n "$component_plist" ]; then
    /usr/bin/pkgbuild --root "$payload_root" --identifier "$identifier" --version "$component_version" \
        --install-location "$install_location" --ownership recommended \
        --component-plist "$component_plist" "$component_package" \
        || fail "pkgbuild failed"
else
    /usr/bin/pkgbuild --root "$payload_root" --identifier "$identifier" --version "$component_version" \
        --install-location "$install_location" --ownership recommended "$component_package" \
        || fail "pkgbuild failed"
fi

# pkgbuild always writes overwrite-permissions="true", which tells Installer to
# apply the BOM's root:wheel owner and mode to directories that already exist -
# with a payload under /usr/local that resets a Homebrew user's /usr/local.
# pkgbuild has no option for it, so PackageInfo is patched through an
# expand/flatten round trip; --expand keeps Payload and Bom opaque. The grep is
# not decoration: a silently failed sed would ship the harmful package.
expand_dir="$staging_dir/expand"
# Removed first. pkgutil --expand refuses a directory that already exists, and
# with several components this block runs once per component into the same
# scratch path - so the second one failed outright until this line was here.
/bin/rm -rf "$expand_dir"
/usr/sbin/pkgutil --expand "$component_package" "$expand_dir" || fail "pkgutil --expand failed"
[ -f "$expand_dir/PackageInfo" ] || fail "The component package has no PackageInfo"
/usr/bin/sed -i '' "s/overwrite-permissions=\"[a-z]*\"/overwrite-permissions=\"$overwrite_permissions\"/" "$expand_dir/PackageInfo"
/usr/bin/grep -q "overwrite-permissions=\"$overwrite_permissions\"" "$expand_dir/PackageInfo" \
    || fail "Could not set overwrite-permissions to $overwrite_permissions"
/bin/rm -f "$component_package"
/usr/sbin/pkgutil --flatten "$expand_dir" "$component_package" || fail "pkgutil --flatten failed"
printf 'overwrite-permissions set to %s\n' "$overwrite_permissions"

announce "PRODUCTBUILD distribution package"
dist_xml="$staging_dir/Distribution.xml"
: > "$dist_xml" || fail "Could not write the Distribution XML"
printf '%s' '<?xml version="1.0" encoding="UTF-8"?>' >> "$dist_xml"
printf '%s' '<installer-gui-script minSpecVersion="2">' >> "$dist_xml"
printf '%s' '    <options hostArchitectures="arm64,x86_64" customize="never" require-scripts="false"/>' >> "$dist_xml"
printf '%s' '    <volume-check>' >> "$dist_xml"
printf '%s' '        <allowed-os-versions>' >> "$dist_xml"
printf '%s' '            <os-version min="12.0"/>' >> "$dist_xml"
printf '%s' '        </allowed-os-versions>' >> "$dist_xml"
printf '%s' '    </volume-check>' >> "$dist_xml"
printf '%s' '    <title>replay command line tools</title>' >> "$dist_xml"
printf '%s' '    <license file="license.txt"/>' >> "$dist_xml"
printf '%s' '    <welcome file="welcome.txt"/>' >> "$dist_xml"
printf '%s' '    <choices-outline>' >> "$dist_xml"
printf '%s' '        <line choice="com_abracode_pkg_replay_choice"/>' >> "$dist_xml"
printf '%s' '    </choices-outline>' >> "$dist_xml"
printf '%s' '    <choice id="com_abracode_pkg_replay_choice" title="replay command line tools" description="">' >> "$dist_xml"
printf '%s' '        <pkg-ref id="com.abracode.pkg.replay"/>' >> "$dist_xml"
printf '%s' '    </choice>' >> "$dist_xml"
printf '%s%s%s' '    <pkg-ref id="com.abracode.pkg.replay" version="' "$package_version" '" auth="Root">#replay.pkg</pkg-ref>' >> "$dist_xml"
printf '%s' '</installer-gui-script>' >> "$dist_xml"

resources_dir="$staging_dir/Resources"
/bin/mkdir -p "$resources_dir" || fail "Could not create the resources directory"
/usr/bin/ditto ''"$project_dir"'/resources/license.txt' "$resources_dir/"'license.txt' || fail "LICENSE resource is not there"
/usr/bin/ditto ''"$project_dir"'/resources/welcome.txt' "$resources_dir/"'welcome.txt' || fail "WELCOME resource is not there"

unsigned_package="$staging_dir/$project_name-unsigned.pkg"
/usr/bin/productbuild --distribution "$staging_dir/Distribution.xml" \
    --resources "$resources_dir" --package-path "$component_dir" "$unsigned_package" \
    || fail "productbuild failed"

package_name=''"$project_name"'_'"$package_version"'.pkg'
# A path separator here would put every write below outside --output-dir
# entirely: "../elsewhere.pkg" lands one directory above it and reports
# success. The app refuses the same value in its signing preconditions, and
# the exported script has to refuse it too, since --version reaches this name.
case "$package_name" in
    ''|*/*) fail "The package file name '$package_name' must not be empty or contain a path separator" ;;
esac
case "$package_name" in
    *.pkg|*.PKG|*.Pkg) unsigned_name="${package_name%.*}-unsigned.pkg" ;;
    *) unsigned_name="$package_name-unsigned.pkg"; package_name="$package_name.pkg" ;;
esac
/bin/mkdir -p "$output_dir" || fail "Could not create the output folder $output_dir"

if [ "$do_codesign" = "1" ]; then
    announce "PRODUCTSIGN installer package"
    # Signed in the staging directory and verified there, then landed through a
    # sibling temp file and a rename, so the output folder never holds an
    # unsigned or half-written package under a real name (the app's design 8.3).
    staged_signed="$staging_dir/signed.pkg"
    /usr/bin/productsign --sign "$installer_identity" "$unsigned_package" "$staged_signed" \
        || fail "productsign failed; the output folder was not touched"
    /usr/sbin/pkgutil --check-signature "$staged_signed" \
        || fail "The signed package did not verify; the output folder was not touched"
    landing="$output_dir/.$package_name.$$.makepkg"
    /bin/cp "$staged_signed" "$landing" || fail "Could not write into $output_dir"
    /bin/mv -f "$landing" "$output_dir/$package_name" \
        || { /bin/rm -f "$landing"; fail "Could not put the signed package in place"; }
    final_package="$output_dir/$package_name"
else
    announce "UNSIGNED build - skipping productsign"
    # Landed the same way the signed package is, for the same reason: a copy
    # written straight onto the final name leaves a truncated .pkg under that
    # name if it is interrupted, and a truncated package looks like a finished
    # one until something tries to expand it.
    landing="$output_dir/.$unsigned_name.$$.makepkg"
    /bin/cp "$unsigned_package" "$landing" || fail "Could not write into $output_dir"
    /bin/mv -f "$landing" "$output_dir/$unsigned_name" \
        || { /bin/rm -f "$landing"; fail "Could not put the package in place"; }
    final_package="$output_dir/$unsigned_name"
fi

announce "DONE"
printf 'Package:    %s\n' "$final_package"
printf 'Version:    %s\n' "$package_version"
printf 'Identifier: %s\n' 'com.abracode.pkg.replay'
printf '\n'
if [ "$do_codesign" = "1" ]; then
    printf 'This package is signed but NOT notarized. Notarize and staple it with:\n'
    printf '  xcrun notarytool submit "%s" --keychain-profile <profile> --wait\n' "$final_package"
    printf '  xcrun stapler staple "%s"\n' "$final_package"
    printf 'where <profile> was made once with: xcrun notarytool store-credentials\n'
    printf 'Or open it in Notarize.app, with "Sign before submitting" turned off.\n'
else
    printf 'NOT signed and NOT notarized. Do not distribute this package.\n'
fi
