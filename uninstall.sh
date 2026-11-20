#!/bin/bash
# Stop and remove the background watcher.
# Keeps your token and captures; delete the folder to remove everything.
LABEL="io.github.harsxv.lensbell"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/Lensbell.app"
if [ -d "$APP" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
fi
echo "Watcher stopped; Lensbell.app removed from ~/Applications."
echo "To also sign out, delete ezviz_token.json (or change your EZVIZ password)."
