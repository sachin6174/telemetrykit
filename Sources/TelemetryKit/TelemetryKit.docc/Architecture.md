# Architecture

Understand how TelemetryKit keeps capture fast while bounding memory, persistence, retries, and lifecycle work.

## Pipeline at a glance

```text
Swift call / Objective-C facade
              |
              v
 synchronous validation + privacy limits
              |
              v
       bounded ingress buffer
              |
              v
 actor-isolated pipeline state
       |                |
       v                v
 durable disk queue   OSLog/signposts
       |
       v
 size/count batch planner
       |
       v
 cancellable transport
       |
       +--> success: acknowledge durable records
       +--> retryable: capped exponential delay + full jitter
       +--> permanent: apply documented drop/report behavior
```

## Synchronous capture, asynchronous ownership

`TelemetryClient` is a thread-safe final class. `capture` performs bounded validation and admission synchronously so callers receive a ``TelemetryCaptureResult`` without awaiting disk or network work. It does not create one unbounded task per event.

Mutable lifecycle and delivery state is serialized by a runtime actor, and disk-queue mutation has a separate actor owner. A small lock-protected ingress provides the synchronous boundary. This split allows Swift and Objective-C producers to remain simple while preserving coordinated transitions such as start, flush, consent change, erasure, and shutdown.

An `.accepted` result means the event entered the bounded in-memory ingress. It is not a persistence or server acknowledgement. Results such as `.eventTooLarge`, `.queueFull`, `.consentRequired`, and `.clientStopped` make immediate rejection visible at the call site. An accepted event can still expire, be evicted by the configured disk policy, or be discarded after a permanent server response.

## Keep every layer bounded

Queue limits cover ingress count and encoded payload bytes, disk-record count and encoded payload bytes, per-event bytes, event age, and overflow policy. Batch limits independently cap event count and the complete encoded request; validation reserves fixed envelope overhead so a maximum-sized event fits by itself. These constraints prevent a disconnected app, a slow endpoint, or a bursty producer from turning the SDK into unlimited memory or storage.

Byte counters cover encoded `TelemetryEvent` payloads. The binary property-list envelope and filesystem allocation for each queue file are not included in `maximumDiskBytes` or ``TelemetryQueueStatus/byteCount``. Event-count limits bound the number of queue files, but integrators should allow storage headroom beyond the configured payload-byte limit. Queue recovery keeps record metadata rather than every payload resident; a delivery reads only the bounded candidate batch.

Immediate ingress backpressure is expressed as a capture result rather than waiting for queue capacity. With `.dropNewest`, a full ingress reports `.queueFull`; with `.dropOldest`, a new event can replace earlier buffered work. Disk overflow is handled asynchronously with the same policy, so `.accepted` cannot promise indefinite retention. Choose a policy according to product needs and make application-local diagnostics rate-limited so an overload does not recursively create more telemetry.

## Persist before assuming delivery

The disk queue decouples accepted observations from network availability. Queue mutation and acknowledgement must be crash-consistent: a process interruption can cause a retry, but must not silently acknowledge an event that the server never accepted.

Granted startup decodes recovered records, verifies that each payload identity matches its storage envelope, reapplies the current privacy limits and effective category set, atomically rewrites changed records, and durably removes records that are no longer eligible. Delivery repeats the identity, category, and privacy checks before encoding a request. This prevents a looser policy from an earlier launch—or a changed queue record—from bypassing the active configuration.

Applications should make ingestion idempotent using event IDs because mobile delivery is naturally at-least-once around ambiguous network failures. Treat the queue's storage representation as private implementation detail; migrate it inside the SDK rather than letting applications inspect files.

## Batch and retry

The batch planner observes both `batchSize` and `batchByteLimit`. `TelemetryRetryPolicy` calculates full-jitter delay in this range:

```text
0 ... min(maximumDelay, initialDelay * 2^attempt)
```

`maximumAttemptsPerCycle` counts scheduled retries after the initial request. Jitter prevents many clients from retrying in lockstep. A valid `Retry-After` value can extend the jittered delay, capped at 24 hours. TelemetryKit retries HTTP 408, 425, 429, 5xx responses, and retryable transport failures. It treats 2xx as delivered, pauses this client's delivery after 401 or 403, splits a 413 batch, and permanently discards other HTTP responses. The upload session refuses redirects so a body or credential cannot be forwarded to another origin and the original 3xx remains visible to this classifier. A single event that still receives 413 is dropped. An explicit flush reports an authentication pause as a transport error. Calling `setConsent(.granted)` clears the pause, but client configuration is immutable; create a new client when the endpoint or credential must change.

The ingestion service should deduplicate by event ID. A response can be lost after the service accepted a batch, so retries provide at-least-once rather than exactly-once delivery around ambiguous network failure.

## Cancellation and lifecycle

Long-running operations check cancellation around queue access, encoding, delay, and transport. Cancelling a flush stops the caller's wait and active attempt as appropriate; it must not fabricate delivery or delete queued records. The optional timeout on `flush(timeout:)` uses the same cancellation path.

Concurrent flushes share one serialized delivery owner. Waiting callers are themselves bounded; an excessive flush storm fails rather than creating an unbounded continuation queue. Centralize flush policy instead of launching one flush per producer.

An explicit flush first persists current ingress work, records a disk sequence watermark, and attempts delivery only through that watermark. Events captured concurrently after the watermark can remain locally. The report separates 2xx-acknowledged, permanently dropped during this flush, and the complete local queue count at its final snapshot; it is not a lifetime loss counter.

`shutdown(flush:)` prevents new captures and tears down owned resources. When requested, its graceful flush is nonthrowing and best effort within `shutdownFlushTimeout`. Process termination is not a reliable opportunity for synchronous cleanup, so normal interval and batch delivery must carry the workload.

Changing consent to `.pending` or `.denied` closes admission synchronously, suspends new upload registration, cancels configured automatic instrumentation and the active upload, and attempts to purge ingress plus disk records. Capture admission carries a privacy revision, so work begun before a consent or erase boundary cannot be admitted after a later grant. A durable purge tombstone makes interrupted deletion fail closed during the next initialization. A storage failure is thrown after admission has closed and can mean deletion was incomplete. Startup in a non-granted state also removes records found in the selected namespace or fails. Already accepted server data cannot be recalled. Verify races between capture, flush, consent change, data erasure, and shutdown with deterministic tests.

## Diagnostics without recursion

TelemetryKit uses a dedicated OSLog category and signposts for local pipeline work. Logs should describe state and counts while marking variable values private. The SDK's own upload session is excluded from network instrumentation. Internal diagnostics are bounded and must not recursively emit an unlimited stream of SDK events.

## Dependency boundaries

The public event/configuration model does not expose the disk format, actor implementation, random-number generator, clock, or HTTP client. Internal protocols for clock, randomness, persistence, and transport keep retry and recovery tests deterministic. Apple-only adapters for URLSession task metrics, lifecycle notifications, OSLog, and MetricKit sit at the edge of the core pipeline.
