# Sol Temporal Model Research

This document defines the boundary for investigating a custom Sol-trained
Temporal model without coupling model experiments to the emulator core or the
SwiftUI application.

## First model job

The first model should improve the existing motion reconstruction provider,
not attempt to replace MetalFX upscaling. It receives:

- current and previous low-resolution color or luminance;
- optional validated native depth;
- frame delta, render jitter, and discontinuity state when available.

It produces the same textures already consumed by `DLSMProcessor`:

- `RG16Float` current-to-previous motion in input-pixel units;
- `R8Unorm` confidence/reactive coverage;
- optional `R32Float` normalized depth or disocclusion guidance.

Keeping this contract stable means the current block matcher, a Core ML model,
or an MPSGraph/Metal implementation can be swapped without changing the native
frame ABI or presentation layer.

## Apple-native execution finding

The installed macOS 26 SDK exposes a practical GPU-native prototype path:

- `MPSImage` can wrap the existing `MTLTexture`, and
  `MPSGraphTensorData` accepts an `MPSImageBatch`;
- MPSGraph can encode through a supplied Metal command queue or command buffer,
  so inference can stay ordered with reconstruction and MetalFX;
- the newer `MTLTensor` to MPSGraph bridge can alias machine-learning storage,
  but it requires macOS 16 and therefore cannot be the only path while Sol's
  deployment target remains macOS 15;
- Core ML accepts pixel-buffer and multi-array inputs, but the current
  MoltenVK swapchain is not guaranteed to be IOSurface-backed. Core ML remains
  a benchmark candidate until a no-readback texture boundary is proven.

MPSGraph remains useful for larger experiments, but the first production
candidate is small enough that a fused Metal implementation is the simpler
and faster runtime. It reads the existing `MTLTexture`, executes on Sol's Metal
command buffer, and writes the canonical MetalFX textures without CPU image
readback or cross-device copies.

## Implemented model shape

The bundled `sol-flow-reactive-2x3x3-v1` family is a compact two-layer
flow-and-confidence network at the reconstruction provider's quarter
resolution. It consumes current luminance, previous luminance, signed
difference, and absolute difference. It emits two signed motion channels and
one reactive-confidence channel. A final Metal kernel converts those outputs
into full-input-resolution `RG16Float` motion, `R8Unorm` reactive coverage,
and conservative `R32Float` depth for MetalFX.

The initial M4 gate is at most 2.0 ms for model inference and at most 10.5 ms
for total DLSM Temporal work at the same Performance-preset scene used for the
current baseline. Both average and 95th-percentile time must be reported; a
faster average does not excuse visible spikes.

## Bundled candidates

The retained v0 baseline, `sol-flow-reactive-v0-e91ab009e4c8`, was trained
locally for 1,200 MLX steps using 46
locally captured frames as texture sources and synthetic known-motion,
scene-cut, exposure-change, and overlay examples as the teacher. Only the
6.3 KB model artifact ships; captured game pixels do not.

Its held-out synthetic validation measured:

- 3.332 input-pixel motion mean absolute error;
- 71.91% reactive-mask accuracy;
- 32.46% reactive precision;
- 84.67% reactive recall.

The high recall is intentional for this first safety-biased candidate:
questionable history is rejected even when that gives up some temporal
sharpness. In a signed Mario Kart 8 Deluxe run, the full DLSM Temporal command
buffer averaged about 7.2 ms over more than 6,000 frames. Hard cuts, pulsing
title UI, fast camera motion, particles, stop, and relaunch did not reproduce
the prior double-image artifact.

Sol now prefers `sol-flow-reactive-v1-0d8f9c7a5d5e`, with v0 retained as a
load-time fallback. v1 was motion-only fine-tuned from v0 using a deterministic
local sequence suite:

- 480 quarter-resolution luminance frames in two title-labelled sessions;
- 478 genuine adjacent-frame pairs;
- a dense offline block-flow teacher with forward/backward consistency,
  photometric residual, texture ambiguity, and cut reactivity;
- a complete Mario Kart 8 Deluxe title holdout rather than a random frame
  split.

On that unseen title, sequence motion error improved from 1.335 to 1.207 input
pixels, a 9.6% reduction. The frozen feature and reactive branches preserved
v0's synthetic accuracy, precision, recall, and F2 safety metrics. The 7.2 KB
artifact is the only new training output shipped; captured pixels remain
local.

An explicit-candidate run exceeded 5,100 rendered frames and a later bundled
v1 run exceeded 3,600 frames across title, hard-cut, and animated demo scenes
without reproducing the split or double-history artifact. This promotes v1 as
the preferred model, not as a claim that Temporal or Frame Generation is
finished.

## Data and training path

Capture schema v2 stores the exact model-scale `L8` luminance input rather than
full-resolution BGRA. Every frame carries a session UUID, capture-group label,
monotonic sequence index, extent, and discontinuity state. The default cadence
is every adjacent frame, writes are bounded to three in flight, and a session
is capped at 360 frames unless a developer explicitly changes it. Filenames
include the session UUID, so stop/relaunch cannot overwrite an earlier sample.

The dataset preparer supports legacy schema-v1 captures, but only schema-v2
frame-gap-one pairs qualify as genuinely adjacent temporal labels. It groups
by session before pairing and therefore cannot create false history across a
relaunch. Captured game frames remain local and must never ship as a training
dataset.

The first experiment should predict quarter-resolution motion and confidence.
Benchmark MPSGraph first, then Core ML GPU only after its resource boundary is
proven, and compare both with a fused Metal path on Apple Silicon. Neural
Engine placement is a measured option, not an assumption.

## Acceptance gates

A model is not ready merely because it runs. It must:

1. preserve the current-to-previous sign and pixel-unit contract;
2. reduce ghosting and edge breakup versus the Metal block-matching baseline;
3. reset cleanly on discontinuities and remain stable through hard cuts;
4. complete without CPU image readback or cross-device texture copies;
5. fit an explicit frame-time and memory budget on the target Apple GPU;
6. pass a fixed capture suite plus live multi-title validation.

The current packaged baseline is roughly 8.3 ms of total reconstructed
Temporal GPU work in a heavy animated Mario Kart 8 Deluxe scene at the
Performance preset. Model experiments report their own estimator cost and
end-to-end DLSM cost separately so an apparent quality gain cannot hide a
frame-time regression.

Opt-in stage-boundary profiling measured v1 model inference at about 1.576 ms
average and 4.557 ms p95 over more than 5,100 frames. Those Metal timestamp
attachments perturb and partially serialize the total pipeline, so
`SOL_DLSM_PROFILE_MODEL=1` is diagnostic-only and disabled in normal runs.

Without those counters, bundled v1 measured 8.18 ms average / 13.18 ms p95 at
2,400 frames in the title sequence, rising to 9.70 ms average / 19.76 ms p95
after 3,600 frames in the heavier animated demo. Average time remains inside
the 10.5 ms gate, but the tail does not. Reducing that tail and validating more
titles are required before Temporal can be described as complete.

## Investigation order

1. Expand the fixed capture/replay suite beyond the current two titles.
2. Optimize the fused Metal model and MetalFX path against the measured p95
   tail.
3. Compare the fused Metal candidate with MPSGraph and Core ML GPU paths.
4. Add automated visual regression scoring for cuts, overlays, resize,
   stop/relaunch, and mode changes.
5. Export native scene attachments only after their canonical semantics pass.

Frame Generation remains a separate milestone. It should not unlock until
validated native depth, motion, and camera metadata are available.

## Implemented capture and runtime boundary

The complete v0 capture-to-runtime path now lives inside `SolDLSM`:

- production Temporal no longer treats the block matcher as a safe provider;
  without a trained model or validated native inputs it resolves to Spatial;
- `SOL_DLSM_ALLOW_EXPERIMENTAL_TEMPORAL=1` is the explicit research-only gate
  for comparing the old estimator;
- `SOL_DLSM_CAPTURE_DIR` enables local-only schema-v2 `L8` capture from the
  exact quarter-resolution model input; the default interval is one frame;
- capture sessions are title-labelled, bounded, and flush through a
  three-write in-flight cap;
- `script/build_and_run.sh --capture-model` launches the signed app with those
  capture variables; select Spatial before launching a game so collection uses
  the stable path;
- `script/dlsm/prepare_sol_temporal_dataset.py <capture-directory>` validates
  payload sizes, rejects discontinuities and incompatible extents, groups by
  session, and writes deterministic current/previous pairs;
- `script/dlsm/train_sol_temporal_model.py <capture-directory> --output
  <artifact>` trains with deterministic title/session holdouts and refuses a
  candidate that regresses the bundled baseline gates;
- `DLSMSolTemporalModelProvider` runs preferred v1, with v0 as a safe resource
  fallback, as native Metal compute and supplies canonical motion, reactive,
  and depth textures;
- `SOL_DLSM_PROFILE_MODEL=1` enables inference-only timestamp counters for a
  diagnostic run; normal presentation does not attach those counters;
- An explicit `SOL_DLSM_MODEL_PATH` can test a candidate, but an invalid
  override fails closed instead of silently selecting the bundled artifact.

Captured game frames stay local and are not application resources. They must
not be committed or shipped as Sol training data.
