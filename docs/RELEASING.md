# Releasing Tamebar

Tamebar ships as a DMG only: the app plus an `Applications` shortcut, for the first download
and for Sparkle updates (decision P1). `./scripts/package-release.sh` builds a universal
(arm64 + x86_64) app and packages it. It writes local files under `dist/` and never uploads
anything. `./scripts/publish-tap.sh` does the upload (see [Publishing](#publishing)).

## Publishing

Releases live on [pFournet/tamebar](https://github.com/pFournet/tamebar/releases) (decision P2): each
holds `Tamebar-<version>.dmg` and `Tamebar-<version>.dmg.sha256`, which is what `install.sh` at the
repository's root downloads and checks. The Homebrew tap
[pFournet/homebrew-tamebar](https://github.com/pFournet/homebrew-tamebar) holds only the cask
(`Casks/tamebar.rb`, downloading from those releases), a copy of `install.sh` for the old URL, and a README.
Neither repository has GitHub Actions workflows.

```sh
curl -fsSL https://raw.githubusercontent.com/pFournet/tamebar/main/install.sh | sh
# or
brew install --cask pfournet/tamebar/tamebar
```

Both put `tamebar` on PATH and replace a running copy. Updates are `brew upgrade --cask tamebar` or running
the curl command again; the app doesn't update itself (see [Hosting and updates](#hosting-and-updates)).
[Installing](INSTALL.md) is the user-facing page.

### Release steps

The local clone of the tap is `~/Documents/Repo/homebrew-tamebar` (`TAMEBAR_TAP_DIR` changes it);
`TAMEBAR_RELEASE_REPO` changes the repository the release goes to.

1. **Bump the version** in `support/Info.plist` (`CFBundleShortVersionString`, and
   `CFBundleVersion` by one). A release tag can't be reused.
2. **Build**, signed with an Apple Development identity if you have one, so macOS permissions survive
   updates, and without `TAMEBAR_RELEASE_GOOGLE` (Google Calendar stays off):
   ```zsh
   TAMEBAR_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')" \
       ./scripts/package-release.sh
   ```
   This writes `dist/Tamebar-<version>-unsigned.dmg` and its `.sha256` ("unsigned" means "no
   Developer ID"; the app inside is signed). Without an identity the app is ad-hoc signed, and macOS asks
   for its permissions again after each update.
3. **Publish:** `./scripts/publish-tap.sh dist/Tamebar-<version>-unsigned.dmg`. It does the rest:
   - reads the version from the app inside the DMG, and stops if the app carries a Google client id;
   - checks that the cask downloads from `pFournet/tamebar`'s releases;
   - `gh release create v<version> Tamebar-<version>.dmg Tamebar-<version>.dmg.sha256 --repo
     pFournet/tamebar`, with short notes holding the install commands, the signer and the SHA-256. The
     asset is always named `Tamebar-<version>.dmg`, whatever the build was called, so the cask's url and
     the installer never change shape;
   - sets `version` and `sha256` in the tap's `Casks/tamebar.rb`, commits "Tamebar <version>" there;
   - pushes the tap's `main`.

   The release goes up before the cask that points at it. If the push fails, run the script again:
   it reuses a release whose DMG has the same checksum and refuses one that differs.
4. **Check** (on this Mac, without touching the installed app):
   ```zsh
   brew update && brew fetch --cask --force pfournet/tamebar/tamebar     # url and sha256 match
   brew style ~/Documents/Repo/homebrew-tamebar/Casks/tamebar.rb
   brew audit --cask --strict pfournet/tamebar/tamebar
   TAMEBAR_APP_DIR=$(mktemp -d) TAMEBAR_BIN_DIR=$(mktemp -d) TAMEBAR_NO_OPEN=1 TAMEBAR_HOOKS=no \
       sh ./install.sh                                                   # verifies the checksum
   ```
   `brew audit` sets up a build environment first and stops while the Command Line Tools are older
   than the macOS release. The same strict audit without that step:
   ```zsh
   brew ruby -e 'require "utils/gem_setup"; Utils::GemSetup.install_bundler_gems!(groups: ["audit", "ast"]); require "utils/ast"; require "cask/auditor"; e = Cask::Auditor.audit(Cask::CaskLoader.load(ARGV.first), audit_strict: true, any_named_args: true); puts(e.empty? ? "audit: no problems" : e.map { |x| x[:message] })' pfournet/tamebar/tamebar
   ```
   When `install.sh` changes, copy it into the tap too, so the old tap URL installs the same way.

### What a user sees

- Homebrew downloads the DMG with the quarantine flag, and macOS would refuse a quarantined app that
  isn't notarized ("Apple could not verify 'Tamebar' is free of malware"). The cask's
  `postflight_steps` removes the flag from the installed app only. The curl installer downloads with
  curl, which sets no flag, and clears it anyway. So the app opens without a Gatekeeper prompt.
  Someone who downloads the DMG from the release page by hand gets the prompt; [Installing](INSTALL.md)
  says how to clear it.
- On first launch, Tamebar asks for Accessibility (and Calendar, if they let it quiet agents before meetings).
  An Apple Development signature gives the app a stable designated requirement (bundle id + that
  certificate), so those grants survive updates. An ad-hoc build loses them at every update.
- The curl installer asks once, y/N, whether to run `tamebar hooks install` (decision P2); with no terminal
  the answer is No.
- Settings, Updates reads "This build has no update feed. Download releases from GitHub." and its button opens the releases page.
- The code signature names the certificate's owner; anyone can read it with `codesign -dvv`.
- Tamebar declines a plain Quit Apple event (it closes its window and keeps monitoring). The curl
  installer asks first and then sends SIGTERM to the copy it replaces, matched by path; the cask's
  `uninstall` adds `signal: TERM` after `quit:` for the same reason.

## What the script produces

What comes out depends on what is configured:

| Configured | DMG | Use |
|---|---|---|
| Nothing (today) | `dist/Tamebar-<version>-unsigned.dmg`, volume "Tamebar <version> (unsigned)" | Local testing only. Ad-hoc signed, not notarized; Gatekeeper blocks it on other Macs. No update feed is embedded. |
| `TAMEBAR_SIGNING_IDENTITY` = a Developer ID | `dist/Tamebar-<version>-unnotarized.dmg` | Checking the signed build before notarizing. Not for distribution. |
| Developer ID and `TAMEBAR_NOTARY_PROFILE` | `dist/Tamebar-<version>.dmg`, notarized and stapled, plus `dist/appcast.xml` | The release. |

Each DMG gets a `.sha256` file beside it. A notarized run also writes
`dist/notarization-<version>.json`.

The script builds the app, the DMG and the appcast in a temporary folder, and signs, notarizes,
staples and validates them there. Only once every step has passed does it move the DMG into
`dist/` under its release name, then write its `.sha256`, then `appcast.xml`. A run that fails
anywhere leaves nothing under a release name, so a file under the release name has always
passed every check (and been notarized, for `Tamebar-<version>.dmg`). A notarized run also
deletes any `dist/appcast.xml` from an earlier run before it starts. The packaged app is never
written to `dist/Tamebar.app`, which stays the development build `install.sh` uses.

## No Google client in a release

A release carries no Google OAuth client, so its Settings row reads "Google Calendar: Not
configured in this build", and it never talks to Google. The script unsets
`TAMEBAR_GOOGLE_CLIENT_ID` and `TAMEBAR_GOOGLE_CLIENT_SECRET` before building, and stops if the
built app still has a client id. This holds until Google has verified the client: a Testing-mode
client only lets its listed test users sign in, and its secret, if any, ships readable in every copy. Once the
client is verified, set `TAMEBAR_RELEASE_GOOGLE=1` to keep them.

The preview runs with no credentials:

```zsh
./scripts/package-release.sh
```

`TAMEBAR_SIGNING_IDENTITY` defaults to `-` (ad-hoc). Setting it to an Apple Development
identity also works and is still labelled unsigned; that is how the published builds are made. Setting a notary profile without a
Developer ID stops the script, because Apple only notarizes Developer ID signatures.

## Once the Apple Developer account exists

1. **Join the Apple Developer Program** ($99/yr). Note the Team ID (10 characters) from
   developer.apple.com, Membership.
2. **Create the Developer ID Application certificate.** In Xcode: Settings, Accounts, select
   the team, Manage Certificates, +, "Developer ID Application". It lands in the login
   keychain. Check that it's there:
   ```zsh
   security find-identity -v -p codesigning
   # "Developer ID Application: <Name> (<TEAMID>)"
   ```
   Export it with its private key to a `.p12` outside the repository and keep that safe.
3. **Store the notarization credentials** in the keychain once. Use an app-specific password
   from account.apple.com (Sign-In and Security, App-Specific Passwords):
   ```zsh
   xcrun notarytool store-credentials tamebar-notary \
       --apple-id <apple id email> --team-id <TEAMID> --password <app-specific password>
   ```
   An App Store Connect API key works too (`--key AuthKey_XXXX.p8 --key-id <id> --issuer <uuid>`).
4. **Create the Sparkle update key** once, and back it up:
   ```zsh
   ./scripts/sparkle-key.sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account tamebar -x <path outside the repository>
   ```
   Without this key, installed copies can never accept another update. To package a
   Developer ID build without updates, set `TAMEBAR_SKIP_UPDATES=1`.
5. **Package:**
   ```zsh
   TAMEBAR_SIGNING_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
   TAMEBAR_NOTARY_PROFILE=tamebar-notary \
   ./scripts/package-release.sh
   ```
   The script signs the app with the hardened runtime and a secure timestamp, builds the DMG,
   signs it, submits it to `notarytool` and waits, staples the ticket to the DMG, and runs
   `stapler validate` and `spctl --assess --type open`.
6. **Check it on another Mac or account:** open the DMG, drag Tamebar to Applications, and
   launch it. There should be no Gatekeeper warning beyond the "downloaded from the internet"
   prompt.

## Hosting and updates

For now `pFournet/tamebar`'s releases host the downloads.

The published builds carry no `SUFeedURL` and no `SUPublicEDKey`: `build-app.sh` writes them only when
`package-release.sh` passes a Sparkle key, which it does for a Developer ID build only.
`AppUpdateController` then creates no Sparkle updater at all (`FeedConfiguration.isValid` needs an
https feed and a key), so the app never checks anywhere for updates; Settings shows "This build has no
update feed". Updates come from `brew upgrade --cask tamebar` or the curl command.

**Next step, not built yet:** self-updates from the releases. Create the Sparkle EdDSA key
(`./scripts/sparkle-key.sh`, step 4 above), build with `TAMEBAR_SPARKLE_FEED_URL` pointing at an
`appcast.xml` in the repository (for example
`https://raw.githubusercontent.com/pFournet/tamebar/main/appcast.xml`) and
`TAMEBAR_DOWNLOAD_URL_PREFIX` at the release downloads, sign each DMG into that appcast with
`generate_appcast`, and have `publish-tap.sh` commit it with the cask. Today `package-release.sh`
embeds the feed and writes the appcast only for a notarized Developer ID build, so this needs either
that account or a change to allow the feed on Apple Development builds. Once the app updates itself,
the cask should declare `auto_updates true`.

- The app reads its update feed from `https://tamebar.com/appcast.xml`
  (`TAMEBAR_SPARKLE_FEED_URL` in `scripts/build-app.sh` changes it).
- `generate_appcast` signs the DMG with the Sparkle EdDSA key and points the enclosure at
  `https://tamebar.com/download/<dmg name>`. `TAMEBAR_DOWNLOAD_URL_PREFIX` changes the prefix.
- The appcast is written only for a notarized build. Release notes come from the matching
  `## <version>` section of `CHANGELOG.md`.
- Publishing is manual: upload the DMG and `appcast.xml` to the host. Upload the DMG first,
  then the appcast, so no feed points at a missing file. Each update downloads the whole DMG,
  a trade-off accepted in P1.

Before the first release, bump `CFBundleShortVersionString` and `CFBundleVersion` in
`support/Info.plist`. Sparkle compares `CFBundleVersion`, so it must increase with every release.

## The command line

`./scripts/install.sh` links `~/.local/bin/tamebar` to the installed app's executable
([CLI](CLI.md)). The two installers do the same: the cask's `binary` stanza and the curl
script's link. Only someone who drags the app out of the DMG by hand has no `tamebar` on PATH. They
will need an "Install command-line tool" option (Settings or the app menu) that makes the same link,
replacing only a link that already points into a `Tamebar.app`. Out of scope for now.

## Development builds

Build and install locally with `./scripts/install.sh` (see [CONTRIBUTING.md](../CONTRIBUTING.md)).
Development builds never embed the update feed, so they never update themselves.
