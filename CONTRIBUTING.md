# Contributing to Sol

Sol is still an early project. Small fixes with a clear reproduction and a
focused diff are the easiest changes to review.

## Before opening an issue

- Reproduce the problem with the latest source build.
- Check whether it happens before launch, during engine startup, or only after
  the first rendered frame.
- Include the macOS version, Mac model, controller model, and relevant Sol log
  lines.
- Remove usernames, local paths, Apple account data, room codes, and title keys
  from logs.
- Never upload games, firmware, keys, save data, or other copyrighted system
  content.

Compatibility reports should name the title and describe the behavior; they
should not include content files.

## Development setup

```bash
./script/install_dotnet_sdk.sh
SOL_APPLE_SIGNING=off ./script/build_and_run.sh --build
swift test
```

Run `./script/generate_project.sh` after editing `project.yml`. It needs
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Pull requests

- Keep native UI work in SwiftUI/AppKit and avoid introducing a second desktop
  UI framework.
- Keep engine changes in `NativeHost` or the bundled `Vendor/Ryubing` source,
  and update the corresponding review patch under `script/patches`.
- Add a regression test when a bug can be reproduced without protected content.
- Describe what you tested on a fresh app launch and, for session changes,
  through launch, render, stop, and relaunch.
- Do not commit engine build output, credentials, system files, game content,
  or personal Xcode data.

For broad architecture changes, open a discussion before investing in a large
patch.
