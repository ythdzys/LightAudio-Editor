# macOS parity verification — 20 October 2026

`platform-parity/verification.json` records the final implementation checks: 102 passes in the full 108-test run and all six initially failing tests passing after test-only corrections. Application sources did not change between those runs. The report includes source fingerprints, addressed behavior and runtime limitations.

`platform-parity/audit.json` and its source manifests are historical, before the parity fixes. `macos-media/verification.json` records the earlier export/relink milestone; its format-version and synchronous-verification limitations were subsequently addressed by this parity implementation.

The XCTest suites are `LightAudio EditorTests/MediaPortabilityTests.swift` and `LightAudio EditorTests/PlatformParityTests.swift`, alongside the existing regressions. Run them using the Xcode command documented in the repository README. Large result bundles and build products remain outside the repository.

`platform-parity/run-probe.py macos` runs the original five small renderer probes against this checkout. Use `ipad --source-root /path/to/Shared` for a reference checkout. Generated fixtures and results go to a temporary folder unless `--output` is provided. Localization is stubbed only in this standalone probe; the application regression suites use the actual localized AppKit controls.
