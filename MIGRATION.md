# Migrating to TelemetryKit

This guide is for applications replacing an analytics, crash, or home-grown telemetry client. TelemetryKit is not a drop-in protocol adapter: migration is the right time to reduce the data contract and make lifecycle behavior explicit.

## Before changing code

Inventory the existing integration:

- Every emitted event name and attribute, including values added by middleware.
- Automatic collection, method swizzling, global URL interception, and crash hooks.
- Consent, deletion, retention, sampling, and regional-routing rules.
- Flush calls made during backgrounding or termination.
- Server payload, authentication, retry, deduplication, and rate-limit expectations.
- Dashboards and alerts that depend on legacy names or units.

Classify each field as required, optional, prohibited, or pending privacy review. Do not carry fields forward merely because they already exist.

## Recommended rollout

### 1. Add the package without starting it

Integrate the SwiftPM product or XCFramework and compile both Swift and Objective-C call sites. Keep the previous SDK active while the new client remains unstarted.

### 2. Define the collection boundary

Create `TelemetryConfiguration` from an application-owned endpoint and narrowly scoped ingestion key. Select categories, queue bounds, retry behavior, URL detail, session tracking, and MetricKit behavior deliberately. Consent defaults to `.pending`; start with `.granted` only after the application has established its collection basis.

TelemetryKit does not provide a global sampling engine, remote configuration, regional router, or synchronous crash hook. Apply sampling before `capture`, create independently configured clients only when policy requires distinct routes, and treat MetricKit diagnostics as delayed supplemental data rather than a replacement for a real-time crash pipeline.

Model revocation before rollout. `setConsent(.pending)` and `setConsent(.denied)` close capture, cancel the SDK's active upload, and attempt to purge this client's ingress and disk queue. Handle a thrown storage error rather than assuming deletion succeeded. Starting a client in either non-granted state also removes records found in its selected storage namespace or fails to start. A server-accepted upload cannot be recalled. `eraseStoredData()` provides an explicit local purge without otherwise changing granted consent.

### 3. Translate events

Prefer a small adapter while migrating:

```swift
struct AppTelemetry {
    let client: TelemetryClient

    func checkoutStarted(plan: String) -> TelemetryCaptureResult {
        client.capture(
            "checkout.started",
            attributes: ["plan": .string(plan)],
            category: .custom,
            level: .info
        )
    }
}
```

Typed application methods keep arbitrary user input and high-cardinality fields away from the SDK boundary.

Common lifecycle mappings are:

| Previous concept | TelemetryKit concept |
| --- | --- |
| `track`, `record`, or `breadcrumb` | `capture(_:attributes:)` |
| `drain` or `sendPending` | `flush()` |
| `close` or `stop` | `shutdown(flush:)` |
| global network hook | `makeInstrumentedURLSession(configuration:)` |
| timer/transaction | `startSpan(_:)` and `end(status:attributes:)` |

Do not translate a legacy “uploaded” callback into `capture`. Local acceptance and server delivery are different states.

`flush()` uploads or permanently drops only records through its sequence watermark. Its `remainingEventCount` is a snapshot of the complete local queue, including both disk and ingress, so it can include work accepted after the watermark. A flush can time out or be cancelled while durable records remain. Update the receiver for [TelemetryKit's ingestion contract](SERVER_CONTRACT.md), and deduplicate by `TelemetryEvent.id` because an ambiguous network failure can cause at-least-once delivery.

### 4. Migrate network instrumentation explicitly

Pass a client-created session into application networking code. Requests performed by old sessions remain uninstrumented, which makes incremental rollout possible and visible. Do not run old and new global network hooks together; duplicate spans and altered delegate behavior are common consequences.

### 5. Exercise offline and lifecycle cases

Before increasing rollout, verify:

- Launch and capture with no network.
- Relaunch with a non-empty disk queue.
- Oversized attributes and batches at their configured limits.
- Cancellation during encoding, retry delay, and upload.
- HTTP rate limiting and permanent client errors.
- Background/foreground transitions and shutdown.
- Consent withdrawal, including automatic queue purge and a simulated deletion failure.
- Startup with `.pending` or `.denied` against a namespace that already contains data.

### 6. Compare, then remove the previous SDK

If policy permits parallel collection, use a short, sampled overlap and compare counts, latency, and field shape. Never duplicate sensitive fields solely for comparison. Remove the old binary, initialization, privacy-manifest entries, build phases, and server credentials together.

## Swift concurrency changes

`TelemetryClient.start(configuration:)`, `flush`, consent changes, erasure, queue inspection, and shutdown cross concurrency boundaries. Capture, instrumented-session creation, and span start are synchronous and bounded. Propagate `async` for lifecycle work instead of introducing semaphores or blocking the main thread. Treat `CancellationError` as expected control flow.

## Objective-C changes

Use `TKTelemetryConfiguration` and `TKTelemetryClient`. Startup, consent changes, capture bridging, flush, erasure, and shutdown use completion handlers that TelemetryKit invokes asynchronously on the main thread. A nil capture error means local admission, not delivery.

`TKTelemetryConfiguration` exposes category toggles, queue and retry limits, privacy controls, automatic instrumentation, timing, custom headers, and storage selection. Configure its mutable properties before startup; the client snapshots them when `startWithConfiguration:completion:` is called. The short capture selector emits custom/info events, while the extended selector accepts `TKTelemetryCategory` and `TKTelemetryLevel`. Queue status, flush reports, explicitly instrumented sessions, and end-once spans also have Objective-C wrappers.

There are still language-shaped differences: Objective-C bridges attributes through bounded Foundation collections, completion APIs replace Swift `async`, and the shutdown facade always requests a graceful flush. Keep completion handling asynchronous even though event conversion and local admission are bounded.

## Version-to-version migrations

TelemetryKit is currently establishing its initial public contract. Version-specific source and behavior changes will be added here before a release that requires consumer action. Until a stable major release, pin exact versions in production and read [CHANGELOG.md](CHANGELOG.md) during every upgrade.
