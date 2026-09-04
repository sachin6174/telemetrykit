#!/bin/bash

set -Eeuo pipefail

# Produces a library-evolution-enabled XCFramework containing iOS device and
# universal iOS Simulator slices. Output defaults to ./Artifacts.

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
    tk_fail "XCFramework creation requires macOS and Xcode"
fi

TK_SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TK_DEFAULT_PACKAGE_PATH="$(cd "$TK_SCRIPT_DIRECTORY/.." && pwd -P)"
TK_PACKAGE_PATH="${TK_PACKAGE_PATH:-$TK_DEFAULT_PACKAGE_PATH}"
[[ -d "$TK_PACKAGE_PATH" ]] || tk_fail "package directory does not exist: $TK_PACKAGE_PATH"
TK_PACKAGE_PATH="$(cd "$TK_PACKAGE_PATH" && pwd -P)"

TK_SCHEME="${TK_SCHEME:-TelemetryKit}"
TK_FRAMEWORK_NAME="${TK_FRAMEWORK_NAME:-TelemetryKit}"
TK_BUILD_CONFIGURATION="${TK_BUILD_CONFIGURATION:-Release}"
TK_IOS_DEPLOYMENT_TARGET="${TK_IOS_DEPLOYMENT_TARGET:-15.0}"
TK_OUTPUT_DIRECTORY="${TK_OUTPUT_DIRECTORY:-$TK_PACKAGE_PATH/Artifacts}"
TK_OVERWRITE="${TK_OVERWRITE:-0}"
TK_CREATE_ZIP="${TK_CREATE_ZIP:-1}"
TK_INCLUDE_X86_64_SIMULATOR="${TK_INCLUDE_X86_64_SIMULATOR:-1}"
TK_REQUIRE_OBJC_HEADER="${TK_REQUIRE_OBJC_HEADER:-1}"
TK_REQUIRE_PRIVACY_MANIFEST="${TK_REQUIRE_PRIVACY_MANIFEST:-1}"
TK_PRIVACY_MANIFEST="${TK_PRIVACY_MANIFEST:-}"
TK_VALIDATE_CONSUMERS="${TK_VALIDATE_CONSUMERS:-1}"
TK_SWIFT_COMPATIBILITY_FIXTURE="${TK_SWIFT_COMPATIBILITY_FIXTURE:-Compatibility/SwiftConsumer/main.swift}"
TK_OBJC_COMPATIBILITY_FIXTURE="${TK_OBJC_COMPATIBILITY_FIXTURE:-Compatibility/ObjectiveCConsumer/main.m}"

[[ "$TK_FRAMEWORK_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || tk_fail "TK_FRAMEWORK_NAME must be a valid module identifier"
[[ -f "$TK_PACKAGE_PATH/Package.swift" ]] || tk_fail "Package.swift not found at $TK_PACKAGE_PATH"

tk_require_command xcodebuild
tk_require_command swift
tk_require_command plutil
tk_require_command lipo
tk_require_command ditto
tk_require_command shasum
if tk_is_enabled "$TK_VALIDATE_CONSUMERS"; then
    tk_require_command xcrun
fi

mkdir -p "$TK_OUTPUT_DIRECTORY"
TK_OUTPUT_DIRECTORY="$(cd "$TK_OUTPUT_DIRECTORY" && pwd -P)"
[[ "$TK_OUTPUT_DIRECTORY" != "/" ]] || tk_fail "refusing to use the filesystem root as output"

TK_TEMP_PARENT="${TMPDIR:-/tmp}"
[[ -d "$TK_TEMP_PARENT" ]] || tk_fail "temporary directory does not exist: $TK_TEMP_PARENT"
TK_TEMP_PARENT="$(cd "$TK_TEMP_PARENT" && pwd -P)"
TK_STAGE_ROOT="$(mktemp -d "$TK_TEMP_PARENT/telemetrykit-xcframework.XXXXXX")"

tk_cleanup() {
    if [[ -n "${TK_STAGE_ROOT:-}" && -d "$TK_STAGE_ROOT" ]]; then
        case "$TK_STAGE_ROOT" in
            "$TK_TEMP_PARENT"/telemetrykit-xcframework.*) rm -rf -- "$TK_STAGE_ROOT" ;;
            *) printf 'warning: refusing to remove unexpected temporary path: %s\n' "$TK_STAGE_ROOT" >&2 ;;
        esac
    fi
}
trap tk_cleanup EXIT INT TERM

TK_ARCHIVE_ROOT="$TK_STAGE_ROOT/Archives"
TK_DEVICE_ARCHIVE="$TK_ARCHIVE_ROOT/$TK_FRAMEWORK_NAME-iOS.xcarchive"
TK_SIMULATOR_ARCHIVE="$TK_ARCHIVE_ROOT/$TK_FRAMEWORK_NAME-iOS-Simulator.xcarchive"
TK_STAGED_XCFRAMEWORK="$TK_STAGE_ROOT/$TK_FRAMEWORK_NAME.xcframework"
TK_STAGED_ZIP="$TK_STAGE_ROOT/$TK_FRAMEWORK_NAME.xcframework.zip"
mkdir -p "$TK_ARCHIVE_ROOT"

TK_COMMON_BUILD_SETTINGS=(
    "SKIP_INSTALL=NO"
    "BUILD_LIBRARY_FOR_DISTRIBUTION=YES"
    "CODE_SIGNING_ALLOWED=NO"
    "IPHONEOS_DEPLOYMENT_TARGET=$TK_IOS_DEPLOYMENT_TARGET"
    "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES"
    "GCC_TREAT_WARNINGS_AS_ERRORS=YES"
    'OTHER_SWIFT_FLAGS=$(inherited) -strict-concurrency=complete'
)

cd "$TK_PACKAGE_PATH"
tk_note "Resolving package dependencies"
xcodebuild -resolvePackageDependencies -scheme "$TK_SCHEME"

tk_note "Archiving iOS device framework"
xcodebuild archive \
    -scheme "$TK_SCHEME" \
    -configuration "$TK_BUILD_CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$TK_DEVICE_ARCHIVE" \
    "ARCHS=arm64" \
    "ONLY_ACTIVE_ARCH=NO" \
    "${TK_COMMON_BUILD_SETTINGS[@]}"

TK_SIMULATOR_ARCHS="arm64"
if tk_is_enabled "$TK_INCLUDE_X86_64_SIMULATOR"; then
    TK_SIMULATOR_ARCHS="arm64 x86_64"
fi

tk_note "Archiving iOS Simulator framework ($TK_SIMULATOR_ARCHS)"
xcodebuild archive \
    -scheme "$TK_SCHEME" \
    -configuration "$TK_BUILD_CONFIGURATION" \
    -destination "generic/platform=iOS Simulator" \
    -archivePath "$TK_SIMULATOR_ARCHIVE" \
    "ARCHS=$TK_SIMULATOR_ARCHS" \
    "ONLY_ACTIVE_ARCH=NO" \
    "EXCLUDED_ARCHS=" \
    "${TK_COMMON_BUILD_SETTINGS[@]}"

tk_find_framework() {
    local tk_archive="$1"
    local tk_candidate

    for tk_candidate in \
        "$tk_archive/Products/usr/local/lib/$TK_FRAMEWORK_NAME.framework" \
        "$tk_archive/Products/Library/Frameworks/$TK_FRAMEWORK_NAME.framework"; do
        if [[ -d "$tk_candidate" ]]; then
            printf '%s\n' "$tk_candidate"
            return
        fi
    done

    tk_candidate="$(find "$tk_archive/Products" -type d -name "$TK_FRAMEWORK_NAME.framework" -print -quit 2>/dev/null || true)"
    [[ -n "$tk_candidate" ]] || tk_fail "archive does not contain $TK_FRAMEWORK_NAME.framework: $tk_archive"
    printf '%s\n' "$tk_candidate"
}

TK_DEVICE_FRAMEWORK="$(tk_find_framework "$TK_DEVICE_ARCHIVE")"
TK_SIMULATOR_FRAMEWORK="$(tk_find_framework "$TK_SIMULATOR_ARCHIVE")"

if tk_is_enabled "$TK_REQUIRE_PRIVACY_MANIFEST"; then
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
    plutil -lint "$TK_PRIVACY_MANIFEST"

    # SwiftPM may place processed resources in a bundle beside the framework.
    # An XCFramework contains only its framework slices, so embed the manifest
    # at each framework root before assembly.
    cp "$TK_PRIVACY_MANIFEST" "$TK_DEVICE_FRAMEWORK/PrivacyInfo.xcprivacy"
    cp "$TK_PRIVACY_MANIFEST" "$TK_SIMULATOR_FRAMEWORK/PrivacyInfo.xcprivacy"
fi

TK_CREATE_ARGUMENTS=(
    -create-xcframework
    -framework "$TK_DEVICE_FRAMEWORK"
)

tk_append_debug_symbols() {
    local tk_archive="$1"
    local tk_dsym="$tk_archive/dSYMs/$TK_FRAMEWORK_NAME.framework.dSYM"
    local tk_symbol

    if [[ -d "$tk_dsym" ]]; then
        TK_CREATE_ARGUMENTS+=(-debug-symbols "$tk_dsym")
    fi
    while IFS= read -r -d '' tk_symbol; do
        TK_CREATE_ARGUMENTS+=(-debug-symbols "$tk_symbol")
    done < <(find "$tk_archive/BCSymbolMaps" -type f -name '*.bcsymbolmap' -print0 2>/dev/null)
}

tk_append_debug_symbols "$TK_DEVICE_ARCHIVE"
TK_CREATE_ARGUMENTS+=(-framework "$TK_SIMULATOR_FRAMEWORK")
tk_append_debug_symbols "$TK_SIMULATOR_ARCHIVE"
TK_CREATE_ARGUMENTS+=(-output "$TK_STAGED_XCFRAMEWORK")

tk_note "Creating $TK_FRAMEWORK_NAME.xcframework"
xcodebuild "${TK_CREATE_ARGUMENTS[@]}"

TK_XCFRAMEWORK_INFO="$TK_STAGED_XCFRAMEWORK/Info.plist"
[[ -f "$TK_XCFRAMEWORK_INFO" ]] || tk_fail "XCFramework Info.plist was not generated"
plutil -lint "$TK_XCFRAMEWORK_INFO"

TK_FOUND_DEVICE_ARM64=0
TK_FOUND_SIMULATOR_ARM64=0
TK_FOUND_SIMULATOR_X86_64=0
TK_FRAMEWORK_COUNT=0
TK_DEVICE_SLICE_FRAMEWORK=""
TK_SIMULATOR_SLICE_FRAMEWORK=""

while IFS= read -r -d '' tk_framework; do
    TK_FRAMEWORK_COUNT=$((TK_FRAMEWORK_COUNT + 1))
    tk_binary="$tk_framework/$TK_FRAMEWORK_NAME"
    [[ -f "$tk_binary" ]] || tk_fail "framework binary missing: $tk_binary"
    tk_architectures="$(lipo -archs "$tk_binary")"
    tk_note "$(basename "$(dirname "$tk_framework")"): $tk_architectures"

    case "$tk_framework" in
        *-simulator/*)
            [[ " $tk_architectures " == *" arm64 "* ]] && TK_FOUND_SIMULATOR_ARM64=1
            [[ " $tk_architectures " == *" x86_64 "* ]] && TK_FOUND_SIMULATOR_X86_64=1
            TK_SIMULATOR_SLICE_FRAMEWORK="$tk_framework"
            ;;
        *)
            [[ " $tk_architectures " == *" arm64 "* ]] && TK_FOUND_DEVICE_ARM64=1
            TK_DEVICE_SLICE_FRAMEWORK="$tk_framework"
            ;;
    esac

    find "$tk_framework/Modules" -type f -name '*.swiftinterface' -print -quit 2>/dev/null | grep -q . \
        || tk_fail "no stable Swift interface found in $tk_framework"
    [[ -f "$tk_framework/Modules/module.modulemap" ]] \
        || tk_fail "module map missing from $tk_framework"

    if tk_is_enabled "$TK_REQUIRE_OBJC_HEADER"; then
        [[ -f "$tk_framework/Headers/$TK_FRAMEWORK_NAME-Swift.h" ]] \
            || tk_fail "generated Objective-C compatibility header missing from $tk_framework"
    fi

    if tk_is_enabled "$TK_REQUIRE_PRIVACY_MANIFEST"; then
        find "$tk_framework" -type f -name PrivacyInfo.xcprivacy -print -quit 2>/dev/null | grep -q . \
            || tk_fail "privacy manifest missing from $tk_framework"
    fi
done < <(find "$TK_STAGED_XCFRAMEWORK" -type d -name "$TK_FRAMEWORK_NAME.framework" -print0)

[[ "$TK_FRAMEWORK_COUNT" -eq 2 ]] || tk_fail "expected two framework slices; found $TK_FRAMEWORK_COUNT"
[[ "$TK_FOUND_DEVICE_ARM64" -eq 1 ]] || tk_fail "XCFramework is missing the iOS arm64 slice"
[[ "$TK_FOUND_SIMULATOR_ARM64" -eq 1 ]] || tk_fail "XCFramework is missing the simulator arm64 slice"
if tk_is_enabled "$TK_INCLUDE_X86_64_SIMULATOR"; then
    [[ "$TK_FOUND_SIMULATOR_X86_64" -eq 1 ]] || tk_fail "XCFramework is missing the simulator x86_64 slice"
fi

tk_resolve_fixture() {
    local tk_fixture="$1"
    if [[ "$tk_fixture" != /* ]]; then
        tk_fixture="$TK_PACKAGE_PATH/$tk_fixture"
    fi
    [[ -f "$tk_fixture" ]] || tk_fail "compatibility fixture not found: $tk_fixture"
    printf '%s\n' "$tk_fixture"
}

if tk_is_enabled "$TK_VALIDATE_CONSUMERS"; then
    [[ -n "$TK_DEVICE_SLICE_FRAMEWORK" ]] \
        || tk_fail "could not locate the XCFramework's iOS device framework"
    [[ -n "$TK_SIMULATOR_SLICE_FRAMEWORK" ]] \
        || tk_fail "could not locate the XCFramework's iOS Simulator framework"

    TK_SWIFT_COMPATIBILITY_FIXTURE="$(tk_resolve_fixture "$TK_SWIFT_COMPATIBILITY_FIXTURE")"
    TK_OBJC_COMPATIBILITY_FIXTURE="$(tk_resolve_fixture "$TK_OBJC_COMPATIBILITY_FIXTURE")"

    tk_validate_consumers() {
        local tk_label="$1"
        local tk_sdk_name="$2"
        local tk_target="$3"
        local tk_framework="$4"
        local tk_sdk_path
        local tk_framework_search_path
        local tk_module_cache="$TK_STAGE_ROOT/ConsumerModuleCache/$tk_sdk_name"

        tk_sdk_path="$(xcrun --sdk "$tk_sdk_name" --show-sdk-path)"
        [[ -d "$tk_sdk_path" ]] || tk_fail "$tk_label SDK not found: $tk_sdk_path"
        tk_framework_search_path="$(dirname "$tk_framework")"
        mkdir -p "$tk_module_cache/swift" "$tk_module_cache/clang"

        tk_note "Type-checking Swift consumer against the $tk_label XCFramework slice"
        xcrun --sdk "$tk_sdk_name" swiftc \
            -typecheck \
            -swift-version 5 \
            -strict-concurrency=complete \
            -warnings-as-errors \
            -target "$tk_target" \
            -sdk "$tk_sdk_path" \
            -module-cache-path "$tk_module_cache/swift" \
            -F "$tk_framework_search_path" \
            "$TK_SWIFT_COMPATIBILITY_FIXTURE"

        tk_note "Syntax-checking Objective-C consumer against the $tk_label XCFramework slice"
        xcrun --sdk "$tk_sdk_name" clang \
            -fsyntax-only \
            -fmodules \
            -fmodules-cache-path="$tk_module_cache/clang" \
            -fobjc-arc \
            -Wall \
            -Wextra \
            -Werror \
            -target "$tk_target" \
            -isysroot "$tk_sdk_path" \
            -F "$tk_framework_search_path" \
            "$TK_OBJC_COMPATIBILITY_FIXTURE"
    }

    tk_validate_consumers \
        "iOS device" \
        iphoneos \
        "arm64-apple-ios${TK_IOS_DEPLOYMENT_TARGET}" \
        "$TK_DEVICE_SLICE_FRAMEWORK"
    tk_validate_consumers \
        "iOS Simulator" \
        iphonesimulator \
        "arm64-apple-ios${TK_IOS_DEPLOYMENT_TARGET}-simulator" \
        "$TK_SIMULATOR_SLICE_FRAMEWORK"
fi

if tk_is_enabled "$TK_CREATE_ZIP"; then
    tk_note "Creating distributable zip and checksums"
    (
        cd "$TK_STAGE_ROOT"
        ditto -c -k --sequesterRsrc --keepParent \
            "$TK_FRAMEWORK_NAME.xcframework" \
            "$TK_FRAMEWORK_NAME.xcframework.zip"
    )
    swift package compute-checksum "$TK_STAGED_ZIP" \
        >"$TK_STAGED_ZIP.checksum"
    (
        cd "$TK_STAGE_ROOT"
        shasum -a 256 "$TK_FRAMEWORK_NAME.xcframework.zip" \
            >"$TK_FRAMEWORK_NAME.xcframework.zip.sha256"
    )
fi

TK_OUTPUTS=("$TK_FRAMEWORK_NAME.xcframework")
if tk_is_enabled "$TK_CREATE_ZIP"; then
    TK_OUTPUTS+=(
        "$TK_FRAMEWORK_NAME.xcframework.zip"
        "$TK_FRAMEWORK_NAME.xcframework.zip.checksum"
        "$TK_FRAMEWORK_NAME.xcframework.zip.sha256"
    )
fi

for tk_output in "${TK_OUTPUTS[@]}"; do
    tk_destination="$TK_OUTPUT_DIRECTORY/$tk_output"
    if [[ -e "$tk_destination" ]]; then
        if ! tk_is_enabled "$TK_OVERWRITE"; then
            tk_fail "output already exists (set TK_OVERWRITE=1 to replace it): $tk_destination"
        fi
        case "$tk_output" in
            "$TK_FRAMEWORK_NAME.xcframework") rm -rf -- "$tk_destination" ;;
            "$TK_FRAMEWORK_NAME.xcframework.zip" | \
                "$TK_FRAMEWORK_NAME.xcframework.zip.checksum" | \
                "$TK_FRAMEWORK_NAME.xcframework.zip.sha256") rm -f -- "$tk_destination" ;;
            *) tk_fail "refusing to replace unexpected output name: $tk_output" ;;
        esac
    fi
    mv "$TK_STAGE_ROOT/$tk_output" "$tk_destination"
done

tk_note "XCFramework artifacts written to $TK_OUTPUT_DIRECTORY"
