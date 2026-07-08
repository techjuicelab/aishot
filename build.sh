#!/bin/zsh
# Build AIShot.app (universal, ad-hoc signed, no dependencies) and install it
# to ~/Applications so launchers can start it by NAME: open -gna AIShot
set -e
cd "$(dirname "$0")"

APP=AIShot.app
BIN="$APP/Contents/MacOS/AIShot"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal binary (Apple Silicon + Intel), deployment target macOS 14
swiftc -O -target arm64-apple-macos14.0  -o /tmp/aishot-arm64  main.swift
swiftc -O -target x86_64-apple-macos14.0 -o /tmp/aishot-x86_64 main.swift
lipo -create /tmp/aishot-arm64 /tmp/aishot-x86_64 -output "$BIN"
rm -f /tmp/aishot-arm64 /tmp/aishot-x86_64

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AIShot</string>
	<key>CFBundleIdentifier</key><string>com.techjuicelab.aishot</string>
	<key>CFBundleName</key><string>AIShot</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# App icon (generated from icon.png with stock sips/iconutil, if present)
if [ -f icon.png ]; then
  ICONSET=/tmp/aishot-appicon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  mkdir -p "$APP/Contents/Resources"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

codesign --force --sign - "$APP"

# Install to ~/Applications and register with LaunchServices
NEW_CDHASH=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash/{print $2}')
OLD_CDHASH=$(codesign -dvvv "$HOME/Applications/$APP" 2>&1 | awk -F= '/^CDHash/{print $2}')
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP"
ditto "$APP" "$HOME/Applications/$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$HOME/Applications/$APP" || true

# Keep exactly one registered copy: unregister and remove the build-tree
# bundle so `open -a AIShot` (and TCC identity) can never resolve ambiguously.
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f -u "$PWD/$APP" || true
rm -rf "$APP"

echo "installed: $HOME/Applications/$APP"
echo "launch:    open -gn \"\$HOME/Applications/$APP\""

# Ad-hoc re-signing changes the CDHash when the binary changes, which
# silently invalidates existing TCC grants while System Settings still shows
# them enabled. Reset our records so the next launch re-prompts cleanly —
# but only when the code actually changed.
if [ "$NEW_CDHASH" != "$OLD_CDHASH" ]; then
  tccutil reset All com.techjuicelab.aishot >/dev/null 2>&1 || true
  echo "note:      binary changed — permissions were reset, first run will prompt again"
else
  echo "note:      binary unchanged — existing permissions kept"
fi
