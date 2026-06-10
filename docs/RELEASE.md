# Release Setup

The hosted release workflow is `.github/workflows/release.yml`. It runs on
GitHub-hosted macOS, builds the Xcode app target, signs with Developer ID,
notarizes and staples the app and DMG, generates a Sparkle appcast, and uploads
the release assets to GitHub Releases.

## Required GitHub Actions Secrets

These are maintainer-only repository secrets:

- `CSC_LINK`: base64 contents of the Developer ID Application `.p12`
  certificate export
- `CSC_KEY_PASSWORD`: password for the `.p12` export
- `APPLE_ID`: Apple ID email used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for `notarytool`
- `APPLE_TEAM_ID`: Apple Developer team ID

Sparkle needs one additional secret:

- `SPARKLE_PRIVATE_KEY`: the private EdDSA key used by Sparkle `generate_appcast`

## Required GitHub Actions Variable

- `SPARKLE_PUBLIC_ED_KEY`: the public EdDSA key embedded into the release app's
  `SUPublicEDKey` Info.plist value

Generate the Sparkle key pair once with Sparkle's `generate_keys` tool. After
resolving the Sparkle package locally, the tool is under
`SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`.

```bash
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project Mactions.xcodeproj \
  -scheme MactionsApp \
  -clonedSourcePackagesDirPath SourcePackages

GENERATE_KEYS="SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
"$GENERATE_KEYS" --account com.kyter.mactions
"$GENERATE_KEYS" --account com.kyter.mactions -p
"$GENERATE_KEYS" --account com.kyter.mactions -x /tmp/mactions-sparkle-private-key
```

Put the printed public key in `SPARKLE_PUBLIC_ED_KEY`, and store the exact
contents of `/tmp/mactions-sparkle-private-key` as the `SPARKLE_PRIVATE_KEY`
secret.

## Releasing

Push a version tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Or run the workflow manually and provide `0.1.0`. The workflow creates or updates
the matching GitHub Release and uploads:

- `Mactions-<version>.dmg`
- `Mactions-<version>.zip`
- `appcast.xml`
- `Mactions-<version>.md`
- `checksums.txt`
