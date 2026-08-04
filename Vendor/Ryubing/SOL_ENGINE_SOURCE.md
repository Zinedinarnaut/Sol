# Bundled Sol Engine source

This directory contains the complete buildable upstream engine source used by
Sol, pinned to Ryubing commit
`a82350bb774f70fcbd41c9987bf67a3775409963`. Sol's runtime, stability,
native-surface, multiplayer, and DLSM patches are already applied to this
checked-in source.

The Sol-specific managed entry point and native ABI bridge live in
`NativeHost/Sol.Engine` and `NativeHost/Sol.Engine.NativeHost`. The build uses
those projects with the engine modules in this directory. It does not download
another engine checkout.

The vendored dependency graph retains the upstream engine modules, required
native assets, and licensing. Upstream desktop applications, distribution
artwork, and Avalonia views are deliberately excluded because Sol replaces
them with its native SwiftUI/AppKit application. The build fails if Avalonia,
FluentAvalonia, Projektanker, or another desktop UI artifact enters the runtime
dependency graph.
