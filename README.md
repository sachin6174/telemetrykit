# TelemetryKit

TelemetryKit is a privacy-first observability SDK for iOS and macOS. It gives an app one bounded, thread-safe path for recording product-owned telemetry, persisting it while offline, and delivering it in batches without hiding data collection behind global swizzling.

The project is intentionally SDK-shaped: a small public API, Swift concurrency internally, an Objective-C facade, source and binary distribution, documentation, sample consumers, and verification focused on compatibility as well as correctness.

> [!IMPORTANT]
> TelemetryKit is under active development. Pin an exact version for production use, review the privacy configuration for every release, and treat the application—not the SDK—as the authority for consent and disclosure.

## What it provides

- Public Swift and Objective-C APIs.
- Swift Package Manager and XCFramework distribution paths.
- A synchronous, thread-safe capture path backed by actor-isolated pipeline state.
- A bounded in-memory buffer and offline disk queue.
- Batch delivery with exponential retry, jitter, cancellation, and backpressure.
- Opt-in `URLSession` performance instrumentation without method swizzling.
- OSLog/signpost diagnostics and opt-in MetricKit ingestion.
- A privacy manifest plus category and URL-detail controls.
- DocC articles, Swift and Objective-C sample consumers, and migration guidance.

## Privacy stance

TelemetryKit does not decide what your application is permitted to collect. Its controls are designed to make the decision explicit:

1. Start each client with an explicit consent state, and use `.granted` only after your application has established an appropriate collection basis.
2. Enable only the categories your product needs.
3. Keep URL collection at the least detailed setting that answers the performance question.
4. Never place secrets, authorization values, request or response bodies, raw user input, or direct identifiers in event attributes.
5. Treat a transition to `.pending` or `.denied` as destructive: TelemetryKit closes admission, cancels its active upload, and attempts to purge that client's in-memory and persisted queue. Handle a thrown storage error instead of assuming deletion succeeded.

An upload already accepted by the server cannot be recalled. A durable purge tombstone makes an interrupted deletion fail closed on the next startup. Use `eraseStoredData()` for an explicit local purge while consent otherwise remains granted.

Network instrumentation is limited to sessions created by the client. TelemetryKit does not globally intercept every request. Request/response bodies, cookies, and authorization headers are not observability inputs, although transfer byte counts are recorded. See the [privacy guide](Sources/TelemetryKit/TelemetryKit.docc/Privacy.md) for the integration checklist.

## Installation

### Swift Package Manager

The source package supports iOS 15 and macOS 12 or later. In Xcode, choose **File > Add Package Dependencies…**, enter this repository URL, select a version rule, and add the `TelemetryKit` product to the application target.

The versioned example below is the intended installation after publishing `0.1.0`; this checkout has not yet produced a verified release. Use the local package until that tag and its artifacts exist.

For a manifest-based consumer:

```swift
dependencies: [
    .package(
        url: "https://github.com/sachin6174/TelemetryKit.git",
        exact: "0.1.0"
    )
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "TelemetryKit", package: "TelemetryKit")
        ]
    )
]
```

For local development, choose **Add Local…** in Xcode or use `.package(path: "../TelemetryKit")`.

### XCFramework

Release artifacts can also contain `TelemetryKit.xcframework` with iOS device and iOS Simulator slices for consumers that cannot resolve Swift packages:

1. Download `TelemetryKit.xcframework.zip` and `TelemetryKit.xcframework.zip.sha256` from the same release. The adjacent `.checksum` file is the SwiftPM binary-artifact checksum value.
2. Verify the SHA-256 checksum before extracting the archive.
3. Drag `TelemetryKit.xcframework` into the Xcode project.
4. Add it to the application target under **Frameworks, Libraries, and Embedded Content** and select **Embed & Sign** for a dynamic artifact.
5. Confirm the framework's `PrivacyInfo.xcprivacy` is present in the archived application.

Do not mix the SwiftPM and XCFramework products in one target. CI should compile one fixture against each distribution form.

## Swift quick start

```swift
import Foundation
import TelemetryKit

let configuration = TelemetryConfiguration(
    endpoint: URL(string: "https://telemetry.example.com/v1/events")!,
    apiKey: "public-ingest-key",
    // Set this only after the app has established the user's collection choice.
    consent: .granted
)

let client = try await TelemetryClient.start(configuration: configuration)

let captureResult = client.capture(
    "checkout.started",
    attributes: [
        "plan": .string("pro"),
        "source": .string("settings")
    ],
    category: .custom,
    level: .info
)

do {
    let report = try await client.flush()
    print("Uploaded \(report.uploadedEventCount); \(report.remainingEventCount) remain")
} catch is CancellationError {
    // The caller cancelled the flush. Queued work remains governed by queue policy.
} catch {
    // Delivery failed or timed out. Inspect the error and keep the queue for a later attempt.
}

await client.shutdown(flush: true)
```

`captureResult` reports the immediate in-memory admission decision. Pending consent returns `.consentRequired` and does not hold the event for later. Even `.accepted` does not guarantee later persistence or server delivery: a bounded overflow policy, storage failure, expiry, permanent HTTP response, or cancellation can still leave an event unsent. Use `flush()` only at meaningful boundaries; flushing after every event defeats batching.

### Instrument an explicit URL session

```swift
let session = client.makeInstrumentedURLSession(configuration: .ephemeral)
let (data, response) = try await session.data(
    from: URL(string: "https://api.example.com/catalog")!
)
```

Only work performed by the returned session is instrumented. Existing shared or third-party sessions are unaffected.

Invalidate the returned session when its owner is finished with it. If the application already owns a `URLSessionDelegate`, forward `didFinishCollecting` to `TelemetryNetworkMetricsRecorder` instead of installing a second delegate.

### Measure application work

```swift
let span = client.startSpan("catalog.decode")

do {
    _ = try JSONDecoder().decode(Catalog.self, from: data)
    span.end(status: .ok, attributes: [:])
} catch {
    span.end(
        status: .error,
        attributes: ["error.type": .string(String(describing: type(of: error)))]
    )
    throw error
}
```

End every span exactly once. Prefer low-cardinality names and attributes.

## Objective-C quick start

```objc
@import TelemetryKit;

NSURL *endpoint = [NSURL URLWithString:@"https://telemetry.example.com/v1/events"];
TKTelemetryConfiguration *configuration =
    [[TKTelemetryConfiguration alloc] initWithEndpoint:endpoint
                                                apiKey:@"public-ingest-key"];

[TKTelemetryClient startWithConfiguration:configuration
                                completion:^(TKTelemetryClient * _Nullable client,
                                             NSError * _Nullable error) {
    if (client == nil) {
        NSLog(@"Telemetry failed to start: %@", error);
        return;
    }

    // Call this only after the app has established the user's collection choice.
    [client setConsent:TKTelemetryConsentGranted
             completion:^(NSError * _Nullable consentError) {
        if (consentError != nil) {
            NSLog(@"Consent update failed: %@", consentError);
            return;
        }

        [client captureEventNamed:@"checkout.started"
                       attributes:@{ @"plan": @"pro" }
                       completion:^(NSError * _Nullable captureError) {
            if (captureError != nil) {
                NSLog(@"Capture failed: %@", captureError);
            }
        }];
    }];
}];
```

The Objective-C facade reports asynchronous failures through completion handlers, which are invoked asynchronously on the main thread. The short capture selector emits custom/info events; an extended selector accepts `TKTelemetryCategory` and `TKTelemetryLevel`. `TKTelemetryConfiguration` mirrors category, queue, retry, privacy, instrumentation, timing, header, and storage controls and snapshots its mutable properties at startup. Objective-C callers can also request a flush report or queue status, create an instrumented session, and measure a span. Do not block the main thread waiting for a completion.

## Configuration

Create a separate configuration for each client; do not mutate it after starting the client. The exact value types and defaults are documented beside the public symbols in DocC.

| Setting | Purpose | Integration guidance |
| --- | --- | --- |
| `enabledCategories` | Filters manually produced, network, and span categories | Session and MetricKit options add their corresponding category when enabled. |
| `queueLimits` | Bounds encoded event payload count and bytes in memory and in the disk queue | File-envelope and filesystem overhead is outside `maximumDiskBytes`; size for a realistic offline interval. |
| `retryPolicy` | Controls scheduled retries, exponential delay, cap, and jitter | `maximumAttemptsPerCycle` counts retries after the initial request; a valid `Retry-After` can extend a delay, bounded to 24 hours. |
| `batchSize` | Caps events per upload | Tune together with byte limits. |
| `batchByteLimit` | Caps the complete encoded request | It must leave a small fixed-envelope allowance beyond `maximumEventBytes`; keep it below gateway and mobile-network limits. |
| `flushInterval` | Target cadence for automatic delivery | It is not a delivery deadline; short values cost radio wakeups and battery. |
| `flushTimeout` / `shutdownFlushTimeout` | Requests cancellation of explicit and shutdown-triggered flushes after a deadline | Shutdown remains nonthrowing and treats its flush as best effort. |
| `privacy.networkURLCollection` | Chooses how much URL detail is retained | Prefer host-only; query strings are always removed. |
| `instrumentation.sessionTrackingEnabled` | Enables foreground/background session events | Treat session identifiers as potentially linkable data. |
| `instrumentation.metricKitMetricsEnabled` / `metricKitDiagnosticsEnabled` | Enables Apple-provided payload families | Opt into each only after reviewing disclosure and retention. |
| `storageNamespace` / `storageDirectory` | Selects an isolated queue | A custom directory overrides default endpoint/namespace path derivation; ownership is lock-protected, but never intentionally share one queue across live clients or app processes. |

The API key is an ingestion credential intended for a shipped client. It must be narrowly scoped and revocable; never embed an administrative secret in an application.

The application owns the receiver. Implement its JSON, acknowledgement, retry, and idempotency behavior according to [SERVER_CONTRACT.md](SERVER_CONTRACT.md).

## Instrumentation caveats

### Network sessions

- TelemetryKit observes only `URLSession` instances it creates.
- It cannot retroactively instrument `URLSession.shared`, sessions owned by other SDKs, or requests created before the instrumented session.
- Background sessions are restored by iOS and have lifecycle constraints that differ from foreground sessions; validate them in a real host app.
- Task cancellation remains cancellation. Instrumentation must not retry an application request or turn cancellation into success.
- SDK upload requests are excluded from network telemetry to prevent recursive events.
- URLSession metrics can be partial for cache hits, redirects, connection reuse, and requests that fail before a task exists.

### MetricKit

MetricKit payload delivery is controlled by the operating system, delayed, aggregated, and not guaranteed for every launch. Simulator behavior is not representative. MetricKit should be treated as a supplemental signal, not a synchronous crash reporter or a source of real-time alerts. Test subscription and payload handling on physical devices, and expect payload schemas to evolve with the OS.

## Architecture

```text
app tasks / Objective-C callers
              |
              v
   synchronous admission
       |       |        |
       |       |        +--> OSLog + signposts
       |       +-----------> explicit URLSession / MetricKit adapters
       v
 bounded ingress --> actor-isolated pipeline
       v
 durable offline queue
       v
 batch planner --> transport --> retry policy with jitter
```

Actor-isolated runtime and disk-queue components serialize lifecycle transitions, persistence, and delivery ownership. Producers are subject to configured bounds; the SDK does not use unbounded fire-and-forget tasks as hidden storage. Disk persistence decouples local acceptance from network delivery. The uploader checks cancellation between queue, encode, delay, and transport operations.

The queue retains only bounded record metadata in memory and loads payloads for one bounded batch at a time. On a granted launch, recovered records are re-sanitized and filtered through the current category policy before delivery; tightened privacy settings therefore apply to offline work from an earlier launch.

Read the [architecture guide](Sources/TelemetryKit/TelemetryKit.docc/Architecture.md) for lifecycle and failure semantics and [instrumentation guide](Sources/TelemetryKit/TelemetryKit.docc/Instrumentation.md) for the supported observation boundaries.

## Verification

Authoritative iOS checks require macOS and Xcode. A typical local pass is:

```sh
swift build
swift test
xcodebuild docbuild -scheme TelemetryKit -destination 'generic/platform=iOS Simulator'
```

Generate and build each sample from its checked-in XcodeGen specification:

```sh
cd Examples/SwiftDemo
xcodegen generate
xcodebuild -project SwiftDemo.xcodeproj -scheme SwiftDemo \
  -destination 'generic/platform=iOS Simulator' build

cd ../ObjectiveCDemo
xcodegen generate
xcodebuild -project ObjectiveCDemo.xcodeproj -scheme ObjectiveCDemo \
  -destination 'generic/platform=iOS Simulator' build
```

Release CI should additionally exercise strict concurrency, Thread Sanitizer, cancellation, offline recovery, bounded-memory behavior, API compatibility, performance trends, DocC warnings, privacy-manifest validation, and both source and binary consumer fixtures.

## Documentation and examples

- [Getting started](Sources/TelemetryKit/TelemetryKit.docc/GettingStarted.md)
- [Privacy integration](Sources/TelemetryKit/TelemetryKit.docc/Privacy.md)
- [Architecture](Sources/TelemetryKit/TelemetryKit.docc/Architecture.md)
- [Instrumentation](Sources/TelemetryKit/TelemetryKit.docc/Instrumentation.md)
- [Swift sample](Examples/SwiftDemo/README.md)
- [Objective-C sample](Examples/ObjectiveCDemo/README.md)
- [Migration guide](MIGRATION.md)
- [Ingestion server contract](SERVER_CONTRACT.md)

Contributions are welcome under [CONTRIBUTING.md](CONTRIBUTING.md). Please report vulnerabilities using [SECURITY.md](SECURITY.md), not a public issue.
