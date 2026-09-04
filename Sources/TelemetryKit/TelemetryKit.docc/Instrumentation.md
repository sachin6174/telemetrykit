# Instrumentation

Add network, span, session, OSLog, and MetricKit signals without turning observation into global behavior.

## Instrument a URL session

Ask the client for an instrumented session and inject it into application networking code:

```swift
let session = client.makeInstrumentedURLSession(configuration: .ephemeral)
let request = URLRequest(url: URL(string: "https://api.example.com/catalog")!)

let (data, response) = try await session.data(for: request)
```

The client uses URLSession task metrics to derive supported timing and transfer measurements. It does not swizzle Foundation APIs, replace `URLSession.shared`, or observe sessions created by another library. The SDK's own delivery requests carry an internal marker and are excluded to prevent recursive network events.

Invalidate the returned session when its owner no longer needs it. Applications that already own a session delegate can forward metrics without changing delegate ownership:

```swift
let recorder = TelemetryNetworkMetricsRecorder(client: client)

func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
) {
    recorder.record(session: session, task: task, metrics: metrics)
}
```

### Interpret network measurements carefully

- A reused connection may have no new DNS, connect, or TLS phase.
- Cache hits can omit network phases entirely.
- Redirects can produce multiple transactions for one task.
- A failure before task creation has little or no timing detail.
- Streaming and background transfers have lifecycles beyond a foreground call.
- Cancellation is an application outcome and must remain cancellation.

Instrumentation observes an application request; it never retries that request. Telemetry delivery retry is a separate subsystem.

URL collection follows `configuration.privacy.networkURLCollection`. Query strings, fragments, URL credentials, schemes, and ports are excluded. Bodies, cookies, and authorization headers are not collected. The event can include the HTTP method and status, phase durations, redirect count, protocol and connection flags, and request/response header and body **byte counts** supplied by task metrics. Review those metadata fields as part of the application's schema.

## Add a span

Use a span for an operation that is not already represented by an instrumented network task:

```swift
let span = client.startSpan("catalog.decode")

do {
    let catalog = try JSONDecoder().decode(Catalog.self, from: data)
    span.end(
        status: .ok,
        attributes: ["item_count": .integer(Int64(catalog.items.count))]
    )
} catch {
    span.end(
        status: .error,
        attributes: ["error.type": .string(String(describing: type(of: error)))]
    )
    throw error
}
```

End a span exactly once. Keep the span name stable; dynamic identifiers belong in reviewed attributes or should be omitted. Initial span names and attributes are bounded and sanitized before the span retains them. End-time attributes receive the same bounded pass before they are merged, and the finished event is filtered again at capture. Starting and ending emits a payload-free local signpost even when collection is unavailable; the resulting `span.finished` event still follows consent, category, privacy, size, and queue limits.

## Session tracking

Session tracking is opt-in:

```swift
configuration.instrumentation.sessionTrackingEnabled = true
configuration.instrumentation.sessionTimeout = 30 * 60
```

The adapter records `session.started` with a fresh UUID and `session.finished` with that identifier and a monotonic duration. A background/inactive interval at least as long as the configured timeout closes the old session when the app next becomes active. It cannot perfectly represent force-quit, crash, extension, or background-execution boundaries. Treat session identifiers as potentially linkable and document their retention.

Session instrumentation starts only while consent is granted. Enabling it adds `.session` to the effective category set even if the caller omitted that category from `enabledCategories`.

## MetricKit

Enable metrics and diagnostics independently:

```swift
configuration.instrumentation.metricKitMetricsEnabled = true
configuration.instrumentation.metricKitDiagnosticsEnabled = false
```

MetricKit payload delivery is delayed, aggregated, opportunistic, and controlled by the operating system. It is not guaranteed for each launch and is not reliable in the simulator. Diagnostics can include crash and stack information; metrics can describe launch time, responsiveness, CPU, memory, disk, and network use depending on OS availability.

Each attempted MetricKit event includes the payload byte count. TelemetryKit parses detailed JSON only below a bounded fraction of `maximumEventBytes`; larger or unconvertible payloads receive `payload_omitted: true` instead of being expanded in memory. It derives a deterministic event ID from the original payload bytes. Normal privacy truncation, nesting, event-size, consent, and queue rules still apply, so detailed payload data can be reduced, omitted, or rejected. The active subscriber suppresses only a bounded recent set of repeated payload IDs; that cache is not persistent across subscriber restarts or process launches. The ingestion service must deduplicate by event ID when cross-launch idempotency is required.

Validate MetricKit on physical devices, tolerate new OS fields, and review metrics and diagnostics independently. Enabling each option adds its corresponding `.metricKitMetric` or `.metricKitDiagnostic` category to the effective category set.

## OSLog and signposts

Local OSLog messages and signposts help an integrator distinguish validation, queue, batch, and transport latency while profiling. They are diagnostics, not an alternate durable event store. Variable values should remain private and logs must not contain event payloads, API keys, authorization material, or full URLs.

Use Instruments' Points of Interest and OSLog views during development. TelemetryKit's diagnostics contain numeric counts, status codes, and reason codes rather than event attributes, endpoints, headers, or credentials; they are not a durable event store.

## Avoid double instrumentation

When another SDK already observes a network stack or lifecycle:

1. Choose one owner for automatic measurement.
2. Disable the overlapping TelemetryKit category or adapter.
3. Keep manual product events distinct from transport spans.
4. Verify one user action does not generate duplicate measurements.

Explicit session creation makes this boundary reviewable in code and allows incremental migration.
