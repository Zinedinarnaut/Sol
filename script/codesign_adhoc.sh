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

APP="${1:-}"
if [ -z "$APP" ]; then echo "usage: $0 <Sol.app>" >&2; exit 2; fi
if [ ! -d "$APP" ]; then echo "no such bundle: $APP" >&2; exit 2; fi
APP="$(cd "$APP" && pwd -P)"
case "$(basename "$APP")" in
  *.app) ;;
  *) echo "$APP is not an .app bundle" >&2; exit 2 ;;
esac

# sort paths deepest-first (by '/' count) so inner code is signed before outer
depth_sort() { awk '{ d=gsub(/\//,"/"); print d "\t" $0 }' | sort -rn -k1,1 | cut -f2-; }

# 1. Standalone Mach-O files (loose dylibs/executables under Resources, etc.).
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
  while IFS= read -r d; do
    /usr/bin/codesign --force --sign - --timestamp=none "$d" >/dev/null
  done

# 3. Outer app, preserving entitlements/requirements/runtime flags.
/usr/bin/codesign --force --sign - --timestamp=none \
  --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$APP" >/dev/null

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
