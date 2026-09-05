# Validation status

Last validation: 2026-09-05, on a Mac over SSH in an isolated source snapshot.
Toolchain: macOS 26.6.2, Xcode 26.6 (17F113), Apple Swift 6.3.3.
Simulator: iPhone Air, iOS 26.5.

## Verified

- Strict Swift formatting lint passed, including the binary staging manifest.
- Optimized macOS `swift test -c release`: 118 tests passed, zero failures.
- Generic iOS device and universal simulator builds passed with complete strict-concurrency checking and warnings as errors.
- iOS simulator: 119 tests passed (67 unit, 41 integration, 5 performance, 6 real-network runtime), zero failures. The additional iOS test covers file protection and backup exclusion.
- All 119 simulator tests passed with Thread Sanitizer enabled, with no sanitizer issues reported. The saturation test retains its workload and assertions but omits the XCTest resource-measurement wrapper in this lane; see [the isolated harness limitation](PERFORMANCE.md).
- Both Swift and Objective-C sample applications passed three consecutive automated UI-test iterations covering consent, capture, revocation, re-enabling, and relaunch with collection off. Builds were separately checked with warnings as errors. Tests verify switch state explicitly and use a short physical press to avoid the simulator's intermittently missed tap.
- DocC documentation build succeeded.
- Release XCFramework archives succeeded for device arm64 and simulator arm64/x86_64, with library evolution enabled.
- Each binary slice contains Swift interfaces, a module map, the generated Objective-C header, and the privacy manifest.
- Standalone Swift and Objective-C compatibility fixtures passed compiler checks against device arm64 and both simulator arm64/x86_64 binary slices. Intel simulator checks are now included in the distribution script.
- Seven tests passed against the actual simulator XCFramework: six public-API real-network tests and an Objective-C lifecycle/callback test. No source-package dependency is linked into this consumer.
- Real HTTP tests cover schema/redaction, retry identity, persistence through shutdown/restart, redirect blocking, consent cancellation/purge, and sanitized URLSession metrics. The first five also passed 20 consecutive optimized runs (100 test executions).
- Public-capture saturation stayed at 500 queued events and within configured serialized-byte limits; CPU and physical-memory measurements are recorded in [PERFORMANCE.md](PERFORMANCE.md).
- The distributable zip and SwiftPM/SHA-256 checksums were generated. The checksum was verified again after transfer to Windows.

The Mac run exposed and fixed type-inference and Darwin symbol issues, bounded privacy-key handling, sample compiler warnings, and SwiftPM archive metadata/resource packaging. Source distribution retains its privacy resource bundle; binary distribution uses a resource-free staging manifest and embeds the privacy manifest in each framework.

Runtime validation additionally found and fixed missing dynamic-framework embedding
and project generation overwriting the sample launch property lists. CI and release
workflows now run binary and UI tests. Release publication refuses to overwrite an
existing version's artifacts.

## Evidence and artifacts

Local, git-ignored output is under `Artifacts/`: the XCFramework zip and adjacent checksum files, plus validation logs in `Artifacts/Validation/`.

Validated zip SHA-256:

```text
227fee28a78006326acfee4856c97e978e8d3cf22713e32d2e165c9a93c863bc
```

## Release gates still open

- Physical-device MetricKit delivery and OSLog/signpost inspection in Instruments.
- The declared minimum-OS and older-Xcode compatibility matrix; this run used one current Xcode and simulator runtime.
- End-to-end acceptance against the application's staging ingestion service, including TLS/authentication and server deduplication; loopback HTTP does not validate that deployment.
- Reviewed performance and memory baselines on representative hardware; passing measurement tests does not establish production budgets.
- Hosted CI and release workflows, published repository/tag/artifacts, and compatibility comparison against a prior release (none exists yet).

This is a Mac-tested SDK candidate, not a production release certification.
