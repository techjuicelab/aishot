#!/bin/zsh
# Build AIShot.app (universal, locally signed, no dependencies) and install it
# into /Applications, like any other Mac app, so launchers can start it by
# name: open -gna AIShot
set -e
cd "$(dirname "$0")"

APP=AIShot.app
BIN="$APP/Contents/MacOS/AIShot"
MENUBAR_LABEL=space.techjuicelab.aishot.menubar
MENUBAR_PLIST="$HOME/Library/LaunchAgents/$MENUBAR_LABEL.plist"

# /Applications is the expected home for an app and is group-writable for
# admin users, so no sudo is needed on a normal Mac. Fall back to ~/Applications
# on a managed machine where it is locked down. Override with:
#   AISHOT_INSTALL_DIR=~/Applications ./build.sh
INSTALL_DIR="${AISHOT_INSTALL_DIR:-}"
if [ -z "$INSTALL_DIR" ]; then
  if [ -w /Applications ]; then
    INSTALL_DIR=/Applications
  else
    INSTALL_DIR="$HOME/Applications"
  fi
fi
INSTALL_DIR="${INSTALL_DIR%/}"
INSTALLED="$INSTALL_DIR/$APP"

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
	<key>CFBundleIdentifier</key><string>space.techjuicelab.aishot</string>
	<key>CFBundleName</key><string>AIShot</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.3</string>
	<key>CFBundleVersion</key><string>6</string>
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

SIGN_IDENTITY="TechJuice Local Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
  echo "signing:   $SIGN_IDENTITY (stable permissions across updates)"
else
  codesign --force --sign - "$APP"
  echo "signing:   ad-hoc (permissions may need reapproval after updates)"
fi

# Install and register with LaunchServices
NEW_REQUIREMENT=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^.*designated => //p')
OLD_REQUIREMENT=$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^.*designated => //p')
if [ -z "$NEW_REQUIREMENT" ]; then
  echo "error:     could not read the new app's signing requirement"
  exit 1
fi
if [ -e "$INSTALLED" ] && [ -z "$OLD_REQUIREMENT" ]; then
  # Never treat an unreadable installed signature as an identity match.
  OLD_REQUIREMENT="<unreadable-installed-requirement>"
fi

# Retire the pre-1.4 bundle ID. Its agent would keep restarting a host whose
# status item macOS refuses to place in the menu bar, and both hosts would
# fight over the same lock.
LEGACY_LABEL=com.techjuicelab.aishot.menubar
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [ -e "$LEGACY_PLIST" ] || launchctl print "gui/$UID/$LEGACY_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID/$LEGACY_LABEL" >/dev/null 2>&1 || true
  rm -f "$LEGACY_PLIST"
  pkill -f "AIShot --menubar" >/dev/null 2>&1 || true
  echo "cleanup:   retired the com.techjuicelab.aishot menu bar agent"
fi

# Stop the previously installed resident host only after the new build has
# succeeded. Captures are separate short-lived processes and are left alone.
launchctl bootout "gui/$UID/$MENUBAR_LABEL" >/dev/null 2>&1 || true
for _ in {1..40}; do
  launchctl print "gui/$UID/$MENUBAR_LABEL" >/dev/null 2>&1 || break
  sleep 0.05
done
if launchctl print "gui/$UID/$MENUBAR_LABEL" >/dev/null 2>&1; then
  echo "error:     previous menu bar LaunchAgent did not stop"
  exit 1
fi

# Any host still running from a previous install — at either location.
while read -r process_pid process_command; do
  if [[ "$process_command" == *"/$APP/Contents/MacOS/AIShot --menubar" ]]; then
    kill "$process_pid" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      kill -0 "$process_pid" >/dev/null 2>&1 || break
      sleep 0.05
    done
    if kill -0 "$process_pid" >/dev/null 2>&1; then
      echo "error:     previous manual menu bar host did not stop"
      exit 1
    fi
  fi
done < <(ps ax -o pid=,command=)

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$INSTALLED" || true

# Keep exactly one registered copy: two bundles sharing a bundle ID make
# `open -a AIShot`, the TCC identity and the menu bar item resolve ambiguously.
# Drop the build-tree bundle and any copy left at the other install location.
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f -u "$PWD/$APP" || true
rm -rf "$APP"
for other in /Applications "$HOME/Applications"; do
  [ "$other" = "$INSTALL_DIR" ] && continue
  [ -e "$other/$APP" ] || continue
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f -u "$other/$APP" || true
  rm -rf "$other/$APP"
  echo "cleanup:   removed the earlier install at $other/$APP"
done

# Keep a single lightweight menu-bar host available after login. The host only
# owns the status item; each capture still runs as a short-lived app instance.
mkdir -p "$(dirname "$MENUBAR_PLIST")"
cat > "$MENUBAR_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MENUBAR_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALLED/Contents/MacOS/AIShot</string>
    <string>--menubar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <!-- Restart on any exit: a host that dies for any reason must not leave the
       user without a menu bar item. Quit AIShot unloads this agent instead. -->
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
plutil -lint "$MENUBAR_PLIST" >/dev/null
if ! launchctl bootstrap "gui/$UID" "$MENUBAR_PLIST"; then
  echo "error:     could not register the menu bar LaunchAgent"
  exit 1
fi
sleep 0.25
MENUBAR_RUNNING=0
for _ in {1..40}; do
  if launchctl print "gui/$UID/$MENUBAR_LABEL" 2>/dev/null \
      | grep -q 'state = running'; then
    MENUBAR_RUNNING=1
    break
  fi
  sleep 0.05
done
if [ "$MENUBAR_RUNNING" -ne 1 ]; then
  echo "error:     menu bar LaunchAgent registered but its host is not running"
  exit 1
fi

echo "installed: $INSTALLED"
echo "launch:    open -gn \"$INSTALLED\""
echo "menu bar:  running now and automatically after login"
if [ "$INSTALL_DIR" != "/Applications" ]; then
  echo "note:      /Applications was not writable — installed to $INSTALL_DIR instead"
fi

# A changed designated requirement invalidates TCC grants while System Settings
# can still show them enabled. Reset only on that identity transition; a stable
# local signing certificate keeps permissions valid across later updates.
if [ "$NEW_REQUIREMENT" != "$OLD_REQUIREMENT" ]; then
  if tccutil reset All space.techjuicelab.aishot >/dev/null 2>&1; then
    echo "note:      signing identity changed — permissions were reset once"
  else
    echo "warning:   signing identity changed but TCC reset failed; re-add AIShot permissions manually"
  fi
else
  echo "note:      signing identity unchanged — existing permissions kept"
fi
