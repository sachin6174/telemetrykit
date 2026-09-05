# Changelog

All notable changes to TelemetryKit will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases are intended to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Dates use ISO 8601.

## [Unreleased]

### Added

- Initial Swift and Objective-C SDK surfaces.
- Real-HTTP public API tests shared by SwiftPM and XCFramework runtime consumers.
- Objective-C binary lifecycle and sample consent/capture/revocation/relaunch UI tests.
- Saturated public-capture CPU/memory measurements and documented release acceptance gates.
- Synchronous bounded admission with actor-isolated persistence and delivery.
- Count- and payload-byte-bounded memory and offline disk queues with age and overflow policies.
- Batched transport with exponential retry, jitter, and cancellation.
- Explicit URLSession instrumentation, OSLog/signposts, and MetricKit integration.
- Privacy controls and `PrivacyInfo.xcprivacy` packaging.
- Consent revocation that closes admission, cancels active delivery, and surfaces failure if client-owned queued data cannot be fully purged.
- Durable purge tombstones, capture privacy revisions, recovered-event policy reconciliation, and redirect-resistant upload handling.
- Metadata-only disk recovery so offline capacity does not become equivalent resident payload memory.
- Main-thread Objective-C completion callbacks plus configuration, typed capture, status, flush-report, network-session, and span wrappers.
- SwiftPM and XCFramework distribution workflows.
- DocC, sample consumers, migration and ingestion-server guidance, and verification suites.

### Security

- Documented private vulnerability-reporting expectations.

### Fixed

- Apple-toolchain compilation of disk locking and throwing continuations.
- Sensitive-key recognition when attribute string limits are very small.
- Swift and Objective-C sample compilation under warnings-as-errors.
- Library-evolution XCFramework resource handling and installation of Swift modules and Objective-C compatibility metadata.
- Sample projects now embed the dynamic SwiftPM product and preserve their checked-in launch property lists.
- Release publishing refuses to overwrite an existing version's binary artifacts and requires runtime and sanitizer validation.

Release links will be added when the repository publishes its first tagged version.
