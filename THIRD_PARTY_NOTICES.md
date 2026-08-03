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

## Apple frameworks

Sol links against system frameworks supplied with macOS, including SwiftUI,
AppKit, Metal, MetalFX, GameController, AuthenticationServices, and WidgetKit.
Their use is governed by Apple's SDK and platform terms.

This summary does not replace the license files embedded with a binary
distribution.
