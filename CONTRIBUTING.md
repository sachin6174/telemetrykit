# Contributing to TelemetryKit

Thank you for helping improve TelemetryKit. SDK changes affect many host applications, so compatibility, privacy, failure behavior, and documentation are part of the implementation—not follow-up work.

By participating, you agree to [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Development environment

Use a macOS version and Xcode toolchain supported by the package manifest and CI. The command-line Swift toolchain can run platform-neutral checks, but UIKit, URLSession task metrics, OSLog/signposts, MetricKit, Objective-C interop, simulator tests, and XCFramework creation require Xcode on macOS.

Clone the repository, open `Package.swift` in Xcode, and resolve dependencies. Do not commit user-specific Xcode state, generated sample projects, DerivedData, result bundles, signing identities, or credentials.

## Before opening a change

Run the checks relevant to the change:

```sh
swift build
swift test
xcodebuild docbuild -scheme TelemetryKit \
  -destination 'generic/platform=iOS Simulator'
```

Generate each example from its `project.yml` and build it. Changes involving concurrency or lifecycle should also run the Thread Sanitizer lane. Changes involving persistence or transport need tests for corruption, cancellation, backpressure, retryability, and relaunch behavior.

CI is authoritative for the complete supported-Xcode matrix and binary-distribution checks.

## Test expectations

- **Unit tests:** deterministic value, encoding, queue, batching, retry, and state-machine behavior.
- **Integration tests:** disk persistence, recovery, cancellation, mocked transport, URLSession instrumentation, and MetricKit adapters.
- **Compatibility tests:** public Swift/Objective-C consumers and both SwiftPM/XCFramework forms.
- **Performance tests:** capture throughput, allocation/retained-memory bounds, queue recovery, and batch encoding in Release configuration.

Avoid wall-clock sleeps in tests. Inject clocks, random-number sources, file locations, and transport seams so retry and failure cases stay deterministic.

## Public API changes

Before changing a public symbol:

1. Describe the consumer problem, including Objective-C impact.
2. Prefer additive changes and source-compatible defaults.
3. Add or update symbol documentation and a sample call site.
4. Add compatibility coverage for both distribution forms.
5. Record user-visible behavior in [CHANGELOG.md](CHANGELOG.md).
6. Add an upgrade recipe to [MIGRATION.md](MIGRATION.md) when consumer action is required.

Public APIs must not expose implementation actors, storage formats, concrete transports, or unstable OS payload types unnecessarily.

Changes to request headers, JSON fields, value encoding, acknowledgement handling, or retryable status codes must update [SERVER_CONTRACT.md](SERVER_CONTRACT.md), add receiver fixtures, and either remain compatible with the current `schemaVersion` or introduce a deliberate version transition.

## Privacy review

Every collection or instrumentation change must answer:

- What exact data can enter an event?
- Is collection off or minimized by default?
- Can the application configure, redact, or omit it?
- Can values contain secrets or direct identifiers?
- What persists to disk, for how long, and under which bounds?
- Does the privacy manifest or App Store disclosure guidance change?
- Are logs and signposts using appropriate privacy annotations?
- What happens after consent changes?

Call out privacy impact explicitly in the pull request even when the answer is “none.”

## Pull requests

Keep changes focused. Include motivation, API/behavior changes, tests added, performance evidence when relevant, privacy impact, and migration notes. Screenshots are useful for sample UI changes; concise logs are useful for binary-layout or compatibility checks. Never paste real event payloads, tokens, or customer endpoints into an issue or pull request.
