# Installing Tamebar

Tamebar needs macOS 14 (Sonoma) or later, on Apple silicon or Intel.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/pFournet/tamebar/main/install.sh | sh
```

The script downloads the latest release's `Tamebar-<version>.dmg` from
[Releases](https://github.com/pFournet/tamebar/releases), checks it against the published `.sha256` and stops
on a mismatch, copies `Tamebar.app` into `~/Applications` (no admin password), links `~/.local/bin/tamebar`
(and says so when that folder isn't on your PATH), replaces a running copy, and opens the app. Then it asks
once, y/N, whether to add the start hook (below). Run it again to update. `TAMEBAR_VERSION`, `TAMEBAR_APP_DIR`,
`TAMEBAR_BIN_DIR`, `TAMEBAR_NO_OPEN=1`, `TAMEBAR_FORCE=1` and `TAMEBAR_HOOKS=yes|no` are described at the top
of [install.sh](../install.sh).

With Homebrew:

```sh
brew install --cask pfournet/tamebar/tamebar
```

The cask links `tamebar` into Homebrew's `bin`. Update with `brew upgrade --cask tamebar`.

To build it yourself, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## The start hook

`tamebar hooks install` adds `tamebar wait` as a `SessionStart` hook to Claude Code
(`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`), with a backup of each file. A new session then
waits while the Mac is struggling, and starts by itself once it eases (or with Start now in Tamebar's card,
or `tamebar start <project>`). It never holds a running session. `tamebar hooks status` shows where it is,
`tamebar hooks remove` takes it out. See [Command line](CLI.md#hooks).

## "Apple could not verify Tamebar"

Releases aren't notarized by Apple yet, so macOS can refuse to open a copy that carries the download flag.
Both installers clear that flag, so you shouldn't see it. If you do (for example after opening the DMG from
the Releases page yourself): open System Settings, Privacy & Security, and click Open Anyway next to the
message about Tamebar, or run `xattr -dr com.apple.quarantine ~/Applications/Tamebar.app`.

Tamebar then asks for Accessibility, and for Calendar if you let it quiet agents before meetings.

## What it does on its own

On a new install Tamebar watches, slows busy background work under CPU pressure, heat or a call, pauses idle
AI sessions during a call, holds new sessions at start while the Mac struggles (with the hook), shows brief
notes, and lists everything it stopped in the Stopped list with the command to bring it back. It ends or edits
nothing until you switch it on in Settings, Automatic actions:

- **Unused AI sessions: End after N days** ends sessions idle that long while you're away.
- **End long-idle sessions on their own** ends a session idle 12 h while memory stays tight, or idle 24 h
  with a dev server nobody opened (the server first). **Never end servers on ports** lists ports it never
  touches; servers run through portless are always left alone.
- **Turn off unused Codex plugins** sets `enabled = false` in `~/.codex/config.toml`, after a backup, for an
  MCP server no Codex session called in 30 days. **Never turn off** lists servers it never touches (one that
  receives messages, for example).
- **Quit under pressure**, per app, quits it under sustained memory pressure and reopens it after.

Every switch and list is also a setting in the `com.tamebar.Tamebar` domain; see
[Command line](CLI.md#settings).

## Where the data lives

- Files: `~/Library/Application Support/Tamebar` (charts, the usage record, the removal log, backups), each
  store with a size limit.
- Settings: the `com.tamebar.Tamebar` preference domain.
- [Privacy and permissions](PRIVACY.md) lists exactly what is read and stored. There is no telemetry; the
  only network request is a release build's update check.

## Uninstall

```sh
brew uninstall --cask tamebar          # add --zap to also remove settings and data
```

Without Homebrew: choose Quit Tamebar in Settings, then

```sh
tamebar hooks remove                   # if you added the start hook
rm -rf ~/Applications/Tamebar.app ~/.local/bin/tamebar
rm -rf ~/Library/Application\ Support/Tamebar ~/Library/Preferences/com.tamebar.Tamebar.plist  # data, optional
```
