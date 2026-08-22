<p align="center">
  <img src="Docs/Images/sol-logo.png" width="144" height="144" alt="Sol logo">
</p>

<h1 align="center">Sol</h1>

<p align="center">
  Native macOS emulation, built for Apple Silicon.
</p>

<p align="center">
  <a href="https://github.com/Zinedinarnaut/Sol/actions/workflows/ci.yml"><img src="https://github.com/Zinedinarnaut/Sol/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="https://github.com/Zinedinarnaut/Sol/releases"><img src="https://img.shields.io/github/v/release/Zinedinarnaut/Sol?include_prereleases" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Zinedinarnaut/Sol" alt="License"></a>
</p>

<p align="center">
  <a href="https://github.com/Zinedinarnaut/Sol/releases"><strong>Download the latest preview</strong></a>
  ·
  <a href="#build-from-source">Build from source</a>
  ·
  <a href="https://github.com/Zinedinarnaut/Sol/issues">Report a bug</a>
</p>

Sol is a SwiftUI and AppKit frontend with a bundled, UI-free Sol Engine. The
app owns the library, setup, profiles, controller mapping, launch progress, and
game controls. Games render into an AppKit-owned Metal surface through the
current Vulkan and MoltenVK backend.

This is an early developer preview for Apple Silicon Macs running macOS 15 or
later. It is usable, but compatibility and repeated-session stability are still
being widened with every release.

## Download

Get the current disk image from [GitHub Releases](https://github.com/Zinedinarnaut/Sol/releases).

1. Open `Sol-<version>-macOS.dmg`.
2. Drag Sol to Applications.
3. Open Sol.

Preview builds are ad-hoc signed and not yet notarized. If macOS blocks the
first launch, open **System Settings → Privacy & Security** and choose
**Open Anyway** for Sol. Sol never asks you to disable Gatekeeper globally.

## What works

- Native Home, Library, Game Detail, Settings, Profiles, and launch screens
- Bundled Sol Engine with no separate engine checkout or frontend to install
- Keys, firmware, DLC, title updates, content folders, mods, and cheats
- Keyboard and controller assignment with saved per-player mappings
- Shader and cache progress instead of a blank launch window
- Pause, resume, stop, fullscreen, VSync, volume, screenshots, and Game Mode
- Playtime checkpoints that survive a crash or forced quit
- Local and internet multiplayer controls tied to the selected profile
- High-resolution cover and background artwork with a local cache
- NFC-figure browsing, Spotlight, widgets, Quick Look, Share, and `sol://`
- Native GitHub update checks with verified downloads

Sol releases do not include games, artwork, keys, firmware, or other system
content.

## First run

1. Open Settings and choose the folder containing your own game backups.
2. Under System, install keys and firmware sourced from hardware you own.
3. Add DLC or title updates under Content when needed.
4. Assign a keyboard or controller under Controllers.
5. Pick a game and press Play.

Sol keeps its engine state in `~/Library/Application Support/Sol`. It does not
inspect another emulator's folders automatically. To bring over compatible
keys, firmware, profiles, or saves, use **Settings → System → Import Existing
Data…** and choose the old data folder yourself. Existing Sol files are not
overwritten.

## Build from source

The generated Xcode project and the complete engine source are checked in. The
setup script installs a project-local .NET SDK, so it does not change your
system-wide installation.

```bash
git clone https://github.com/Zinedinarnaut/Sol.git
cd Sol
./script/install_dotnet_sdk.sh
SOL_APPLE_SIGNING=off ./script/build_and_run.sh --build
```

The app is written to:

```text
/tmp/sol-derived-data/Build/Products/Debug/Sol.app
```

Run the regression suite with:

```bash
swift test
./script/audit_public_source.sh
./script/audit_public_branding.sh
```

On a Mac with an Apple Development identity, omit `SOL_APPLE_SIGNING=off` to
build and launch a signed app. [Development](Docs/DEVELOPMENT.md) covers
engine-only builds, project generation, sandbox audits, and troubleshooting.

## Project layout

```text
Sources/Sol/                       macOS app, services, models, and views
Sources/SolDLSM/                   Metal and MetalFX reconstruction library
Sources/SolWidgets/                widget extension
Sources/SolQuickLook/              Finder Quick Look extension
Sources/SolShare/                  share extension
NativeHost/Sol.Engine/             UI-free managed engine host
NativeHost/Sol.Engine.NativeHost/  stable native ABI bridge
Vendor/                            pinned, buildable engine source
script/                            build, audit, packaging, and patch tools
Tests/SolTests/                    Swift regression and boundary tests
Docs/                              architecture, development, and research notes
```

The engine source is pinned to upstream commit
`a82350bb774f70fcbd41c9987bf67a3775409963`. Its origin, license, and native
integration boundary are documented in
[Sol Engine architecture](Docs/SOL_ENGINE_ARCHITECTURE.md).

## DLSM

DLSM (Deep Learning Super Metal) is Sol's Apple-Silicon graphics research
layer. Public builds keep it disabled while Spatial, Temporal reconstruction,
and frame generation are validated against correct game-aware inputs.

<details>
<summary><strong>M4 10-core GPU benchmark snapshot</strong></summary>

The same warmed, 30 FPS scene was rendered at 2026 × 1103 and presented at
3024 × 1646, reducing the internal pixel count by 55.1%.

| Mode | Source → output FPS | GPU busy | DLSM GPU median / p95 | Metal memory | Process CPU<sup>*</sup> |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native / Off | 30.0 → 30.0 | 48.1% | 0 ms | 317.5 MiB | 60.4% |
| Spatial Quality | 30.0 → 30.0 | 42.3% | 1.27 / 3.30 ms | 371.9 MiB | 84.4% |
| Temporal Quality | 30.0 → 30.0 | 60.0% | 11.54 / 18.16 ms | 633.9 MiB | 77.7% |
| Temporal + Frame Gen | 21.6 → 43.2 | 72.4% | ≈23.02 / 25.60 ms | 714.4 MiB | 87.2% |

<sup>*</sup> 100% CPU is one fully occupied CPU core.

Spatial held 30 FPS with about 12% less GPU activity. Temporal added cost
without improving this capped scene, while Frame Generation raised displayed
output to 43.2 FPS and lowered real rendering to 21.6 FPS. This measures
pipeline overhead, not a general performance uplift.

</details>

The full status and acceptance gates are in [DLSM.md](Docs/DLSM.md).

## Privacy and legal

Sol has no analytics service. Network access is limited to features you open or
enable, including artwork metadata, NFC-figure data, multiplayer, updates, and
Apple account or iCloud services. Games, keys, firmware, saves, and room
credentials stay local.

Sol Engine builds on MIT-licensed third-party components. Copyright notices,
source provenance, and dependency licenses are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and are embedded in packaged
apps. Sol is independent and is not affiliated with or endorsed by its
upstream projects, platform vendors, or game publishers.

Product copy follows [the public naming policy](Docs/PUBLIC_NAMING.md). Required
upstream names stay in technical provenance and legal notices.

## Contributing

Bug reports and focused pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md), keep protected content out of reports, and
include the launch, render, stop, and relaunch path you tested for session work.
