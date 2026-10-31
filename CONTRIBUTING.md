# Contributing to Tamebar

Tamebar is a focused tool with strict safety rules, so opening a PR does not guarantee it will be merged.
For anything larger than a fix, such as a new automatic action or a change to process control, open an issue
first so we can agree on the approach.

## Building from source

You need no Apple developer account.

- macOS 14 or later.
- A Swift 6 toolchain: Xcode 16 or later, or the Command Line Tools (`xcode-select --install`) with Swift 6.
- Optional: FFmpeg (`brew install ffmpeg`) for the media integration tests.

```sh
swift build                 # the debug build
./scripts/build-app.sh      # dist/Tamebar.app
./scripts/install.sh        # builds, installs ~/Applications/Tamebar.app, links ~/.local/bin/tamebar, opens it
./scripts/check.sh          # build, every test, swift-format lint, plist and shell checks
./scripts/e2e.sh            # the end-to-end suite against an isolated e2e build
```

`build-app.sh` signs with `TAMEBAR_SIGNING_IDENTITY` when it is set (`-` is ad-hoc), else with an Apple
Development identity from your keychain if you have one, else ad-hoc. An ad-hoc build works, but macOS ties
the Accessibility grant to the exact build, so it asks for Accessibility again after each rebuild: remove the
old Tamebar entry in System Settings, Privacy & Security, Accessibility, and allow the new one.
`./script/build_and_run.sh` wraps the install with `--debug`, `--logs` and `--verify`.

`scripts/e2e.sh` builds a second copy with its own bundle id (`com.tamebar.Tamebar.e2e`), defaults and data
folder, and drives it with fake agents in a temporary folder. It never touches an installed Tamebar. Run one
build or test run at a time: the e2e suite measures timing.

The installed app keeps its data in `~/Library/Application Support/Tamebar` and its settings in the
`com.tamebar.Tamebar` domain ([Installing](docs/INSTALL.md#where-the-data-lives)).
[Releasing](docs/RELEASING.md) covers signed releases.

## What to contribute

Good first contributions:

- Bug reports with clear reproduction steps.
- Small bug fixes with a test.
- Documentation and wording improvements.
- New rebuildable cache or build-output locations, with tests proving what is and isn't removed.
- Test coverage for existing behavior.

## Pull requests

Keep each PR to one change. Explain the user-visible behavior and include the relevant validation. A PR may be
closed if it:

- Adds automatic deletion, automatic force-quit, or memory-purge behavior, or an automatic action that ends
  or edits something without a switch that is off by default.
- Changes the UI without following [docs/DESIGN.md](docs/DESIGN.md).
- Adds dependencies, network calls, or telemetry.
- Includes secrets, private paths, process command lines, or personal data.
- Is too large to review confidently.

Closing a PR is not a judgment on the contributor; it usually means the change does not fit right now.

For UI changes, render every screen with `TAMEBAR_DESIGN_DIR=/tmp/shots swift test --filter DesignRenderTests`
and attach before/after images. Screenshots must use synthetic project names and data; do not publish your
running processes or history.

## Safety requirements

- Never infer that low CPU means a process is abandoned.
- Revalidate process identity, owner and project policy immediately before signaling it.
- Keep AI apps, active sessions, booted simulators and data-bearing Docker resources protected.
- Never add silent deletion, automatic force-quitting or memory-purge commands.
- Verify cleanup and process control against disposable fixtures, not your real files or sessions.
- Keep persisted history bounded and exclude commands, environment variables, tokens and conversation contents.
- Keep the migration of data folders and preferences from earlier releases working.
- Default to small build concurrency and avoid repeated full-disk scans.

Use one input structure for functions with multiple domain parameters.
Add focused tests for deletion boundaries, process identity, launch validation and persistence migrations.
Use `xcrun swift-format format --in-place <changed files>` for Swift formatting.

See `OPEN_SOURCE_BASES.md` before adapting source from another project and preserve all required notices.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
