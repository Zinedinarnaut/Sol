# Sol Engine for macOS

The macOS app owns every user-facing surface in SwiftUI and AppKit. Sol Engine
remains the emulation engine.

## Boundary

- `Sources/Sol`: native library, settings, commands, controllers,
  session state, system-file management, and diagnostics.
- `NativeHost/Sol.Engine.NativeHost`: a .NET Native AOT shared library with a
  deliberately small C ABI.
- `NativeHost/Sol.Engine`: an Apple-only managed component
  assembled from upstream emulation, configuration, input, audio, and renderer
  sources. It compiles no Avalonia package or view.
- `Vendor/Ryubing`: an ignored, pinned upstream checkout fetched by
  `script/fetch_ryubing_source.sh`.

The app embeds its bundled .NET runtime with `hostfxr` and resolves a small set
of unmanaged-callable entry points. The separate Native AOT bridge remains the
discovery and compatibility boundary. Both bridges expose only C-compatible
values, opaque handles, and callbacks; Swift never receives a managed object.

The main Sol target is deliberately unsandboxed. Launching the bundled
engine process, scanning an arbitrary game library, and updating Sol Engine's
configuration are core features. Widgets and Finder extensions remain
sandboxed and receive only the minimum App Group access they need.

## Current runtime

1. The SwiftUI shell loads only the bundled Apple runtime inside the Sol
   process. There is no external or legacy UI launch path.
2. The runtime sends versioned event payloads for engine readiness, game state,
   title metadata, pause state, fullscreen state, volume, screenshots,
   failures, applet dialogs, keys, and firmware.
3. Native controls send pause, resume, graceful stop, Cocoa fullscreen, volume,
   VSync, screenshot, keys installation, and firmware installation commands
   back to the engine.
4. AppKit owns the in-window `NSView` and its `CAMetalLayer`. SDL 3 wraps that
   existing Cocoa surface while MoltenVK presents the Vulkan renderer through
   Apple's native window stack. SDL is a platform and input layer here, not an
   application UI toolkit.
5. Software-keyboard, confirmation, controller, error, and Amiibo applet
   prompts cross the protocol and are presented as native AppKit dialogs.
6. Controller discovery and player routing use the engine's SDL device IDs;
   the native Controller pane can install default Sol Engine mappings for players
   1–8 or handheld mode.
7. SwiftUI and AppKit own every settings, home, loading, confirmation,
   management, and live-control surface. The shipped engine dependency graph
   contains no Avalonia, FluentAvalonia, or Projektanker package.
8. DLSM gives MoltenVK a sub-native presentation surface, exports that
   low-resolution texture and command queue through `VK_EXT_metal_objects`,
   and presents a full-resolution MetalFX result in a native overlay layer.
   Spatial and Temporal are active today. Temporal prefers validated native
   depth and motion when available, otherwise a Metal-only reconstruction
   provider derives bounded motion and a reactive mask from frame history.
   Versioned DLSM Frame ABI v2 can transport native depth, motion, jitter, and
   camera data once a game-aware renderer provider supplies those semantics.
   Frame Generation remains gated behind that stricter native contract.

The engine and surface now share the Sol process, so Cocoa pointers never
cross a process boundary. The Swift host owns their lifetime; the managed
runtime borrows opaque `NSView` and `CAMetalLayer` pointers for the duration of
one emulation session.

## ABI rules

- The Native AOT library exports the protocol version, capability bitset, and
  native defaults through a small C-compatible discovery ABI.
- Swift never receives a managed object reference.
- Long-running emulation runs on the managed runtime's emulation thread.
  Swift pumps versioned events and sends commands without blocking the main
  actor.
- The AOT library is process-lifetime and is not unloaded at runtime.
- The in-process surface API keeps Cocoa ownership in the macOS app and exposes
  only C-compatible values, opaque handles, and callbacks.
- DLSM Frame ABI v2 is a 144-byte append-only frame description. Its
  Objective-C Metal pointers are borrowed and first bridged only inside the
  synchronous callback. Swift may retain the bounded active Metal swapchain set
  for that renderer session, releases it before Vulkan teardown, and never
  retains a managed reference.

## Upstream

Sol Engine is built from Ryubing's maintained Ryujinx fork at commit
`a82350bb774f70fcbd41c9987bf67a3775409963`. Ryujinx is MIT licensed; its
upstream copyright and license remain in redistributed source and binaries.
