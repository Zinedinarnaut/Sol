#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_DIR="$ROOT_DIR/Vendor/Ryubing"
REVISION_FILE="$SOURCE_DIR/SOL_UPSTREAM_COMMIT"
PINNED_COMMIT="a82350bb774f70fcbd41c9987bf67a3775409963"

required_paths=(
  "$SOURCE_DIR/LICENSE.txt"
  "$SOURCE_DIR/Directory.Build.props"
  "$SOURCE_DIR/global.json"
  "$SOURCE_DIR/src/ARMeilleure/ARMeilleure.csproj"
  "$SOURCE_DIR/src/Ryujinx.Common/Ryujinx.Common.csproj"
  "$SOURCE_DIR/src/Ryujinx.Graphics.Vulkan/MetalFxAttachmentDiscovery.cs"
  "$SOURCE_DIR/src/Ryujinx.Graphics.Vulkan/MetalFxPresentation.cs"
  "$SOURCE_DIR/src/Ryujinx.HLE/Ryujinx.HLE.csproj"
  "$SOURCE_DIR/src/Ryujinx/Headless/HeadlessRyujinx.cs"
)

for required_path in "${required_paths[@]}"; do
  if [[ ! -f "$required_path" ]]; then
    echo "Bundled Sol Engine source is incomplete: missing $required_path" >&2
    exit 1
  fi
done

if [[ ! -f "$REVISION_FILE" ]]; then
  echo "Bundled Sol Engine source is missing its upstream revision marker." >&2
  exit 1
fi

actual_commit="$(tr -d '[:space:]' < "$REVISION_FILE")"
if [[ "$actual_commit" != "$PINNED_COMMIT" ]]; then
  echo "Bundled Sol Engine revision mismatch: expected $PINNED_COMMIT, found $actual_commit" >&2
  exit 1
fi

if ! /usr/bin/grep -q 'Sol Engine Console' \
  "$SOURCE_DIR/src/Ryujinx/Headless/HeadlessRyujinx.cs"; then
  echo "Bundled Sol Engine source is missing the native runtime patch set." >&2
  exit 1
fi

if /usr/bin/grep -q 'using Avalonia.Media' \
  "$SOURCE_DIR/src/Ryujinx/Systems/Configuration/ConfigurationState.Migration.cs"; then
  echo "Bundled Sol Engine configuration still depends on Avalonia." >&2
  exit 1
fi

if [[ -d "$SOURCE_DIR/src/Ryujinx/UI" ]] || \
  find "$SOURCE_DIR" -type f -name '*.axaml' -print -quit | /usr/bin/grep -q .; then
  echo "Bundled Sol Engine source unexpectedly contains the upstream Avalonia UI." >&2
  exit 1
fi

echo "Bundled Sol Engine source verified at $PINNED_COMMIT"
