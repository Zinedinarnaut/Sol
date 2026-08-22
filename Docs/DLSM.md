# DLSM — Deep Learning Super Metal

DLSM is this project's Apple Silicon-native rendering system. It renders
Sol Engine at a reduced internal resolution and presents a full-resolution image
through Metal and MetalFX without adding a second UI framework.

## Render path

1. DLSM sizes Sol Engine's Vulkan presentation surface to the selected
   sub-native resolution.
2. Sol Engine composes directly into that smaller MoltenVK swapchain, and
   `VK_EXT_metal_objects` exposes its `MTLTexture` and command queue without a
   CPU readback.
3. `DLSMProcessor` encodes MetalFX directly from that low-resolution Metal
   texture. A private staging image remains available only as a compatibility
   fallback if a driver returns a larger surface.
4. A second, visible `CAMetalLayer` presents the full-resolution DLSM result.

The source layer is transformed to fill the view as a failure fallback, but its
actual drawable and swapchain stay at the selected DLSM size. Sol Engine's existing
`ResScale` feature is intentionally not used: it was designed to multiply guest
render targets above native resolution and sub-1.0 values can produce black
frames. DLSM v1 therefore reduces the emulator's final presentation work and
MetalFX input size without rewriting game-owned render attachments.

## Modes

- **Spatial** is the stable DLSM path. It uses MetalFX spatial scaling and only
  requires the final game color texture available at the compositor boundary.
- **Temporal** is gated. It requires validated game-authored depth and motion
  or the bundled Sol Temporal model. The native Metal model is the normal
  color-only provider; the older quarter-resolution block matcher is retained
  only behind an explicit developer flag because pulsing UI and alpha effects
  can leave visible historical copies.
- **Frame Generation** remains gated off until the native core exports
  validated game-authored depth, motion, and camera metadata. Reconstructed
  motion is deliberately not treated as sufficient for interpolation.

Quality presets present Sol Engine at 77%, 67%, 58%, or 50% of the display
dimensions.
DLSM is off by default and can be selected in the native Graphics settings.
Changes apply when the next game starts.

## Temporal input topology

The native compositor callback now uses **DLSM Frame ABI v2**, a fixed
144-byte, versioned C structure. Each synchronous frame can carry:

- a monotonic frame ID, timestamp, delta time, and discontinuity flag;
- borrowed Metal command-queue and color/depth/motion texture pointers that
  are first bridged inside the synchronous callback;
- independent dimensions and canonical format tags for every attachment;
- current-to-previous motion-vector scales, render jitter, and reversed-depth
  state;
- near/far planes, vertical field of view, and aspect ratio for frame
  interpolation.

The Swift side validates the ABI header, Metal device, dimensions, texture
usage, formats, motion convention, and camera values before MetalFX sees any
attachment. The canonical initial contract is `R32Float` normalized device
depth and `RG16Float` current-to-previous motion at the DLSM input resolution.
A frame-ID gap or explicit discontinuity resets both temporal histories.

Sol Engine's generic `Window.Present` path currently owns only the final
composited color texture. It emits a truthful color-only ABI v2 frame. Sol can
now run Temporal from that frame through its reconstruction provider while the
native attachment path remains a preferred future quality source. A guest
depth target is not automatically the depth corresponding to the final
composite, and guest titles do not expose motion vectors through one standard
render-target semantic.

The first provider milestone was a passive attachment-discovery layer in
the Vulkan renderer. It records bounded render-pass provenance, follows sampled
texture dependencies backwards from the presented color image, and scores:

- depth attachments repeatedly paired with the probable scene-color family;
- secondary float render targets repeatedly written beside that scene color as
  motion-vector candidates;
- format and resolution compatibility, later sampling, ambiguity, and
  cross-frame stability.

The second provider milestone now turns those observations into a typed,
pointer-free readiness contract. It independently reports scene, depth, and
motion readiness, tracks a provider generation, and emits a scene-cut edge
whenever the stable scene family changes. The native Graphics pane shows this
state live.

Readiness is deliberately separate from exportability. Even a `stable`
candidate cannot enter ABI v2 until its Vulkan image was created with the
correct `VK_EXT_metal_objects` export topology and its depth/motion convention
has passed validation. The provider therefore reports
`canonicalExportReady = false`, so Sol does not consume that native attachment.
Production Temporal remains locked, while the experimental provider can still
run behind a developer flag for capture comparisons. This keeps the export
milestone honest without letting plausible but incorrect history corrupt
gameplay again.

### Current validation snapshot

A live, fast-moving 60 FPS scene repeatedly identified the same
`D32Float 1920×1080` depth family. It reached a `stable` label at 94–95%
confidence when its two-step presentation chain was visible, with exact-size,
read-later, and 97–100% scene-pairing evidence. The scene-color family remains
`candidate` because the game alternates several equally plausible HDR and
compositor attachments. No compatible motion-vector MRT appeared in this
capture, so motion correctly stays `unresolved`.

These observations are runtime evidence, not a title-specific rule: no texture
ID, format, or resolution is hard-coded into the provider. Reports are also
rate-limited so composition-pass changes do not flood the Sol Console.

Temporal providers are isolated behind one canonical texture contract. The
experimental block matcher still performs no CPU image readback and remains
available for research, while an opt-in capture path records exact DLSM inputs
for later Sol-model training. Sol now prefers
`sol-flow-reactive-v1-0d8f9c7a5d5e`, a 7.2 KB native Metal resource, and keeps
`sol-flow-reactive-v0-e91ab009e4c8` as its bundled fallback. An invalid local
model override fails closed; if neither a bundled model nor trusted native
inputs are available, Temporal falls back to Spatial.

Sol retains the small active command-queue and swapchain-texture set once per
emulation session. Presentation is closed first during stop, in-flight
callbacks drain, and those retained Metal objects are released before the
managed Vulkan renderer tears down. This avoids repeatedly bridging the same
borrowed Objective-C pointers and prevents one session's objects from entering
the next launch.

### Historical Temporal validation

The block matcher has a real-GPU regression test that checks motion direction and
passes its depth, motion, and reactive textures through
`MTLFXTemporalScaler`. A packaged run of the same validation title then exercised more
than 8,000 reconstructed Temporal frames across camera motion, particles,
transparent item boxes, and hard scene changes without reproducing the earlier
split-frame corruption. The observed DLSM command-buffer average was about
8.3 ms in the heavier animated scene on the current test machine. This is one
title and one Apple GPU, so it is an acceptance baseline rather than a
universal quality claim. A later live regression reproduced ghosting on pulsing
the title screen's pulsing UI, so these earlier stability runs no longer justify
enabling the heuristic in production.

### Sol Temporal v1 validation

The sequence-trained v1 provider used 480 local quarter-resolution luminance
frames and 478 adjacent pairs from two title-labelled sessions. The validation
title was held out in full. Its held-out sequence motion error
fell from v0's 1.335 to 1.207 input pixels, a 9.6% improvement, while the
frozen reactive branch preserved v0's synthetic safety metrics.

An explicit-candidate run exceeded 5,100 frames and the packaged, bundled-v1
run exceeded 3,600 frames. Pulsing title UI, hard cuts, animated demos, stop,
and relaunch remained visually stable without reproducing the split or
double-history artifact.

Inference-only Metal timestamp profiling measured about 1.576 ms average and
4.557 ms p95. It is opt-in because stage-boundary counter sampling perturbs the
pipeline. In the normal uninstrumented build, the full Temporal command buffer
measured 8.18 ms average / 13.18 ms p95 at 2,400 title-scene frames, rising to
9.70 ms average / 19.76 ms p95 in the heavier demo by 3,600 frames. The
average remains within the 10.5 ms target, but the p95 tail does not. v1 is
therefore the preferred quality candidate while Temporal remains opt-in and
DLSM stays off by default.

The packaged app also completed two consecutive launch, Temporal presentation,
and stop cycles in one Sol process. The second session presented more than
1,500 reconstructed Temporal frames, stopped back to the library, and updated
playtime without the previous callback deadlock. Resident memory after the
second stop was about 1.14 GB while teardown completed, then settled to about
194 MB on the current test machine.

## Frame-generation gate

Frame generation has a stricter gate than temporal upscaling. In addition to
validated depth and motion, it requires valid camera frustum metadata and a
positive frame interval. The first frame, a frame after resize/scene
discontinuity, or any frame without those values is presented directly and
refreshes interpolation history.

## Input latency companion fix

The embedded AppKit render view now forwards physical macOS key positions
directly to the native engine's SDL scancode state. SDL polling remains as a
fallback for controllers and other devices, while keyboard presses no longer
wait for the Cocoa-to-SDL event pump. Key state is cleared whenever focus is
lost to prevent stuck inputs.
