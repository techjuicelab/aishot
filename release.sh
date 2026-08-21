#!/bin/zsh
# Cut an AIShot release: build, package, sign, publish, and update the appcast.
#
#   ./release.sh 1.7             build 1.7, publish it, update the appcast
#   ./release.sh 1.7 --dry-run   build and package into dist/ and stop there
#
# Two artifacts come out of a release, and they are not interchangeable:
#
#   AIShot-<version>.zip   what Sparkle downloads and what scripted installers
#                          (mac-setup) fetch. Versioned, because Sparkle keys
#                          its cache off the URL.
#   AIShot.dmg             what a person downloads. Deliberately *not*
#                          versioned, so that
#                          github.com/techjuicelab/aishot/releases/latest/download/AIShot.dmg
#                          is a permanent link the website can point at.
#
# Publishing order matters: the assets go up before the appcast that advertises
# them is pushed. The appcast is served straight off main
# (raw.githubusercontent.com/.../main/appcast.xml), so a pushed appcast is a
# live one, and pushing it first would point every installed copy at a URL that
# does not exist yet.
set -e
cd "$(dirname "$0")"

REPO=techjuicelab/aishot
DIST=dist
DRY_RUN=0
VERSION=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) echo "usage: release.sh <version> [--dry-run]" >&2; exit 2 ;;
    *)
      [ -n "$VERSION" ] && { echo "usage: release.sh <version> [--dry-run]" >&2; exit 2; }
      VERSION="$arg" ;;
  esac
done
[ -n "$VERSION" ] || { echo "usage: release.sh <version> [--dry-run]" >&2; exit 2; }
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] \
  || { echo "error:     version must look like 1.7 or 1.7.1" >&2; exit 2; }

fail() { print -u2 -- "error:     $*"; exit 1; }

# --- preconditions ------------------------------------------------------------
# A release is a promise about a specific commit, so refuse to make one from a
# tree that does not match what will be tagged.
if [ "$DRY_RUN" != "1" ]; then
  command -v gh >/dev/null 2>&1 || fail "gh is required to publish (brew install gh)"
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (gh auth login)"
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "releases are cut from main"
  [ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
  git fetch --quiet origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || fail "main and origin/main have diverged — push or pull first"
  gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 \
    && fail "v$VERSION already exists on GitHub"
fi

CURRENT_VERSION=$(sed -n 's/^VERSION=//p' build.sh | head -1)
CURRENT_BUILD=$(sed -n 's/^BUILD=//p' build.sh | head -1)
[ -n "$CURRENT_BUILD" ] || fail "could not read BUILD from build.sh"
BUILD=$((CURRENT_BUILD + 1))
echo "release:   $CURRENT_VERSION (build $CURRENT_BUILD) → $VERSION (build $BUILD)"

# --- Sparkle's signing tool ---------------------------------------------------
# Same archive, same pinned hash, same rule as build.sh: verify the archive on
# every use and never keep an extracted tree around. The EdDSA private key lives
# in the login keychain; sign_update finds it there.
SPARKLE_VERSION=$(sed -n 's/^SPARKLE_VERSION=//p' build.sh | head -1)
SPARKLE_SHA256=$(sed -n 's/^SPARKLE_SHA256=//p' build.sh | head -1)
SPARKLE_TARBALL="$HOME/Library/Caches/space.techjuicelab.sparkle/Sparkle-${SPARKLE_VERSION}.tar.xz"
mkdir -p "$(dirname "$SPARKLE_TARBALL")"
if [ ! -f "$SPARKLE_TARBALL" ]; then
  curl -fsSL -o "$SPARKLE_TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    || { rm -f "$SPARKLE_TARBALL"; fail "could not download Sparkle ${SPARKLE_VERSION}"; }
fi
ACTUAL=$(shasum -a 256 "$SPARKLE_TARBALL" | awk '{print $1}')
[ "$ACTUAL" = "$SPARKLE_SHA256" ] \
  || { rm -f "$SPARKLE_TARBALL"; fail "Sparkle archive failed verification"; }
SPARKLE_TOOLS=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-tools-XXXXXX")
trap 'rm -rf "$SPARKLE_TOOLS" "${STAGE:-}"' EXIT
tar -xf "$SPARKLE_TARBALL" -C "$SPARKLE_TOOLS"
SIGN_UPDATE="$SPARKLE_TOOLS/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || fail "sign_update is missing from the Sparkle archive"

# --- build --------------------------------------------------------------------
# The version has to be committed before the build, because the number baked
# into Info.plist is what Sparkle compares against the appcast.
sed -i '' "s/^VERSION=.*/VERSION=$VERSION/; s/^BUILD=.*/BUILD=$BUILD/" build.sh
./build.sh --no-install

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" AIShot.app/Contents/Info.plist)
[ "$PLIST_VERSION" = "$VERSION" ] || fail "the built app reports $PLIST_VERSION, not $VERSION"

# An ad-hoc signed release would change every installed copy's designated
# requirement — and with it every screen recording and accessibility grant — on
# a machine that has no way to get the certificate back.
codesign -d -r- AIShot.app 2>&1 | grep -q 'certificate leaf' \
  || fail "the app is ad-hoc signed; releases must use the TechJuice signing certificate"

# --- package ------------------------------------------------------------------
rm -rf "$DIST"; mkdir -p "$DIST"
ZIP="$DIST/AIShot-$VERSION.zip"
DMG="$DIST/AIShot.dmg"

ditto -c -k --sequesterRsrc --keepParent AIShot.app "$ZIP"

# A plain read-only compressed image: the app and a symlink to drag it onto.
# Nothing here needs a background picture or scripted Finder window placement,
# and both would add a build-host dependency to a release.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/aishot-dmg-XXXXXX")
ditto AIShot.app "$STAGE/AIShot.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname AIShot -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"; STAGE=""

# Both artifacts are made, so the build-tree bundle has done its job. Leaving it
# behind is the ambiguity build.sh cleans up after an install: two bundles with
# the same ID, and `open -a AIShot`, the TCC identity and the menu bar item all
# resolve to whichever one macOS happened to register last.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f -u "$PWD/AIShot.app" || true
rm -rf AIShot.app

# --- sign and measure ---------------------------------------------------------
# The EdDSA signature is what makes an update trustworthy: Sparkle installs a
# download only if it verifies against the public key inside the *installed*
# copy. The SHA-256 is for installers that are not Sparkle.
sign_of() { "$SIGN_UPDATE" "$1" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p'; }
size_of() { stat -f%z "$1"; }
hash_of() { shasum -a 256 "$1" | awk '{print $1}'; }

ZIP_SIGNATURE=$(sign_of "$ZIP"); [ -n "$ZIP_SIGNATURE" ] || fail "could not sign $ZIP"
DMG_SIGNATURE=$(sign_of "$DMG"); [ -n "$DMG_SIGNATURE" ] || fail "could not sign $DMG"
ZIP_SIZE=$(size_of "$ZIP"); DMG_SIZE=$(size_of "$DMG")
ZIP_HASH=$(hash_of "$ZIP"); DMG_HASH=$(hash_of "$DMG")

echo "packaged:  $ZIP ($ZIP_SIZE bytes)"
echo "packaged:  $DMG ($DMG_SIZE bytes)"

# --- appcast ------------------------------------------------------------------
# Sparkle reads the enclosure and ignores the aishot: elements; scripted
# installers read the aishot: elements. Keeping both in one file means the
# automatic updater and mac-setup are looking at the same statement about what
# the current version is.
BASE="https://github.com/$REPO/releases/download/v$VERSION"
PUB_DATE=$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")
ITEM=$(cat <<XML
        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <link>https://github.com/$REPO</link>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="$BASE/AIShot-$VERSION.zip" length="$ZIP_SIZE" type="application/octet-stream" sparkle:edSignature="$ZIP_SIGNATURE"/>
            <aishot:sha256>$ZIP_HASH</aishot:sha256>
            <aishot:dmg url="$BASE/AIShot.dmg" length="$DMG_SIZE" sha256="$DMG_HASH" sparkle:edSignature="$DMG_SIGNATURE"/>
        </item>
XML
)
grep -q 'xmlns:aishot=' appcast.xml || sed -i '' \
  's|<rss xmlns:sparkle=|<rss xmlns:aishot="https://aishot.techjuicelab.site/appcast" xmlns:sparkle=|' \
  appcast.xml

# Insert as the first item: the newest release is what Sparkle picks and what
# mac-setup's parser stops at. Splitting the file around that line keeps the
# multi-line item out of any tool's argument list — awk -v, for one, cannot
# carry a newline.
INSERT_AT=$(grep -n '<item>' appcast.xml | head -1 | cut -d: -f1)
[ -n "$INSERT_AT" ] || INSERT_AT=$(grep -n '</channel>' appcast.xml | head -1 | cut -d: -f1)
[ -n "$INSERT_AT" ] || fail "appcast.xml has neither an <item> nor a </channel> to insert before"
{
  head -n $((INSERT_AT - 1)) appcast.xml
  print -r -- "$ITEM"
  tail -n +"$INSERT_AT" appcast.xml
} > appcast.xml.new
mv appcast.xml.new appcast.xml

# The insert is the one step here that silently produces a plausible-looking
# file when it goes wrong, so check the result rather than the exit status.
FIRST_VERSION=$(sed -n 's|.*<sparkle:shortVersionString>\(.*\)</sparkle:shortVersionString>.*|\1|p' appcast.xml | head -1)
[ "$FIRST_VERSION" = "$VERSION" ] \
  || fail "appcast.xml still leads with ${FIRST_VERSION:-nothing}, not $VERSION"
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout appcast.xml || fail "appcast.xml is not well-formed"
else
  echo "warning:   xmllint is unavailable — appcast was not validated"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "dry run:   nothing was committed, tagged or published"
  echo "artifacts: $DIST"
  echo "revert:    git checkout build.sh appcast.xml"
  exit 0
fi

# --- publish ------------------------------------------------------------------
# Commit the version bump first and tag *that* commit: a tag whose build.sh says
# 1.6 while the release says 1.7 cannot be rebuilt into what was shipped.
git add build.sh
git commit -m "chore(release): bump to $VERSION — build $BUILD

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push origin main

gh release create "v$VERSION" -R "$REPO" \
  --title "AIShot $VERSION" \
  --notes "AIShot $VERSION

- \`AIShot.dmg\` — 내려받아 \`/Applications\`로 드래그. 공증되지 않은 앱이라 첫 실행 때 시스템 설정 → 개인정보 보호 및 보안에서 '그래도 열기'가 필요합니다.
- \`AIShot-$VERSION.zip\` — Sparkle 자동 업데이트와 스크립트 설치용." \
  "$ZIP" "$DMG"

# Only now: the appcast points at assets that exist.
git add appcast.xml
git commit -m "release(aishot): publish $VERSION — appcast에 $VERSION 항목 추가

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push origin main

echo "published: https://github.com/$REPO/releases/tag/v$VERSION"
echo "appcast:   https://raw.githubusercontent.com/$REPO/main/appcast.xml"
