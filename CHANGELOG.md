# Changelog

## 0.3.0-preview.1 — 2026-08-26

- Added the first end-to-end SolMetal renderer path, including native Metal
  resources, SPIR-V translation, presentation, lifecycle handling, and a
  versioned Sol Engine bridge.
- Added repeatable native, managed-bridge, compatibility, and visual regression
  tests for SolMetal. The renderer remains developer-only and reports itself as
  not yet playable.
- Added a native first-run setup and expanded profiles with custom avatars,
  play activity, captures, Save Vault, local friends, and opt-in iCloud backup
  foundations.
- Hardened rapid keyboard input, repeated game sessions, playtime checkpoints,
  shader-cache loading, and native engine teardown.
- Published this checkpoint as source only. The normal Vulkan/MoltenVK backend
  remains Sol's default, and public DLSM modes remain disabled.

## 0.2.1 — 2026-08-08

- Fixed fresh installs showing a missing `Config.json` error before Sol Engine
  had written its defaults.
- Fixed firmware ZIP installation by streaming NCA files through a bounded,
  disk-backed staging area instead of retaining every archive in memory.
- Added a real extracted-folder choice to the firmware picker and clearer
  errors for incomplete packages or mismatched production keys.
- Fixed the home carousel layout feedback loop and the remaining clipped card
  edge at the bottom of the window.
- Fixed a zero-sized Metal background surface during startup and corrected the
  app's macOS document-role declaration.
- Hardened launch/stop transitions against transient invalid layout sizes,
  stopped overriding application-wide presentation flags outside fullscreen,
  and isolated every emulation session on a fresh Metal render surface.
- Fixed rapid controller and keyboard changes leaving stale movement behind by
  isolating launcher input observation during gameplay and coalescing native
  key-state transitions.

## 0.2.0 — 2026-08-07

- Added the first downloadable Sol DMG and a verified native GitHub updater.
- Added native Library and Game Detail screens with exact-match high-resolution
  artwork and fixed card clipping.
- Fixed a shared-resource race in DLSM Spatial and kept source presentation
  visible until the MetalFX output is proven healthy.
- Added crash-resistant playtime checkpoints and bookmark-only, full-session
  game-folder security scope.
- Gave Sol its own engine-data directory with an explicit, non-destructive
  importer for compatible existing data.
- Added full engine/app CI, an App Sandbox audit build, and complete developer,
  release, security, and artwork documentation.

## 0.1.1 — 2026-08-04

- Included the complete patched Sol Engine source in the repository and GitHub
  source archives.
- Removed the external upstream clone step from normal builds.
- Added source-integrity checks for the pinned engine revision and native patch
  set.

## 0.1.0 — 2026-08-04

- Replaced the previous desktop frontend with a native SwiftUI and AppKit app.
- Added an embedded, UI-free Sol Engine runtime and native process bridge.
- Added native library, setup, controller, profile, content, multiplayer, and
  session surfaces.
- Added native launch activity, playtime updates, fullscreen handling, and
  repeat-session stability work.
