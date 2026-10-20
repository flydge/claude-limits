#!/bin/bash
# Starts ClaudeLimits at login through a user LaunchAgent, and starts it now.
set -euo pipefail
LABEL=com.flydge.claude-limits
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits"
[ -x "$BIN" ] || { echo "Run ./install.sh first: $BIN not found" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Loaded $PLIST"
