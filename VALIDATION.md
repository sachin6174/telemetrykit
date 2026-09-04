# Validation status

Last local validation: 2026-09-05, Windows with Swift 6.3.3.

- Strict Swift formatting lint passed.
- Syntax parsing passed for all 40 Swift files, including samples and compatibility fixtures.
- Bash syntax checks passed for all four distribution and validation scripts.
- The SDK privacy manifest and four sample property lists previously passed `plutil -lint`.
- The suite contains 112 test methods. They have not been executed on this host.

Syntax parsing does not establish type correctness, Apple API availability, Objective-C interoperability, or runtime correctness. SwiftPM manifest execution on this host fails at linking because the Visual C++ libraries `msvcrt.lib`, `oldnames.lib`, and `msvcprt.lib` are absent. Xcode and Apple SDKs are unavailable here.

Before release, run the checked-in CI on macOS: device and simulator builds, simulator tests with strict concurrency, Thread Sanitizer, both sample apps, DocC, and XCFramework consumer checks. Verify MetricKit delivery on a physical device. Inspect performance measurements before claiming throughput or memory results. Hosted runner and action availability still needs a successful CI run.

The repository has no published release or validated XCFramework yet. Do not treat this document as release certification.
