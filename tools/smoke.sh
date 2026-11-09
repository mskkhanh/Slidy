#!/bin/bash
# Smoke test: launches a PRIVATE copy of Slidy (its own bundle id and preferences) on a copy of a deck, waits, quits it,
# and cleans up. It never touches the installed app's recent files, preferences or open document.
# Usage: tools/smoke.sh path/to/deck.pptx
set -euo pipefail
cd "$(dirname "$0")/.."
DECK="${1:?usage: tools/smoke.sh deck.pptx}"
WORK="$(mktemp -d)"
APP="$WORK/Slidy Smoke.app"
ID="com.khanh.slidy.smoke"
cp -R Slidy.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
cp "$DECK" "$WORK/smoke-deck.pptx"
BEFORE="$(md5 -q "$WORK/smoke-deck.pptx")"
open -n -a "$APP" "$WORK/smoke-deck.pptx"
sleep 4
pgrep -f "Slidy Smoke.app" >/dev/null && echo "running" || echo "NOT running"
osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pgrep -f "Slidy Smoke.app" >/dev/null && echo "still running" || echo "quit-ok"
[ "$BEFORE" = "$(md5 -q "$WORK/smoke-deck.pptx")" ] && echo "deck unchanged" || echo "deck changed"
defaults delete "$ID" >/dev/null 2>&1 || true
rm -rf "$WORK"
