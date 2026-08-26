# Compatibility runs

The compatibility runner has two deliberately separate execution paths:

- MoltenVK runs through the standalone Sol Engine executable.
- SolMetal runs through the developer compatibility host, which owns an AppKit
  view and `CAMetalLayer` and calls the existing embedded ABI.

SolMetal remains opt-in. `--backend solmetal` and `--backend both` still fail
before process launch unless `--embedded-solmetal` is also present. Setting
`SOL_METAL_GAL_BACKEND=1` on the standalone executable is never accepted as a
SolMetal run. Older reports produced that way are not renderer evidence.

## Privacy boundary

The runner deliberately splits each run into two kinds of data:

- A private manifest contains game paths, the Sol data directory, and local
  filenames. By default it lives in Sol's Developer application-support folder
  with owner-only permissions.
- Standalone raw output stays beside the private manifest in its owner-only
  `runs` folder. Embedded managed output and its original benchmark stay in
  Sol's private data directory under `Developer/SolMetalCompatibility`; the
  runner keeps the host's JSON stream beside the manifest.
- The public result is rebuilt from an allowlist. It contains aliases, timing,
  frame-pacing distributions, draw milestones, and categorized error
  fingerprints. It contains no game, key, firmware, save, raw-log, or local
  user paths.

The public-result writer refuses to save a report if its final privacy scan
finds a local path or a private title. The runner does not copy screenshots,
games, keys, firmware, saves, shader caches, or mods.

Keep the private manifest out of the repository. Give a game a `publicLabel`
only when you intentionally want its name to appear in a shareable report;
otherwise its generated `game-…` alias is used.

## Set up the suite

Build the standalone engine, the app bundle, and the compatibility host:

```sh
./script/build_sol_engine.sh
./script/build_and_run.sh build
./script/build_solmetal_compatibility_host.sh
```

Create a private manifest from the game folder already selected in Sol:

```sh
python3 script/solmetal_compatibility.py discover
python3 script/solmetal_compatibility.py validate
```

`discover` only reads supported game files. It does not hash their contents or
open them, so even a large library inventory is quick. Re-running it preserves
existing aliases, labels, enabled flags, and per-game timings.

The inventory on the current development Mac contains twelve base-game
candidates across open-world, racing, platformer, party, and turn-based
workloads. That private inventory is intentionally not checked into the repo.

## Plan before launching

`run` is dry by default. This prints a redacted plan and launches nothing:

```sh
python3 script/solmetal_compatibility.py run \
  --backend moltenvk \
  --repeat 3 \
  --warmup 30 \
  --duration 60
```

Use the generated manifest id to narrow a run:

```sh
python3 script/solmetal_compatibility.py run \
  --only game-0123456789 \
  --backend moltenvk
```

Repeat `--only` to build a focused suite. Games run in the order supplied, not
the order stored in the private manifest:

```sh
python3 script/solmetal_compatibility.py run \
  --only game-3333333333 \
  --only game-1111111111 \
  --only game-2222222222 \
  --backend moltenvk
```

If an id is supplied more than once, only its first occurrence is kept. Use
`--repeat` when the same case should run more than once. An unknown or malformed
id fails before execution begins, and the diagnostic never repeats a path-like
value. With no `--only` arguments, enabled games retain their private manifest
order.

The output plan contains aliases and durations only. A SolMetal case says
`executionMode: embedded-appkit` and remains unsupported until the explicit
mode is selected. Add `--execute` when a MoltenVK plan is right:

```sh
python3 script/solmetal_compatibility.py run \
  --execute \
  --backend moltenvk \
  --repeat 3 \
  --warmup 30 \
  --duration 60 \
  --cooldown 15 \
  --keep-awake \
  --output solmetal-compatibility-results.json
```

For an embedded SolMetal run:

```sh
python3 script/solmetal_compatibility.py run \
  --execute \
  --backend solmetal \
  --embedded-solmetal \
  --repeat 3 \
  --warmup 30 \
  --duration 60 \
  --cooldown 15 \
  --keep-awake \
  --output solmetal-compatibility-results.json
```

To A/B the bounded direct-mutation command-buffer experiment, repeat the same
embedded case with `--solmetal-direct-mutation-batching`. The runner sets the
exact native opt-in, removes any ambient value first, and records the experiment
in both the report scope and case metadata. This option is rejected for the
standalone MoltenVK path.

`--backend both --embedded-solmetal` runs the standalone MoltenVK case and the
embedded SolMetal case sequentially. The defaults expect the developer build
at `/tmp/sol-derived-data/Build/Products/Debug/Sol.app` and the host produced by
`build_solmetal_compatibility_host.sh`.

The runner refuses to begin while Sol or another engine/compatibility host is
already running. Each case owns one child. The standalone path sends the native
stop command and accepts `idle` or `stopped` as acknowledgement. The embedded
host sends that command through `SendCommand`, calls `Shutdown`, keeps pumping,
and must emit `embedded.terminated`. On an outer suite timeout the runner sends
`SIGINT` only to its owned host, allowing the same graceful path to run before a
bounded forced teardown. No process-name-wide stop command is used.

Like Sol's embedded runtime, the runner disables Apple Hypervisor execution for
its child and uses the engine's JIT path. A bare developer engine does not carry
the app's signing context, so inheriting a saved hypervisor setting would make
macOS reject an otherwise valid compatibility run before rendering begins.

Ambient `SOL_METAL_*`, `SOL_DLSM_*`, `SOL_BENCHMARK_*`, and `SOL_PRIVATE_*`
variables are removed before every case. Embedded game and data paths are then
passed only through fresh `SOL_PRIVATE_GAME_PATH` and `SOL_PRIVATE_DATA_PATH`
values, never on the child command line.

## What a case records

The structured result includes:

- the requested backend, its execution mode, the independently observed
  backend, the backend named by the benchmark recorder, and attestation status;
- time to `host.ready`, application load, and a first-frame event when the
  standalone host emits one;
- the ordered launch stages, including configuration, content, input, shader
  cache, and first-frame waiting stages;
- completed/partial benchmark state, presented and source FPS, present-frame
  median/p95/p99, FIFO load, process CPU, and working-set distributions;
- slow-GPU-warning counts, routine MoltenVK diagnostic counts, shutdown-only
  error counts, and path-free fingerprints for real engine failures;
- whether the stop command was sent, the session acknowledged idle, how the
  owned host process ended, and whether a forced session teardown was needed.

A MoltenVK case is attested only when runtime output independently identifies
MoltenVK or Vulkan and the completed benchmark names the same backend. A
benchmark label alone is insufficient. Conflicting, missing, or mismatched
evidence fails the case, and the public `backend` field becomes the observed
backend or `unattested` rather than echoing the request.

An embedded SolMetal case has four gates: the managed launch stream must emit
`starting-solmetal-gal`, the benchmark must name SolMetal, the compatibility
host must report matching evidence, and shutdown must reach
`embedded.terminated`. A host cannot make a case pass by printing an attested
label; contradictory or missing underlying evidence fails the case.

The engine does not always emit `launch.first-frame` in standalone mode. A
completed benchmark with a finite, positive `presentedFrames` count is accepted
as deterministic frame evidence and recorded as
`firstFrameEvidence: completed-benchmark`; no synthetic timestamp is invented.

MoltenVK routes its `[mvk-debug]`, `[mvk-info]`, and `[mvk-warn]` callbacks
through Ryubing's `|E|` logger. Those callbacks and their multiline capability
dumps are diagnostic, not fatal. `[mvk-error]`, unhandled exceptions, and other
pre-stop `|E|` records remain fatal. Error-looking records emitted after the
stop request are counted separately as shutdown diagnostics.

`passed` means the engine produced a first frame, completed its timed benchmark,
all backend evidence agreed, no fatal engine error was seen, and the session
stopped cleanly. `partial` means a frame appeared but another non-attestation
completion gate was not met. `unsupported` is reserved for a reported
unsupported graphics contract. `failed` includes timeouts, no frame, forced
stop, and missing or contradictory backend evidence.

Every case also says `visualStatus: not-reviewed`. The runner cannot infer that
lighting, depth, texture sampling, geometry, or post-processing is correct from
frame timing alone.

## Production matrix

Use three layers rather than treating one title screen as compatibility:

1. **Standalone baseline:** every candidate, one MoltenVK pass, 20-second
   warmup and 30-second capture. This checks content boot and provides an
   attested baseline.
2. **Embedded SolMetal evidence:** launch through Sol's real native surface,
   use the same warmed scene and capture duration, and record explicit renderer
   readiness plus visual output. Do not relabel a standalone baseline.
3. **Long lifecycle:** the heaviest titles in windowed and fullscreen sessions,
   manual in-game traversal, stop, relaunch, save/load, and at least 30 minutes
   without corruption, progressive memory growth, or input drift.

For meaningful pacing numbers, use a stable in-game checkpoint and make the
manifest warmup long enough to navigate there. Record whether the shader cache
was cold or warm outside the public JSON; the runner never deletes caches or
saves on your behalf.

Before promoting SolMetal from experimental, review each representative scene
visually and compare it to the stable backend. Screenshots can be kept in a
private test record, but should not be added automatically to this runner's
shareable output.

## Embedded host status

`NativeHost/SolMetalCompatibilityHost` is a developer tool, not part of the Sol
interface. It owns the native surface, loads `Start`, `Pump`, `ReadEvent`,
`SendCommand`, and `Shutdown` from the runtime bundled in `Sol.app`, and emits
path-free JSON Lines. Managed stdout and stderr never share that public stream.

The current attestation uses the managed `starting-solmetal-gal` launch stage
plus the benchmark backend. A dedicated `renderer.ready` event emitted after
renderer construction would still be a useful protocol improvement.

## Offline harness test

The offline suites launch no game and read no real Sol data:

```sh
python3 script/test_solmetal_compatibility.py
python3 script/test_solmetal_embedded_host.py
```

They verify private manifest permissions, command construction, ambient-variable
cleanup, fail-closed standalone behavior, independent backend attestation,
mislabel rejection, completed-benchmark frame evidence, MoltenVK callback
classification, graceful embedded and standalone stopping, ABI resolution,
ordered repeated selection, duplicate and missing-id handling, raw/private
separation, and the final public path-leak gate.

## Current limitations

- Embedded execution has now been attested with controlled private title runs.
  The harness verified the requested and observed SolMetal backend, completed
  benchmark output, first-frame evidence, natural host teardown, and a graceful
  engine stop. That proves the measurement route; it does not make an unreviewed
  frame visually correct.
- It can measure a title or manually reached scene, but it does not navigate
  game menus or load saves automatically.
- Benchmark distributions come from the existing in-engine recorder; raw frame
  intervals are not exported, so the report cannot calculate custom stutter
  buckets yet.
- Visual correctness, controller behavior, audio correctness, multiplayer, and
  suspend/resume still need human review.
- The suite does not normalize ambient temperature, power mode, shader-cache
  state, game patch level, firmware, or background system load. Those must be
  controlled when publishing comparisons.
