#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_FILE="$ROOT_DIR/Vendor/Ryubing/src/Ryujinx/Systems/Configuration/ConfigurationState.Migration.cs"
SOURCE_ROOT="$ROOT_DIR/Vendor/Ryubing"
PATCHES=(
  "$ROOT_DIR/script/patches/upstream-stop-stability.patch"
  "$ROOT_DIR/script/patches/native-headless-dialogs.patch"
  "$ROOT_DIR/script/patches/native-headless-profile-bootstrap.patch"
  "$ROOT_DIR/script/patches/native-embedded-runtime.patch"
  "$ROOT_DIR/script/patches/native-headless-multiplayer.patch"
  "$ROOT_DIR/script/patches/dlsm-native-metal.patch"
)

if [[ ! -f "$MIGRATION_FILE" ]]; then
  echo "Missing Ryubing configuration source at $MIGRATION_FILE" >&2
  exit 1
fi

# The upstream configuration migration used Avalonia's Color struct for one
# compile-time ARGB constant. Replace that UI-framework type with the identical
# packed value so the native engine source has no Avalonia reference at all.
perl -0pi -e 's/\\s*using Avalonia\\.Media;\\n/\\n/' "$MIGRATION_FILE"
perl -0pi -e 's/new Color\\(255, 5, 1, 253\\)\\.ToUInt32\\(\\)/0xFF0501FDu/g' "$MIGRATION_FILE"

for patch in "${PATCHES[@]}"; do
  if git -C "$SOURCE_ROOT" apply --check "$patch" >/dev/null 2>&1; then
    git -C "$SOURCE_ROOT" apply "$patch"
  elif ! git -C "$SOURCE_ROOT" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "Native patch no longer applies cleanly: $patch" >&2
    exit 1
  fi
done
