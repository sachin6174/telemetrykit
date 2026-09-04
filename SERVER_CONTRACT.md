# TelemetryKit ingestion contract

TelemetryKit sends versioned JSON batches to the application-owned endpoint configured for a client. This document describes the current schema and the response behavior an ingestion service must support.

## Request

The SDK performs an HTTP `POST` with:

- `Content-Type: application/json`
- `Accept: application/json`
- `X-TelemetryKit-Internal: 1`, which prevents the SDK from instrumenting its own upload
- `User-Agent: TelemetryKit/<sdk-version>`
- `Authorization: Bearer <api-key>` when the configured key is nonempty
- Reviewed `additionalHeaders` from the client configuration

The SDK rejects endpoint URLs containing credentials, query strings, or fragments. HTTPS is required unless `allowsInsecureTransport` is explicitly enabled. Protocol-owned, authorization, cookie, host, and content-length headers cannot be supplied through `additionalHeaders`; custom header names and values are count- and size-bounded and cannot contain control-line delimiters.

Response bodies are not part of the protocol and are discarded incrementally. Do not return a large response body.

The SDK does not follow HTTP redirects for ingestion. A 3xx response is classified as a final rejection, preventing the event body and authorization material from being forwarded to another URL.

## Batch schema version 1

The encoded object has this shape:

```json
{
  "schemaVersion": 1,
  "batchID": "7D690724-C0D5-4EFC-AACB-44EC6735A671",
  "sentAt": "2026-09-03T12:00:00Z",
  "sdk": {
    "name": "telemetrykit-swift",
    "version": "0.1.0"
  },
  "events": [
    {
      "id": "07F4A742-E3F8-42B0-A398-D2CE8A31C76D",
      "name": "checkout.started",
      "timestamp": "2026-09-03T11:59:58Z",
      "level": "info",
      "category": "custom",
      "attributes": {
        "plan": { "type": "string", "value": "pro" },
        "item_count": { "type": "integer", "value": 2 },
        "sampled": { "type": "boolean", "value": true },
        "ratio": { "type": "double", "value": 1.0 },
        "missing": { "type": "null" }
      }
    }
  ]
}
```

Every telemetry value is tagged so an explicit integer, double, boolean, and null remain distinct across disk and network round trips. Arrays contain tagged values. Objects map strings to tagged values recursively. JSON object ordering is not part of the contract.

`timestamp` is supplied by the event producer; `sentAt` describes batch encoding time. Queue age is based on local SDK acceptance time, which is intentionally not exposed as a wire field.

## Acknowledgement and retry

TelemetryKit treats the final HTTP status as follows:

| Status | SDK behavior |
| --- | --- |
| `2xx` | Acknowledges and removes every event in the batch. |
| `401`, `403` | Keeps the batch and pauses this client's delivery; an explicit flush returns an error. |
| `408`, `425`, `429`, `5xx` | Retries within the configured bounded retry cycle. |
| `413` | Retries smaller batches; permanently drops a single event that still receives `413`. |
| Other final statuses | Treats the batch as permanently rejected and removes its events. |

For retryable responses, `Retry-After` may be either nonnegative delta seconds or an IMF-fixdate HTTP date. The SDK uses the greater of its jittered delay and a valid future server delay, with server guidance capped at 24 hours.

The service must make one status apply to the entire request; the current protocol has no partial-acknowledgement response body.

## Idempotency and evolution

Deduplicate using each event's `id`, not `batchID`. A response can be lost after the service commits a batch, and a later delivery cycle can encode the same events under a new batch ID. Exactly-once transport is therefore not guaranteed.

Use `schemaVersion` to select the batch decoder. Within a supported schema version, ignore unknown object fields and unknown attribute keys. Validate size, authentication, authorization, retention, and allowed event schemas on the server even though the client also applies local limits.

TelemetryKit does not currently sign request bodies. Treat the shipped API key as a public-client credential: scope it to ingestion, make it revocable, and never grant administrative capabilities.
