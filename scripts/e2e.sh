#!/bin/zsh
# Builds an isolated e2e Tamebar (its own bundle id, defaults and permissions) and runs the e2e suite.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
export TAMEBAR_SIGNING_IDENTITY="${TAMEBAR_SIGNING_IDENTITY:--}"
TAMEBAR_BUNDLE_ID=com.tamebar.Tamebar.e2e TAMEBAR_APP_DIR="$ROOT_DIR/dist/e2e" \
  "$ROOT_DIR/scripts/build-app.sh" >/dev/null
TAMEBAR_E2E_APP="$ROOT_DIR/dist/e2e/Tamebar.app" \
  swift test --no-parallel --filter EndToEndTests
