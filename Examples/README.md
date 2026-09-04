# TelemetryKit consumer examples

The examples are intentionally ordinary UIKit applications. They exercise the public product as external consumers rather than importing internal implementation targets.

- `SwiftDemo` uses async startup/lifecycle methods and the synchronous capture path directly.
- `ObjectiveCDemo` uses only the Objective-C facade and Foundation/UIKit types.

Each directory contains source, resources, and an XcodeGen `project.yml`. Generated `.xcodeproj` bundles are not committed because they are derived artifacts with noisy tool-version metadata.

Both apps use `https://telemetry.example.invalid/v1/events` by default. `.invalid` is a reserved non-routable domain, so enabling the demo does not send telemetry to a real service. Replace it with a development ingestion endpoint and scoped test key when testing successful delivery.

See each example's README for generation and privacy notes.
