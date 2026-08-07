# Security and capabilities

Sol combines a native macOS app with an in-process .NET runtime and a CPU JIT.
That makes its security boundary different from a normal document app. This
document records which capabilities are intentional and which ones are not
part of the shipping target.

## Standard build

The standard Sol target is currently not App Sandbox enabled. It loads a bundled
runtime, executes JIT code, scans a user-selected library, and can host local
multiplayer traffic. Sol owns `~/Library/Application Support/Sol` and never
probes another application's data directory during startup. A native import
picker can copy missing compatible items into Sol's directory after the user
explicitly selects a source; existing Sol files are not overwritten.

Provisioned Release archives enable Hardened Runtime and use the narrow runtime
exceptions needed by the engine:

- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-library-validation`

The more dangerous `disable-executable-page-protection` exception is not used.
Widgets, Quick Look, and Share extensions are already sandboxed.

The downloadable ad-hoc preview is signed with `SolPublic.entitlements`. It
keeps Hardened Runtime and the three exceptions above, but deliberately omits
Sign in with Apple, iCloud, notifications, and App Group entitlements that an
ad-hoc identity cannot legitimately claim.

## Sandbox audit build

`SolSandbox.entitlements` adds App Sandbox, incoming and outgoing network
access, user-selected read-only files, and the same JIT/runtime exceptions.
`./script/audit_sandbox.sh` builds a provisioned app with that entitlement set,
verifies the nested signatures, and confirms that App Sandbox, file selection,
network access, and every JIT/runtime exception are present in the final code
signature.

The library is opened only through its security-scoped bookmark; Sol never
falls back to probing a stored plain-text path. A stale or invalid bookmark asks
the user to choose the folder again instead of producing a broad Files & Folders
prompt during startup. The scope remains active for the full emulation session.
The sandbox build is not the public default until it passes a real title through
setup, launch, render, save, stop, and relaunch. The explicit engine-data
importer is covered by focused filesystem tests, but it does not replace that
end-to-end validation.

## Apple services

The main provisioned target declares Sign in with Apple, iCloud key-value
storage, time-sensitive notifications, and the Sol App Group. These services
fail closed when the local signing team or provisioning profile does not grant
them. The ad-hoc public preview does not claim that Apple account services are
available.

## Capabilities intentionally omitted

- Low-Latency Streaming is a visionOS capability, not a macOS game-performance
  switch.
- The multicast entitlement requires Apple approval and is not required for
  ordinary macOS local-network sockets. Sol keeps the local-network usage
  description and sandbox client/server access instead.
- Increased memory and debugging limits are not production macOS performance
  controls. The public target does not request them.
- Sol does not disable Gatekeeper, executable page protection, or system
  integrity features.

## Distribution status

The GitHub developer-preview DMG is deep ad-hoc signed and checksum verified,
but not notarized. Gatekeeper therefore requires an explicit first-launch
approval. A Developer ID Application certificate and notarization are required
before Sol can offer a normal trusted installer or silent in-place update.
