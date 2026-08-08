# Releasing Sol

Sol has two distribution tiers: the current ad-hoc-signed Developer Preview and
the future Developer ID signed/notarized release. Both are built from a tag on
`main`; never upload a local debug app.

## Version contract

The release version lives in `project.yml`:

```yaml
MARKETING_VERSION: "0.2.1"
CURRENT_PROJECT_VERSION: "4"
```

For every release:

1. Increase both values and run `./script/generate_project.sh`.
2. Add user-facing notes at `Docs/Releases/<version>.md`.
3. Update `CHANGELOG.md` and any version-specific documentation.
4. Merge to `main` and wait for every CI job to pass.
5. Create an annotated `v<version>` tag on that `main` commit and push it.

The Release workflow rejects a tag that does not match `MARKETING_VERSION`,
lacks notes, or points outside `main`.

## Developer Preview DMG

Pushing the tag validates the source, builds and inspects the DMG, then creates
or updates a GitHub prerelease with all three assets together:

- `Sol-<version>-macOS.dmg`
- `Sol-<version>-macOS.dmg.sha256`
- `dmg-signing.sh`

The app and every nested executable/framework/extension are ad-hoc signed
innermost-first. `SolPublic.entitlements` enables Hardened Runtime with only the
JIT/runtime exceptions needed by Sol Engine. The integration test mounts the
image, validates those entitlements and the private runtime, deliberately
removes a nested extension signature, runs the repair helper, and verifies the
hierarchy again. It also checks that both the app metadata and main Mach-O
executable target macOS 15 even though the release uses the current Xcode
toolchain. A failed build never creates a new source-only release record.

Build the same artifact locally before tagging:

```bash
./script/build_dmg.sh
./script/test_dmg_release.sh dist/Sol-*.dmg
```

The preview is not notarized. Release notes and the README must tell users to
approve the first launch through System Settings → Privacy & Security. Do not
tell users to disable Gatekeeper globally.

## Updater requirements

The native updater considers a GitHub release installable only when it has both
the DMG and an asset named exactly `<dmg-name>.sha256`. It compares semantic
versions, downloads both assets over HTTPS, hashes the complete DMG, and opens
the image only after a match.

Do not rename only one asset, upload an unverified replacement, or move the
checksum into release prose. Updating an existing asset is allowed only when
the matching sidecar is replaced in the same release operation.

## Developer ID and notarization

A normal trusted release requires:

- Developer ID Application certificate
- Matching Apple Developer team identifier
- `notarytool` keychain profile
- Provisioning for the main app and all extensions/capabilities

Build, export, notarize, staple, and assess the archive with:

```bash
SOL_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
SOL_NOTARY_PROFILE=YOUR_NOTARY_PROFILE \
./script/package_release.sh
```

After testing the stapled app on a clean Mac, attach the zip and checksum to the
same tag. The in-app delivery path can move from verified DMG handoff to a
signed appcast/in-place updater only after this tier exists.

Never publish Apple Development-signed builds, provisioning profiles, signing
keys, games, firmware, title keys, account data, or local diagnostics.
