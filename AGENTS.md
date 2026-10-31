# Tamebar

Guidance for coding agents working in this repository.

- Build with `swift build`; package with `./scripts/build-app.sh` (ad-hoc signed without an identity). Run
  `./scripts/check.sh` before proposing a change, and `./scripts/e2e.sh` for changes to process control or
  automatic actions. Run one build or test run at a time.
- For changes to visible UI, interactions, or product copy, read [docs/DESIGN.md](docs/DESIGN.md), and check
  the changed screens in the running app as well as compiling them
  (`TAMEBAR_DESIGN_DIR=/tmp/shots swift test --filter DesignRenderTests` renders them).
- Follow the safety requirements in [CONTRIBUTING.md](CONTRIBUTING.md): never end, pause, quit or delete
  anything the user hasn't reviewed or switched on, and test process control and cleanup against disposable
  fixtures only, never your own sessions, files or `~/.claude` / `~/.codex` settings.
- An automatic action that ends or edits something ships off by default, behind a switch in Settings.
- Tests and docs use synthetic names (`my-app`, `api`, `/Users/me`), never real projects, paths or people.
