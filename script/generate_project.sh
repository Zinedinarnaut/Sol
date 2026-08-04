#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCAL_XCODEGEN="$ROOT_DIR/.tools/XcodeGen/.build/release/xcodegen"

if command -v xcodegen >/dev/null 2>&1; then
  XCODEGEN="$(command -v xcodegen)"
elif [[ -x "$LOCAL_XCODEGEN" ]]; then
  XCODEGEN="$LOCAL_XCODEGEN"
else
  echo "XcodeGen is not installed." >&2
  echo "Install it with Homebrew or build it under .tools/XcodeGen." >&2
  exit 1
fi

"$XCODEGEN" generate --spec "$ROOT_DIR/project.yml"
