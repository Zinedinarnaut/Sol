#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

capture_build_path() {
  local build_output
  if ! build_output="$("$ROOT_DIR/script/build_sol_metal.sh" 2>&1)"; then
    printf '%s\n' "$build_output" >&2
    return 1
  fi
  printf '%s\n' "$build_output" | tail -n 1
}

SOL_METAL_CONFIGURATION=Release
SOL_METAL_SANITIZE=none
export SOL_METAL_CONFIGURATION SOL_METAL_SANITIZE
RELEASE_DIR="$(capture_build_path)"
DYLIB="$RELEASE_DIR/SolMetal.dylib"
VALIDATION="$RELEASE_DIR/SolMetalValidation"

if [[ ! -f "$DYLIB" ]]; then
  echo "Missing SolMetal library: $DYLIB" >&2
  exit 1
fi
if [[ ! -x "$VALIDATION" ]]; then
  echo "Missing SolMetal validation executable: $VALIDATION" >&2
  exit 1
fi

if /usr/bin/otool -L "$DYLIB" | /usr/bin/grep -Eiq 'MoltenVK|Vulkan'; then
  echo "SolMetal must not link MoltenVK or Vulkan." >&2
  exit 1
fi

REQUIRED_EXPORTS=(
  _sol_metal_abi_version
  _sol_metal_query_capabilities
  _sol_metal_context_create
  _sol_metal_context_destroy
  _sol_metal_context_copy_last_error
  _sol_metal_context_query_capabilities
  _sol_metal_context_run_validation
  _sol_metal_context_translate_spirv
  _sol_metal_shader_translation_destroy
  _sol_metal_shader_translation_copy_msl
  _sol_metal_context_buffer_create
  _sol_metal_buffer_destroy
  _sol_metal_context_buffer_upload
  _sol_metal_context_buffer_download
  _sol_metal_context_buffer_copy
  _sol_metal_context_buffer_fill_u32
  _sol_metal_context_buffer_expand_quad_indices
  _sol_metal_context_texture_create_2d
  _sol_metal_context_texture_create_buffer_view
  _sol_metal_context_texture_create_view_2d
  _sol_metal_texture_destroy
  _sol_metal_context_texture_upload_2d
  _sol_metal_context_texture_download_2d
  _sol_metal_context_texture_probe_download_depth32_2d
  _sol_metal_context_texture_download_depth_stencil_subresource_2d
  _sol_metal_context_texture_copy_to_buffer
  _sol_metal_context_texture_copy_2d
  _sol_metal_context_texture_copy_subresource_2d
  _sol_metal_context_texture_copy_r32float_to_depth32_subresource_2d
  _sol_metal_context_texture_clear_color
  _sol_metal_context_texture_clear_depth_stencil
  _sol_metal_context_texture_blit_2d
  _sol_metal_context_sampler_create
  _sol_metal_sampler_destroy
  _sol_metal_context_compute_pipeline_create
  _sol_metal_compute_pipeline_destroy
  _sol_metal_compute_pipeline_query_info
  _sol_metal_context_compute_dispatch
  _sol_metal_context_render_pipeline_create
  _sol_metal_context_render_pipeline_create_with_vertex_layout
  _sol_metal_context_render_pipeline_create_advanced
  _sol_metal_render_pipeline_destroy
  _sol_metal_context_render_draw
  _sol_metal_context_render_draw_bound
  _sol_metal_context_render_draw_indexed_bound
  _sol_metal_context_render_draw_advanced
  _sol_metal_context_render_draw_rasterized
  _sol_metal_context_render_draw_mrt_rasterized_indirect
  _sol_metal_context_render_draw_mrt_rasterized_indirect_count
  _sol_metal_context_render_draw_mrt_rasterized_query
  _sol_metal_context_memory_barrier
  _sol_metal_context_visibility_query_create
  _sol_metal_context_visibility_query_resolve
  _sol_metal_visibility_query_destroy
  _sol_metal_context_timeline_submit
  _sol_metal_context_timeline_query
  _sol_metal_context_runtime_batch_query
  _sol_metal_context_timeline_wait
  _sol_metal_context_wait_idle
  _sol_metal_context_present_clear
  _sol_metal_context_present_texture
)

EXPORTED_SYMBOLS="$(/usr/bin/nm -gU "$DYLIB")"
for symbol in "${REQUIRED_EXPORTS[@]}"; do
  if ! /usr/bin/grep -q " $symbol$" <<<"$EXPORTED_SYMBOLS"; then
    echo "SolMetal is missing required export $symbol" >&2
    exit 1
  fi
done

"$VALIDATION" \
  --contexts 4 \
  --iterations 1 \
  --max-growth-mib 384 \
  --shared-context-threads 8 \
  --present \
  --json

# Direct-mutation borrowing remains an explicit runtime experiment. Exercise
# the shared-command-buffer path, both budget fallbacks, and fail-closed
# callback handling with deliberately small but usable limits.
if "$VALIDATION" \
    --contexts 1 \
    --iterations 1 \
    --render-pipeline-api-only \
    --require-direct-mutation-batching \
    --max-growth-mib 384 \
    --json >/dev/null 2>&1; then
  echo "Direct mutation batching must remain disabled without its exact opt-in flag." >&2
  exit 1
fi
SOL_METAL_DIRECT_MUTATION_BATCHING=1 \
SOL_METAL_DIRECT_MUTATION_MAX_ENCODERS=6 \
SOL_METAL_DIRECT_MUTATION_MAX_TRANSIENT_BYTES=65536 \
  "$VALIDATION" \
    --contexts 1 \
    --iterations 1 \
    --render-pipeline-api-only \
    --require-direct-mutation-batching \
    --max-growth-mib 384 \
    --json

# TOTK's cave path combines early fragment tests with both invocation discard
# and fragment-stage storage writes on a guest D16 target. Exercise the exact
# D16-on-D32 compatibility branch explicitly; the default validation process
# does not enable this runtime mode.
SOL_METAL_D16_BACKING_D32=1 \
  "$VALIDATION" \
    --contexts 1 \
    --iterations 1 \
    --render-only \
    --max-growth-mib 384 \
    --json

"$VALIDATION" \
  --contexts 48 \
  --iterations 2 \
  --max-growth-mib 256 \
  --json

SOL_METAL_CONFIGURATION=Debug
SOL_METAL_SANITIZE=address
export SOL_METAL_CONFIGURATION SOL_METAL_SANITIZE
ASAN_DIR="$(capture_build_path)"
# LeakSanitizer is not supported on macOS. AddressSanitizer still catches
# use-after-free, out-of-bounds access, double-free, and allocator corruption;
# ownership leaks are checked separately with Apple's leaks tool below.
ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:check_initialization_order=1" \
  "$ASAN_DIR/SolMetalValidation" \
    --contexts 4 \
    --iterations 1 \
    --max-growth-mib 512 \
    --json

SOL_METAL_CONFIGURATION=Debug
SOL_METAL_SANITIZE=undefined
export SOL_METAL_CONFIGURATION SOL_METAL_SANITIZE
UBSAN_DIR="$(capture_build_path)"
UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
  "$UBSAN_DIR/SolMetalValidation" \
    --contexts 4 \
    --iterations 1 \
    --shared-context-threads 8 \
    --max-growth-mib 512 \
    --json

LEAKS_OUTPUT="$(mktemp -t sol-metal-leaks.XXXXXX)"
trap '/bin/rm -f "$LEAKS_OUTPUT"' EXIT
if ! MallocStackLogging=1 /usr/bin/leaks --quiet --atExit -- \
    "$VALIDATION" \
      --contexts 8 \
      --iterations 2 \
      --max-growth-mib 512 \
      --json >"$LEAKS_OUTPUT" 2>&1; then
  /bin/cat "$LEAKS_OUTPUT" >&2
  exit 1
fi
if /usr/bin/grep -Eq '[1-9][0-9]* leaks? for ' "$LEAKS_OUTPUT"; then
  /bin/cat "$LEAKS_OUTPUT" >&2
  exit 1
fi

echo "SolMetal validation gates passed."
