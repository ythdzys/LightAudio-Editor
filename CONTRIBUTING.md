# Contributing to LightAudio Editor

Thank you for helping improve LightAudio Editor. The project is in public beta, so reproducible bug reports and narrowly scoped fixes are especially valuable.

## Report a Bug

Use the GitHub bug report template and include:

- macOS version and Mac architecture (`Intel` or `Apple silicon`)
- LightAudio Editor version and build number
- Source media format, codec details when known, and approximate duration
- Exact steps that reproduce the issue
- Expected and actual behavior
- Error messages, screenshots, or a small non-confidential sample project when useful

Before filing, check existing issues and test the latest beta when practical. Never attach copyrighted or private media without permission.

## Propose a Change

For substantial behavior or architecture changes, open an issue first. LightAudio Editor targets macOS Catalina 10.15 and later and uses Swift with AppKit; changes must preserve that compatibility and should follow existing architecture and UI conventions.

Keep pull requests focused. Avoid unrelated formatting, generated build products, personal Xcode settings, or destructive project-format changes.

## Contribution Terms

The first-party macOS project is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE), with scope and exclusions described in [NOTICE](NOTICE). This is a source-available noncommercial license, not an OSI-approved open-source license.

Issue reports and feature discussions are welcome. Do not submit a code contribution unless the maintainer has agreed to it in advance. A separate contributor agreement may be required before a pull request can be merged so that contributions can be maintained across the public macOS project and separately licensed products. Unsolicited code submissions may be closed without being merged.

By submitting an accepted contribution, you represent that you have the right to provide it and agree to the contribution terms confirmed with the maintainer. Submitting a pull request by itself does not change ownership or grant rights beyond the repository license.

## Build and Test

```bash
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  build
```

```bash
xcodebuild \
  -project "LightAudio Editor.xcodeproj" \
  -scheme "LightAudio Editor" \
  -configuration Debug \
  -derivedDataPath Build/DerivedData \
  test
```

Please add focused regression coverage for behavioral fixes. Changes affecting import, timeline editing, playback, or export should be exercised through the full import-edit-export workflow.

## Project Safety

- Never modify original imported media.
- Keep `.liau` files backward compatible by providing defaults for new fields.
- Keep waveform, proxy, recovery, and build output outside project documents.
- Keep media processing off the main thread.
- Do not commit credentials, signing identities, notarization secrets, or downloaded upstream source archives.
