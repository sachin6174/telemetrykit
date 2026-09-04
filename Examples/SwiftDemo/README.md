# SwiftDemo

SwiftDemo is a programmatic UIKit consumer of the local TelemetryKit Swift package. It demonstrates:

- A visible collection-consent switch.
- Explicit `.granted` consent only after the user action.
- Synchronous capture results.
- A client-created instrumented URL session.
- A manually measured span.
- Flush on demand and best-effort background flush.
- Shutdown when collection is disabled.

No telemetry client is created at launch. The sample endpoint uses the reserved `.invalid` domain, so events remain subject to the bounded offline/retry policy until you supply a real development endpoint.

## Generate and run

Requirements: macOS, a supported Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd Examples/SwiftDemo
xcodegen generate
open SwiftDemo.xcodeproj
```

Select an iOS simulator and run the `SwiftDemo` scheme. Xcode resolves the package from `../..`; no published package is required.

For a command-line build:

```sh
xcodebuild -project SwiftDemo.xcodeproj \
  -scheme SwiftDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Point at a development backend

Edit `DemoTelemetry.makeConfiguration()` in `Sources/DemoTelemetry.swift`. Use only a narrowly scoped, revocable ingestion key. Do not commit a production key or customer endpoint.

The “Example request” button calls `https://example.com` using a session returned by TelemetryKit. It demonstrates task metrics separately from the SDK's upload endpoint.

## Privacy behavior

The application-owned switch is a teaching device, not a complete consent experience. A production app should persist and restore its reviewed consent state, disclose enabled categories, define what happens to queued events after revocation, and provide any required deletion control. Pending consent drops captures rather than holding them for a later decision.

The app privacy manifest declares no additional collection or required-reason API use. TelemetryKit's package manifest is bundled separately; verify the merged result in an archived production application.
