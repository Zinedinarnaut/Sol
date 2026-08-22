# Sol

Sol is a native macOS game-compatibility frontend and bundled emulation engine
for Apple Silicon. The library, setup flow, controller mapping, profiles,
settings, launch progress, and session controls are written in SwiftUI and
AppKit. Games render into an AppKit-owned Metal surface through Sol Engine,
Vulkan, and MoltenVK.

[![CI](https://github.com/Zinedinarnaut/Sol/actions/workflows/ci.yml/badge.svg)](https://github.com/Zinedinarnaut/Sol/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Zinedinarnaut/Sol?include_prereleases)](https://github.com/Zinedinarnaut/Sol/releases)
[![License](https://img.shields.io/github/license/Zinedinarnaut/Sol)](LICENSE)

![Sol graphics settings](Docs/Images/sol-settings.jpg)

Sol is young, but it is a complete project rather than a skin for another app.
Every clone contains the native frontend, the UI-free Sol Engine host, the
patched engine source, and the runtime packaging needed to build the app.

## Download

Download the latest macOS disk image from
[GitHub Releases](https://github.com/Zinedinarnaut/Sol/releases).

1. Open `Sol-<version>-macOS.dmg`.
2. Drag Sol to Applications.
3. Open Sol. The current developer-preview build is ad-hoc signed and not yet
   notarized, so macOS may block the first launch.
4. If it is blocked, open **System Settings → Privacy & Security** and choose
   **Open Anyway** for Sol.

The release also includes a SHA-256 checksum. A Developer ID signed and
notarized build will replace this interim install path once the distribution
identity is available. Sol never asks users to disable Gatekeeper globally.

## What is here today

- Native Home, Library, Game Detail, Settings, Profiles, and launch surfaces
- Direct launch through the bundled Sol Engine with no separate engine install
- Real shader/cache/engine progress instead of a blank loading window
- Pause, resume, stop, fullscreen, VSync, volume, screenshots, and Game Mode
- Keyboard and controller assignment with saved per-player remapping
- Keys, firmware, DLC, title-update, and content-folder management
- Local and internet multiplayer controls connected to the selected profile
- Playtime saved during a session, not only after a clean quit
- Exact-match, high-resolution cover and hero artwork with a local cache
- NFC-figure catalog browsing, Spotlight, widgets, Quick Look, Share, and `sol://`
- Sign in with Apple and iCloud profile linking in provisioned builds
- Verified GitHub update downloads with a native toolbar update button

![Sol controller mapping](Docs/Images/sol-controllers.jpg)

Sol never ships games, artwork, keys, firmware, or other system content.

## First run

1. Open Settings and choose the folder containing your own game backups.
2. Under System, install keys and firmware sourced from hardware you own.
3. Add DLC and title updates under Content if a game needs them.
4. Assign a keyboard or controller under Controllers.
5. Pick a game and press Play.

Sol keeps its engine state in `~/Library/Application Support/Sol`. It does not
inspect another emulator's folders at startup. If you already have compatible
keys, firmware, profiles, or saves, use **Settings → System → Import Existing
Data…** and choose the old data folder yourself. Sol copies missing items and
does not replace files already in its own directory.

Sol requires an Apple Silicon Mac running macOS 15 or later.

## Build from source

The generated Xcode project is checked in. A normal build does not need a
separate engine checkout or a system-wide .NET installation.

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
```

On a Mac with a provisioned Apple Development identity, omit
`SOL_APPLE_SIGNING=off` to build and launch the signed app. See
[Development](Docs/DEVELOPMENT.md) for engine-only builds, project generation,
sandbox audits, troubleshooting, and release checks.

## Project map

```text
Sources/
  Sol/                 Native macOS app, services, models, and views
  SolDLSM/             Metal and MetalFX reconstruction library
  SolWidgets/          Widget extension
  SolQuickLook/        Finder Quick Look extension
  SolShare/            Share extension
NativeHost/
  Sol.Engine/          UI-free managed Sol Engine entry point
  Sol.Engine.NativeHost/  Stable native ABI bridge
Vendor/                Pinned, buildable upstream engine source
script/
  patches/             Reviewable upstream changes used by Sol Engine
Tests/SolTests/        Swift regression and boundary tests
Docs/                  Architecture, development, research, and release notes
```

The engine source is pinned to upstream commit
`a82350bb774f70fcbd41c9987bf67a3775409963`. Generated engine artifacts are
ignored; the source compiled into Sol is included in each clone and source
archive. Its origin, license, and integration boundary are documented in
[Sol Engine architecture](Docs/SOL_ENGINE_ARCHITECTURE.md).

## DLSM

DLSM (Deep Learning Super Metal) is Sol's Apple-Silicon graphics research
layer. Public builds keep it disabled while the developer pipeline is being
validated. Spatial uses MetalFX and is the current clean baseline. Temporal
reconstruction and frame generation remain research paths until they have
correct, game-aware depth, motion, jitter, camera, and timing inputs.

The current M4 10-core GPU baseline used the same warmed, 30 FPS test scene.
DLSM Quality rendered 2026 × 1103 → 3024 × 1646, 55.1% fewer internal pixels.

| Mode | Source → output FPS | GPU busy | DLSM GPU median / p95 | Metal memory | Process CPU<sup>*</sup> |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native / Off | 30.0 → 30.0 | 48.1% | 0 ms | 317.5 MiB | 60.4% |
| Spatial Quality | 30.0 → 30.0 | 42.3% | 1.27 / 3.30 ms | 371.9 MiB | 84.4% |
| Temporal Quality | 30.0 → 30.0 | 60.0% | 11.54 / 18.16 ms | 633.9 MiB | 77.7% |
| Temporal + Frame Gen | 21.6 → 43.2 | 72.4% | ≈23.02 / 25.60 ms | 714.4 MiB | 87.2% |

<sup>*</sup> 100% CPU is one fully occupied CPU core.

Spatial held 30 FPS with about 12% less GPU activity in this capped scene.
Temporal added cost without a performance benefit, and frame generation raised
output to 43.2 FPS while lowering real rendering to 21.6 FPS. This measures
pipeline overhead, not a general performance uplift; an unlocked, GPU-bound
scene is still needed. The complete status and validation gates live in
[DLSM.md](Docs/DLSM.md).

## Privacy and legal

Sol has no analytics service. Network requests are limited to features the user
opens or enables: artwork metadata, NFC-figure data, multiplayer, updates, and Apple
account/iCloud services. Games, keys, firmware, saves, and room credentials stay
local.

Sol Engine builds on MIT-licensed third-party components. Copyright notices,
source provenance, and dependency licenses are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and are embedded in packaged
apps. Sol is independent and is not affiliated with or endorsed by its
upstream projects, platform vendors, or game publishers.

Product-facing naming follows [the public naming policy](Docs/PUBLIC_NAMING.md).
Required upstream names stay in technical provenance and legal notices.

## Contributing

Bug reports and focused pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) first, keep protected content out of reports,
and describe the launch/render/stop/relaunch path you tested for session work.
