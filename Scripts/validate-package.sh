#!/bin/bash

set -Eeuo pipefail

# Validates the source package on macOS. Every setting can be overridden without
# modifying this script; see the TK_* defaults below.

tk_fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

tk_note() {
    printf '==> %s\n' "$*"
}

tk_require_command() {
    command -v "$1" >/dev/null 2>&1 || tk_fail "required command not found: $1"
}

tk_is_enabled() {
    case "$1" in
        1 | true | TRUE | yes | YES) return 0 ;;
        0 | false | FALSE | no | NO) return 1 ;;
        *) tk_fail "expected a boolean value, received: $1" ;;
    esac
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    tk_fail "iOS package validation requires macOS and Xcode"
fi

TK_SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TK_DEFAULT_PACKAGE_PATH="$(cd "$TK_SCRIPT_DIRECTORY/.." && pwd -P)"
TK_PACKAGE_PATH="${TK_PACKAGE_PATH:-$TK_DEFAULT_PACKAGE_PATH}"
[[ -d "$TK_PACKAGE_PATH" ]] || tk_fail "package directory does not exist: $TK_PACKAGE_PATH"
TK_PACKAGE_PATH="$(cd "$TK_PACKAGE_PATH" && pwd -P)"

TK_SCHEME="${TK_SCHEME:-TelemetryKit}"
TK_PRODUCT="${TK_PRODUCT:-TelemetryKit}"
TK_IOS_DEPLOYMENT_TARGET="${TK_IOS_DEPLOYMENT_TARGET:-15.0}"
TK_BUILD_CONFIGURATION="${TK_BUILD_CONFIGURATION:-Debug}"
TK_RUN_FORMAT="${TK_RUN_FORMAT:-1}"
TK_VALIDATE_PRIVACY="${TK_VALIDATE_PRIVACY:-1}"
TK_RUN_DEVICE_BUILD="${TK_RUN_DEVICE_BUILD:-1}"
TK_RUN_SIMULATOR_BUILD="${TK_RUN_SIMULATOR_BUILD:-1}"
TK_RUN_TESTS="${TK_RUN_TESTS:-1}"
TK_RUN_DOCC="${TK_RUN_DOCC:-1}"
TK_ENABLE_CODE_COVERAGE="${TK_ENABLE_CODE_COVERAGE:-1}"
TK_ENABLE_THREAD_SANITIZER="${TK_ENABLE_THREAD_SANITIZER:-0}"
TK_WARNINGS_AS_ERRORS="${TK_WARNINGS_AS_ERRORS:-1}"
TK_FORMAT_CONFIGURATION="${TK_FORMAT_CONFIGURATION:-$TK_PACKAGE_PATH/.swiftformat}"
TK_PRIVACY_MANIFEST="${TK_PRIVACY_MANIFEST:-}"
TK_SIMULATOR_UDID="${TK_SIMULATOR_UDID:-}"
TK_SIMULATOR_OS_VERSION="${TK_SIMULATOR_OS_VERSION:-}"
TK_SIMULATOR_DEVICE_NAME="${TK_SIMULATOR_DEVICE_NAME:-}"
TK_SWIFT_SAMPLE_CONTAINER="${TK_SWIFT_SAMPLE_CONTAINER:-}"
TK_SWIFT_SAMPLE_SCHEME="${TK_SWIFT_SAMPLE_SCHEME:-}"
TK_OBJC_SAMPLE_CONTAINER="${TK_OBJC_SAMPLE_CONTAINER:-}"
TK_OBJC_SAMPLE_SCHEME="${TK_OBJC_SAMPLE_SCHEME:-}"

tk_require_command xcodebuild
tk_require_command xcrun
tk_require_command swift
tk_require_command plutil
tk_require_command /usr/bin/python3

[[ -f "$TK_PACKAGE_PATH/Package.swift" ]] || tk_fail "Package.swift not found at $TK_PACKAGE_PATH"

TK_TEMP_PARENT="${TMPDIR:-/tmp}"
[[ -d "$TK_TEMP_PARENT" ]] || tk_fail "temporary directory does not exist: $TK_TEMP_PARENT"
TK_TEMP_PARENT="$(cd "$TK_TEMP_PARENT" && pwd -P)"
TK_VALIDATION_TEMP=""

if [[ -n "${TK_DERIVED_DATA_PATH:-}" ]]; then
    mkdir -p "$TK_DERIVED_DATA_PATH"
    TK_DERIVED_DATA_PATH="$(cd "$TK_DERIVED_DATA_PATH" && pwd -P)"
else
    TK_VALIDATION_TEMP="$(mktemp -d "$TK_TEMP_PARENT/telemetrykit-validation.XXXXXX")"
    TK_DERIVED_DATA_PATH="$TK_VALIDATION_TEMP/DerivedData"
fi

tk_cleanup() {
    if [[ -n "$TK_VALIDATION_TEMP" && -d "$TK_VALIDATION_TEMP" ]]; then
        case "$TK_VALIDATION_TEMP" in
            "$TK_TEMP_PARENT"/telemetrykit-validation.*) rm -rf -- "$TK_VALIDATION_TEMP" ;;
            *) printf 'warning: refusing to remove unexpected temporary path: %s\n' "$TK_VALIDATION_TEMP" >&2 ;;
        esac
    fi
}
trap tk_cleanup EXIT INT TERM

TK_MANIFEST_JSON="$TK_DERIVED_DATA_PATH/package-description.json"
mkdir -p "$TK_DERIVED_DATA_PATH"

tk_note "Checking package manifest contract"
head -n 1 "$TK_PACKAGE_PATH/Package.swift" | grep -Eq '^// swift-tools-version:[[:space:]]*5\.9([[:space:]]|$)' \
    || tk_fail "Package.swift must declare swift-tools-version 5.9"

swift package --package-path "$TK_PACKAGE_PATH" dump-package >"$TK_MANIFEST_JSON"
/usr/bin/python3 - "$TK_MANIFEST_JSON" "$TK_PRODUCT" "$TK_IOS_DEPLOYMENT_TARGET" <<'PY'
import json
import sys

manifest_path, expected_product, expected_ios = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as manifest_file:
    package = json.load(manifest_file)

product_names = {product.get("name") for product in package.get("products", [])}
if expected_product not in product_names:
    raise SystemExit(f"error: library product {expected_product!r} is missing from Package.swift")

ios_versions = [
    platform.get("version")
    for platform in package.get("platforms", [])
    if str(platform.get("platformName", "")).lower() == "ios"
]
if expected_ios not in ios_versions:
    rendered = ", ".join(str(version) for version in ios_versions) or "none"
    raise SystemExit(
        f"error: expected iOS deployment target {expected_ios}; manifest declares {rendered}"
    )
PY

if tk_is_enabled "$TK_RUN_FORMAT"; then
    [[ -f "$TK_FORMAT_CONFIGURATION" ]] || tk_fail "swift-format configuration missing: $TK_FORMAT_CONFIGURATION"

    if command -v swift-format >/dev/null 2>&1; then
        TK_SWIFT_FORMAT=(swift-format)
    elif xcrun --find swift-format >/dev/null 2>&1; then
        TK_SWIFT_FORMAT=(xcrun swift-format)
    else
        tk_fail "swift-format is not available in the selected toolchain"
    fi

    TK_FORMAT_PATHS=("$TK_PACKAGE_PATH/Package.swift")
    for tk_candidate in Sources Tests Examples Samples Compatibility; do
        if [[ -d "$TK_PACKAGE_PATH/$tk_candidate" ]]; then
            TK_FORMAT_PATHS+=("$TK_PACKAGE_PATH/$tk_candidate")
        fi
    done

    tk_note "Linting Swift source formatting"
    "${TK_SWIFT_FORMAT[@]}" lint \
        --configuration "$TK_FORMAT_CONFIGURATION" \
        --recursive \
        --parallel \
        --strict \
        "${TK_FORMAT_PATHS[@]}"
fi

if tk_is_enabled "$TK_VALIDATE_PRIVACY"; then
    if [[ -z "$TK_PRIVACY_MANIFEST" ]]; then
        TK_PRIVACY_CANDIDATES=()
        while IFS= read -r -d '' tk_candidate; do
            TK_PRIVACY_CANDIDATES+=("$tk_candidate")
        done < <(find "$TK_PACKAGE_PATH/Sources" -type f -name PrivacyInfo.xcprivacy -print0 2>/dev/null)

        [[ "${#TK_PRIVACY_CANDIDATES[@]}" -eq 1 ]] \
            || tk_fail "expected exactly one PrivacyInfo.xcprivacy under Sources; found ${#TK_PRIVACY_CANDIDATES[@]}"
        TK_PRIVACY_MANIFEST="${TK_PRIVACY_CANDIDATES[0]}"
    elif [[ "$TK_PRIVACY_MANIFEST" != /* ]]; then
        TK_PRIVACY_MANIFEST="$TK_PACKAGE_PATH/$TK_PRIVACY_MANIFEST"
    fi

    [[ -f "$TK_PRIVACY_MANIFEST" ]] || tk_fail "privacy manifest not found: $TK_PRIVACY_MANIFEST"
    tk_note "Validating privacy manifest"
    plutil -lint "$TK_PRIVACY_MANIFEST"
    for tk_privacy_key in \
        NSPrivacyTracking \
        NSPrivacyTrackingDomains \
        NSPrivacyCollectedDataTypes \
        NSPrivacyAccessedAPITypes; do
        /usr/libexec/PlistBuddy -c "Print :$tk_privacy_key" "$TK_PRIVACY_MANIFEST" >/dev/null \
            || tk_fail "privacy manifest is missing $tk_privacy_key"
    done
fi

TK_XCODE_WARNINGS="NO"
if tk_is_enabled "$TK_WARNINGS_AS_ERRORS"; then
    TK_XCODE_WARNINGS="YES"
fi

TK_COMMON_BUILD_SETTINGS=(
    "IPHONEOS_DEPLOYMENT_TARGET=$TK_IOS_DEPLOYMENT_TARGET"
    "SWIFT_TREAT_WARNINGS_AS_ERRORS=$TK_XCODE_WARNINGS"
    "GCC_TREAT_WARNINGS_AS_ERRORS=$TK_XCODE_WARNINGS"
    'OTHER_SWIFT_FLAGS=$(inherited) -strict-concurrency=complete'
    "CODE_SIGNING_ALLOWED=NO"
)

cd "$TK_PACKAGE_PATH"
tk_note "Resolving package dependencies"
xcodebuild -resolvePackageDependencies -scheme "$TK_SCHEME"

if tk_is_enabled "$TK_RUN_DEVICE_BUILD"; then
    tk_note "Building $TK_SCHEME for a generic iOS device"
    xcodebuild build \
        -scheme "$TK_SCHEME" \
        -configuration "$TK_BUILD_CONFIGURATION" \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$TK_DERIVED_DATA_PATH/device" \
        "${TK_COMMON_BUILD_SETTINGS[@]}"
fi

if tk_is_enabled "$TK_RUN_SIMULATOR_BUILD"; then
    tk_note "Building $TK_SCHEME for the iOS Simulator"
    xcodebuild build \
        -scheme "$TK_SCHEME" \
        -configuration "$TK_BUILD_CONFIGURATION" \
        -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "$TK_DERIVED_DATA_PATH/simulator" \
        "${TK_COMMON_BUILD_SETTINGS[@]}"
fi

tk_select_simulator() {
    if [[ -n "$TK_SIMULATOR_UDID" ]]; then
        printf '%s\n' "$TK_SIMULATOR_UDID"
        return
    fi

    local tk_sdk_version
    local tk_simulator_json
    tk_sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
    tk_simulator_json="$TK_DERIVED_DATA_PATH/available-simulators.json"
    xcrun simctl list devices available --json >"$tk_simulator_json"
    /usr/bin/python3 - "$tk_simulator_json" \
        "$tk_sdk_version" "$TK_SIMULATOR_OS_VERSION" "$TK_SIMULATOR_DEVICE_NAME" <<'PY'
import json
import re
import sys

simulator_path, sdk_version, requested_os, requested_name = sys.argv[1:]

def version_tuple(value):
    return tuple(int(part) for part in re.findall(r"\d+", value))

sdk = version_tuple(sdk_version)
with open(simulator_path, encoding="utf-8") as simulator_file:
    payload = json.load(simulator_file)
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    if ".iOS-" not in runtime:
        continue
    runtime_version = version_tuple(runtime.rsplit(".iOS-", 1)[-1])
    if runtime_version > sdk:
        continue
    if requested_os and runtime_version != version_tuple(requested_os):
        continue
    for device in devices:
        name = str(device.get("name", ""))
        if not device.get("isAvailable", False) or not name.startswith("iPhone"):
            continue
        if requested_name and name != requested_name:
            continue
        candidates.append((runtime_version, name, str(device.get("udid", ""))))

if not candidates:
    raise SystemExit("error: no compatible, available iPhone Simulator was found")

candidates.sort(reverse=True)
print(candidates[0][2])
PY
}

if tk_is_enabled "$TK_RUN_TESTS"; then
    TK_SELECTED_SIMULATOR="$(tk_select_simulator)"
    [[ -n "$TK_SELECTED_SIMULATOR" ]] || tk_fail "failed to select an iPhone Simulator"
    TK_TEST_RESULT="$TK_DERIVED_DATA_PATH/TelemetryKitTests.xcresult"
    [[ ! -e "$TK_TEST_RESULT" ]] || tk_fail "test result bundle already exists: $TK_TEST_RESULT"

    TK_XCODE_CODE_COVERAGE="NO"
    if tk_is_enabled "$TK_ENABLE_CODE_COVERAGE"; then
        TK_XCODE_CODE_COVERAGE="YES"
    fi

    TK_TEST_OPTIONS=(
        -enableCodeCoverage "$TK_XCODE_CODE_COVERAGE"
        -resultBundlePath "$TK_TEST_RESULT"
    )
    if tk_is_enabled "$TK_ENABLE_THREAD_SANITIZER"; then
        TK_TEST_OPTIONS+=(-enableThreadSanitizer YES)
    fi

    tk_note "Testing $TK_SCHEME on simulator $TK_SELECTED_SIMULATOR"
    xcodebuild test \
        -scheme "$TK_SCHEME" \
        -configuration "$TK_BUILD_CONFIGURATION" \
        -destination "platform=iOS Simulator,id=$TK_SELECTED_SIMULATOR" \
        -destination-timeout 120 \
        -derivedDataPath "$TK_DERIVED_DATA_PATH/tests" \
        "${TK_TEST_OPTIONS[@]}" \
        "${TK_COMMON_BUILD_SETTINGS[@]}"
fi

if tk_is_enabled "$TK_RUN_DOCC"; then
    tk_note "Building DocC documentation"
    xcodebuild docbuild \
        -scheme "$TK_SCHEME" \
        -configuration "$TK_BUILD_CONFIGURATION" \
        -destination "generic/platform=iOS" \
        -derivedDataPath "$TK_DERIVED_DATA_PATH/docc" \
        "OTHER_DOCC_FLAGS=--warnings-as-errors" \
        "${TK_COMMON_BUILD_SETTINGS[@]}"
fi

tk_build_sample() {
    local tk_language="$1"
    local tk_container="$2"
    local tk_scheme="$3"

    [[ -n "$tk_scheme" ]] || tk_fail "$tk_language sample scheme is required when its container is set"
    if [[ "$tk_container" != /* ]]; then
        tk_container="$TK_PACKAGE_PATH/$tk_container"
    fi
    [[ -e "$tk_container" ]] || tk_fail "$tk_language sample container not found: $tk_container"

    local tk_container_option
    case "$tk_container" in
        *.xcworkspace) tk_container_option=-workspace ;;
        *.xcodeproj) tk_container_option=-project ;;
        *) tk_fail "$tk_language sample container must be an .xcodeproj or .xcworkspace" ;;
    esac

    tk_note "Building $tk_language sample scheme $tk_scheme"
    xcodebuild build \
        "$tk_container_option" "$tk_container" \
        -scheme "$tk_scheme" \
        -configuration "$TK_BUILD_CONFIGURATION" \
        -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "$TK_DERIVED_DATA_PATH/sample-$tk_language" \
        "${TK_COMMON_BUILD_SETTINGS[@]}"
}

if [[ -n "$TK_SWIFT_SAMPLE_CONTAINER" || -n "$TK_SWIFT_SAMPLE_SCHEME" ]]; then
    tk_build_sample swift "$TK_SWIFT_SAMPLE_CONTAINER" "$TK_SWIFT_SAMPLE_SCHEME"
fi

if [[ -n "$TK_OBJC_SAMPLE_CONTAINER" || -n "$TK_OBJC_SAMPLE_SCHEME" ]]; then
    tk_build_sample objc "$TK_OBJC_SAMPLE_CONTAINER" "$TK_OBJC_SAMPLE_SCHEME"
fi

tk_note "Package validation completed successfully"
