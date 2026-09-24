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

`scripts/release-signed.sh` does the whole thing: it builds a universal `Rekord.app`, signs it with your **Developer ID Application** certificate (hardened runtime, secure timestamp), checks it, sends it to Apple for notarization, staples the ticket, and zips it as `build/signed/Rekord-<version>.zip`.

One-time setup:

1. Create a **Developer ID Application** certificate (Xcode > Settings > Accounts > Manage Certificates > +). The script finds it in your keychain automatically.
2. Save notarization credentials, using an [app-specific password](https://support.apple.com/102654) for your Apple ID:

   ```sh
   xcrun notarytool store-credentials <profile-name> --apple-id <you@example.com> --team-id <TEAMID>
   ```

Then, for each release:

```sh
NOTARY_PROFILE=<profile-name> scripts/release-signed.sh
```

Upload the resulting zip to the GitHub Release (step 3). `SKIP_NOTARIZE=1 scripts/release-signed.sh` builds and signs only, which is useful for testing the signing setup; that zip must not be distributed.

The app needs the `com.apple.security.device.audio-input` entitlement (in `Rekord/Resources/Rekord.entitlements`) to use the microphone under the hardened runtime, and Release builds must not contain `get-task-allow`. The script checks for both.

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
