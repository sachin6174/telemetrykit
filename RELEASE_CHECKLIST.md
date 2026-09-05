# Release acceptance

A green build is necessary but does not certify production fitness. Keep evidence
for the exact release commit, Xcode versions, OS versions, and binary checksum.
Do not mark an unexecuted check as passed.

## Automated checks

On a Mac with Xcode and XcodeGen:

```sh
bash Scripts/generate-samples.sh
bash Scripts/validate-package.sh
bash Scripts/build-xcframework.sh
bash Scripts/validate-runtime.sh
TK_ENABLE_THREAD_SANITIZER=1 TK_ENABLE_CODE_COVERAGE=0 \
  TK_RUN_DEVICE_BUILD=0 TK_RUN_SIMULATOR_BUILD=0 TK_RUN_DOCC=0 \
  bash Scripts/validate-package.sh
```

`validate-runtime.sh` preserves logs and result bundles in a unique directory
under `Artifacts/Validation`. It runs optimized source tests, public-API tests
against the actual dynamic XCFramework, Objective-C callbacks, and both apps'
consent/capture/revocation/relaunch UI flows. The HTTP receiver is bounded and
loopback-only; its credentials and events are synthetic. No production service
is contacted by that suite. Set `TK_SIMULATOR_UDID` to select a particular device.

Before tagging:

- [ ] CI passes on every supported toolchain, including the older-Xcode lane.
- [ ] Minimum supported iOS/macOS runtime coverage is recorded separately from
  deployment-target compilation.
- [ ] Unit, disk integration, real-network, performance, and sanitizer tests pass.
- [ ] Binary and sample runtime tests pass, not just link or type checks.
- [ ] DocC builds; migration guide and server schema match the public API.
- [ ] Archive privacy manifests are present and match the app's enabled collection.

## Device and operational acceptance

- [ ] On representative devices, verify offline capture, process termination,
  relaunch delivery, queue saturation, low storage, backgrounding, and consent
  revocation. Verify protected storage behavior before and after first unlock.
- [ ] Verify MetricKit delivery with a signed device consumer. Inspect received
  payloads for the chosen collection policy and ensure denying consent stops it.
  Simulator compilation alone is not evidence of OS payload delivery.
- [ ] Inspect OSLog/signposts in Instruments; no payload, endpoint, header, or
  credential should appear in SDK diagnostics.
- [ ] Run against the application's staging ingestion service, including TLS,
  revoked keys, rate limiting, batch rejection, and event-ID deduplication.
- [ ] Set application-specific CPU, memory, disk, and battery budgets on the
  oldest supported device. Review regression measurements without sanitizers.
- [ ] Have the application owner review privacy disclosures, retention, event
  schemas, and operational alerting. Keep collection opt-in.

## Publication and recovery

- [ ] Select the repository and visibility explicitly; configure protected branches
  and release permissions. Do not commit ingest credentials or signing material.
- [ ] Set the wire SDK version, changelog, and tag to the same semantic version.
- [ ] Retain the verified zip checksum and test evidence with the release.
- [ ] Never replace artifacts under an existing version. Fixes get a new version.
- [ ] Test an exact-version consumer install from the published location.
- [ ] Record rollback: pin the preceding version, disable collection if needed,
  revoke scoped ingest keys if compromised, and use app-controlled local erasure.

The current executed evidence and remaining gaps are in [VALIDATION.md](VALIDATION.md).
