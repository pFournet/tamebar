#!/bin/sh
# Installs or updates Tamebar from the latest release of github.com/pFournet/tamebar.
#
#   curl -fsSL https://raw.githubusercontent.com/pFournet/tamebar/main/install.sh | sh
#
# It downloads the release's Tamebar-<version>.dmg, checks it against its published .sha256, copies
# Tamebar.app into ~/Applications, links ~/.local/bin/tamebar to the app's command line, and opens the
# app. Then it asks once, y/N, whether to add the start hook (tamebar hooks install) to Claude Code and
# Codex; without a terminal to ask in, the answer is No. It never uses sudo and never touches
# /Applications. Run it again to update.
#
# Settings, all optional:
#   TAMEBAR_VERSION=0.1.0   install that release instead of the latest
#   TAMEBAR_APP_DIR=<dir>   install the app there instead of ~/Applications
#   TAMEBAR_BIN_DIR=<dir>   put the tamebar link there instead of ~/.local/bin
#   TAMEBAR_NO_OPEN=1       don't open the app at the end
#   TAMEBAR_FORCE=1         reinstall even when that version is already installed
#   TAMEBAR_HOOKS=yes|no    answer the start hook question without asking
set -eu

REPO="${TAMEBAR_REPO:-pFournet/tamebar}"
APP_DIR="${TAMEBAR_APP_DIR:-$HOME/Applications}"
BIN_DIR="${TAMEBAR_BIN_DIR:-$HOME/.local/bin}"
WANTED="${TAMEBAR_VERSION:-}"
BUNDLE_ID="com.tamebar.Tamebar"
TARGET="$APP_DIR/Tamebar.app"
EXE="$TARGET/Contents/MacOS/Tamebar"
HELPER_EXE="$TARGET/Contents/Helpers/Tamebar Emergency.app/Contents/MacOS/TamebarRescue"

say() { printf '%s\n' "$*"; }
die() {
    printf 'Tamebar install failed: %s\n' "$*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "Tamebar runs on macOS only."
[ "$(id -u)" -ne 0 ] || die "run it as yourself, without sudo. It installs into your home folder."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] || die "Tamebar needs macOS 14 (Sonoma) or later."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tamebar-install.XXXXXX")"
MOUNT="$WORK/mount"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Reads one value from a JSON or plist file.
json_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# 1. Find the release through the public GitHub API (no token needed).
if [ -n "$WANTED" ]; then
    API="https://api.github.com/repos/$REPO/releases/tags/v${WANTED#v}"
else
    API="https://api.github.com/repos/$REPO/releases/latest"
fi
curl -fsSL -H "Accept: application/vnd.github+json" -o "$WORK/release.json" "$API" ||
    die "couldn't read $API (no such release, no network, or GitHub's hourly limit for anonymous requests)."
TAG="$(json_value "$WORK/release.json" tag_name)" || die "the release has no tag."
VERSION="${TAG#v}"
ASSET_COUNT="$(json_value "$WORK/release.json" assets)" || die "the release lists no files."
DMG_NAME="Tamebar-$VERSION.dmg"
DMG_URL=""
SUM_URL=""
i=0
while [ "$i" -lt "$ASSET_COUNT" ]; do
    NAME="$(json_value "$WORK/release.json" "assets.$i.name")"
    URL="$(json_value "$WORK/release.json" "assets.$i.browser_download_url")"
    case "$NAME" in
        "$DMG_NAME") DMG_URL="$URL" ;;
        "$DMG_NAME.sha256") SUM_URL="$URL" ;;
    esac
    i=$((i + 1))
done
[ -n "$DMG_URL" ] || die "release $TAG has no $DMG_NAME."
[ -n "$SUM_URL" ] || die "release $TAG has no $DMG_NAME.sha256, so the download can't be checked."

installed_version() {
    plutil -extract CFBundleShortVersionString raw -o - "$TARGET/Contents/Info.plist" 2>/dev/null || true
}

# Links $BIN_DIR/tamebar to the app's executable. Only a link into a Tamebar.app is replaced.
link_cli() {
    LINK="$BIN_DIR/tamebar"
    mkdir -p "$BIN_DIR"
    if [ -L "$LINK" ]; then
        CURRENT="$(readlink "$LINK")"
        case "$CURRENT" in
            "$EXE") ;;
            *Tamebar.app/*) ln -sfn "$EXE" "$LINK" ;;
            *) say "Note: $LINK points to $CURRENT; left as it is." ;;
        esac
    elif [ -e "$LINK" ]; then
        say "Note: $LINK exists and isn't a link; left as it is."
    else
        ln -s "$EXE" "$LINK"
    fi
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            case "${SHELL:-}" in
                */bash) PROFILE=".bash_profile" ;;
                *) PROFILE=".zprofile" ;;
            esac
            say ""
            say "$BIN_DIR isn't on your PATH yet. To run tamebar from a terminal, add it and open a new window:"
            say "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/$PROFILE"
            ;;
    esac
}

# Prints the process ids running this install's copy of the app (never another copy).
running_pids() {
    ps -axo pid=,comm= | awk -v exe="$EXE" -v helper="$HELPER_EXE" '{
        pid = $1
        sub(/^[ ]*[0-9]+[ ]+/, "")
        if ($0 == exe || $0 == helper) print pid
    }'
}

wait_for_exit() {
    n=0
    while [ -n "$(running_pids)" ] && [ "$n" -lt 20 ]; do
        sleep 0.25
        n=$((n + 1))
    done
    [ -z "$(running_pids)" ]
}

# Asks once whether to add the start hook (a new Claude Code or Codex session waits while the Mac
# is struggling). The question is read from the terminal, since stdin is the script itself under
# curl | sh; with no terminal, the answer is No. TAMEBAR_HOOKS=yes or no answers it beforehand.
offer_hooks() {
    ANSWER="${TAMEBAR_HOOKS:-}"
    if [ -z "$ANSWER" ]; then
        # In a subshell: a failed redirection on `:` would end the script itself.
        if ! (: </dev/tty) 2>/dev/null; then
            say "No terminal to ask in: the start hook wasn't added. Add it any time with: tamebar hooks install"
            return 0
        fi
        printf '\nAdd the start hook to Claude Code and Codex, so a new session waits while the Mac is\nstruggling? It edits ~/.claude/settings.json and ~/.codex/hooks.json, with a backup. [y/N] ' >/dev/tty
        read -r ANSWER </dev/tty || ANSWER=""
    fi
    case "$ANSWER" in
        [yY] | [yY][eE][sS])
            "$EXE" hooks install || say "Note: the start hook couldn't be added everywhere; see above."
            ;;
        *) say "Start hook not added. Add it any time with: tamebar hooks install" ;;
    esac
}

finish() {
    link_cli
    if [ "${TAMEBAR_NO_OPEN:-0}" != "1" ]; then
        open "$TARGET"
    fi
    if [ -d /Applications/Tamebar.app ] && [ "$APP_DIR" != "/Applications" ]; then
        say "Note: another copy is in /Applications (Homebrew?). Keep one: brew uninstall --cask tamebar, or delete it."
    fi
    offer_hooks
}

if [ "$(installed_version)" = "$VERSION" ] && [ "${TAMEBAR_FORCE:-0}" != "1" ]; then
    say "Tamebar $VERSION is already installed in $APP_DIR."
    finish
    exit 0
fi

# 2. Download the DMG and its published checksum.
say "Downloading Tamebar $VERSION..."
curl -fL --progress-bar -o "$WORK/$DMG_NAME" "$DMG_URL" || die "couldn't download $DMG_URL."
curl -fsSL -o "$WORK/$DMG_NAME.sha256" "$SUM_URL" || die "couldn't download $SUM_URL."

# 3. Check it: a mismatch stops everything before anything is installed.
EXPECTED="$(awk 'NR == 1 { print tolower($1) }' "$WORK/$DMG_NAME.sha256")"
ACTUAL="$(shasum -a 256 "$WORK/$DMG_NAME" | awk '{ print tolower($1) }')"
case "$EXPECTED" in
    [0-9a-f]*) [ "${#EXPECTED}" -eq 64 ] || die "$DMG_NAME.sha256 doesn't hold a SHA-256 checksum." ;;
    *) die "$DMG_NAME.sha256 doesn't hold a SHA-256 checksum." ;;
esac
if [ "$ACTUAL" != "$EXPECTED" ]; then
    printf '\nCHECKSUM MISMATCH for %s\n  expected %s\n  got      %s\n' "$DMG_NAME" "$EXPECTED" "$ACTUAL" >&2
    die "the download doesn't match the published checksum. Nothing was installed."
fi
say "Checksum verified: $ACTUAL"

# 4. Mount it and copy the app into place.
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$WORK/$DMG_NAME" ||
    die "couldn't open $DMG_NAME."
MOUNTED=1
SOURCE="$MOUNT/Tamebar.app"
[ -d "$SOURCE" ] || die "$DMG_NAME has no Tamebar.app."
[ "$(json_value "$SOURCE/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] ||
    die "the app in $DMG_NAME isn't $BUNDLE_ID."
codesign --verify --deep --strict "$SOURCE" 2>/dev/null || die "the app's code signature doesn't verify."

if [ -e "$TARGET" ]; then
    [ "$(json_value "$TARGET/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] ||
        die "$TARGET isn't Tamebar; move it away first."
fi

# Tamebar keeps running when asked to quit by a plain Quit event (it closes its window and keeps
# monitoring), so ask politely first, then end this copy's processes.
if [ -n "$(running_pids)" ]; then
    say "Quitting the running Tamebar..."
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    if ! wait_for_exit; then
        # shellcheck disable=SC2046
        kill -TERM $(running_pids) 2>/dev/null || true
        wait_for_exit || die "Tamebar is still running. Choose \"Stop monitoring and quit\" in its menu, then run this again."
    fi
fi

mkdir -p "$APP_DIR"
STAGED="$APP_DIR/.Tamebar.app.installing"
rm -rf "$STAGED"
ditto "$SOURCE" "$STAGED"
hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
MOUNTED=0
rm -rf "$TARGET"
mv "$STAGED" "$TARGET"
# curl doesn't quarantine downloads, so macOS doesn't stop this copy at first launch. Clearing the flag
# anyway covers a DMG that arrived some other way. Notarized releases will make this unnecessary.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
say "Installed Tamebar $VERSION in $TARGET"

# 5 and 6. Link the command line and open the app.
finish
say "Done. Run this command again any time to update."
