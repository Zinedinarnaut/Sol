#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

capture_build_path() {
  local build_output
  if ! build_output="$("$1" 2>&1)"; then
    printf '%s\n' "$build_output" >&2
    return 1
  fi
  printf '%s\n' "$build_output" | tail -n 1
}

SOL_METAL_DIR="$(capture_build_path "$ROOT_DIR/script/build_sol_metal.sh")"
MANAGED_DIR="$(capture_build_path "$ROOT_DIR/script/build_sol_engine_managed.sh")"
TEMP_ROOT="$(mktemp -d -t sol-metal-bridge.XXXXXX)"
OUTPUT_FILE="$TEMP_ROOT/probe.log"
FAILURE_OUTPUT="$TEMP_ROOT/probe-failure.log"
ABI_MISMATCH_OUTPUT="$TEMP_ROOT/probe-abi-mismatch.log"
GAL_OUTPUT="$TEMP_ROOT/gal-smoke.log"
INPUT_OUTPUT="$TEMP_ROOT/input-smoke.log"

cleanup() {
  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    /bin/rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

SOL_METAL_LIBRARY_PATH="$SOL_METAL_DIR/SolMetal.dylib" \
  "$ROOT_DIR/.tools/dotnet/dotnet" \
    "$MANAGED_DIR/Sol.Engine.dll" \
    --native-solmetal-status \
    --root-data-dir "$TEMP_ROOT/data" >"$OUTPUT_FILE" 2>&1

if ! /usr/bin/grep -q '"event":"solmetal.status"' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"success":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"playable":false' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"testsPassed":15' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"spirvTranslationReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"bufferResourcesReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"textureResourcesReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"samplerResourcesReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"computePipelinesReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"renderPipelinesReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"renderBindingsReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"indexedDrawingReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"depthStencilReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"blendingReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"timelineSynchronizationReady":true' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -Eq '"shaderCacheHits":[1-9]' "$OUTPUT_FILE" ||
   ! /usr/bin/grep -q '"binaryArchivesCreated":1' "$OUTPUT_FILE"; then
  /bin/cat "$OUTPUT_FILE" >&2
  echo "Sol Engine did not report a passing, non-playable SolMetal probe." >&2
  exit 1
fi

if ! SOL_METAL_DIRECT_MUTATION_BATCHING=1 \
     SOL_METAL_LIBRARY_PATH="$SOL_METAL_DIR/SolMetal.dylib" \
       "$ROOT_DIR/.tools/dotnet/dotnet" \
         "$MANAGED_DIR/Sol.Engine.dll" \
         --native-solmetal-gal-smoke \
         --root-data-dir "$TEMP_ROOT/gal-data" >"$GAL_OUTPUT" 2>&1; then
  /bin/cat "$GAL_OUTPUT" >&2
  echo "Sol Engine's controlled SolMetal GAL smoke exited unsuccessfully." >&2
  exit 1
fi

if ! /usr/bin/grep -q '"event":"solmetal.gal-smoke"' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"success":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"playable":false' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"bufferResourcesReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"textureResourcesReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"samplerResourcesReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"spirvTranslationReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"computePipelinesReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"renderPipelinesReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"renderBindingsReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"indexedDrawingReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"depthStencilReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"blendingReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"rasterizerStateReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -q '"timelineSynchronizationReady":true' "$GAL_OUTPUT" ||
   ! /usr/bin/grep -Eq '"bytesVerified":[1-9][0-9]*' "$GAL_OUTPUT"; then
  /bin/cat "$GAL_OUTPUT" >&2
  echo "Sol Engine did not pass the controlled SolMetal GAL resource and draw smoke." >&2
  exit 1
fi

"$ROOT_DIR/.tools/dotnet/dotnet" \
  "$MANAGED_DIR/Sol.Engine.dll" \
  --native-input-bridge-smoke \
  --root-data-dir "$TEMP_ROOT/input-data" >"$INPUT_OUTPUT" 2>&1

if ! /usr/bin/grep -q '"event":"input.bridge-smoke"' "$INPUT_OUTPUT" ||
   ! /usr/bin/grep -q '"operation":"input-bridge-smoke"' "$INPUT_OUTPUT" ||
   ! /usr/bin/grep -q '"success":true' "$INPUT_OUTPUT" ||
   ! /usr/bin/grep -q '"count":6' "$INPUT_OUTPUT"; then
  /bin/cat "$INPUT_OUTPUT" >&2
  echo "Sol Engine did not preserve quick taps and release back to neutral." >&2
  exit 1
fi

# A missing or malformed experimental library must degrade into a structured
# non-playable result. It must never stop Sol Engine from starting.
SOL_METAL_LIBRARY_PATH="/usr/lib/libSystem.B.dylib" \
  "$ROOT_DIR/.tools/dotnet/dotnet" \
    "$MANAGED_DIR/Sol.Engine.dll" \
    --native-solmetal-status \
    --root-data-dir "$TEMP_ROOT/failure-data" >"$FAILURE_OUTPUT" 2>&1

if ! /usr/bin/grep -q '"event":"solmetal.status"' "$FAILURE_OUTPUT" ||
   ! /usr/bin/grep -q '"success":false' "$FAILURE_OUTPUT" ||
   ! /usr/bin/grep -q '"playable":false' "$FAILURE_OUTPUT"; then
  /bin/cat "$FAILURE_OUTPUT" >&2
  echo "Sol Engine did not contain a malformed SolMetal library safely." >&2
  exit 1
fi

# Version negotiation must happen before binding ABI-v2 exports. This stub
# intentionally exposes only the v1 version function; a safe loader rejects it
# as incompatible instead of failing halfway through symbol binding.
/usr/bin/clang -dynamiclib \
  "$ROOT_DIR/NativeHost/SolMetal/Validation/SolMetalAbiV1Stub.c" \
  -o "$TEMP_ROOT/SolMetalAbiV1.dylib"
SOL_METAL_LIBRARY_PATH="$TEMP_ROOT/SolMetalAbiV1.dylib" \
  "$ROOT_DIR/.tools/dotnet/dotnet" \
    "$MANAGED_DIR/Sol.Engine.dll" \
    --native-solmetal-status \
    --root-data-dir "$TEMP_ROOT/abi-mismatch-data" >"$ABI_MISMATCH_OUTPUT" 2>&1

if ! /usr/bin/grep -q '"event":"solmetal.status"' "$ABI_MISMATCH_OUTPUT" ||
   ! /usr/bin/grep -q '"success":false' "$ABI_MISMATCH_OUTPUT" ||
   ! /usr/bin/grep -q '"playable":false' "$ABI_MISMATCH_OUTPUT"; then
  /bin/cat "$ABI_MISMATCH_OUTPUT" >&2
  echo "Sol Engine did not reject an ABI-v1 SolMetal library safely." >&2
  exit 1
fi

echo "Sol Engine passed the ABI v2 probe, GAL resource smoke, keyboard edge latch, and malformed-library containment gate."
