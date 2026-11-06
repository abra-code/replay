#!/bin/bash
# Fetches the license of ICU (International Components for Unicode) into
# linux/licenses/ICU-LICENSE.txt, which is committed. linux/package.sh puts it into the
# Swift runtime tarball beside lib_FoundationICU.so.
#
# Swift's runtime bundles ICU as swift-foundation-icu, which carries Swift's own Apache
# license only. Its README names ICU 74 for FoundationICU 0.0.10 and later, which includes
# Swift 6.2.4. The text below is upstream ICU's LICENSE at release-74-2 (release-74-1 is
# identical), checked against the SHA-256 recorded on 2026-11-06.
#
# Usage: linux/licenses/fetch-icu-license.sh
#   Rerun only when a Swift update changes the bundled ICU version: update ICU_TAG and
#   ICU_SHA256 together, after reading the new text.

ICU_TAG="release-74-2"
ICU_SHA256="17510cf7a58b4879b887ec05a45d72cf1b73544dd9ec7e72f20110ed104229ee"
ICU_URL="https://raw.githubusercontent.com/unicode-org/icu/$ICU_TAG/LICENSE"

LICENSES_DIR="$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
if [ -z "$LICENSES_DIR" ]; then
    echo "Error: cannot find the folder of this script" >&2
    exit 1
fi
OUT="$LICENSES_DIR/ICU-LICENSE.txt"

TMP_FILE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/icu-license.XXXXXX")"
status=$?
if [ "$status" -ne 0 ] || [ -z "$TMP_FILE" ]; then
    echo "Error: cannot create a temporary file" >&2
    exit 1
fi

/usr/bin/curl -fsSL --retry 3 -o "$TMP_FILE" "$ICU_URL"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: downloading $ICU_URL failed with status $status" >&2
    /bin/rm -f "$TMP_FILE"
    exit 1
fi

if [ -x /usr/bin/sha256sum ]; then
    SUM_LINE="$(/usr/bin/sha256sum "$TMP_FILE")"
else
    SUM_LINE="$(/usr/bin/shasum -a 256 "$TMP_FILE")"
fi
SUM="${SUM_LINE%% *}"
if [ "$SUM" != "$ICU_SHA256" ]; then
    echo "Error: $ICU_URL has SHA-256 $SUM, expected $ICU_SHA256; not writing $OUT" >&2
    /bin/rm -f "$TMP_FILE"
    exit 1
fi

/bin/mv -f "$TMP_FILE" "$OUT"
status=$?
if [ "$status" -ne 0 ]; then
    echo "Error: cannot write $OUT" >&2
    /bin/rm -f "$TMP_FILE"
    exit 1
fi
/bin/chmod 644 "$OUT"
echo "Wrote $OUT (ICU $ICU_TAG)"
