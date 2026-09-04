# ``TelemetryKit``

Collect bounded, privacy-conscious mobile observability data and deliver it reliably from Swift or Objective-C applications.

## Overview

TelemetryKit separates local event acceptance from network delivery. A synchronous, thread-safe capture path validates and bounds data; actor-isolated pipeline state persists accepted events, builds limited-size batches, and retries eligible failures with capped exponential delay and full jitter.

Collection is explicit. The application supplies the endpoint, establishes consent, chooses categories, and opts into network, session, or MetricKit signals. Network instrumentation applies only to sessions created through the client and does not use global method swizzling.

Start with <doc:GettingStarted>, then complete the checklist in <doc:Privacy> before enabling collection in a production app.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Privacy>
- ``TelemetryConfiguration``
- ``TelemetryClient``
- ``TelemetryConsent``
- ``TelemetryError``

### Event model

- ``TelemetryEvent``
- ``TelemetryValue``
- ``TelemetryCategory``
- ``TelemetryLevel``
- ``TelemetryCaptureResult``

### Reliability

- <doc:Architecture>
- ``TelemetryQueueLimits``
- ``TelemetryQueueOverflowPolicy``
- ``TelemetryRetryPolicy``
- ``TelemetryQueueStatus``
- ``TelemetryFlushReport``

### Signals

- <doc:Instrumentation>
- ``TelemetryPrivacyConfiguration``
- ``TelemetryInstrumentationConfiguration``
- ``TelemetryNetworkURLCollection``
- ``TelemetryNetworkInstrumentation``
- ``TelemetryURLSessionDelegate``
- ``TelemetryNetworkMetricsRecorder``
- ``TelemetrySpan``
- ``TelemetrySpanStatus``

### Objective-C facade

- ``TKTelemetryConfiguration``
- ``TKTelemetryClient``
- ``TKTelemetryConsent``
- ``TKTelemetryCategory``
- ``TKTelemetryLevel``
- ``TKTelemetryQueueOverflowPolicy``
- ``TKTelemetryNetworkURLCollection``
- ``TKTelemetryQueueStatus``
- ``TKTelemetryFlushReport``
- ``TKTelemetrySpan``
- ``TKTelemetrySpanStatus``
- ``TKTelemetryErrorCode``
