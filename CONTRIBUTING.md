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

By submitting a contribution, you confirm that you have the right to provide it. The project does not currently declare an open-source license; discuss licensing expectations with the maintainer before making a substantial contribution.
