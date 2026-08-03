#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET="$ROOT_DIR/.tools/dotnet/dotnet"
PROJECT="$ROOT_DIR/NativeHost/Sol.Engine/Sol.Engine.csproj"
OUTPUT_DIR="$ROOT_DIR/NativeHost/artifacts/engine"

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
  --output "$OUTPUT_DIR"

DEPENDENCY_REPORT="$(
  DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    "$DOTNET" list "$PROJECT" package --include-transitive --no-restore
)"
if /usr/bin/grep -Eiq 'Avalonia|FluentAvalonia|Projektanker' <<<"$DEPENDENCY_REPORT"; then
  echo "Sol Engine unexpectedly contains a desktop UI package." >&2
  exit 1
fi

UI_ARTIFACT="$(
  find "$OUTPUT_DIR" -maxdepth 1 -type f \
    \( -iname '*Avalonia*' -o -iname '*FluentAvalonia*' -o -iname '*Projektanker*' \) \
    -print -quit
)"
if [[ -n "$UI_ARTIFACT" ]]; then
  echo "Sol Engine contains an unexpected UI artifact: $UI_ARTIFACT" >&2
  exit 1
fi

if [[ ! -x "$OUTPUT_DIR/Sol.Engine" ]]; then
  echo "Sol Engine publish completed without producing an executable." >&2
  exit 1
fi

echo "$OUTPUT_DIR"
