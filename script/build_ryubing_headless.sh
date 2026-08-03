#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Vendor/Ryubing"
DOTNET="$ROOT_DIR/.tools/dotnet/dotnet"
PROJECT="$SOURCE_DIR/src/Ryujinx/Ryujinx.csproj"
OUTPUT_DIR="$SOURCE_DIR/build-native-headless"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  "$ROOT_DIR/script/fetch_ryubing_source.sh"
fi

if [[ ! -x "$DOTNET" ]]; then
  echo "Missing the project-local .NET SDK." >&2
  echo "Run $ROOT_DIR/script/install_dotnet_sdk.sh first." >&2
  exit 1
fi

DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
  "$DOTNET" publish "$PROJECT" \
  --configuration Release \
  --runtime osx-arm64 \
  --self-contained true \
  --output "$OUTPUT_DIR"

if [[ ! -x "$OUTPUT_DIR/Ryujinx" ]]; then
  echo "Ryubing publish completed without producing an executable." >&2
  exit 1
fi

echo "$OUTPUT_DIR"
