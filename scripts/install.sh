#!/usr/bin/env bash
# Builds ModePin, installs it to /Applications, links the `modepin` command
# and starts it now and at every login.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

dest=/Applications/ModePin.app
exe="$dest/Contents/MacOS/ModePin"

# Stop the installed copy first so its binary isn't replaced while running.
if [[ -x "$exe" ]]; then
    "$exe" uninstall-agent >/dev/null || true
fi
rm -rf "$dest"
cp -R build/ModePin.app "$dest"

if command -v brew >/dev/null; then
    ln -sf "$exe" "$(brew --prefix)/bin/modepin"
    echo "Linked $(brew --prefix)/bin/modepin"
fi

"$exe" install-agent
