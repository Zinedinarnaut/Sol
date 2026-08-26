# Developing Sol

Sol builds as one native macOS application with a bundled managed engine,
native host bridge, experimental SolMetal library, private .NET runtime, and
three app extensions. The normal workflow does not clone another repository
and does not install .NET globally.

## Requirements

- Apple Silicon Mac running macOS 15 or later
- A current Xcode installation with Command Line Tools selected
- Internet access for the first project-local .NET SDK install and package restore
- XcodeGen only when changing `project.yml`

This checkout is currently validated with Xcode 26. Older toolchains may build
the macOS 15 path, but CI uses the current Xcode release.

## First build

```bash
./script/install_dotnet_sdk.sh
SOL_APPLE_SIGNING=off ./script/build_and_run.sh --build
```

That command verifies the pinned engine source, compiles Sol Engine, builds the
native host bridge, embeds the private runtime, and builds the Swift app. The
result is `/tmp/sol-derived-data/Build/Products/Debug/Sol.app`.

Use a provisioned local build when testing Apple services, entitlements, or
extensions:

```bash
SOL_DEVELOPMENT_TEAM=YOUR_TEAM_ID ./script/build_and_run.sh
```

If Xcode can identify the team from an installed Apple Development certificate,
the explicit team variable is optional.

## Useful checks

Run the Swift and Metal boundary tests:

```bash
swift test
./script/test_sol_metal.sh
./script/test_sol_metal_bridge.sh
```

The bridge gate also runs the controlled managed GAL resource path. It creates
shared and private Metal buffers through `IRenderer`, copies and reads back a
non-aligned payload, round-trips a non-aligned 2D texture, creates a native
sampler, executes resource-bound indexed raster work with depth, blending,
culling and readback, dispatches compute work, then retires a guest sync ID on
SolMetal's queue timeline. This is deliberately not a compatibility claim.

The first SolMetal test stays outside the emulator and stresses native Metal
resources, shaders, binary archives, presentation, sanitizers, leaks, threads,
and repeated teardown. The bridge test proves Sol Engine can load the ABI from
the bundle boundary and can contain a missing or malformed library safely. See
[SolMetal](SOLMETAL.md) for the current milestone status.

To exercise SolMetal's developer-only launch-layer bootstrap before the normal
Vulkan guest renderer starts:

```bash
SOL_APPLE_SIGNING=off ./script/build_and_run.sh --solmetal-bootstrap
```

The bootstrap emits `solmetal.bootstrap-frame`; it is not a guest-renderer
selection and must not be treated as `launch.first-frame`.

To exercise the fail-closed embedded GAL renderer instead of creating a Vulkan
surface:

```bash
SOL_METAL_GAL_BACKEND=1 SOL_APPLE_SIGNING=off ./script/build_and_run.sh run
```

The first unsupported GAL contract stops this developer run with a precise
error. Normal launches remain on the stable Vulkan/MoltenVK backend until the
native path passes the full real-game lifecycle gate.

Build only the managed Sol Engine:

```bash
./script/build_sol_engine.sh
```

Build the Native AOT host bridge:

```bash
./script/build_sol_engine_native_host.sh
```

Audit the checked-in engine and public source tree:

```bash
./script/verify_sol_engine_source.sh
./script/audit_public_source.sh
```

Build and inspect the opt-in App Sandbox configuration:

```bash
./script/audit_sandbox.sh
```

That audit needs a provisioned Apple Development identity. The standard public
build remains unsandboxed until the sandbox configuration completes real-game
setup, launch, save, stop, and relaunch testing; see
[Security model](SECURITY_MODEL.md).

## Changing the Xcode project

`project.yml` is the source of truth for targets, build settings, versions,
entitlements, and generated Info plists. After editing it, regenerate the
checked-in project:

```bash
brew install xcodegen   # once, if needed
./script/generate_project.sh
```

Commit both `project.yml` and the generated `Sol.xcodeproj/project.pbxproj`.
New files under the target source folders are picked up by XcodeGen.

## Runtime layout

The post-build embedding step creates these important app paths:

```text
Sol.app/Contents/Frameworks/SolDLSM.framework
Sol.app/Contents/Frameworks/Sol.Engine.NativeHost.dylib
Sol.app/Contents/Frameworks/SolMetal.dylib
Sol.app/Contents/Resources/SolEngine/
Sol.app/Contents/Resources/SolEngineManaged/
Sol.app/Contents/Resources/Dotnet/
Sol.app/Contents/Resources/Legal/
```

Do not validate a runtime change with `swift test` alone. Build the Xcode app
and check the fresh bundle because missing managed files, host libraries, or
signatures only appear after packaging.

Runtime state belongs to Sol at `~/Library/Application Support/Sol`. The app
must not probe another application's data directory during launch. Existing
compatible engine data can be copied through the native **Import Existing
Data…** picker; imported items never overwrite current Sol files.

## Session changes

For launch, input, graphics, or lifecycle work, verify this whole sequence:

1. Start from a fresh Sol process.
2. Launch a game and wait for the first accepted frame.
3. Exercise the changed feature in windowed and fullscreen modes when relevant.
4. Stop from Sol rather than force-quitting.
5. Launch the same game again in the same process.

A window that says `Running` but remains black is not a successful renderer
test. Capture the engine event log and identify whether the failure happened
before surface attachment, during engine startup, or after frame submission.

## Release build

Build and verify the interim ad-hoc DMG locally:

```bash
./script/build_dmg.sh
./script/test_dmg_release.sh dist/Sol-*.dmg
```

The tag-driven GitHub workflow repeats the source audit, tests, Release build,
DMG inspection, public JIT entitlement checks, nested signature repair, and
checksum generation. Maintainer steps are in [RELEASING.md](RELEASING.md).

## Common problems

### Xcode cannot see a new Swift file

Run `./script/generate_project.sh`. The Swift package discovers files itself,
but the Xcode project is generated from `project.yml`.

### The engine is missing from the app

Run `./script/install_dotnet_sdk.sh`, then rebuild. Inspect the runtime paths
above rather than pointing Sol at a separate emulator installation.

### Keys, firmware, DLC, or games cannot be selected

Use Sol's native picker instead of typing a path. Sandboxed audit builds need a
security-scoped selection; the standard build also stores that bookmark so the
same path continues to work if sandboxing is enabled later.

If the files already live in another compatible engine-data folder, open
**Settings → System → Import Existing Data…**. Import is deliberately a user
action: a normal Sol launch must not request access to another app's data.

### A build appears to use stale code

Quit every running copy of Sol and rebuild. Xcode and `/tmp/sol-derived-data`
can contain separate apps with the same bundle identifier, so verify the exact
bundle path you launched.
