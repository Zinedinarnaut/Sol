#!/usr/bin/env bash
# Deep ad-hoc sign a Sol app bundle.
#
# Sol ships without an Apple Developer identity, so releases are ad-hoc signed.
# Hardened Runtime library validation rejects a mix of signatures (Microsoft's
# .NET runtime, the bundled Sol Engine dylibs, the appex extensions), so every
# Mach-O and nested code bundle is re-sealed with a single ad-hoc identity ("-"),
# innermost-first, and the result is verified.
#
# Usage: codesign_adhoc.sh <Sol.app>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PUBLIC_ENTITLEMENTS="${SOL_PUBLIC_ENTITLEMENTS:-$SCRIPT_DIR/../SolPublic.entitlements}"
APP="${1:-}"
if [ -z "$APP" ]; then echo "usage: $0 <Sol.app>" >&2; exit 2; fi
if [ ! -d "$APP" ]; then echo "no such bundle: $APP" >&2; exit 2; fi
APP="$(cd "$APP" && pwd -P)"
case "$(basename "$APP")" in
  *.app) ;;
  *) echo "$APP is not an .app bundle" >&2; exit 2 ;;
esac
if ! /usr/bin/plutil -lint "$PUBLIC_ENTITLEMENTS" >/dev/null 2>&1; then
  echo "invalid public entitlement file: $PUBLIC_ENTITLEMENTS" >&2
  exit 2
fi

# 1. Standalone Mach-O files (loose dylibs/executables under Resources, etc.).
find "$APP" -type f -print0 |
  while IFS= read -r -d '' f; do
    # Signing a bundle's main executable path asks codesign to validate the
    # enclosing bundle. If a nested extension is intentionally damaged, that
    # makes the outer executable fail before the extension can be repaired.
    # Bundle signing below seals these executables in the correct order.
    case "$f" in
      */Contents/MacOS/*) continue ;;
    esac
    if /usr/bin/file -b "$f" 2>/dev/null | grep -q '^Mach-O'; then
      /usr/bin/codesign --force --sign - --timestamp=none "$f" >/dev/null
    fi
  done

# 2. Nested code bundles (frameworks, appex), innermost first. `find -depth`
# keeps the stream NUL-delimited while guaranteeing children precede parents.
find "$APP" -depth -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' \) \
  -not -path "$APP" -print0 |
  while IFS= read -r -d '' d; do
    /usr/bin/codesign --force --deep --sign - --timestamp=none \
      --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
      "$d" >/dev/null
  done

# 3. Seal the public app with Hardened Runtime and only the exceptions the
# bundled CPU JIT and managed runtime need. Provisioned Apple-service
# entitlements must never be copied into an ad-hoc public build.
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  --options runtime \
  --entitlements "$PUBLIC_ENTITLEMENTS" \
  --preserve-metadata=identifier,requirements "$APP" >/dev/null

# 4. Verify the whole tree, deep + strict.
VERIFY_LOG="$(mktemp -t codesign-adhoc.XXXXXX)"
trap 'rm -f "$VERIFY_LOG"' EXIT
if /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" >"$VERIFY_LOG" 2>&1; then
  tail -n 2 "$VERIFY_LOG"
  echo "ad-hoc signed: $APP"
else
  cat "$VERIFY_LOG" >&2
  echo "verification failed for $APP" >&2
  exit 1
fi
