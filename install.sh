#!/bin/bash
# Copies the status line script and the menu bar app into place.
# Does not edit ~/.claude/settings.json or install the launch agent: see README.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/.claude" "$HOME/Applications"
install -m 755 statusline/statusline-limits.sh "$HOME/.claude/statusline-limits.sh"
bash menubar/build.sh
rm -rf "$HOME/Applications/ClaudeLimits.app"
cp -R build/ClaudeLimits.app "$HOME/Applications/"
echo "Installed:"
echo "  $HOME/.claude/statusline-limits.sh"
echo "  $HOME/Applications/ClaudeLimits.app"
