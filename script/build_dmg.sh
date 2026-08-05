#!/usr/bin/env bash
# Build an ad-hoc-signed Sol DMG for distribution without an Apple Developer
# identity. Produces dist/Sol-<version>-macOS.dmg and its sha256.
#
# The DMG contains Sol.app (deep ad-hoc signed) and an /Applications symlink for
# drag-to-Applications install. End users approve it via System Settings ->
# Privacy & Security -> "Open Anyway", or run dmg-signing.sh after copying.
#
# Env overrides:
#   SOL_RELEASE_VERSION  - version string (default: MARKETING_VERSION from project.yml)
#   SOL_BUILD_CONFIGURATION - Debug|Release (default: Release)
#   SOL_DMG_APP           - reuse an existing built Sol.app instead of building
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST_DIR="$ROOT_DIR/dist"
VERSION="${SOL_RELEASE_VERSION:-}"
CONFIGURATION="${SOL_BUILD_CONFIGURATION:-Release}"

if [ -z "$VERSION" ]; then
  VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*$/\1/p' "$ROOT_DIR/project.yml" | head -n1)"
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Could not resolve a valid Sol version (set SOL_RELEASE_VERSION)." >&2
  exit 2
fi

mkdir -p "$DIST_DIR"

# 0. Project-local .NET SDK (idempotent); the engine build needs it.
"$ROOT_DIR/script/install_dotnet_sdk.sh" >/dev/null

# 1. Build (or reuse) the app, unsigned.
if [ -n "${SOL_DMG_APP:-}" ]; then
  APP="$SOL_DMG_APP"
else
  echo "==> Building Sol ($CONFIGURATION, unsigned)"
  APP="$(
    cd "$ROOT_DIR" &&
    SOL_BUILD_CONFIGURATION="$CONFIGURATION" SOL_APPLE_SIGNING=off \
      ./script/build_and_run.sh --build | tail -n1
  )"
fi
if [ ! -d "$APP" ]; then
  echo "No Sol.app to package: $APP" >&2
  exit 1
fi
APP="$(cd "$APP" && pwd -P)"
echo "==> App: $APP"

# 2. Deep ad-hoc sign the whole bundle.
"$ROOT_DIR/script/codesign_adhoc.sh" "$APP"

# 3. Stage DMG contents: Sol.app + /Applications symlink.
STAGE="$(mktemp -d -t sol-dmg-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 4. Create a compressed, read-only DMG.
DMG="$DIST_DIR/Sol-$VERSION-macOS.dmg"
rm -f "$DMG" "$DMG.sha256"
echo "==> Creating $DMG"
hdiutil create \
  -volname "Sol $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >/dev/null

# 5. Ad-hoc sign the DMG itself.
/usr/bin/codesign --force --sign - --timestamp=none "$DMG" >/dev/null

# 6. Verify the image, then write the checksum.
hdiutil verify "$DMG" >/dev/null
/usr/bin/shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"

echo "==> DMG:  $DMG"
echo "==> SHA:  $DMG.sha256 ($(cat "$DMG.sha256"))"
