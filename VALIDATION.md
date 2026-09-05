# Validation status

Last validation: 2026-09-05, on a Mac over SSH in an isolated source snapshot.
Toolchain: macOS 26.6.2, Xcode 26.6 (17F113), Apple Swift 6.3.3.
Simulator: iPhone Air, iOS 26.5.

## Verified

- Strict Swift formatting lint passed, including the binary staging manifest.
- macOS `swift test`: 111 tests passed, zero failures.
- Generic iOS device and universal simulator builds passed with complete strict-concurrency checking and warnings as errors.
- iOS simulator: 112 tests passed (67 unit, 41 integration, 4 performance), zero failures. The additional iOS test covers file protection and backup exclusion.
- The same 112 simulator tests passed with Thread Sanitizer enabled; no sanitizer issues were reported.
- Both Swift and Objective-C sample applications built for the simulator with warnings as errors. Interactive sample flows were not manually exercised.
- DocC documentation build succeeded.
- Release XCFramework archives succeeded for device arm64 and simulator arm64/x86_64, with library evolution enabled.
- Each binary slice contains Swift interfaces, a module map, the generated Objective-C header, and the privacy manifest.
- Standalone Swift and Objective-C compatibility fixtures passed compiler checks against device arm64 and simulator arm64 binary slices. These are compile checks, not binary-consumer runtime tests.
- The distributable zip and SwiftPM/SHA-256 checksums were generated. The checksum was verified again after transfer to Windows.

The Mac run exposed and fixed type-inference and Darwin symbol issues, bounded privacy-key handling, sample compiler warnings, and SwiftPM archive metadata/resource packaging. Source distribution retains its privacy resource bundle; binary distribution uses a resource-free staging manifest and embeds the privacy manifest in each framework.

## Evidence and artifacts

Local, git-ignored output is under `Artifacts/`: the XCFramework zip and adjacent checksum files, plus validation logs in `Artifacts/Validation/`.

Validated zip SHA-256:

```text
227fee28a78006326acfee4856c97e978e8d3cf22713e32d2e165c9a93c863bc
```

## Release gates still open

- Physical-device MetricKit delivery and OSLog/signpost inspection in Instruments.
- The declared minimum-OS and older-Xcode compatibility matrix; this run used one current Xcode and simulator runtime.
- Interactive sample testing, binary-consumer runtime smoke testing, and an end-to-end run against a real ingestion service.
- Reviewed performance and memory baselines on representative hardware; passing measurement tests does not establish production budgets.
- Hosted CI and release workflows, published repository/tag/artifacts, and compatibility comparison against a prior release (none exists yet).

This is a Mac-tested SDK candidate, not a production release certification.
