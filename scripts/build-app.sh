#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
# TAMEBAR_APP_DIR and TAMEBAR_BUNDLE_ID let end-to-end runs build a copy beside the installed app.
APP_DIR="${TAMEBAR_APP_DIR:-$ROOT_DIR/dist}/Tamebar.app"
BUNDLE_ID="${TAMEBAR_BUNDLE_ID:-com.tamebar.Tamebar}"
CONTENTS_DIR="$APP_DIR/Contents"
# Signing: TAMEBAR_SIGNING_IDENTITY when set ("-" is ad-hoc), else an Apple Development identity
# from the keychain, else ad-hoc. No Apple developer account is needed to build (decisions P2).
LOCAL_SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:/ { print $2; exit }' || true)"
SIGNING_IDENTITY="${TAMEBAR_SIGNING_IDENTITY:-$LOCAL_SIGNING_IDENTITY}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "No Apple Development identity: signing ad-hoc. macOS asks for Accessibility again after each rebuild." >&2
fi
cd "$ROOT_DIR"
ARCH_FLAGS=()
BUILD_ARCHS="${TAMEBAR_BUILD_ARCHS:-}"
for ARCH in ${=BUILD_ARCHS}; do
    case "$ARCH" in
        arm64|x86_64) ARCH_FLAGS+=(--arch "$ARCH") ;;
        *) print -u2 "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
done
swift build -c release -j "${TAMEBAR_BUILD_JOBS:-2}" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
"$ROOT_DIR/scripts/build-icon.sh"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$CONTENTS_DIR/Frameworks"
cp "$BIN_DIR/Tamebar" "$CONTENTS_DIR/MacOS/Tamebar"
ditto "$BIN_DIR/Sparkle.framework" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
cp "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$CONTENTS_DIR/Resources/Sparkle-LICENSE.txt"
cp "$ROOT_DIR/licenses/OrphanBar-LICENSE.txt" "$CONTENTS_DIR/Resources/OrphanBar-LICENSE.txt"
cp "$ROOT_DIR/LICENSE" "$CONTENTS_DIR/Resources/LICENSE.txt"
if ! otool -l "$CONTENTS_DIR/MacOS/Tamebar" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS_DIR/MacOS/Tamebar"
fi
cp "$ROOT_DIR/support/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
# The short commit, for the usage trend's version marker (decisions Q16).
if COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null)"; then
    plutil -replace TamebarCommit -string "$COMMIT" "$CONTENTS_DIR/Info.plist"
fi
# Google Calendar (M1): the OAuth client stays out of the repo. Without an id the Settings row
# reads "Not configured in this build" and nothing talks to Google. Google gives Desktop clients a
# secret that isn't one; pass it only if the token exchange asks for it.
if [[ -n "${TAMEBAR_GOOGLE_CLIENT_ID:-}" ]]; then
    plutil -replace TamebarGoogleClientID -string "$TAMEBAR_GOOGLE_CLIENT_ID" "$CONTENTS_DIR/Info.plist"
    if [[ -n "${TAMEBAR_GOOGLE_CLIENT_SECRET:-}" ]]; then
        plutil -replace TamebarGoogleClientSecret -string "$TAMEBAR_GOOGLE_CLIENT_SECRET" "$CONTENTS_DIR/Info.plist"
    fi
fi
RESCUE_APP="$CONTENTS_DIR/Helpers/Tamebar Emergency.app"
mkdir -p "$RESCUE_APP/Contents/MacOS"
cp "$CONTENTS_DIR/MacOS/Tamebar" "$RESCUE_APP/Contents/MacOS/TamebarRescue"
install_name_tool -add_rpath "@executable_path/../../../../Frameworks" "$RESCUE_APP/Contents/MacOS/TamebarRescue"
cp "$ROOT_DIR/support/Emergency-Info.plist" "$RESCUE_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID.Emergency" "$RESCUE_APP/Contents/Info.plist"
# Only release packaging passes the key; development builds never update themselves.
if [[ -n "${TAMEBAR_SPARKLE_PUBLIC_KEY:-}" ]]; then
    PLIST="$CONTENTS_DIR/Info.plist"
    plutil -replace SUFeedURL -string "${TAMEBAR_SPARKLE_FEED_URL:-https://tamebar.com/appcast.xml}" "$PLIST"
    plutil -replace SUPublicEDKey -string "$TAMEBAR_SPARKLE_PUBLIC_KEY" "$PLIST"
    plutil -replace SUEnableAutomaticChecks -bool YES "$PLIST"
    plutil -replace SUAutomaticallyUpdate -bool YES "$PLIST"
    plutil -replace SUScheduledCheckInterval -integer 86400 "$PLIST"
    plutil -replace SUVerifyUpdateBeforeExtraction -bool YES "$PLIST"
fi
cp "$ROOT_DIR/.build/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$ROOT_DIR/assets/brand/Tamebar.icon/Assets/Mark.svg" "$CONTENTS_DIR/Resources/Mark.svg"
find "$APP_DIR" -name '._*' -delete
SIGNING_FLAGS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_FLAGS=(--options runtime)
    if [[ "$SIGNING_IDENTITY" == *"Developer ID Application"* ]]; then
        SIGNING_FLAGS+=(--timestamp)
    fi
fi
SPARKLE="$CONTENTS_DIR/Frameworks/Sparkle.framework/Versions/B"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force "${SIGNING_FLAGS[@]}" --preserve-metadata=entitlements --sign "$SIGNING_IDENTITY" "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$SPARKLE/Autoupdate"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$SPARKLE/Updater.app"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
codesign --force "${SIGNING_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$RESCUE_APP"
codesign --force "${SIGNING_FLAGS[@]}" --entitlements "$ROOT_DIR/support/Tamebar.entitlements" --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
