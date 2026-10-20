#!/bin/bash
# Builds build/ClaudeLimits.app with swiftc. Run: bash menubar/build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=../build/ClaudeLimits.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ClaudeLimits" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $(cd "$APP" && pwd)"
