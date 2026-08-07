#!/usr/bin/env bash
#
# dmg-signing.sh — re-sign a downloaded Sol.app locally and clear quarantine.
#
# Sol is distributed ad-hoc signed (no Apple Developer identity). After you drag
# Sol.app into /Applications, macOS will block it on first launch ("cannot be
# opened because the developer cannot be verified"). You then have two choices:
#
#   1. System Settings -> Privacy & Security -> "Open Anyway"   (no Terminal)
#   2. Run this script                                            (this file)
#
# This script re-applies Sol's ad-hoc signature to every embedded binary and
# strips the quarantine attribute, so the app launches with no Gatekeeper prompt.
# It only touches the Sol.app you point it at; it does not change system security
# settings.
#
# Usage:   dmg-signing.sh [path/to/Sol.app]
# Default: /Applications/Sol.app
#
set -euo pipefail

APP="${1:-/Applications/Sol.app}"

if [ ! -d "$APP" ]; then
  echo "Sol.app not found at: $APP" >&2
  echo "Drag Sol.app into /Applications first, or pass its path as an argument." >&2
  exit 1
fi
case "$(basename "$APP")" in
  *.app) ;;
  *) echo "$APP is not an .app bundle" >&2; exit 2 ;;
esac

# Capture the public JIT/runtime entitlements before touching any nested code.
# The downloaded app is the source of truth so this standalone helper does not
# need an entitlement file beside it.
PUBLIC_ENTITLEMENTS="$(mktemp -t sol-public-entitlements.XXXXXX)"
trap 'rm -f "$PUBLIC_ENTITLEMENTS"' EXIT
if ! /usr/bin/codesign -d --entitlements :- "$APP" \
  >"$PUBLIC_ENTITLEMENTS" 2>/dev/null ||
  ! /usr/bin/plutil -lint "$PUBLIC_ENTITLEMENTS" >/dev/null 2>&1; then
  echo "Sol.app has no readable public runtime entitlements." >&2
  exit 1
fi
for required_key in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation; do
  if ! /usr/bin/grep -q "<key>$required_key</key>" "$PUBLIC_ENTITLEMENTS"; then
    echo "Sol.app is missing required runtime entitlement: $required_key" >&2
    exit 1
  fi
done

echo "Re-signing and clearing quarantine for:"
echo "  $APP"
echo "This applies an ad-hoc signature to every binary inside Sol.app and removes"
echo "the Gatekeeper quarantine flag from it. No system settings are changed."
echo

# 1. Standalone Mach-O files (deepest first).
find "$APP" -type f -print0 |
  while IFS= read -r -d '' f; do
    # Main executables are sealed with their containing bundle below. Trying
    # to sign the outer executable first prevents codesign from repairing a
    # damaged nested extension.
    case "$f" in
      */Contents/MacOS/*) continue ;;
    esac
    if /usr/bin/file -b "$f" 2>/dev/null | grep -q '^Mach-O'; then
      /usr/bin/codesign --force --sign - --timestamp=none "$f" >/dev/null
    fi
  done

# 2. Nested code bundles (frameworks, appex), innermost first.
find "$APP" -depth -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' \) \
  -not -path "$APP" -print0 |
  while IFS= read -r -d '' d; do
    /usr/bin/codesign --force --deep --sign - --timestamp=none \
      --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
      "$d" >/dev/null
  done

# 3. Outer app. Restore the captured public runtime boundary explicitly;
# --preserve-metadata cannot preserve entitlements from an unsigned build.
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  --options runtime \
  --entitlements "$PUBLIC_ENTITLEMENTS" \
  --preserve-metadata=identifier,requirements "$APP" >/dev/null

# 4. Verify.
if ! /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "Signature verification failed. The app may be incomplete or damaged." >&2
  exit 1
fi

# 5. Clear only the browser quarantine flag. Preserve unrelated Finder and
# metadata attributes that may already belong to the installed bundle.
/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "Done. Sol is ready to launch from:"
echo "  $APP"
