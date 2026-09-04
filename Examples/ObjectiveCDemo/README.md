# ObjectiveCDemo

ObjectiveCDemo is a programmatic UIKit consumer that imports only TelemetryKit's Objective-C facade. It demonstrates:

- Async client startup through a completion handler.
- Pending consent followed by an explicit `TKTelemetryConsentGranted` user decision.
- Foundation dictionaries at the event boundary.
- Nonblocking capture and flush completions.
- Consent withdrawal and shutdown.

The default endpoint uses the reserved `.invalid` domain, so it cannot deliver real telemetry.

## Generate and run

Requirements: macOS, a supported Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd Examples/ObjectiveCDemo
xcodegen generate
open ObjectiveCDemo.xcodeproj
```

The project resolves TelemetryKit from `../..` and enables Clang modules plus Swift runtime embedding for the Swift implementation behind the Objective-C facade.

For a command-line build:

```sh
xcodebuild -project ObjectiveCDemo.xcodeproj \
  -scheme ObjectiveCDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Backend and credential

Replace the endpoint and test ingestion key in `TKDemoTelemetry.m`. Never embed an administrative credential. The example logs only state and errors; it does not print event payloads or keys.

## Privacy behavior

The switch is deliberately application-owned. Starting the client with pending consent does not queue events for possible later upload; captures are rejected until consent is granted. A production app must use its reviewed consent source, disclose the chosen categories, and define an erase policy for queued data after revocation or sign-out.

The app manifest declares no additional collection or required-reason API use. Inspect the merged privacy manifest in an archive before shipping a real app.
