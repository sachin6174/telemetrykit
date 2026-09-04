#!/bin/bash

set -Eeuo pipefail

# Generates the checked-in XcodeGen sample specifications in place. The
# resulting .xcodeproj directories are build artifacts and are intentionally
# not committed.

tk_fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

tk_note() {
    printf '==> %s\n' "$*"
}

command -v xcodegen >/dev/null 2>&1 || tk_fail "XcodeGen is required to generate the sample apps"

TK_SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TK_DEFAULT_PACKAGE_PATH="$(cd "$TK_SCRIPT_DIRECTORY/.." && pwd -P)"
TK_PACKAGE_PATH="${TK_PACKAGE_PATH:-$TK_DEFAULT_PACKAGE_PATH}"
[[ -d "$TK_PACKAGE_PATH" ]] || tk_fail "package directory does not exist: $TK_PACKAGE_PATH"
TK_PACKAGE_PATH="$(cd "$TK_PACKAGE_PATH" && pwd -P)"

tk_generate_sample() {
    local tk_name="$1"
    local tk_directory="$2"
    local tk_project="$3"
    local tk_specification="$TK_PACKAGE_PATH/$tk_directory/project.yml"
    local tk_expected_project="$TK_PACKAGE_PATH/$tk_directory/$tk_project.xcodeproj"

    [[ -f "$tk_specification" ]] || tk_fail "$tk_name sample specification not found: $tk_specification"
    tk_note "Generating $tk_name sample"
    (
        cd "$(dirname "$tk_specification")"
        xcodegen generate --spec "$(basename "$tk_specification")"
    )
    [[ -d "$tk_expected_project" ]] \
        || tk_fail "$tk_name sample project was not generated: $tk_expected_project"
    [[ -f "$tk_expected_project/project.pbxproj" ]] \
        || tk_fail "$tk_name sample project is incomplete: $tk_expected_project"
}

tk_note "Using $(xcodegen --version)"
tk_generate_sample Swift Examples/SwiftDemo SwiftDemo
tk_generate_sample Objective-C Examples/ObjectiveCDemo ObjectiveCDemo
tk_note "Sample projects generated successfully"
