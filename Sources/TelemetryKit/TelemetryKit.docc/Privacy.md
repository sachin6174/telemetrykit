# Privacy

Treat TelemetryKit as a controlled data pipeline, not as permission to collect data.

## Assign responsibility to the application

The host application determines its lawful basis, consent experience, event schema, endpoint, retention, access controls, and user-facing disclosures. The SDK cannot infer these decisions and its privacy manifest does not replace the application's App Store privacy answers.

Start a client with `.pending` or `.denied` consent when collection must not proceed. Set `.granted` only after the application has established its collection basis. Starting a non-granted client removes records already present in that client's selected storage namespace.

Calling `setConsent(.pending)` or `setConsent(.denied)` closes admission before the asynchronous transition, stops configured session and MetricKit adapters, suspends new upload registration, cancels the SDK's active upload, and attempts to purge both the in-memory ingress and persisted queue. A capture begun before this boundary carries an old admission revision and cannot appear after a later grant. Handle a thrown storage error instead of assuming every file was deleted. An upload the server already accepted cannot be recalled. Call `eraseStoredData()` for an explicit local purge while otherwise leaving consent granted. Exercise all of these transitions with a non-empty queue.

## Minimize the event schema

Telemetry values are deliberately limited to strings, integers, doubles, booleans, arrays, objects, and null. That type boundary is not a sanitizer for product policy.

Do not capture:

- Passwords, authentication material, cookies, or session tokens.
- Request or response bodies and arbitrary HTTP headers.
- Raw text entered by a user.
- Email addresses, phone numbers, precise locations, advertising identifiers, or other direct identifiers.
- Full URLs that can contain account IDs, search terms, or secrets.
- Unbounded exception descriptions or object dumps.

Prefer stable event names and coarse, allow-listed dimensions. Hashing a direct identifier often leaves it linkable and does not automatically make it anonymous.

## Configure hard limits

`TelemetryPrivacyConfiguration` applies limits before persistence:

```swift
configuration.privacy = TelemetryPrivacyConfiguration(
    redactedAttributeKeys: [
        "authorization", "cookie", "email", "password", "token"
    ],
    maximumAttributeCount: 32,
    maximumStringLength: 512,
    maximumCollectionLength: 32,
    maximumNestingDepth: 4,
    networkURLCollection: .host
)
```

Key matching should be treated as a safety net, not the primary data model. Synonyms, misspellings, and sensitive values under an innocent-looking key can bypass a deny-list. Build application-owned typed telemetry methods with allow-listed fields.

Redacted-key matching is case-insensitive after trimming surrounding whitespace and replaces the value with a constant `[REDACTED]` marker. String, collection, nesting, and attribute limits can truncate or omit data before encoding; they do not preserve an oversized input losslessly. Empty event names are rejected, and non-finite floating-point values are omitted. Test the serialized server shape of representative events rather than treating capture input as the final wire payload.

## Bound memory and offline retention

The disk queue retains accepted events when transport is unavailable. Configure limits for a realistic offline period:

- `maximumMemoryEventCount` and `maximumMemoryBytes` cap the synchronous ingress buffer.
- `maximumEventCount` and `maximumDiskBytes` cap records and encoded event payload bytes in the disk queue.
- `maximumEventBytes` rejects an individual oversized event.
- `maximumEventAge` expires records by time since local SDK acceptance, independently of an event's caller-supplied timestamp.
- `overflowPolicy` makes overload behavior explicit.

`.dropOldest` preserves recent context; `.dropNewest` preserves the earlier sequence. The policy applies at both the memory and disk boundaries. A `.queueFull` capture result describes immediate ingress backpressure, while an event reported as `.accepted` can still be evicted later when the disk boundary is reached. Neither policy is universally correct. Monitor local capture results and queue status without creating recursive telemetry.

`maximumDiskBytes` and `TelemetryQueueStatus.byteCount` count encoded event payload bytes. Per-record envelope data and filesystem allocation overhead are not included, so the on-device footprint can be larger. Event-count limits still bound the number of queue files. Disk bounds are not server retention; configure backend deletion and access policy separately.

Age pruning runs when TelemetryKit recovers, appends to, or reads the queue. The operating system can suspend or terminate an app, so `maximumEventAge` is not a promise that a file is deleted at the exact expiry instant; stale records are removed the next time queue work runs.

On iOS, queue files use complete-until-first-user-authentication data protection and are excluded from backup, so background delivery remains possible after the first device unlock without copying telemetry into device backups. This is device file protection, not application-level or end-to-end encryption. By default, TelemetryKit derives an endpoint-specific Application Support directory and appends `storageNamespace`. A custom `storageDirectory` replaces that derivation entirely, so it must be a dedicated non-root file URL. TelemetryKit combines an in-process ownership registry with an Apple-platform advisory file lock. Treat that lock as misuse detection rather than a sharing protocol: do not point app and extension processes at the same queue, and shut a client down before reusing its directory. An interrupted privacy purge leaves a protected tombstone and must finish before the queue can reopen.

On every granted startup, recovered events are decoded and passed through the current privacy limits and effective category set before delivery. Changed events are atomically rewritten and newly disabled records are removed, so an older, looser configuration does not retain authority indefinitely.

A namespace is not automatically scoped to the signed-in application user, and the API key is not part of default path derivation. On sign-out, account change, or credential rotation, explicitly flush or erase according to policy before the next client can upload retained records.

## Limit URL data

`TelemetryNetworkURLCollection` has three levels:

| Value | Recorded URL component | Use |
| --- | --- | --- |
| `.none` | No URL component | Strongest minimization; suitable when host/path dimensions are unnecessary. |
| `.host` | Lowercased host | Default; useful for origin-level performance. |
| `.hostAndPath` | Host and path | Use only after reviewing route parameters. |

Query strings and fragments are removed at every level. Paths can still contain user IDs, filenames, or opaque tokens, so prefer `.host` unless routes are normalized before collection. Instrumentation does not need bodies, cookies, or authorization headers to calculate task timings.

## Opt into automatic signals separately

`TelemetryInstrumentationConfiguration` defaults all optional signal families off. Session tracking can create linkable activity sequences. MetricKit diagnostic payloads can contain stack and crash information, while metrics describe performance and resource behavior. Enabling session or MetricKit collection also adds its corresponding event category to the client's effective category set; review each family independently rather than relying on `enabledCategories` alone.

MetricKit delivery is delayed and controlled by iOS. Payloads must follow the same queue, category, consent, and retention rules as manually captured events.

## Understand the privacy manifest

The packaged `PrivacyInfo.xcprivacy` declares that the SDK does not track, declares no tracking domains, and lists product-interaction, performance, and crash-data categories that supported features can submit. Those data types are marked not linked and not used for tracking based on TelemetryKit's own generated fields. It also declares the System Boot Time required-reason category used for elapsed-time measurements. The SDK cannot know whether application-supplied attributes, an ingestion key, or backend processing links data to an identity. Your containing app's manifest and App Store privacy responses must describe the integration that actually ships and use stricter declarations when appropriate.

Review the manifest whenever the SDK version or configuration changes. A manifest is a disclosure artifact, not runtime enforcement.

## Shipping checklist

- [ ] Event and attribute allow-list reviewed by privacy/security owners.
- [ ] Consent behavior verified for pending, granted, denied, and changed states.
- [ ] Category allow-list reduced to the necessary signal families.
- [ ] URL mode set to `.none` or `.host` unless paths are demonstrably safe.
- [ ] Optional session and MetricKit signals assessed individually.
- [ ] Memory, disk, event-size, age, and server-retention limits documented.
- [ ] Ingestion key is scoped, revocable, and not administrative.
- [ ] Endpoint uses TLS and does not contain URL credentials.
- [ ] Queued-data behavior under sign-out, account change, and consent withdrawal tested.
- [ ] Custom storage directories are dedicated to one client and one process.
- [ ] Privacy manifest verified in an archive and App Store disclosures updated.
