# LightAudio Editor Beta Release Guide

LightAudio Editor Beta 2 uses bundle identifier `com.ythdzys.LightAudioEditor`, marketing version `0.1.1`, and build number `2`.

The release is one Universal app containing both `x86_64` and `arm64`. Its Intel slice supports macOS Catalina 10.15 and later. Its Apple silicon slice supports macOS Big Sur 11.0 and later, which is the first macOS release available for Apple silicon Macs.

## Apple Developer Requirement

A paid Apple Developer Program membership is required to distribute a Developer ID-signed and notarized macOS beta outside the Mac App Store. A free Apple ID can build and run the app locally, but it cannot provide the Developer ID Application certificate required by Gatekeeper and Apple's notary service.

Apple references:

- [Developer ID](https://developer.apple.com/developer-id/)
- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

At the time this workflow was added, this Mac had no valid Developer ID code-signing identities installed.

## One-Time Account Setup

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/) as an individual or organization.
2. In Xcode, open **Xcode > Settings > Accounts** and add the enrolled Apple ID.
3. Register the explicit macOS App ID `com.ythdzys.LightAudioEditor` in Certificates, Identifiers & Profiles.
4. As the Account Holder, create a **Developer ID Application** certificate and install it in the login keychain. Xcode can manage the certificate, or it can be created on the Apple Developer website.
5. Find the certificate name and Team ID:

   ```bash
   security find-identity -v -p codesigning
   ```

6. Create an app-specific password for the enrolled Apple ID, then store notarization credentials in Keychain. The command prompts securely for values that are omitted:

   ```bash
   xcrun notarytool store-credentials "LightAudioEditor-notary" \
     --apple-id "YOUR_APPLE_ID" \
     --team-id "YOUR_TEAM_ID"
   ```

Do not put certificate keys, Apple passwords, app-specific passwords, or App Store Connect keys in this repository.

## Build a Signed Universal Beta

Run from the repository root. Use the exact identity shown by `security find-identity`:

```bash
APPLE_TEAM_ID="YOUR_TEAM_ID" \
DEVELOPER_ID_APPLICATION="Developer ID Application: Yishun Zhao (YOUR_TEAM_ID)" \
./Scripts/build-beta.sh
```

The script:

- Archives the Release configuration for generic macOS.
- Requires both `arm64` and `x86_64` in the executable.
- Requires an Intel minimum system version of macOS 10.15 and an Apple silicon minimum of macOS 11.0.
- Validates the bundled FFmpeg helper's architectures, deployment targets, and AAC/MP3/FLAC encoders.
- Packages the exact verified FFmpeg/LAME source archives and reproducible build script in a separate corresponding-source ZIP.
- Applies version, build, and bundle metadata.
- Signs the nested encoder helper before resealing and verifying the complete app.
- Places a signed but explicitly unnotarized ZIP under `Build/Beta/`.

Running the script without signing variables creates an ad-hoc-signed Universal build named `ADHOC-UNNOTARIZED`. The script seals the complete app bundle and verifies its signature, architectures, deployment targets, version, build number, and bundle identifier before packaging it. Ad-hoc signing requires no Apple Developer account, but it does not establish the developer's identity and does not satisfy Gatekeeper automatically.

## Test an Ad-Hoc Beta

An ad-hoc build can be shared with trusted beta testers before Developer ID setup is complete. On first launch, the tester must attempt to open the app and then choose **Open Anyway** under **System Settings > Privacy & Security**. On Catalina, this control is under **System Preferences > Security & Privacy > General**. Managed Macs may prevent this override.

Do not tell testers to disable Gatekeeper globally. Replace the ad-hoc GitHub asset with a Developer ID-signed and notarized build when credentials become available.

## Notarize and Package

Use the app path printed by the build script:

```bash
NOTARYTOOL_PROFILE="LightAudioEditor-notary" \
./Scripts/notarize-beta.sh "Build/Beta/.../LightAudio Editor.app"
```

The script submits with `notarytool`, waits for acceptance, staples and validates the ticket, runs a Gatekeeper assessment, and creates the final tester ZIP plus a SHA-256 checksum.

Attach both the final `LightAudio-Editor-0.1.1-beta-2-macOS.zip` and the generated `LightAudio-Editor-0.1.1-Bundled-Encoder-Source.zip` to the GitHub prerelease. The second asset provides corresponding source for the LGPL FFmpeg/LAME helper distributed inside the app.

## Versioning Future Builds

- Keep `MARKETING_VERSION` at `0.1.1` for Beta 2 fixes.
- Increment `CURRENT_PROJECT_VERSION` for every distributed build.
- Change the marketing version only for a new user-facing beta or release.
- Tag the Beta 2 source as `v0.1.1-beta.2` after tests and packaging checks pass. Replace the ad-hoc asset with a signed and notarized build when Developer ID credentials become available.
