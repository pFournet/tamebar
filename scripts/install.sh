#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
SOURCE_APP="$ROOT_DIR/dist/Tamebar.app"
TARGET_APP="$HOME/Applications/Tamebar.app"
"$ROOT_DIR/scripts/build-app.sh"
mkdir -p "$HOME/Applications"
pkill -x Tamebar 2>/dev/null || true
pkill -x TamebarRescue 2>/dev/null || true
for attempt in {1..50}; do
    if ! pgrep -x Tamebar >/dev/null; then
        break
    fi
    sleep 0.1
done
if pgrep -x Tamebar >/dev/null; then
    print -u2 "The previous app is still exiting; installation stopped."
    exit 1
fi
if [[ -d "$TARGET_APP" ]]; then
    BACKUP_DIR="$HOME/Library/Application Support/Tamebar/Backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    ditto -c -k --keepParent "$TARGET_APP" "$BACKUP_DIR/Tamebar.zip"
    rm -rf "$TARGET_APP"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
# The read-only command line (docs/CLI.md): ~/.local/bin/tamebar runs the app's own executable.
# Only a link into a Tamebar.app is replaced; anything else at that path is left alone.
CLI_LINK="$HOME/.local/bin/tamebar"
CLI_TARGET="$TARGET_APP/Contents/MacOS/Tamebar"
mkdir -p "${CLI_LINK:h}"
if [[ -L "$CLI_LINK" ]]; then
    CURRENT="$(readlink "$CLI_LINK")"
    if [[ "$CURRENT" == "$CLI_TARGET" ]]; then
        :
    elif [[ "$CURRENT" == *Tamebar.app/* ]]; then
        ln -sfn "$CLI_TARGET" "$CLI_LINK"
    else
        print -u2 "$CLI_LINK points to $CURRENT; left as it is."
    fi
elif [[ -e "$CLI_LINK" ]]; then
    print -u2 "$CLI_LINK exists and isn't a link; left as it is."
else
    ln -s "$CLI_TARGET" "$CLI_LINK"
fi
if [[ ":$PATH:" != *":${CLI_LINK:h}:"* ]]; then
    print -u2 "${CLI_LINK:h} isn't on PATH; add it to run tamebar."
fi
open "$TARGET_APP"
echo "$TARGET_APP"
