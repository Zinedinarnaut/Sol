# SolMetal

SolMetal is an experimental Metal renderer for Sol Engine. The aim is simple:
let the engine talk to Metal directly on Apple Silicon instead of translating
Vulkan through MoltenVK.

It is not Sol's default renderer yet. Public builds still use Vulkan and
MoltenVK because that path has much wider game coverage. SolMetal is available
only through a developer flag, reports `playable: false`, and stops on an
unsupported graphics call instead of quietly falling back to Vulkan.

## Trying it

Build and run the direct renderer with:

```sh
SOL_METAL_GAL_BACKEND=1 SOL_APPLE_SIGNING=off ./script/build_and_run.sh run
```

For a first-frame colour summary while diagnosing a black surface, add
`SOL_METAL_FRAME_PROBE=1`. It records dimensions, colour range, non-black pixel
count, and checksums in the engine log. A requested probe also writes the exact
presented source and, when available, its immediate copy source to a temporary
`SolMetalFrameProbe-<pid>` directory. The presentation number, channel order,
and dimensions are part of each filename so the final handoff can be compared
with draw captures from the same frame. Taking a screenshot while that flag is
active also arms a small set of targeted draw probes. Those probes report Metal
visibility counts, follow both vertex- and fragment-stage texture inputs, and
write the relevant generated MSL and short buffer prefixes to the same
directory. Treat that directory like a private debug artifact; do not attach
it to a public issue without checking its contents.

Renderer developers can narrow a captured frame further with comma-separated
program IDs or stable render-program keys:

- `SOL_METAL_VISIBILITY_PROBE_PROGRAMS=83,84` records one visibility result for
  each selected program after a screenshot request;
- `SOL_METAL_VISIBILITY_PROBE_PROGRAM_KEYS=<sha256>,<sha256>` selects the same
  source SPIR-V programs across relaunches, even when shader creation order
  changes. During a frame probe, each selected draw also records the exact
  bound texture-view lineage, requested and effective Metal sampler state, and
  bounded per-mip/per-slice input and output artifacts;
- `SOL_METAL_TARGETED_PROBE_SELECTORS_JSON='<json-array>'` selects a draw by
  stable program key plus its exact color slot, dimensions and format, with an
  optional depth-target contract and maturity thresholds. Structured selectors
  arm when the renderer is created and re-arm after a screenshot request, so
  they do not need a broad screenshot dump to begin matching. Rejected draws
  are silent; arming, capture, and optional expiry each produce one log entry.
  Every match writes to its own
  `SolMetalFrameProbe-<pid>/capture-<id>-<name>` directory, so selectors that
  share a program key cannot overwrite one another. For example:

  ```sh
  export SOL_METAL_TARGETED_PROBE_SELECTORS_JSON='[
    {
      "name": "p27-mip0",
      "programKey": "<sha256>",
      "colorTarget": {
        "slot": 0,
        "width": 400,
        "height": 224,
        "format": "Rg11B10Float"
      },
      "depthTarget": { "presence": "none" },
      "minPresentations": 500,
      "minColorDraws": 128,
      "maxWaitPresentations": 5000
    },
    {
      "name": "p27-mip1",
      "programKey": "<same-sha256>",
      "colorTarget": {
        "slot": 0,
        "width": 200,
        "height": 112,
        "format": "Rg11B10Float"
      },
      "depthTarget": {
        "presence": "present",
        "width": 200,
        "height": 112,
        "format": "Depth32Float"
      },
      "minDepthPasses": 128,
      "minDepthClears": 8,
      "eligibleOccurrence": 1
    },
    {
      "name": "final-filter",
      "programKey": "<sha256>",
      "colorTarget": {
        "slot": 0,
        "width": 1600,
        "height": 896,
        "format": "Rg11B10Float"
      },
      "depthTarget": { "presence": "none" },
      "minPresentations": 500,
      "minColorDraws": 128,
      "minColorClears": 8,
      "maxWaitPresentations": 50000
    }
  ]'
  SOL_METAL_GAL_BACKEND=1 SOL_METAL_FRAME_PROBE=1 \
    SOL_APPLE_SIGNING=off ./script/build_and_run.sh run
  ```

  `depthTarget.presence` is `any`, `none`, or `present`. Maturity is measured
  before the selected draw: `minColorDraws`, `minColorClears`,
  `minDepthPasses`, and `minDepthClears` therefore describe earlier activity
  on the same underlying target, including activity shared by mip/slice views.
  `eligibleOccurrence` counts only fully eligible draws. Unknown fields,
  unsafe names, unknown formats, or malformed JSON reject the whole selector
  list rather than falling back to a broader capture. Each texture report
  includes a `currentDrawDepth` snapshot frozen from the selected draw; the
  root-wide recent-history entries that follow it describe earlier activity
  and must not be used as the selected draw's depth state. A D16 replay can be
  narrowed further with a `d16Replay` object:

  ```json
  {
    "name": "d16-replay-tag-128",
    "programKey": "<stable-replay-sha256>",
    "colorTarget": {
      "slot": 0,
      "width": 1600,
      "height": 896,
      "format": "Rg11B10Float"
    },
    "depthTarget": {
      "presence": "present",
      "width": 1600,
      "height": 896,
      "format": "Depth16Unorm"
    },
    "minDepthPasses": 128,
    "minDepthClears": 8,
    "d16Replay": {
      "rawTag": 128,
      "expectedCode": 33796,
      "minWriterCodeCount": 1
    },
    "maxWaitPresentations": 5000
  }
  ```

  Include a selector for the corresponding D16 writer in the same array; its
  draw must capture before the requested replay. Once that writer has captured
  its native sidecar, `d16Replay` accepts only a
  read-only `Equal` draw on that same depth target whose runtime constants
  decode to both requested values and whose writer sidecar contains at least
  `minWriterCodeCount` matching pixels. The small runtime constants are read
  only after the stable key, target shape, and maturity checks pass. A match
  retains the exact before/after color target, the writer-sidecar path, and
  classifier coverage for every submitted instance. `maxWaitPresentations`
  still bounds the search and logs an explicit miss;
- `SOL_METAL_DEBUG_FORCE_DEPTH_ALWAYS_PROGRAMS=85` changes only the selected
  program's depth comparison for an A/B diagnosis;
- `SOL_METAL_DEBUG_FORCE_DEPTH_ALWAYS_PROGRAM_KEYS=<sha256>` is the stable-key
  form of that switch;
- `SOL_METAL_DEBUG_DISABLE_COLOR_WRITE_PROGRAM_KEYS=<sha256>` keeps the
  selected draw and all of its depth, visibility, and resource behavior but
  masks every color attachment write for a one-variable composition probe;
- `SOL_METAL_DEBUG_SKIP_PROGRAMS=85` omits only the selected program.
- `SOL_METAL_DEBUG_SKIP_PROGRAM_KEYS=<sha256>` is the stable-key form of that
  switch.
- with `SOL_METAL_FRAME_PROBE=1` also set,
  `SOL_METAL_AUTO_PROBE_AFTER_PRESENTATIONS=570` arms the same screenshot and
  visibility capture after a bounded number of guest presentations, allowing
  an unattended saved-game route to produce diagnostics while the display is
  locked;
- `SOL_METAL_AUTO_PROBE_D16_SEQUENCE_KEYS=<writer>,<replay-a>,<replay-b>`
  changes that presentation count into a lower bound, then waits until the
  exact adjacent six-element, 350-instance D16 sequence completes in two
  different presentations on the same mature depth target (at least 128 depth
  passes and eight clears). Sequence matching also requires the writer to use
  `Always` with depth writes enabled and both replays to use read-only `Equal`.
  This matters because a title may reuse the same shader key under another
  depth state before the real prepass. Matching uses the guest-requested depth
  state, so a diagnostic compare override can change the executed pipeline
  without preventing the same draw from being captured. The following
  occurrence is selected automatically and its writer establishes the capture
  target, so a normal attachment rollover between recognition and capture
  cannot strand the probe. A separate visibility-key setting is not required;
- `SOL_METAL_AUTO_PROBE_TIMEOUT_PRESENTATIONS=5000` logs an explicit miss and
  permanently leaves the probe unarmed if that stable sequence does not arrive
  in time. Malformed sequence input also fails closed rather than falling back
  to the fixed-presentation trigger.

Program IDs are assigned by a particular probe run and can change when shader
creation completes in a different order. The three bounded automatic captures
include the exact pre/post color targets and sampled texture inputs as well as
the D16-specific histograms. D16 probe logs and state files include the stable
key to use for a cross-run comparison. Neither form is a game identifier or
compatibility fix. The force/skip switches are strictly diagnostic; do not use
their output for performance or compatibility claims.

Two narrower comparison flags exist for black-frame bring-up:

- `SOL_METAL_DEBUG_INVERT_NEGATIVE_VIEWPORT_FRONT_FACE=1` swaps winding only
  for negative-height viewports;
- `SOL_METAL_DEBUG_DISABLE_DEPTH_TEST=1` forces depth compare to Always and
  disables depth writes.

They are diagnosis switches, not renderer modes or proposed performance
settings. Results obtained with either switch must be repeated on the normal
path before a compatibility claim.

Run the renderer tests without launching a game:

```sh
./script/test_sol_metal.sh
./script/test_sol_metal_bridge.sh
```

The first command tests the native library, including sanitizers, repeated
creation and teardown, shader translation, rendering, compute work, and
presentation. The second tests the managed Sol Engine bridge and a small GAL
workload. Neither test is a game-compatibility claim.

For repeatable title runs, use the private [compatibility
runner](SOLMETAL_COMPATIBILITY.md). It includes a developer-only AppKit host
that creates the `CAMetalLayer` SolMetal needs; the standalone runner remains a
MoltenVK baseline. Frame counts still do not prove that a scene is drawn
correctly, so pair those runs with the offline [visual regression
tool](SOLMETAL_VISUAL_REGRESSION.md).

## How it is put together

Sol Engine already sends graphics work through the bundled GAL interface.
`SolMetalGalRenderer` implements that interface and passes Metal-friendly
commands through a versioned C ABI to `SolMetal.dylib`. The native library owns
the Metal device, command queue, resources, pipelines, and synchronization. It
presents the final game texture to the `CAMetalLayer` owned by the Sol window.

SPIR-V shaders are translated to MSL with the pinned SPIRV-Cross source in this
repository. SolMetal reflects each translated shader and checks its resource
layout before submitting work. An invalid shader or binding produces a useful
error at the renderer boundary rather than a corrupt frame later on.

This path does not create a Vulkan instance, surface, or MoltenVK device.
`SolMetal.dylib` is also checked during packaging for accidental Vulkan or
MoltenVK links.

## Current support

The renderer currently covers the parts of GAL needed to begin real-game
bring-up:

- shared and private Metal buffers, uploads, copies, fills, and readback;
- 2D, array, cube, cube-array, and 3D textures, including mip and slice views;
- BC1-BC7, common color formats, packed formats, RGBA16Unorm, and
  depth/stencil targets;
- buffer textures backed directly by Metal buffers;
- samplers, sampled textures, storage buffers, storage images, and compute;
- sparse MRT layouts, depth/stencil state, blending, color masks, clears,
  culling, viewport/scissor state, and depth bias;
- UInt8, UInt16, and UInt32 guest indices. UInt8 indices are expanded on the
  GPU because Metal only exposes 16- and 32-bit index types;
- direct and UInt8/UInt16/UInt32 indexed `Quads`. Indexed quads expand through
  a GPU compute pass into a reusable private UInt32 scratch buffer; the
  conversion performs no CPU readback or converted-index upload. Direct
  `QuadStrip` draws map to Metal triangle strips after incomplete pairs are
  removed. Indirect quad and quad-strip conversion still fails closed;
- single and counted GPU-driven direct and UInt8/UInt16/UInt32 indexed draws,
  including command and count buffers passed as slices. Vulkan and Metal use
  the same single-command layout. Counted streams run through a small Metal
  compute prepass that clamps the GPU-written count and zeroes inactive draws,
  without a CPU readback or queue stall;
- bounded asynchronous presentation to Sol's game layer and ordered queue
  synchronization, so the emulation thread does not wait for every drawable;
- independent X/Y source cropping, horizontal and vertical flips, aspect-fit
  letterboxing, and screenshots of the exact cropped source used for
  presentation;
- bounded native draw batching: ordinary draws share a Metal command buffer up
  to 64 draws, and compatible consecutive draws with the same stored
  attachments stay inside one Metal render encoder. An opt-in path can keep
  direct buffer copy/fill, direct texture copy, direct color clear, and direct
  color blit work on that pending command buffer. Uploads, readbacks,
  conversions, arbitrary compute, queries, timeline markers, D16 sidecar work,
  and presentation remain explicit ordering boundaries;
- ordered asynchronous GPU-only uploads, fills, copies, and blits. CPU-visible
  downloads still wait for completion, as they must;
- generic depth/stencil subresource readback for D16, D32, D24S8, and D32S8,
  including selected array and cube slices and mips;
- ordered, GPU-local R32Float/D32Float conversion in both directions;
- bit-preserving copies between 8- or 16-byte unsigned integer texels and
  matching BC compressed blocks. These are raw compatibility copies, not color
  resampling; mismatched grids, linear filtering, MSAA, and 3D cases still fail
  closed;
- queued guest memory and texture barriers that end the active Metal render
  encoder without submitting an otherwise empty command buffer;
- layered vertex output on Apple GPU family 5 and newer or Mac GPU families,
  using Metal's render-target array index for 2D arrays and cube faces. Pipeline
  identity includes primitive topology, attachment layer counts are validated,
  and genuine tessellation stages still fail closed;
- cached managed vertex, fragment, and compute binding tables plus stack-based
  native conversion buffers, avoiding per-draw bridge allocation churn when
  guest resource state is unchanged;
- cached immutable color-attachment and native render-target tables, rebuilt
  only when an attachment, write mask, blend mode, load action, or clear value
  actually changes;
- immutable last-state Metal argument-buffer reuse per pipeline and shader
  stage, with bound buffers, textures, and samplers retained for in-flight GPU
  work;
- full-frame guest screenshots through Sol's existing capture library;
- pipeline reuse and validation of reflected buffer, texture, and sampler
  bindings;
- runtime batch telemetry in the engine log at 1,000 draws, including draw
  command-buffer and render-pass counts, average and peak occupancy, boundary
  flushes, the pending tail batch, direct-mutation borrowing/fallback counts,
  byte and encoder peaks, discards, caps, and each flush reason. Older native
  libraries omit the optional direct-mutation report without preventing Sol
  Engine from loading.

Direct-mutation command-buffer borrowing is deliberately disabled by default.
For a controlled A/B run, enable it with
`SOL_METAL_DIRECT_MUTATION_BATCHING=1`. The default safety budgets are
12 mutation encoders and 32 MiB of declared transient work per pending command
buffer. Developers can lower them with
`SOL_METAL_DIRECT_MUTATION_MAX_ENCODERS` and
`SOL_METAL_DIRECT_MUTATION_MAX_TRANSIENT_BYTES`; exceeding either budget
submits the draw batch and performs that mutation standalone. An encode error
discards the uncommitted batch instead of submitting partially encoded work.

Some shader layouts contain unused resources. Like the established Vulkan
backend, SolMetal binds safe dummy resources for those slots instead of
assuming that every declared resource is live for every draw.

The large pieces still missing are descriptor arrays, uncounted multi-draw
indirect commands, indirect quad and quad-strip conversion, transform feedback,
the remaining storage-image shapes, genuine tessellation/geometry lowering,
device-loss recovery, persistent on-disk pipeline caches, and wider render-pass
coalescing across compatible resource mutations. Visibility queries and sample
counters have a working first implementation but still need wider title
coverage. These are renderer
features, not polish tasks, and games will continue to find them during
bring-up.

## Game bring-up

These runs are compatibility checks. Presentation and draw counts tell us how
far a title travelled through the renderer; they are not FPS measurements.

| Date | Validation title | Result |
| --- | --- | --- |
| 10 Aug 2026 | A | Reached the intro and language menu with correct colour, orientation, and crop. Windowed/fullscreen presentation, a basic key press/release, Stop, and same-process relaunch were checked on an M4. |
| 10 Aug 2026 | B | Reached a native 1920×1080 frame, 60 presentations, and 1,000 guest draws in the short launch check without a SolMetal exception. This was not a gameplay or input test. |
| 11 Aug 2026 | C | Reached its first native 1920×1080 frame at 4.972 s, 60 presentations at 6.890 s, and 1,000 guest draws at 11.090 s. The opening sequence continued beyond 2 min 11 s without a SolMetal exception. The Mac was locked, so this was a log-backed compatibility run rather than a visual or input check; the debug process was terminated afterward instead of using the in-app Stop button. |

The controlled 26 August production sweep uses privacy-safe aliases from the
compatibility runner. Each case launched through Sol's embedded AppKit host,
attested the requested SolMetal backend, completed a five-second warmup and a
20-second measurement, emitted no engine error lines, and stopped through the
normal engine lifecycle without forced termination.

| Workload | Timed result | Current verdict |
| --- | --- | --- |
| `game-1350283b7e` | 60.10 FPS; 16.67 ms median / 17.08 ms p95 frame time | Automated timing and lifecycle pass on this launch route. The earlier non-stationary route is not a benchmark. |
| `game-0392821024` | 30.00 FPS; 33.33 ms median / 33.73 ms p95 | Automated timing and lifecycle pass. |
| `game-b35add98bb` | 60.00 FPS; 16.67 ms median / 17.22 ms p95 | Automated timing and lifecycle pass; current cleanest pacing sample. |
| `game-6c038130c2` | 19.38 FPS; 42.02 ms median / 58.94 ms p95 | Automated lifecycle pass only. Previously retained frames contain dark rectangular corruption, so this remains a visual fail and is not playable. |
| `game-4630d72287` | 30.00 FPS; 33.34 ms median / 33.71 ms p95 | Advanced through the former quad, crop/flip, and RGBA16Unorm stops and completed the timed run. The GPU-only indexed-quad regression reports zero conversion readbacks and uploads. |

These numbers describe captured routes on one development Mac. The runner marks
every case `visualStatus: not-reviewed`; the retained heavy-title evidence is
the explicit exception above. These are not cross-renderer performance claims,
and an attested backend plus a completed timer still does not certify the
picture.

After the ABI-v2 ownership and validation hardening, `game-4630d72287` repeated
the same 20-second route at 30.00 FPS with 33.29 ms median / 34.39 ms p95,
zero engine errors, backend attestation, and a natural shutdown.

The heaviest validation run has already been useful: it exposed attachment aliasing,
vertex attributes that cross a declared stride, buffer textures in compute
shaders, placeholder buffer-texture metadata, unused shader resources, and a
two-layer mipmapped D16 depth upload. Each case now has a focused regression
test instead of a game-specific bypass.

The latest renderer milestone also fixes a generic clear contract that the
earlier TOTK build violated. Color, depth, and stencil clears now honor the
active scissor; color channel masks, typed integer clear values, and partial
stencil write masks are handled by dedicated Metal clear pipelines. The same
milestone adds 64-draw batching, reuses compatible render encoders, and removes
synchronous CPU waits from GPU-only resource mutations. Guest memory and
texture barriers now become encoder boundaries inside the pending command
buffer instead of extra timeline submissions. Native validation covers a
65-draw rollover in exactly two render passes, a barrier that preserves the
pending batch, timeline drain, scissored/masked color clear, and scissored depth
clear. The managed GAL smoke covers the same bridge used by Sol Engine.

TOTK then exposed a second, narrower contract. Its cave scene writes a D16
depth prepass and replays the same geometry with an exact Equal test. SolMetal
now has an opt-in D32-backed D16 path that uses a native D16 sidecar for draws
whose original early-fragment-test ordering must be preserved. Cross-format
depth conversion is performed by Metal render passes, not an invalid blit, and
the original guest shaders, discard behavior, storage side effects, and depth
bias remain in the draw. Non-2D sidecar roots are rejected until layered
conversion is implemented; explicit 2D slice views remain supported.

Depth conversion now follows Metal's round-to-nearest-even UNORM rule. Native
tests exercise non-flat depth, explicit fragment depth, early Equal replay,
discard, storage side effects, the half-tie values found in the cave capture,
and deterministic rejection of an unsupported D16 array root. These tests pass
with Metal API validation enabled.

The controlled cave rerun still reaches the saved scene, but two dark rectangles
remain. A later frame-level capture corrected the earlier diagnosis: the
automatic D16 sequence had matched an earlier temple/loading frame, not the
cave frame. Forcing either captured Equal replay to Always did not remove the
cave rectangles, and disabling their color writes did not remove them either.
Global culling and viewport-winding A/B runs were also not fixes.

The presentation handoff is now ruled out. At presentation 1,424, the upstream
guest copy and the exact source handed to Sol's `CAMetalLayer` were identical
and both already contained the corruption. The retained cave G-buffer included
a complete albedo target and a complete normal/material target, while the dark
regions were visible in the downstream `Rg11B10Float` lighting/composite chain.
The exact D16 writer and its native sidecar are now captured on the same target
as a replay. A replay with raw tag 0 correctly changed only depth code 32768 and
had no overlap with the corrupted region; the dark flat block already existed
before that writer. That evidence does not justify changing D16 behavior.

The next bounded probe targets the first read-only `Equal` replay on that same
writer target with raw tag 128 and expected code 33796. The structured selector
checks the stable program, target shape, depth maturity, runtime constants, and
writer-code population before reading or capturing anything. A downstream
two-input HDR composite remains useful only after this earlier replay is ruled
out. This is diagnostic progress, not a compatibility claim: SolMetal remains
opt-in and `playable: false`, and this scene is still not benchmarkable.

The next useful compatibility pass is a longer, controlled run for each title:
boot, reach a menu, enter gameplay, exercise input, toggle fullscreen, capture
a screenshot, Stop, and relaunch in the same Sol process. A black window or a
`Running` label by itself does not count.

## Benchmarking

SolMetal is not ready for public performance comparisons yet. A fair benchmark
needs a title that reaches stable gameplay on both renderers, the same save and
camera, an unlocked or genuinely GPU-bound scene, a warm shader cache, and
separate measurements for frame time, GPU time, CPU use, memory, and frame
pacing.

TOTK is a good stress title, but the current launch checks are still finding
missing renderer contracts. Once it survives a repeatable in-game route, it
will be added to the benchmark set alongside lighter titles. Until then,
publishing the launch timings above as an FPS win would be misleading.

## Performance work

Correctness is still the first gate, but the current traces already point to a
clear performance problem: SolMetal submits too many short command buffers and
ends too many render passes. Apple recommends batching copies, grouping work of
the same kind, folding full clears into `MTLLoadActionClear`, and preserving
tile memory with deliberate load/store actions. That matches the renderer's
own 1,000-draw telemetry. See Apple's [Metal rendering
guidance](https://developer.apple.com/videos/play/wwdc2023/10125/).

The 26 August direct-mutation A/B used the same warmed 60 FPS workload for two
30-second samples. With borrowing disabled, the 1,000-draw checkpoint recorded
365 command buffers and 448 render passes; enabled recorded 363 and 447. Both
held 60.00 FPS, while p95 frame time moved from 18.05 ms to 17.31 ms. The enabled
sample's median working set was 2,299 MiB versus 1,814 MiB, however, and one
sample is not enough to attribute either pacing or memory movement. A two-buffer
reduction per 1,000 draws does not justify making the path default. It remains
an opt-in experiment until repeated title traces show a useful win without a
memory or visual regression.

The next measured work is deliberately unglamorous:

1. repeat direct-mutation A/B runs on mutation-heavy, stable gameplay routes
   and investigate the working-set variance before changing the default;
2. measure the new GPU-local indexed-quad conversion in title traces. The
   controlled U8/U16/U32 and 72-draw source-mutation gates pass without a CPU
   readback or converted-index upload, but indirect quad conversion is still
   deliberately rejected;
3. reuse staging allocations instead of creating private buffers for individual
   transfers;
4. serialize title-scoped `MTLBinaryArchive` data so a warm launch does not pay
   the same pipeline compilation cost again; and
5. add bounded residency sets only after resource lifetime telemetry can prove
   that they reduce CPU or memory overhead.

Metal 4 is a useful later path, not a reason to abandon the working Metal 3
backend. On supported systems, command allocators, argument tables, flexible
pipeline states, and explicit barriers could reduce encoding and compilation
overhead. They need an availability-gated implementation and the same visual
and pacing matrix before becoming default. Apple's [Metal 4
overview](https://developer.apple.com/videos/play/wwdc2025/205/) and [feature
tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf) are the
baseline for that work.

## Reporting a failure

When a game stops on SolMetal, include:

- the game version and update version;
- Mac model, chip, macOS version, and Sol commit;
- the last SolMetal error from the engine log;
- whether a first visible frame appeared;
- what happened during Stop and relaunch.

Do not upload games, keys, firmware, saves, account data, or absolute local
paths. A short log excerpt around the first exception is usually enough to turn
the failure into a regression test.

## Promotion checklist

SolMetal can replace the default renderer only after it has broad game and
shader coverage, reliable input and presentation, clean Stop/relaunch
lifecycle, stable idle CPU and post-game memory, screenshot support,
device-loss recovery, and repeatable benchmarks. Until then, Vulkan/MoltenVK
remains the supported gameplay path and SolMetal remains opt-in.
