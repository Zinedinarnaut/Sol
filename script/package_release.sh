#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Sol.xcodeproj"
SCHEME="Sol"
VERSION="${SOL_RELEASE_VERSION:-}"
TEAM_ID="${SOL_DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${SOL_NOTARY_PROFILE:-}"
DIST_DIR="$ROOT_DIR/dist"

if [[ -z "$VERSION" ]]; then
  VERSION="$(
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Release \
      -showBuildSettings 2>/dev/null |
      sed -nE 's/^[[:space:]]*MARKETING_VERSION = (.*)$/\1/p' |
      head -n 1
  )"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Could not resolve a valid Sol release version." >&2
  exit 2
fi

ARCHIVE_PATH="$DIST_DIR/Sol-$VERSION.xcarchive"
EXPORT_DIR="$DIST_DIR/export-$VERSION"
ZIP_PATH="$DIST_DIR/Sol-$VERSION-macOS.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

if [[ -z "$TEAM_ID" ]]; then
  echo "Set SOL_DEVELOPMENT_TEAM to the Apple Developer team used for Sol." >&2
  exit 2
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set SOL_NOTARY_PROFILE to an xcrun notarytool keychain profile." >&2
  exit 2
fi

case "$DIST_DIR" in
  "$ROOT_DIR"/dist)
    ;;
  *)
    echo "Refusing to package outside this checkout's dist directory." >&2
    exit 1
    ;;
esac

mkdir -p "$DIST_DIR"
/bin/rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
/bin/rm -f "$ZIP_PATH" "$CHECKSUM_PATH"

"$ROOT_DIR/script/install_dotnet_sdk.sh"
"$ROOT_DIR/script/fetch_ryubing_source.sh"

xcodebuild \
  -allowProvisioningUpdates \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

EXPORT_OPTIONS="$(mktemp -t sol-export-options.XXXXXX.plist)"
trap 'rm -f "$EXPORT_OPTIONS"' EXIT

/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
/usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS"
/usr/bin/plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
/usr/bin/plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
/usr/bin/plutil -insert stripSwiftSymbols -bool YES "$EXPORT_OPTIONS"

xcodebuild \
  -allowProvisioningUpdates \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_BUNDLE="$EXPORT_DIR/Sol.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Xcode export did not produce $APP_BUNDLE" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if ! /usr/bin/codesign -dvv "$APP_BUNDLE" 2>&1 |
  /usr/bin/grep -q '^Authority=Developer ID Application:'; then
  echo "The exported app is not signed with a Developer ID Application certificate." >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

# Recreate the archive so the downloadable copy contains the stapled ticket.
/bin/rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
/usr/bin/shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
