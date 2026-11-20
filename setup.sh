#!/bin/bash
# One-time setup: install dependencies, build the macOS helpers,
# log in to EZVIZ and start the background watcher (launchd).
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
LABEL="io.github.harsxv.lensbell"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/Lensbell.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "==> 1/5 Creating Python venv and installing pyezvizapi"
# Recreate the venv if this folder was moved or renamed (venvs store absolute paths).
if [ -d .venv ] && ! grep -qF "$DIR/.venv" .venv/bin/activate 2>/dev/null; then
  rm -rf .venv
fi
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

echo "==> 2/5 Building macOS helpers (Swift)"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "   swiftc not found. Run: xcode-select --install  then re-run ./setup.sh"
  exit 1
fi
swiftc -O popup.swift -o popup
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<IP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.harsxv.lensbell.app</string>
  <key>CFBundleName</key><string>Lensbell</string>
  <key>CFBundleDisplayName</key><string>Lensbell</string>
  <key>CFBundleExecutable</key><string>Lensbell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
IP
swiftc -O notifier.swift -o "$APP/Contents/MacOS/Lensbell"
# App icon: build AppIcon.icns from assets/icon.png with macOS's sips + iconutil.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
xattr -cr "$APP"   # strip metadata (e.g. from sips) that breaks code signing
codesign --force --deep -s - "$APP"
touch "$APP"
"$LSREGISTER" -f "$APP" 2>/dev/null || true

echo "==> 3/5 Logging in to EZVIZ (once; you'll be asked for an MFA code if needed)"
if [ ! -f ezviz_token.json ]; then
  read -r -p "   EZVIZ email/username: " EZ_USER
  read -r -s -p "   EZVIZ password: " EZ_PASS; echo
  read -r -p "   API region host (leave empty for default): " EZ_REGION
  ARGS=(-u "$EZ_USER" -p "$EZ_PASS" --token-file ezviz_token.json --save-token)
  if [ -n "$EZ_REGION" ]; then
    ARGS+=(-r "$EZ_REGION")
    echo "EZVIZ_REGION=$EZ_REGION" > .region
  fi
  .venv/bin/pyezvizapi "${ARGS[@]}" devices status >/dev/null
  unset EZ_PASS
  chmod 600 ezviz_token.json
  echo "   Logged in. Session token saved to ezviz_token.json (your password is not stored)."
fi
REGION="$(sed -n "s/^EZVIZ_REGION=//p" .region 2>/dev/null || true)"

echo "==> 4/5 Starting the background watcher (launchd)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$DIR/.venv/bin/python</string><string>$DIR/watcher.py</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>LENSBELL_REGION</key><string>$REGION</string>
    <key>LENSBELL_NOTIFIER</key><string>$APP/Contents/MacOS/Lensbell</string>
    <key>LENSBELL_STYLE</key><string>${LENSBELL_STYLE:-notification}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/watcher.log</string>
  <key>StandardErrorPath</key><string>$DIR/watcher.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "==> 5/5 Sending a test notification"
LATEST="$(ls -t captures/*.jpg 2>/dev/null | head -1 || true)"
if [ -n "$LATEST" ]; then
  echo "   Allow notifications for 'Lensbell' if macOS asks."
  "$APP/Contents/MacOS/Lensbell" notify "$LATEST" "Lensbell is running" "Latest capture. Click to open." &
else
  echo "   No capture yet. Trigger a detection on your camera; macOS will ask"
  echo "   permission for 'Lensbell' with the first alarm."
fi

echo
echo "Done. Log: $DIR/watcher.log  |  Captures: $DIR/captures/"
