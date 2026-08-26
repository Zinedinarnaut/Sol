# Third-party notices

Sol is distributed under the MIT License, but it builds on projects with their
own copyright holders and license terms.

## Ryujinx and Ryubing

Sol Engine is derived from the Ryujinx/Ryubing codebase and is built from a
pinned Ryubing source revision. That code is available under the MIT License.
A copy is kept at `ThirdParty/Ryujinx/LICENSE.txt` and is embedded in Sol builds.

The engine also carries dependencies under MIT, BSD, Apache, LGPL, and other
licenses. During a build, Sol copies the complete upstream notice file from
`Vendor/Ryubing/distribution/legal/THIRDPARTY.md` into the app at
`Contents/Resources/Legal/UPSTREAM-THIRD-PARTY-NOTICES.md`.

## .NET runtime

Packaged Sol builds include a private .NET runtime. The .NET runtime is
MIT-licensed and includes additional third-party software. The build copies
`.tools/dotnet/LICENSE.txt` and `.tools/dotnet/ThirdPartyNotices.txt` into the
app at `Contents/Resources/Legal`.

## SPIRV-Cross

SolMetal statically compiles a pinned subset of KhronosGroup/SPIRV-Cross for
SPIR-V reflection and Metal Shading Language generation. The exact upstream
commit is recorded in `ThirdParty/SPIRV-Cross/REVISION`, and the Apache License
2.0 text is kept in `ThirdParty/SPIRV-Cross/LICENSE`. Packaged builds copy that
license to `Contents/Resources/Legal/SPIRV-CROSS-LICENSE.txt`.

## Apple frameworks

Sol links against system frameworks supplied with macOS, including SwiftUI,
AppKit, Metal, MetalFX, GameController, AuthenticationServices, and WidgetKit.
Their use is governed by Apple's SDK and platform terms.

## Native Swift packages

Sol's macOS interface uses the following Swift packages:

- DockProgress, WhatsNewKit, SwiftUI-Shimmer, Glur, ColorfulX,
  SpringInterpolation, MSDisplayLink, and ColorVector under the MIT License.
- Swift Argument Parser under the Apache License 2.0 with Runtime Library
  Exception.
- SemanticVersion under the Apache License 2.0.

`Package.resolved` records the exact source revision included by a build. The
upstream repositories retain their copyright notices and complete license
texts; those terms continue to apply to each package. Sol's build copies every
package license into `Contents/Resources/Legal` beside this notice.

This summary does not replace the license files embedded with a binary
distribution.
