# Releasing Rekord

## Branches

Day-to-day work happens on `dev`. When a feature is done, open a pull request from `dev` to `main`. CI builds the pull request, and merging it is what can trigger a release (below).

## Automatic releases

Pushing to `main` runs `.github/workflows/release.yml`. It reads `MARKETING_VERSION` from `project.yml`; if that version has no GitHub Release yet, it builds a universal, ad-hoc signed `Rekord.app`, zips it, and publishes the release. Pushes that don't change the version do nothing.

To ship a release:

1. Add a `## <version>` section to `CHANGELOG.md`. It becomes the release notes.
2. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`.
3. Merge the pull request into `main`. The release follows within a few minutes; watch the **Actions** tab.

`.github/workflows/ci.yml` also builds every pull request, so a merge can't break the build.

These workflows produce **unsigned** builds. For a signed and notarized release, follow the manual steps below.

## Releasing by hand

A release is a zipped `Rekord.app` attached to a GitHub Release. Pick a path:

- **A. Unsigned (free).** Works today. Users must approve the app once in macOS (see the README's install note).
- **B. Signed and notarized.** Needs a paid Apple Developer Program membership. Opens without any warning, and is what Homebrew expects.

Both start the same way.

## 1. Prepare

1. Bump `MARKETING_VERSION` in `project.yml` and commit.
2. Publish the commit to GitHub.
3. Build from a clean checkout of that commit.

## 2A. Build unsigned

Builds a universal (Apple silicon + Intel) app with an ad-hoc signature and zips it:

```sh
VERSION=0.1.0
xcodegen generate
xcodebuild -project Rekord.xcodeproj -scheme Rekord -configuration Release \
  -derivedDataPath build/release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
cd build/release/Build/Products/Release
ditto -c -k --keepParent Rekord.app "Rekord-$VERSION.zip"
```

`ditto` keeps the app bundle intact, which plain `zip` can break.

## 2B. Build signed and notarized

Requires a **Developer ID Application** certificate in your keychain and notarization credentials stored once with `xcrun notarytool store-credentials`.

Before the first signed release, add an entitlements file with `com.apple.security.device.audio-input` set to true and enable the hardened runtime. Without that entitlement a hardened app gets no microphone. Then test the signed build for both microphone and system audio.

```sh
xcodebuild ... CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=<team id> \
  ENABLE_HARDENED_RUNTIME=YES build
ditto -c -k --keepParent Rekord.app Rekord-$VERSION.zip
xcrun notarytool submit Rekord-$VERSION.zip --keychain-profile <profile> --wait
xcrun stapler staple Rekord.app
ditto -c -k --keepParent Rekord.app Rekord-$VERSION.zip   # re-zip the stapled app
```

(These signed-build steps haven't been run yet.)

## 3. Publish the GitHub Release

With the [GitHub CLI](https://cli.github.com):

```sh
git tag v$VERSION <commit on main>
git push origin v$VERSION
gh release create v$VERSION "Rekord-$VERSION.zip" --title "Rekord $VERSION" --notes "What's new..."
```

Or on github.com: **Releases > Draft a new release**, choose or create the tag, attach the zip, and publish.

Push only `main` and release tags. Never push the local `dev` branch.

## 4. Homebrew (optional, signed builds only)

Create a tap repo `homebrew-tap` with `Casks/rekord.rb` pointing at the release zip and its SHA-256 (`shasum -a 256 Rekord-$VERSION.zip`), then users install with `brew install --cask <you>/tap/rekord`.
