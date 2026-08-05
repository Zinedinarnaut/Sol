# Releasing Sol

Sol has separate source-preview and notarized-binary release stages. Do not
publish an unsigned or Apple Development-signed app as a public download.

## Source preview

1. Update `MARKETING_VERSION` in `project.yml` and regenerate the Xcode project.
2. Add release notes at `Docs/Releases/<version>.md`.
3. Merge the release changes into `main` and wait for CI to pass.
4. Create and push an annotated `v<version>` tag from that `main` commit.

The `Release` workflow validates the tag, project version, release notes,
public-source audit, and Swift tests. It then creates or updates a GitHub
prerelease. GitHub supplies the source `.zip` and `.tar.gz` downloads.

## Ad-hoc DMG (pre-notarization)

Until a Developer ID is available, each prerelease also ships an ad-hoc-signed
DMG so the app runs without building from source. The `Release` workflow builds
it from the tagged source (the `dmg-release` job) and attaches:

- `Sol-<version>-macOS.dmg` — Sol.app, deep ad-hoc signed, with an
  `/Applications` symlink for drag install.
- `Sol-<version>-macOS.dmg.sha256` — checksum.
- `dmg-signing.sh` — self-contained script a user runs after dragging Sol.app
  to `/Applications`, if they prefer it over "Open Anyway".

The DMG is not notarized, so macOS blocks it on first launch. Users approve it
via System Settings → Privacy & Security → **Open Anyway**, or by running
`dmg-signing.sh`, which re-applies the ad-hoc signature across the bundle and
clears the quarantine attribute. This is the interim path, not a replacement
for Developer ID + notarization.

Build and verify it locally (no Apple identity required):

```bash
./script/build_dmg.sh                     # -> dist/Sol-<version>-macOS.dmg
./script/test_dmg_release.sh dist/Sol-*.dmg
```

## Notarized app download

The app archive requires all of the following:

- A Developer ID Application certificate in the signing keychain
- The matching Apple Developer team identifier
- A working `notarytool` keychain profile
- Provisioning for every capability and bundled extension

Build, export, notarize, staple, and validate the app with:

```bash
SOL_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
SOL_NOTARY_PROFILE=YOUR_NOTARY_PROFILE \
./script/package_release.sh
```

After validating the resulting app on a clean Mac, attach the archive and its
checksum to the existing release:

```bash
VERSION=0.1.1
gh release upload "v$VERSION" \
  "dist/Sol-$VERSION-macOS.zip" \
  "dist/Sol-$VERSION-macOS.zip.sha256"
```

Never upload a local debug build, an Apple Development-signed archive, private
keys, provisioning profiles, games, firmware, or account data.
