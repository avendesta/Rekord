# Releasing Rekord

## Branches

Day-to-day work happens on `dev`. When a feature is done, open a pull request from `dev` to `main`. CI builds the pull request, and merging it is what can trigger a release (below).

## Automatic releases

Pushing to `main` runs `.github/workflows/release.yml`. It reads `MARKETING_VERSION` from `project.yml`; if that version has no GitHub Release yet, it builds a universal `Rekord.app`, zips it, and publishes the release. Pushes that don't change the version do nothing.

If signing credentials are configured (below), the build is signed with your Developer ID, notarized by Apple and stapled, so it opens without any warning. With none of them set, the workflow falls back to an unsigned build. With only some set (or one empty), it fails and names the missing secrets, so a release is never published unsigned by accident.

To ship a release:

1. Add a `## <version>` section to `CHANGELOG.md`. It becomes the release notes.
2. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`.
3. Merge the pull request into `main`. The release follows within a few minutes (the first notarization from a new Apple account can take hours); watch the **Actions** tab.

`.github/workflows/ci.yml` also builds every pull request, so a merge can't break the build.

### Signing credentials

Add these as secrets of the **`release`** GitHub Environment (Settings > Environments > release). Only the protected `main` branch can use that environment, and pull requests and forks never see the secrets.

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Your Developer ID Application certificate and private key, exported as a `.p12` file and base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you chose when exporting the `.p12` |
| `NOTARY_APPLE_ID` | The Apple ID email used for notarization |
| `NOTARY_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID |

1. In Keychain Access, open **My Certificates**, expand **Developer ID Application: ...** (so the private key is included), right-click it, choose **Export**, save as `DeveloperID.p12`, and set a password.
2. In Terminal, store the secrets (each command prompts for the value, or reads it from a pipe, so nothing lands in shell history):

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12 --env release --repo <owner>/Rekord
   gh secret set DEVELOPER_ID_CERT_PASSWORD --env release --repo <owner>/Rekord
   gh secret set NOTARY_APPLE_ID --env release --repo <owner>/Rekord
   gh secret set NOTARY_PASSWORD --env release --repo <owner>/Rekord
   ```

3. Delete `DeveloperID.p12`, or keep it somewhere safe. It contains your private signing key.

The team ID is read from the certificate, so it isn't a secret. To try the pipeline without releasing, run **Actions > Release > Run workflow** on `main`: it builds, signs and notarizes, then uploads the zip as a workflow artifact (kept 7 days) and publishes nothing.

If a secret ever leaks, revoke the certificate at developer.apple.com and the app-specific password at appleid.apple.com, then create new ones.

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

Notarization usually takes a few minutes, but the first submission from a new account can take hours. The script prints the submission id and polls Apple every 30 seconds, riding out network drops. If a run is interrupted, pick the same submission back up without rebuilding:

```sh
NOTARY_PROFILE=<profile-name> scripts/release-signed.sh --resume <submission-id>
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

## Mac App Store

The App Store build is the same app with the **App Sandbox** turned on (`Rekord/Resources/RekordAppStore.entitlements`). Everything works inside the sandbox; the one difference is the output folder. A sandboxed app can only write to its own container unless the user picks a folder, so Settings remembers the chosen folder with a security-scoped bookmark. The direct-download build stays unsandboxed and keeps its default of `~/Documents/Rekord`. The direct build and the App Store build both use the bundle ID `com.avendesta.rekord`.

### One-time setup (in Apple's portals)

1. **App ID.** developer.apple.com > Certificates, Identifiers & Profiles > Identifiers: make sure `com.avendesta.rekord` exists for macOS. Automatic signing creates it for you the first time you export.
2. **App record.** appstoreconnect.apple.com > Apps > + > New App: platform macOS, name **Rekord** (App Store names are unique, so check it is free), primary language, bundle ID `com.avendesta.rekord`, and a SKU such as `rekord-macos`.
3. **Xcode account.** Xcode > Settings > Accounts: sign in with the Apple ID that owns the developer account. The export step uses it to create the *Apple Distribution* and *Mac Installer Distribution* certificates and the provisioning profile for you (this needs the Account Holder or Admin role).
4. **Store page** (App Store Connect > the app > App Information / the version page):
   - Category: Productivity. Age rating questionnaire. Price and availability.
   - Description, keywords, promotional text, and **What's New**.
   - **Support URL:** the GitHub repository. **Privacy Policy URL:** `https://github.com/<owner>/Rekord/blob/main/PRIVACY.md`.
   - **Screenshots:** 16:10, one of 1280x800, 1440x900, 2560x1600 or 2880x1800 (1 to 10 of them).
   - **App Privacy:** "Data Not Collected" (Rekord collects nothing).
   - **App Review Information:** explain that Rekord records system audio and the microphone on the user's request, needs the Microphone and System Audio Recording permissions, shows a red menu bar indicator while recording, and has no login. Suggested steps: open the menu bar icon, press Start Recording, play any audio, press Stop, then open Recent Recordings.

### Build and upload

```sh
ARCHIVE_ONLY=1 scripts/build-appstore.sh   # dry run: archive and check the sandbox and privacy manifest
scripts/build-appstore.sh                  # archive and export a signed .pkg to build/appstore/export/
UPLOAD=1 scripts/build-appstore.sh         # archive and upload straight to App Store Connect
```

Every upload needs a build number (`CURRENT_PROJECT_VERSION` in `project.yml`) higher than the last upload. After the upload finishes processing (5 to 30 minutes), the build appears in App Store Connect > TestFlight. Install it from **TestFlight** on your Mac to try it, then attach it to the version on the store page and **Submit for Review**.
