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

echo "Re-signing and clearing quarantine for:"
echo "  $APP"
echo "This applies an ad-hoc signature to every binary inside Sol.app and removes"
echo "the Gatekeeper quarantine flag from it. No system settings are changed."
echo

depth_sort() { awk '{ d=gsub(/\//,"/"); print d "\t" $0 }' | sort -rn -k1,1 | cut -f2-; }

# 1. Standalone Mach-O files (deepest first).
find "$APP" -type f -print0 |
  while IFS= read -r -d '' f; do
    if /usr/bin/file -b "$f" 2>/dev/null | grep -q '^Mach-O'; then
      printf '%s\n' "$f"
    fi
  done |
  depth_sort |
  while IFS= read -r f; do
    /usr/bin/codesign --force --sign - --timestamp=none "$f" >/dev/null
  done

# 2. Nested code bundles (frameworks, appex), innermost first.
find "$APP" -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' \) \
  -not -path "$APP" -print0 |
  while IFS= read -r -d '' d; do printf '%s\n' "$d"; done |
  depth_sort |
  while IFS= read -r -d '' d; do
    /usr/bin/codesign --force --sign - --timestamp=none "$d" >/dev/null
  done

# 3. Outer app.
/usr/bin/codesign --force --sign - --timestamp=none \
  --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$APP" >/dev/null

# 4. Verify.
if ! /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "Signature verification failed. The app may be incomplete or damaged." >&2
  exit 1
fi

# 5. Clear quarantine (and any other extended attributes) recursively.
/usr/bin/xattr -cr "$APP"

echo "Done. Sol is ready to launch from:"
echo "  $APP"
