#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET="$ROOT_DIR/.tools/dotnet/dotnet"
PROJECT="$ROOT_DIR/NativeHost/Sol.Engine/Sol.Engine.csproj"
OUTPUT_DIR="$ROOT_DIR/NativeHost/artifacts/managed"

if [[ ! -x "$DOTNET" ]]; then
  echo "Missing the project-local .NET SDK." >&2
  echo "Run $ROOT_DIR/script/install_dotnet_sdk.sh first." >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/Vendor/Ryubing/.git" ]]; then
  "$ROOT_DIR/script/fetch_ryubing_source.sh"
fi

"$ROOT_DIR/script/prepare_native_ryubing_source.sh"

DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
  "$DOTNET" publish "$PROJECT" \
  --configuration Release \
  --runtime osx-arm64 \
  --self-contained false \
  -p:PublishSingleFile=false \
  -p:UseAppHost=false \
  --output "$OUTPUT_DIR"

PATCHED_SDL="$("$ROOT_DIR/script/build_patched_sdl.sh")"
cp "$PATCHED_SDL" "$OUTPUT_DIR/libSDL3.dylib"

for required in Sol.Engine.dll Sol.Engine.deps.json Sol.Engine.runtimeconfig.json libSDL3.dylib libMoltenVK.dylib; do
  if [[ ! -f "$OUTPUT_DIR/$required" ]]; then
    echo "Sol Engine managed component is missing $required." >&2
    exit 1
  fi
done

if find "$OUTPUT_DIR" -maxdepth 1 -type f \
  \( -iname '*Avalonia*' -o -iname '*FluentAvalonia*' -o -iname '*Projektanker*' \) \
  -print -quit | /usr/bin/grep -q .; then
  echo "Sol Engine managed component unexpectedly contains a desktop UI artifact." >&2
  exit 1
fi

echo "$OUTPUT_DIR"
