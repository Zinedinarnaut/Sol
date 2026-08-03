#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDL_COMMIT="5403934fd30e3568b1e20f652d4823c796739722"
SOURCE_DIR="$ROOT_DIR/.tools/SDL-$SDL_COMMIT"
DERIVED_DATA="$ROOT_DIR/.tools/SDL-$SDL_COMMIT-derived"
OUTPUT_DIR="$ROOT_DIR/NativeHost/artifacts/sdl"
OUTPUT_LIBRARY="$OUTPUT_DIR/libSDL3.dylib"
PATCH_FILE="$ROOT_DIR/script/patches/sdl-external-cocoa-view.patch"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone --filter=blob:none https://github.com/libsdl-org/SDL.git "$SOURCE_DIR" >&2
  git -C "$SOURCE_DIR" checkout --detach "$SDL_COMMIT" >&2
fi

if [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$SDL_COMMIT" ]]; then
  echo "Cached SDL source is not at the pinned commit $SDL_COMMIT." >&2
  exit 1
fi

if git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  git -C "$SOURCE_DIR" apply "$PATCH_FILE"
elif ! git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "The external-Cocoa-view SDL patch no longer applies cleanly." >&2
  exit 1
fi

xcodebuild \
  -quiet \
  -project "$SOURCE_DIR/Xcode/SDL/SDL.xcodeproj" \
  -scheme SDL3 \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS,arch=arm64" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=11.0 \
  CODE_SIGNING_ALLOWED=NO \
  build >&2

BUILT_LIBRARY="$DERIVED_DATA/Build/Products/Release/SDL3.framework/Versions/A/SDL3"
if [[ ! -f "$BUILT_LIBRARY" ]]; then
  echo "The patched SDL build did not produce $BUILT_LIBRARY." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$BUILT_LIBRARY" "$OUTPUT_LIBRARY"
install_name_tool -id "@rpath/libSDL3.0.dylib" "$OUTPUT_LIBRARY"

echo "$OUTPUT_LIBRARY"
