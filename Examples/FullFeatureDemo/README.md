# TelemetryKit Full Feature Demo

This guided UIKit application exercises the complete public Swift API of the local TelemetryKit package. It is intentionally separate from `SwiftDemo`: the small sample teaches the shortest integration, while this project is an interactive feature laboratory and reference implementation.

## What the project demonstrates

- A complete `TelemetryConfiguration`, with every setting explicitly chosen.
- Pending, granted, and denied consent transitions.
- All `TelemetryValue` cases: string, integer, double, Boolean, array, object, and null.
- All `TelemetryLevel` and `TelemetryCategory` cases.
- Typed-event and convenience capture APIs with immediate capture results.
- Privacy redaction, nesting/collection/string limits, and host-plus-path URL collection.
- Bounded memory/disk queues, drop-oldest overflow, expiry, and a dedicated namespace.
- Retry, batching, request, periodic flush, explicit flush, shutdown flush, and invalid-timeout behavior.
- Queue snapshots and complete flush reports.
- Successful, cancelled, and failed spans, including end-once protection.
- Network metrics through the client convenience API, the static factory API, and a `TelemetryNetworkMetricsRecorder` forwarded by an application-owned delegate.
- Automatic session tracking, MetricKit metrics, and MetricKit diagnostics configuration.
- Local erasure, best-effort background flush, and permanent shutdown.

MetricKit payloads arrive on Apple's schedule and generally cannot be forced during a short simulator run. Enabling both MetricKit options demonstrates the integration; use a physical device and allow iOS time to deliver real payloads.

## Safe default behavior

The upload endpoint is `https://telemetry.example.invalid/v1/events`. The `.invalid` domain is reserved, so this demo cannot accidentally upload events to a real collector. Instrumented example requests go to `https://example.com`; TelemetryKit records bounded task metrics but never bodies, credentials, query strings, or fragments.

Because the upload endpoint is intentionally unreachable, Flush is expected to report a transport error after its bounded retry cycle. Replace the endpoint and placeholder key only when testing against a controlled development receiver implementing the repository's `SERVER_CONTRACT.md`.

## Generate, build, and run

Requirements: Xcode and XcodeGen.

```sh
cd Examples/FullFeatureDemo
xcodegen generate
open TelemetryKitFullFeatureDemo.xcodeproj
```

Select an iOS Simulator or device and run `TelemetryKitFullFeatureDemo`.

For a command-line build:

```sh
xcodebuild -project TelemetryKitFullFeatureDemo.xcodeproj \
  -scheme TelemetryKitFullFeatureDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Run the full SDK journey automatically

The UI test launches the real application and taps through the full golden path. It verifies pending-consent rejection, granted capture, every value/level/category, all span outcomes, three network instrumentation integrations, queue status, timeout validation, the real bounded retry failure for the safe `.invalid` endpoint, local erasure, consent transitions, shutdown, and rejection after shutdown.

```sh
xcodebuild -project TelemetryKitFullFeatureDemo.xcodeproj \
  -scheme TelemetryKitFullFeatureDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TelemetryKitFullFeatureDemoUITests/FullFeatureFlowUITests/testCompleteTelemetryKitFeatureJourney \
  test
```

Network instrumentation calls `https://example.com`, so those three checks require network access. MetricKit subscription is configured and started after consent, but actual MetricKit payload delivery remains controlled by iOS and requires separate physical-device observation.

## Golden path

Tap the numbered actions from 1 through 12:

1. Start with pending consent.
2. Grant consent.
3. Capture every typed value.
4. Capture every severity and category.
5. End spans with success, cancellation, and error.
6. Perform a client-created instrumented request.
7. Perform a factory-created instrumented request.
8. Forward metrics from an app-owned delegate.
9. Inspect the queue snapshot.
10. Attempt delivery and inspect the result or expected offline error.
11. Erase locally queued telemetry.
12. Shut down permanently and observe rejection after shutdown.

The unnumbered actions demonstrate consent reversal and invalid timeout handling. For example, capture before granting consent to see `consentRequired`, or deny consent after capturing to exercise destructive revocation.

## Production differences

This is an SDK showcase, not a ready-made legal consent screen or backend configuration. A shipping app must provide reviewed disclosure, persist its application-owned consent decision, enable only necessary categories, supply a narrowly scoped ingestion key, size queues for real traffic, validate its receiver, and inspect the merged privacy manifest in an archived build.
