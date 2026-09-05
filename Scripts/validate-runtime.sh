#!/bin/bash
set -Eeuo pipefail

# Run after build-xcframework.sh (using its default Artifacts output directory).
# No production endpoint, credential, or physical device is used by these tests.
TK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$TK_ROOT"
command -v xcodegen >/dev/null || { echo "error: XcodeGen is required" >&2; exit 1; }
[[ -d Artifacts/TelemetryKit.xcframework ]] || { echo "error: build the XCFramework first" >&2; exit 1; }
mkdir -p Artifacts/Validation
TK_RESULTS="$(mktemp -d "$TK_ROOT/Artifacts/Validation/runtime.XXXXXX")"
TK_SIMULATOR_UDID="${TK_SIMULATOR_UDID:-}"
if [[ -z "$TK_SIMULATOR_UDID" ]]; then
    TK_SIMULATOR_UDID="$(xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
matches = [device for runtime, values in devices.items() if ".iOS-" in runtime
           for device in values if device.get("isAvailable") and device["name"].startswith("iPhone")]
if not matches:
    raise SystemExit("No available iPhone simulator")
matches.sort(key=lambda device: (device["state"] == "Booted", device["name"]), reverse=True)
print(matches[0]["udid"])
')"
fi
TK_DESTINATION="platform=iOS Simulator,id=$TK_SIMULATOR_UDID"

if [[ "${TK_RUNTIME_RUN_SOURCE:-1}" == 1 ]]; then
    swift test -c release 2>&1 | tee "$TK_RESULTS/release-tests.log"
fi
xcodegen generate --spec Compatibility/RuntimeConsumer/project.yml
xcodebuild test -project Compatibility/RuntimeConsumer/BinaryRuntime.xcodeproj \
    -scheme BinaryRuntime -destination "$TK_DESTINATION" \
    -derivedDataPath "$TK_RESULTS/BinaryDerivedData" \
    -resultBundlePath "$TK_RESULTS/BinaryRuntime.xcresult" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$TK_RESULTS/binary.log"

if [[ "${TK_RUNTIME_RUN_UI:-1}" == 1 ]]; then
    bash Scripts/generate-samples.sh
    for TK_SAMPLE in SwiftDemo ObjectiveCDemo; do
        xcodebuild test -project "Examples/$TK_SAMPLE/$TK_SAMPLE.xcodeproj" \
            -scheme "$TK_SAMPLE" -destination "$TK_DESTINATION" \
            -derivedDataPath "$TK_RESULTS/$TK_SAMPLE-DerivedData" \
            -resultBundlePath "$TK_RESULTS/$TK_SAMPLE.xcresult" \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
            CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$TK_RESULTS/$TK_SAMPLE.log"
    done
fi
printf 'Runtime validation passed. Evidence: %s\n' "$TK_RESULTS"
