#!/bin/zsh
# Build AIShot.app (universal, locally signed, no dependencies) and install it
# into /Applications, like any other Mac app, so launchers can start it by
# name: open -gna AIShot
#
#   ./build.sh               build, then install and start the menu bar host
#   ./build.sh --no-install  build only, leaving ./AIShot.app in the tree
#                            (what release.sh packages into the zip and dmg)
#
# The install half is the app's own `--install`, so a build tree, a downloaded
# zip and a dragged-out DMG all produce the same installed state. Override the
# destination with AISHOT_INSTALL_DIR=~/Applications ./build.sh — build.sh only
# passes it through; Install.swift is what acts on it.
set -e
cd "$(dirname "$0")"

APP=AIShot.app
BIN="$APP/Contents/MacOS/AIShot"

# The released version. release.sh rewrites both lines when it cuts a release;
# nothing else should edit them, since VERSION is what the appcast advertises
# and BUILD is what Sparkle compares.
VERSION=1.7
BUILD=10

NO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-install) NO_INSTALL=1 ;;
    *) echo "usage: build.sh [--no-install]" >&2; exit 2 ;;
  esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Sparkle — the auto-updater, embedded in the bundle. If it cannot be fetched
# (offline, say) the build still succeeds: main.swift guards the updater on
# `#if canImport(Sparkle)`, so the app simply ships without update checking
# rather than failing to build.
SPARKLE_VERSION=2.9.5
SPARKLE_SHA256=015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc
# Only the signed archive is cached, never an extracted tree. ~/Library/Caches is
# ordinary user-writable space with no TCC protection — unlike the source repo,
# anything running as this user can write there without a consent prompt — and
# whatever comes out of it is re-signed with the release certificate and shipped.
# A tree cached between runs would therefore be a place to drop code that we then
# sign ourselves. Re-verifying costs 60ms and re-extracting 840ms.
SPARKLE_TARBALL="$HOME/Library/Caches/space.techjuicelab.sparkle/Sparkle-${SPARKLE_VERSION}.tar.xz"

SPARKLE_FRAMEWORKS=""

sparkle_fetch() {
  # An explicit override wins, so release.sh can hand down a copy it has already
  # verified instead of every build re-doing the work.
  if [ -n "${SPARKLE_DIR:-}" ] && [ -d "$SPARKLE_DIR/Sparkle.framework" ]; then
    print -r -- "$SPARKLE_DIR"
    return 0
  fi

  mkdir -p "$(dirname "$SPARKLE_TARBALL")"
  if [ ! -f "$SPARKLE_TARBALL" ]; then
    curl -fsSL -o "$SPARKLE_TARBALL" \
      "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
      || { rm -f "$SPARKLE_TARBALL"; return 1; }
  fi

  # Checked on every build, not once at download time. The pinned hash is the
  # trust anchor, so verifying a cached archive is exactly as strong as fetching
  # it again.
  local actual
  actual=$(shasum -a 256 "$SPARKLE_TARBALL" | awk '{print $1}')
  if [ "$actual" != "$SPARKLE_SHA256" ]; then
    print -u2 "error:     Sparkle archive failed verification (expected $SPARKLE_SHA256, got $actual)"
    rm -f "$SPARKLE_TARBALL"
    return 1
  fi

  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-XXXXXX") || return 1
  if ! tar -xf "$SPARKLE_TARBALL" -C "$dir" || [ ! -d "$dir/Sparkle.framework" ]; then
    rm -rf "$dir"
    return 1
  fi
  print -r -- "$dir"
}

sparkle_embed() {
  local src
  if ! src=$(sparkle_fetch); then
    print "sparkle:   unavailable — building without the auto-updater"
    return 0
  fi
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$src/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  SPARKLE_FRAMEWORKS="$APP/Contents/Frameworks"
  # Clean up here, via $src, and not through a variable set inside
  # sparkle_fetch: that function runs in a command substitution, so any
  # assignment it makes dies with the subshell and the extracted tree would
  # survive every build — which is exactly what "never cache a tree" forbids.
  # A SPARKLE_DIR handed down by release.sh belongs to the caller, so never
  # remove that one.
  if [ -n "$src" ] && [ "$src" != "${SPARKLE_DIR:-}" ]; then
    rm -rf "$src"
  fi
  print "sparkle:   ${SPARKLE_VERSION} embedded"
}

sparkle_embed

SPARKLE_FLAGS=()
if [ -n "$SPARKLE_FRAMEWORKS" ]; then
  SPARKLE_FLAGS=(-F "$SPARKLE_FRAMEWORKS" -framework Sparkle
                 -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

# Universal binary (Apple Silicon + Intel), deployment target macOS 14.
# main.swift must stay in the list: swiftc picks the entry point by that name,
# and every other file is a plain declaration-only source compiled alongside it.
SOURCES=(main.swift ScrollCapture.swift Install.swift)
swiftc -O -target arm64-apple-macos14.0  "${SPARKLE_FLAGS[@]}" -o /tmp/aishot-arm64  "${SOURCES[@]}"
swiftc -O -target x86_64-apple-macos14.0 "${SPARKLE_FLAGS[@]}" -o /tmp/aishot-x86_64 "${SOURCES[@]}"
lipo -create /tmp/aishot-arm64 /tmp/aishot-x86_64 -output "$BIN"
rm -f /tmp/aishot-arm64 /tmp/aishot-x86_64

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AIShot</string>
	<key>CFBundleIdentifier</key><string>space.techjuicelab.aishot</string>
	<key>CFBundleName</key><string>AIShot</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<!-- Sparkle. SUPublicEDKey is what makes an update trustworthy: Sparkle
	     accepts a download only if its EdDSA signature verifies against the key
	     the *installed* copy shipped with. Changing either of these two values
	     strands everyone running an older build, so they are effectively
	     permanent once a version is out. -->
	<key>SUFeedURL</key><string>https://raw.githubusercontent.com/techjuicelab/aishot/main/appcast.xml</string>
	<key>SUPublicEDKey</key><string>Efqk/yyyq+Br71amu6/POKoiYz6RH4cpOhE7cpva94Q=</string>
	<key>SUEnableAutomaticChecks</key><true/>
	<key>SUScheduledCheckInterval</key><integer>86400</integer>
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

SIGN_IDENTITY="${CODESIGN_IDENTITY:-TechJuice Local Code Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""; then
  echo "signing:   $SIGN_IDENTITY (stable permissions across updates)"
else
  SIGN_IDENTITY=-
  echo "signing:   ad-hoc (permissions may need reapproval after updates)"
fi

# Sign inside out. codesign seals nested bundles into the outer signature, so
# Sparkle's updater app, helper tool and XPC services have to carry our
# signature before the app is signed over them. Getting this backwards builds
# and installs fine, then fails at the moment an update is applied.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  for nested in \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
      "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"; do
    [ -e "$nested" ] || continue
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$nested"
  done
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
fi
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

# Installing is the app's own job (Install.swift): the same code runs whether
# the bundle arrived from this build tree, from a downloaded zip or from a DMG,
# so there is exactly one description of what an installed AIShot looks like —
# a single registered copy in /Applications and a LaunchAgent pointing at it.
# build.sh only decides *whether* to install.
if [ "$NO_INSTALL" = "1" ]; then
  echo "built:     $PWD/$APP (not installed — --no-install)"
  exit 0
fi

"$BIN" --install

# The build-tree bundle has served its purpose, and two bundles sharing a bundle
# ID make `open -a AIShot`, the TCC identity and the menu bar item all resolve
# ambiguously. Unregister and drop this one now that the installed copy is live.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f -u "$PWD/$APP" || true
rm -rf "$APP"

echo "launch:    open -gnb space.techjuicelab.aishot"
