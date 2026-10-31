#!/bin/zsh
# Builds a universal Tamebar.app and packages it as a DMG (the app plus an Applications shortcut).
# Local artifacts only, under dist/. Nothing is uploaded.
#
# Three outcomes, chosen by what is configured (see docs/RELEASING.md):
#   - no Developer ID identity: an ad-hoc signed preview, dist/Tamebar-<version>-unsigned.dmg.
#     Gatekeeper blocks it on other Macs; it embeds no update feed.
#   - Developer ID, no notary profile: dist/Tamebar-<version>-unnotarized.dmg, signed but not notarized.
#   - Developer ID and TAMEBAR_NOTARY_PROFILE (or TAMEBAR_ASC_PROFILE): dist/Tamebar-<version>.dmg,
#     notarized and stapled, plus dist/appcast.xml when the Sparkle key is present.
#
# Everything is built, signed, notarized, stapled and checked in a scratch folder. Only then is the
# DMG moved into dist/ under its release name, followed by its .sha256 and the appcast, so a failed
# run leaves nothing under a release name.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
DIST_DIR="$ROOT_DIR/dist"
IDENTITY="${TAMEBAR_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${TAMEBAR_NOTARY_PROFILE:-}"
ASC_PROFILE="${TAMEBAR_ASC_PROFILE:-}"
DEVELOPER_ID=0
[[ "$IDENTITY" == "Developer ID Application:"* ]] && DEVELOPER_ID=1
NOTARIZE=0
[[ -n "$NOTARY_PROFILE" || -n "$ASC_PROFILE" ]] && NOTARIZE=1
if (( NOTARIZE && ! DEVELOPER_ID )); then
    print -u2 "Notarization needs a Developer ID Application identity in TAMEBAR_SIGNING_IDENTITY (got: $IDENTITY)."
    exit 1
fi
# A release carries no Google client until Google has verified it (docs/RELEASING.md).
RELEASE_GOOGLE=0
[[ "${TAMEBAR_RELEASE_GOOGLE:-0}" == "1" ]] && RELEASE_GOOGLE=1
if (( ! RELEASE_GOOGLE )); then
    unset TAMEBAR_GOOGLE_CLIENT_ID TAMEBAR_GOOGLE_CLIENT_SECRET
fi
if (( NOTARIZE )); then
    # A feed left from an earlier run must never sit beside this run's DMG.
    rm -f "$DIST_DIR/appcast.xml"
fi
if (( ! DEVELOPER_ID )); then
    print -u2 "UNSIGNED PREVIEW: no Developer ID identity (TAMEBAR_SIGNING_IDENTITY=$IDENTITY)."
    print -u2 "The DMG is not notarized and Gatekeeper blocks it on other Macs. See docs/RELEASING.md."
elif (( ! NOTARIZE )); then
    print -u2 "NOT NOTARIZED: set TAMEBAR_NOTARY_PROFILE to a notarytool keychain profile to notarize."
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Only a Developer ID build carries the update feed; a preview never updates itself.
SPARKLE_ACCOUNT="${TAMEBAR_SPARKLE_ACCOUNT:-tamebar}"
SPARKLE_TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
SPARKLE_PUBLIC_KEY=""
if (( DEVELOPER_ID )) && [[ "${TAMEBAR_SKIP_UPDATES:-0}" != "1" ]]; then
    (cd "$ROOT_DIR" && swift package resolve >/dev/null)
    if ! SPARKLE_PUBLIC_KEY="$("$SPARKLE_TOOLS/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)"; then
        print -u2 "No Sparkle signing key in the login keychain. Run ./scripts/sparkle-key.sh once and back it up,"
        print -u2 "or set TAMEBAR_SKIP_UPDATES=1 to package a build that cannot update itself."
        exit 1
    fi
fi

BUILD_DIR="$SCRATCH/build"
OUT_DIR="$SCRATCH/out"
mkdir -p "$BUILD_DIR" "$OUT_DIR"
TAMEBAR_SIGNING_IDENTITY="$IDENTITY" TAMEBAR_SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
    TAMEBAR_BUILD_ARCHS="arm64 x86_64" TAMEBAR_APP_DIR="$BUILD_DIR" TAMEBAR_BUNDLE_ID="com.tamebar.Tamebar" \
    "$ROOT_DIR/scripts/build-app.sh"
APP_DIR="$BUILD_DIR/Tamebar.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCHS=" $(lipo -archs "$APP_DIR/Contents/MacOS/Tamebar") "
if [[ "$ARCHS" != *" arm64 "* || "$ARCHS" != *" x86_64 "* ]]; then
    print -u2 "The release must contain both arm64 and x86_64: $ARCHS"
    exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
if (( ! RELEASE_GOOGLE )) &&
    /usr/libexec/PlistBuddy -c 'Print :TamebarGoogleClientID' "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1; then
    print -u2 "The app carries a Google client id, but TAMEBAR_RELEASE_GOOGLE isn't 1."
    exit 1
fi

if (( NOTARIZE )); then
    DMG_NAME="Tamebar-$VERSION.dmg"
    VOLUME="Tamebar"
elif (( DEVELOPER_ID )); then
    DMG_NAME="Tamebar-$VERSION-unnotarized.dmg"
    VOLUME="Tamebar $VERSION (not notarized)"
else
    DMG_NAME="Tamebar-$VERSION-unsigned.dmg"
    VOLUME="Tamebar $VERSION (unsigned)"
fi
# Built and checked here; it reaches dist/ only once every step has passed.
DMG="$OUT_DIR/$DMG_NAME"
STAGE="$SCRATCH/stage"
mkdir -p "$STAGE"
ditto "$APP_DIR" "$STAGE/Tamebar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
if (( DEVELOPER_ID )); then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    codesign --verify --strict "$DMG"
fi

if (( NOTARIZE )); then
    RECEIPT="$DIST_DIR/notarization-$VERSION.json"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        STATUS_PATH="status"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RECEIPT"
    else
        STATUS_PATH="data.attributes.status"
        asc --profile "$ASC_PROFILE" notarization submit --file "$DMG" --wait --output json > "$RECEIPT"
    fi
    STATUS="$(plutil -extract "$STATUS_PATH" raw -o - "$RECEIPT")"
    if [[ "$STATUS" != "Accepted" ]]; then
        print -u2 "Notarization failed: $STATUS. See $RECEIPT (xcrun notarytool log <id> for details)."
        exit 1
    fi
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

# Sparkle installs updates from the DMG. The appcast is written only for a notarized build and never published.
APPCAST=""
if [[ -n "$SPARKLE_PUBLIC_KEY" && -n "${RECEIPT:-}" ]]; then
    APPCAST_DIR="$SCRATCH/appcast"
    mkdir -p "$APPCAST_DIR"
    cp "$DMG" "$APPCAST_DIR/"
    awk -v version="$VERSION" '
        $0 ~ "^## " version "( |$)" { found = 1; next }
        found && /^## / { exit }
        found { print }
    ' "$ROOT_DIR/CHANGELOG.md" > "$APPCAST_DIR/${DMG:t:r}.md"
    "$SPARKLE_TOOLS/generate_appcast" --account "$SPARKLE_ACCOUNT" \
        --download-url-prefix "${TAMEBAR_DOWNLOAD_URL_PREFIX:-https://tamebar.com/download/}" \
        --link "https://tamebar.com" \
        --embed-release-notes --maximum-versions 1 \
        -o "$OUT_DIR/appcast.xml" "$APPCAST_DIR" >/dev/null
    APPCAST="$OUT_DIR/appcast.xml"
elif [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    print -u2 "No appcast: only notarized builds are offered as updates."
fi

# Everything passed: the DMG under its release name, then its checksum, then the feed. Each is
# copied beside its final name in dist/ and renamed, so a name only ever holds a whole file.
mkdir -p "$DIST_DIR"
publish() {
    cp "$1" "$DIST_DIR/.$2.partial"
    mv -f "$DIST_DIR/.$2.partial" "$DIST_DIR/$2"
    print "$DIST_DIR/$2"
}
rm -f "$DIST_DIR/$DMG_NAME.sha256"
publish "$DMG" "$DMG_NAME"
publish "$DMG.sha256" "$DMG_NAME.sha256"
if [[ -n "$APPCAST" ]]; then
    publish "$APPCAST" appcast.xml
fi
