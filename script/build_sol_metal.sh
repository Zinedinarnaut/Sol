#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONFIGURATION="${SOL_METAL_CONFIGURATION:-Release}"
SANITIZER="${SOL_METAL_SANITIZE:-none}"

case "$CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "SOL_METAL_CONFIGURATION must be Debug or Release." >&2
    exit 2
    ;;
esac

case "$SANITIZER" in
  none|address|undefined)
    ;;
  *)
    echo "SOL_METAL_SANITIZE must be none, address, or undefined." >&2
    exit 2
    ;;
esac

OUTPUT_NAME="sol-metal"
if [[ "$CONFIGURATION" == "Debug" ]]; then
  OUTPUT_NAME+="-debug"
fi
if [[ "$SANITIZER" != "none" ]]; then
  OUTPUT_NAME+="-$SANITIZER"
fi

OUTPUT_DIR="$ROOT_DIR/NativeHost/artifacts/$OUTPUT_NAME"
DYLIB="$OUTPUT_DIR/SolMetal.dylib"
VALIDATION="$OUTPUT_DIR/SolMetalValidation"
SOURCE="$ROOT_DIR/NativeHost/SolMetal/SolMetal.mm"
VALIDATION_SOURCE="$ROOT_DIR/NativeHost/SolMetal/Validation/SolMetalValidation.mm"
INCLUDE_DIR="$ROOT_DIR/NativeHost/SolMetal/include"
SPIRV_CROSS_DIR="$ROOT_DIR/ThirdParty/SPIRV-Cross"
SPIRV_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalAdd.spv"
SPIRV_VERTEX_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalTriangle.vert.spv"
SPIRV_FRAGMENT_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalTriangle.frag.spv"
SPIRV_TEXTURE_SAMPLE_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalTextureSample.spv"
SPIRV_BOUND_VERTEX_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalBoundTriangle.vert.spv"
SPIRV_BOUND_FRAGMENT_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalBoundTriangle.frag.spv"
SPIRV_ARRAY_MIP_FRAGMENT_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalArrayMipSample.frag.spv"
SPIRV_COORDINATE_CHAIN_VERTEX_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalCoordinateChain.vert.spv"
SPIRV_COORDINATE_CHAIN_VOLUME_FRAGMENT_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalCoordinateChainVolume.frag.spv"
SPIRV_COORDINATE_CHAIN_SAMPLE_FRAGMENT_FIXTURE="$ROOT_DIR/NativeHost/SolMetal/Validation/Fixtures/SolMetalCoordinateChainSample.frag.spv"
OBJECT_DIR="$OUTPUT_DIR/objects"

mkdir -p "$OUTPUT_DIR" "$OBJECT_DIR"
/bin/rm -f "$DYLIB" "$VALIDATION"

/usr/bin/xxd \
  -i \
  -n sol_metal_add_spirv \
  "$SPIRV_FIXTURE" \
  "$OUTPUT_DIR/SolMetalAddSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_triangle_vertex_spirv \
  "$SPIRV_VERTEX_FIXTURE" \
  "$OUTPUT_DIR/SolMetalTriangleVertexSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_triangle_fragment_spirv \
  "$SPIRV_FRAGMENT_FIXTURE" \
  "$OUTPUT_DIR/SolMetalTriangleFragmentSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_texture_sample_spirv \
  "$SPIRV_TEXTURE_SAMPLE_FIXTURE" \
  "$OUTPUT_DIR/SolMetalTextureSampleSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_bound_triangle_vertex_spirv \
  "$SPIRV_BOUND_VERTEX_FIXTURE" \
  "$OUTPUT_DIR/SolMetalBoundTriangleVertexSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_bound_triangle_fragment_spirv \
  "$SPIRV_BOUND_FRAGMENT_FIXTURE" \
  "$OUTPUT_DIR/SolMetalBoundTriangleFragmentSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_array_mip_fragment_spirv \
  "$SPIRV_ARRAY_MIP_FRAGMENT_FIXTURE" \
  "$OUTPUT_DIR/SolMetalArrayMipFragmentSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_coordinate_chain_vertex_spirv \
  "$SPIRV_COORDINATE_CHAIN_VERTEX_FIXTURE" \
  "$OUTPUT_DIR/SolMetalCoordinateChainVertexSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_coordinate_chain_volume_fragment_spirv \
  "$SPIRV_COORDINATE_CHAIN_VOLUME_FRAGMENT_FIXTURE" \
  "$OUTPUT_DIR/SolMetalCoordinateChainVolumeFragmentSpirv.inc"
/usr/bin/xxd \
  -i \
  -n sol_metal_coordinate_chain_sample_fragment_spirv \
  "$SPIRV_COORDINATE_CHAIN_SAMPLE_FRAGMENT_FIXTURE" \
  "$OUTPUT_DIR/SolMetalCoordinateChainSampleFragmentSpirv.inc"

BASE_FLAGS=(
  -std=c++20
  -fvisibility=hidden
  -mmacosx-version-min=15.0
  -I"$INCLUDE_DIR"
  -I"$SPIRV_CROSS_DIR"
  -I"$OUTPUT_DIR"
)

if [[ "$CONFIGURATION" == "Debug" ]]; then
  BASE_FLAGS+=(-O0 -g -DSOL_METAL_DEBUG=1)
else
  BASE_FLAGS+=(-O2 -DNDEBUG)
fi

if [[ "$SANITIZER" != "none" ]]; then
  BASE_FLAGS+=("-fsanitize=$SANITIZER" -fno-omit-frame-pointer)
fi

SOL_FLAGS=(
  "${BASE_FLAGS[@]}"
  -fobjc-arc
  -fmodules
  -Wall
  -Wextra
  -Werror
)

THIRD_PARTY_FLAGS=(
  "${BASE_FLAGS[@]}"
  -Wno-deprecated-declarations
  -Wno-deprecated-this-capture
)

FRAMEWORKS=(
  -framework Foundation
  -framework Metal
  -framework QuartzCore
)

SPIRV_CROSS_SOURCES=(
  "$SPIRV_CROSS_DIR/spirv_cross.cpp"
  "$SPIRV_CROSS_DIR/spirv_parser.cpp"
  "$SPIRV_CROSS_DIR/spirv_cross_parsed_ir.cpp"
  "$SPIRV_CROSS_DIR/spirv_cfg.cpp"
  "$SPIRV_CROSS_DIR/spirv_glsl.cpp"
  "$SPIRV_CROSS_DIR/spirv_msl.cpp"
)

OBJECTS=()
for third_party_source in "${SPIRV_CROSS_SOURCES[@]}"; do
  object="$OBJECT_DIR/$(basename "${third_party_source%.cpp}").o"
  xcrun clang++ \
    "${THIRD_PARTY_FLAGS[@]}" \
    -c "$third_party_source" \
    -o "$object"
  OBJECTS+=("$object")
done

SOL_OBJECT="$OBJECT_DIR/SolMetal.o"
xcrun clang++ \
  "${SOL_FLAGS[@]}" \
  -c "$SOURCE" \
  -o "$SOL_OBJECT"
OBJECTS+=("$SOL_OBJECT")

xcrun clang++ \
  "${BASE_FLAGS[@]}" \
  -dynamiclib \
  "${OBJECTS[@]}" \
  "${FRAMEWORKS[@]}" \
  -install_name @rpath/SolMetal.dylib \
  -o "$DYLIB"

xcrun clang++ \
  "${SOL_FLAGS[@]}" \
  "$VALIDATION_SOURCE" \
  "$DYLIB" \
  "${FRAMEWORKS[@]}" \
  -framework AppKit \
  -Wl,-rpath,@executable_path \
  -o "$VALIDATION"

if [[ "$(/usr/bin/uname -m)" == "arm64" ]] &&
   ! /usr/bin/file -b "$DYLIB" | /usr/bin/grep -q "arm64"; then
  echo "SolMetal was not built for Apple Silicon." >&2
  exit 1
fi

echo "$OUTPUT_DIR"
