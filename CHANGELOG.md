# Changelog

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
- Removed the external Ryubing clone step from normal builds.
- Added source-integrity checks for the pinned engine revision and native patch
  set.

## 0.1.0 — 2026-08-04

- Replaced the previous desktop frontend with a native SwiftUI and AppKit app.
- Added an embedded, UI-free Sol Engine runtime and native process bridge.
- Added native library, setup, controller, profile, content, multiplayer, and
  session surfaces.
- Added native launch activity, playtime updates, fullscreen handling, and
  repeat-session stability work.
