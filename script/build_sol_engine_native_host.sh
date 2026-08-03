#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET="$ROOT_DIR/.tools/dotnet/dotnet"
PROJECT="$ROOT_DIR/NativeHost/Sol.Engine.NativeHost/Sol.Engine.NativeHost.csproj"
ARTIFACTS_DIR="$ROOT_DIR/NativeHost/artifacts/native-host"

if [[ ! -x "$DOTNET" ]]; then
  echo "Missing project-local .NET SDK at $DOTNET" >&2
  echo "Install the SDK version from Vendor/Ryubing/global.json first." >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/Vendor/Ryubing/.git" ]]; then
  "$ROOT_DIR/script/fetch_ryubing_source.sh"
fi

mkdir -p "$ARTIFACTS_DIR"

DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
  "$DOTNET" publish "$PROJECT" \
  --configuration Release \
  --runtime osx-arm64 \
  --output "$ARTIFACTS_DIR"

DYLIB="$(find "$ARTIFACTS_DIR" -maxdepth 1 -type f -name 'Sol.Engine.NativeHost.dylib' -print -quit)"
if [[ -z "$DYLIB" ]]; then
  echo "Native host build completed without producing a dylib" >&2
  exit 1
fi

echo "$DYLIB"
