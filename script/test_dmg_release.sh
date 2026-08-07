#!/usr/bin/env bash
# Integration tests for the ad-hoc DMG release.
#
# Verifies a built Sol DMG: it is a valid UDIF image, it mounts, it contains a
# deep ad-hoc-signed Sol.app with the engine/.NET/extensions intact, and
# dmg-signing.sh clears a simulated quarantine flag and re-verifies.
#
# Usage: test_dmg_release.sh [path/to/Sol-*.dmg]
#   If no DMG is given, one is built with build_dmg.sh (set SOL_DMG_APP to reuse
#   an existing Sol.app, otherwise a Release app is built).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DMG="${1:-}"
PASS=0
FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { # check <description> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
targets_macos_15() {
  local app="$1"
  local plist_min
  local macho_min
  plist_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "$app/Contents/Info.plist" 2>/dev/null)"
  macho_min="$(/usr/bin/vtool -show-build "$app/Contents/MacOS/Sol" 2>/dev/null |
    /usr/bin/awk '$1 == "minos" { print $2; exit }')"
  [ "$plist_min" = "15.0" ] && [ "$macho_min" = "15.0" ]
}

# Build a DMG if one was not supplied.
if [ -z "$DMG" ]; then
  DMG="$("$ROOT_DIR/script/build_dmg.sh" | sed -nE 's/^==> DMG:  //p')"
fi
if [ ! -f "$DMG" ]; then
  echo "no DMG to test: $DMG" >&2
  exit 2
fi
echo "Testing: $DMG"

# 1. Image validity.
check "DMG exists"                 test -f "$DMG"
check "sha256 sidecar exists"      test -f "$DMG.sha256"
check "checksum matches sidecar"   sh -c '
  expected="$(tr -d "[:space:]" < "$2")"
  actual="$(shasum -a 256 "$1")"
  actual="${actual%% *}"
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
' sh "$DMG" "$DMG.sha256"
check "image verifies (checksum)"  hdiutil verify "$DMG"
fmt="$(hdiutil imageinfo "$DMG" | sed -nE 's/^Format: //p' | head -n1)"
if [ "$fmt" = "UDZO" ]; then ok "format is UDZO ($fmt)"; else fail "format is UDZO (got '$fmt')"; fi

# 2. Mount and inspect contents.
MOUNT="$(mktemp -d -t sol-dmg-test.XXXXXX)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
APP="$MOUNT/Sol.app"

check "Sol.app present on volume"        test -d "$APP"
check "/Applications symlink present"    test -L "$MOUNT/Applications"
check "app launch symlink resolves"      test -e "$MOUNT/Applications"

if [ -d "$APP" ]; then
  check "outer app signature verifies"        /usr/bin/codesign --verify --deep --strict "$APP"
  sig="$(/usr/bin/codesign -dvv "$APP" 2>&1 | sed -nE 's/^Signature=(.*)$/\1/p')"
  if [ "$sig" = "adhoc" ]; then ok "outer app is ad-hoc signed"; else fail "outer app is ad-hoc signed (got '$sig')"; fi
  check "Hardened Runtime is enabled" sh -c '
    /usr/bin/codesign -dvv "$1" 2>&1 | /usr/bin/grep -q "flags=.*runtime"
  ' sh "$APP"
  for entitlement in \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation; do
    check "$entitlement is present" sh -c '
      /usr/bin/codesign -d --entitlements :- "$1" 2>/dev/null |
        /usr/bin/grep -q "<key>$2</key>"
    ' sh "$APP" "$entitlement"
  done
  check "provisioned Apple services are omitted" sh -c '
    ! /usr/bin/codesign -d --entitlements :- "$1" 2>/dev/null |
      /usr/bin/grep -Eq "developer.applesignin|developer.ubiquity|application-groups"
  ' sh "$APP"
  check "main executable targets macOS 15" targets_macos_15 "$APP"

  check "engine native present"      test -e "$APP/Contents/Resources/SolEngine/Sol.Engine"
  check "engine managed present"     test -f "$APP/Contents/Resources/SolEngineManaged/Sol.Engine.dll"
  check ".NET runtime present"       test -f "$APP/Contents/Resources/Dotnet/shared/Microsoft.NETCore.App/10.0.9/libcoreclr.dylib"
  check "NativeHost dylib present"   test -f "$APP/Contents/Frameworks/Sol.Engine.NativeHost.dylib"
  for ext in SolWidgets SolQuickLook SolShare; do
    check "$ext extension present" test -d "$APP/Contents/PlugIns/$ext.appex"
  done
fi

# 3. dmg-signing.sh clears simulated quarantine and re-verifies.
if [ -d "$APP" ]; then
  SCRATCH="$(mktemp -d -t sol-sign-scratch.XXXXXX)"
  cp -R "$APP" "$SCRATCH/"
  SCRATCH_APP="$SCRATCH/Sol.app"
  # simulate a browser download quarantine flag (top-level + a nested file)
  /usr/bin/xattr -w com.apple.quarantine "0081;5f000000;Safari;com.apple.Safari" "$SCRATCH_APP"
  /usr/bin/xattr -w com.apple.quarantine "0081;5f000000;Safari;com.apple.Safari" \
    "$SCRATCH_APP/Contents/Resources/SolEngine/Sol.Engine"
  # Remove one nested signature so the helper has to repair the full bundle
  # hierarchy; simply checking the already-signed copy would miss traversal
  # regressions.
  /usr/bin/codesign --remove-signature \
    "$SCRATCH_APP/Contents/PlugIns/SolWidgets.appex" >/dev/null 2>&1 || true

  if "$ROOT_DIR/script/dmg-signing.sh" "$SCRATCH_APP" >/dev/null 2>&1; then
    ok "dmg-signing.sh runs"
  else
    fail "dmg-signing.sh runs"
  fi
  check "quarantine cleared on bundle"      sh -c "! /usr/bin/xattr -p com.apple.quarantine '$SCRATCH_APP' >/dev/null 2>&1"
  check "quarantine cleared on nested code" sh -c '
    ! /usr/bin/xattr -p com.apple.quarantine "$1" >/dev/null 2>&1
  ' sh "$SCRATCH_APP/Contents/Resources/SolEngine/Sol.Engine"
  check "nested extension was re-signed"     /usr/bin/codesign --verify --strict "$SCRATCH_APP/Contents/PlugIns/SolWidgets.appex"
  check "app still verifies after resign"   /usr/bin/codesign --verify --deep --strict "$SCRATCH_APP"
  check "runtime entitlements survive resign" sh -c '
    /usr/bin/codesign -d --entitlements :- "$1" 2>/dev/null |
      /usr/bin/grep -q "<key>com.apple.security.cs.allow-jit</key>"
  ' sh "$SCRATCH_APP"
  rm -rf "$SCRATCH"
fi

hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
rmdir "$MOUNT" 2>/dev/null || true

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
