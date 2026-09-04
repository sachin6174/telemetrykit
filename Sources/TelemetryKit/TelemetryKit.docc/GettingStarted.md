# Getting Started

Add TelemetryKit to an app, grant collection deliberately, capture a typed event, and shut the client down cleanly.

## Add the SDK

The Swift package supports iOS 15 and macOS 12 or later. Release XCFrameworks contain iOS device and iOS Simulator slices. Add the `TelemetryKit` library product with Swift Package Manager, or embed the XCFramework when an iOS host cannot use SwiftPM. Do not link both forms into the same target.

For a local checkout in Xcode, choose **File > Add Package Dependencies… > Add Local…** and select the repository root.

## Configure before starting

Configuration is copied into a new independent client. Set consent and optional behavior before calling `start(configuration:)`:

```swift
import Foundation
import TelemetryKit

var configuration = TelemetryConfiguration(
    endpoint: URL(string: "https://telemetry.example.com/v1/events")!,
    apiKey: "public-ingest-key",
    consent: .granted
)

configuration.enabledCategories = [.custom, .network, .span]
configuration.queueLimits = TelemetryQueueLimits(
    maximumMemoryEventCount: 250,
    maximumMemoryBytes: 512 * 1_024,
    maximumEventCount: 5_000,
    maximumDiskBytes: 10 * 1_024 * 1_024,
    maximumEventBytes: 32 * 1_024,
    maximumEventAge: 3 * 24 * 60 * 60,
    overflowPolicy: .dropOldest
)
configuration.retryPolicy = TelemetryRetryPolicy(
    initialDelay: 1,
    maximumDelay: 60,
    maximumAttemptsPerCycle: 6
)
configuration.privacy.networkURLCollection = .host

let client = try await TelemetryClient.start(configuration: configuration)
```

Use HTTPS outside controlled local tests. The SDK rejects credentials embedded in the endpoint URL and prevents sensitive or transport-owned headers from being added through `additionalHeaders`.

Consent defaults to `.pending`. Starting with `.pending` or `.denied` opens the selected storage namespace and removes telemetry left there from an earlier client, but it does not accept new events; startup fails if that purge fails. When consent changes from `.granted` to either non-granted state, TelemetryKit closes the synchronous capture gate, stops configured session and MetricKit adapters, cancels its active upload, and attempts to purge its in-memory and persisted queues. Handle a thrown storage error instead of assuming deletion succeeded. A request already accepted by the server cannot be recalled.

Use `try await client.setConsent(.granted)` to begin collection after the application establishes its collection basis. Use `try await client.eraseStoredData()` when the product needs an explicit local purge without changing consent.

## Capture an event

Capture is synchronous and briefly synchronizes access to the bounded ingress. It returns the local decision without waiting for disk or network I/O.

```swift
let result = client.capture(
    "checkout.started",
    attributes: [
        "plan": .string("pro"),
        "item_count": .integer(2),
        "restored": .boolean(false)
    ],
    category: .custom,
    level: .info
)

switch result {
case .accepted:
    break
case .consentRequired, .collectionDisabled:
    // Expected when the application has not enabled this collection path.
    break
case .eventTooLarge, .queueFull:
    // Reduce payload size or revisit deliberately bounded queue settings.
    break
case .invalidEvent, .clientStopped:
    // Record an application-local diagnostic if it is useful.
    break
}
```

Names should be stable and low cardinality. Put dimensions in typed attributes, but never put tokens, raw user input, full URLs, or direct identifiers there.

`enabledCategories` defaults to custom, network, session, and span events. Removing a category rejects captures in that category as `.collectionDisabled`. Enabling session or MetricKit instrumentation explicitly adds its own category to the effective set, so automatic-signal options remain the authority for those adapters.

Inspect queue pressure without reading event contents:

```swift
let status = await client.queueStatus()
print("Queued: \(status.eventCount) events / \(status.byteCount) payload bytes")
```

The status combines memory and persisted counts at the time of the snapshot. `byteCount` is encoded event payload bytes and excludes disk-envelope and filesystem overhead.

## Flush at a meaningful boundary

Normal delivery uses batching and a flush interval. Use an explicit flush for tests, a user-triggered “send diagnostics” action, or another boundary where waiting is appropriate:

```swift
do {
    let report = try await client.flush()
    print("Uploaded: \(report.uploadedEventCount)")
    print("Permanently dropped: \(report.permanentlyDroppedEventCount)")
    print("Remaining: \(report.remainingEventCount)")
} catch is CancellationError {
    // Cancellation stops this wait; it does not turn queued events into delivered events.
} catch {
    // The timeout, transport, encoding, or storage operation failed.
}
```

By default, an explicit flush requests cancellation after `configuration.flushTimeout`. Pass `flush(timeout:)` to set a positive, finite deadline for one call. Cancellation is cooperative, so code should treat it as a deadline request rather than a real-time guarantee. The flush watermark covers work queued before that flush; concurrent later captures can remain and can appear in the report's final `remainingEventCount` snapshot. Do not flush after every capture. That increases energy use and defeats batching.

## Shut down

```swift
await client.shutdown(flush: true)
```

Shutdown is terminal for the instance. `shutdown(flush: true)` makes a nonthrowing, best-effort flush and requests cancellation after `configuration.shutdownFlushTimeout`; inspect an explicit `flush()` report first when the outcome matters. Create a new client to resume after a deliberate stop. iOS does not guarantee enough execution time during process termination, so avoid relying on a last-second flush as the only delivery mechanism.

## Call from Objective-C

The Objective-C facade uses Foundation values and asynchronous completions, always delivered asynchronously on the main thread:

```objc
@import TelemetryKit;

TKTelemetryConfiguration *configuration =
    [[TKTelemetryConfiguration alloc]
        initWithEndpoint:[NSURL URLWithString:@"https://telemetry.example.com/v1/events"]
                   apiKey:@"public-ingest-key"];

[TKTelemetryClient startWithConfiguration:configuration
                                completion:^(TKTelemetryClient * _Nullable client,
                                             NSError * _Nullable error) {
    if (client == nil) {
        NSLog(@"Start failed: %@", error);
        return;
    }

    // Grant only after the application establishes the user's collection choice.
    [client setConsent:TKTelemetryConsentGranted
             completion:^(NSError * _Nullable consentError) {
        if (consentError != nil) { return; }
        [client captureEventNamed:@"checkout.started"
                       attributes:@{ @"plan": @"pro", @"item_count": @2 }
                       completion:^(NSError * _Nullable captureError) {
            if (captureError != nil) {
                NSLog(@"Capture failed: %@", captureError);
            }
        }];
    }];
}];
```

Do not block a queue with a semaphore while waiting for SDK completions. Dispatch UI work to the main queue.

The facade accepts `NSString`, finite `NSNumber`, `NSNull`, `NSArray`, and `NSDictionary` values with string keys through a bounded converter. Unsupported, excessively deep, or excessively large Foundation graphs return an error.

The short capture selector emits custom/info events; use `captureEventNamed:attributes:category:level:completion:` for explicit category and severity. Configuration properties mirror the Swift category, queue, retry, privacy, instrumentation, timing, custom-header, and storage controls and are snapshotted at startup. The facade also provides queue-status and flush-report completions, explicitly instrumented URL sessions, and end-once spans. Shutdown always requests a graceful flush. A nil capture error means local admission only, not server delivery.

## Next steps

- Complete <doc:Privacy> before shipping.
- Understand queue, retry, and cancellation behavior in <doc:Architecture>.
- Add only the signals needed from <doc:Instrumentation>.
- Build the sample consumers under `Examples` against the local package.
