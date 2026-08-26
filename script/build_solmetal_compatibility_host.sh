#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$ROOT_DIR/NativeHost/SolMetalCompatibilityHost/main.swift"
OUTPUT="${SOL_COMPATIBILITY_HOST_OUTPUT:-$ROOT_DIR/NativeHost/artifacts/compatibility-host/SolMetalCompatibilityHost}"
TESTING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "build_solmetal_compatibility_host: --output needs a path" >&2
        exit 2
      fi
      OUTPUT="$2"
      shift 2
      ;;
    --testing)
      TESTING=1
      shift
      ;;
    --help|-h)
      echo "usage: build_solmetal_compatibility_host.sh [--output PATH] [--testing]"
      exit 0
      ;;
    *)
      echo "build_solmetal_compatibility_host: unknown argument" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$SOURCE" ]]; then
  echo "build_solmetal_compatibility_host: host source is unavailable" >&2
  exit 1
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"
case "$ARCHITECTURE" in
  arm64|x86_64)
    ;;
  *)
    echo "build_solmetal_compatibility_host: unsupported macOS architecture" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$OUTPUT")"
SWIFT_FLAGS=(
  -parse-as-library
  -O
  -g
  -sdk "$SDK_PATH"
  -target "$ARCHITECTURE-apple-macos15.0"
  -framework AppKit
  -framework Metal
  -framework QuartzCore
)
if [[ "$TESTING" -eq 1 ]]; then
  SWIFT_FLAGS+=(-D SOL_COMPATIBILITY_HOST_TESTING)
fi

xcrun swiftc "${SWIFT_FLAGS[@]}" "$SOURCE" -o "$OUTPUT"
chmod 755 "$OUTPUT"
printf '%s\n' "$OUTPUT"
