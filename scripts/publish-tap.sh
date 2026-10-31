#!/bin/zsh
# Publishes a DMG built by package-release.sh (docs/RELEASING.md): a GitHub release v<version> of
# pFournet/tamebar holding Tamebar-<version>.dmg and its .sha256 (what install.sh downloads), then
# the Homebrew tap pFournet/homebrew-tamebar's Casks/tamebar.rb bumped to that version and
# checksum, then the tap pushed.
#
#   ./scripts/publish-tap.sh dist/Tamebar-0.1.0-unsigned.dmg
#
# Re-running after a failed push reuses a release whose DMG has the same checksum, and refuses one
# that differs.
set -euo pipefail
DMG="${1:?usage: publish-tap.sh <DMG from package-release.sh>}"
RELEASE_REPO="${TAMEBAR_RELEASE_REPO:-pFournet/tamebar}"
TAP_DIR="${TAMEBAR_TAP_DIR:-$HOME/Documents/Repo/homebrew-tamebar}"
CASK="$TAP_DIR/Casks/tamebar.rb"
die() { print -u2 "publish-tap: $*"; exit 1 }

[[ -f "$DMG" ]] || die "no DMG at $DMG."
[[ -f "$CASK" ]] || die "no cask at $CASK (TAMEBAR_TAP_DIR is the tap's local clone)."
grep -q "^  url \"https://github.com/$RELEASE_REPO/releases/download/" "$CASK" ||
    die "$CASK doesn't download from $RELEASE_REPO's releases."
gh auth status >/dev/null 2>&1 || die "gh isn't logged in."

# The tap must be on main, level with origin, and clean apart from the cask.
git -C "$TAP_DIR" fetch -q origin
[[ "$(git -C "$TAP_DIR" branch --show-current)" == main ]] || die "$TAP_DIR isn't on main."
git -C "$TAP_DIR" merge -q --ff-only origin/main || die "$TAP_DIR has diverged from origin/main."
[[ -z "$(git -C "$TAP_DIR" status --porcelain -- . ':!Casks/tamebar.rb')" ]] ||
    die "$TAP_DIR has uncommitted changes besides the cask."

SCRATCH="$(mktemp -d)"
MOUNT="$SCRATCH/mount"
cleanup() {
    hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Read the version and signature from the app inside the DMG, not from its file name.
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
APP="$MOUNT/Tamebar.app"
[[ -d "$APP" ]] || die "$DMG has no Tamebar.app."
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null }
VERSION="$(plist CFBundleShortVersionString)"
[[ "$(plist CFBundleIdentifier)" == com.tamebar.Tamebar ]] || die "the app isn't com.tamebar.Tamebar."
if [[ "${TAMEBAR_RELEASE_GOOGLE:-0}" != 1 ]] && plist TamebarGoogleClientID >/dev/null; then
    die "the app carries a Google client id (docs/RELEASING.md, No Google client in a release)."
fi
codesign --verify --deep --strict "$APP" || die "the app's signature doesn't verify."
SIGNER="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !seen++ { print $2 }')"
FEED="$(plist SUFeedURL || true)"
hdiutil detach -quiet "$MOUNT"

ASSET="Tamebar-$VERSION.dmg"
TAG="v$VERSION"
cp "$DMG" "$SCRATCH/$ASSET"
(cd "$SCRATCH" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
SHA="$(awk '{ print $1 }' "$SCRATCH/$ASSET.sha256")"
if [[ -f "$DMG.sha256" && "$(awk '{ print $1 }' "$DMG.sha256")" != "$SHA" ]]; then
    die "$DMG doesn't match $DMG.sha256."
fi

if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    gh release download "$TAG" --repo "$RELEASE_REPO" --pattern "$ASSET.sha256" --dir "$SCRATCH/published"
    [[ "$(awk '{ print $1 }' "$SCRATCH/published/$ASSET.sha256")" == "$SHA" ]] ||
        die "release $TAG already exists with a different DMG. Bump the version in support/Info.plist."
    print "Release $TAG already holds this DMG; updating the cask only."
else
    if [[ -z "$SIGNER" ]]; then
        SIGNING="Ad-hoc signed (macOS permissions are asked again after each update)"
    elif [[ "$SIGNER" == "Developer ID Application:"* ]]; then
        SIGNING="Signed with a Developer ID"
    else
        SIGNING="Signed with an Apple Development certificate"
    fi
    if [[ "$SIGNER" == "Developer ID Application:"* ]] && xcrun stapler validate -q "$DMG" 2>/dev/null; then
        NOTARY="Notarized by Apple."
    else
        NOTARY="Not notarized yet: both installers clear the quarantine flag; see docs/INSTALL.md if macOS still says it can't verify Tamebar."
    fi
    if [[ -n "$FEED" ]]; then UPDATES="It updates itself from $FEED."; else UPDATES="Update with \`brew upgrade --cask tamebar\` or by running the install command again."; fi
    NOTES="Tamebar $VERSION for macOS 14 or later, Apple silicon and Intel.

\`\`\`sh
brew install --cask pfournet/tamebar/tamebar
# or, without Homebrew:
curl -fsSL https://raw.githubusercontent.com/$RELEASE_REPO/main/install.sh | sh
\`\`\`

$SIGNING. $NOTARY $UPDATES

SHA-256 of \`$ASSET\`: \`$SHA\`"
    gh release create "$TAG" "$SCRATCH/$ASSET" "$SCRATCH/$ASSET.sha256" --repo "$RELEASE_REPO" \
        --target main --title "Tamebar $VERSION" --notes "$NOTES"
fi

# The release exists before the cask points at it, so `brew install` never meets a missing file.
sed -i '' -E \
    -e "s/^  version \"[^\"]*\"$/  version \"$VERSION\"/" \
    -e "s/^  sha256 \"[0-9a-f]{64}\"$/  sha256 \"$SHA\"/" \
    "$CASK"
grep -q "^  version \"$VERSION\"$" "$CASK" && grep -q "^  sha256 \"$SHA\"$" "$CASK" ||
    die "couldn't set version and sha256 in $CASK."
git -C "$TAP_DIR" add Casks/tamebar.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
    print "The cask already points at $ASSET."
else
    MESSAGE="Tamebar $VERSION"
    [[ -n "${TAMEBAR_COMMIT_TRAILER:-}" ]] && MESSAGE+=$'\n\n'"$TAMEBAR_COMMIT_TRAILER"
    git -C "$TAP_DIR" commit -q -m "$MESSAGE"
fi
git -C "$TAP_DIR" push -q origin main
print "https://github.com/$RELEASE_REPO/releases/tag/$TAG"
print "sha256 $SHA"
