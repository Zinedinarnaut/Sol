#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Vendor/Ryubing"
UPSTREAM_URL="https://git.ryujinx.app/projects/Ryubing.git"
PINNED_COMMIT="a82350bb774f70fcbd41c9987bf67a3775409963"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone --filter=blob:none "$UPSTREAM_URL" "$SOURCE_DIR"
fi

git -C "$SOURCE_DIR" fetch --depth 1 origin "$PINNED_COMMIT"
git -C "$SOURCE_DIR" checkout --detach "$PINNED_COMMIT"

echo "Ryubing source ready at $SOURCE_DIR"
echo "Commit: $(git -C "$SOURCE_DIR" rev-parse HEAD)"
