#!/bin/bash

set -Eeuo pipefail

# Compares the package's public API with a tag or revision. With no explicit
# baseline, the highest semantic-version tag reachable from HEAD is used.

tk_fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

tk_note() {
    printf '==> %s\n' "$*"
}

tk_is_enabled() {
    case "$1" in
        1 | true | TRUE | yes | YES) return 0 ;;
        0 | false | FALSE | no | NO) return 1 ;;
        *) tk_fail "expected a boolean value, received: $1" ;;
    esac
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    tk_fail "Swift API compatibility validation requires macOS and Xcode"
fi

command -v git >/dev/null 2>&1 || tk_fail "required command not found: git"
command -v swift >/dev/null 2>&1 || tk_fail "required command not found: swift"

TK_SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TK_DEFAULT_PACKAGE_PATH="$(cd "$TK_SCRIPT_DIRECTORY/.." && pwd -P)"
TK_PACKAGE_PATH="${TK_PACKAGE_PATH:-$TK_DEFAULT_PACKAGE_PATH}"
[[ -d "$TK_PACKAGE_PATH" ]] || tk_fail "package directory does not exist: $TK_PACKAGE_PATH"
TK_PACKAGE_PATH="$(cd "$TK_PACKAGE_PATH" && pwd -P)"

TK_API_PRODUCT="${TK_API_PRODUCT:-TelemetryKit}"
TK_API_TARGET="${TK_API_TARGET:-}"
TK_API_BASELINE="${TK_API_BASELINE:-}"
TK_API_ALLOWLIST="${TK_API_ALLOWLIST:-}"
TK_API_REQUIRE_BASELINE="${TK_API_REQUIRE_BASELINE:-0}"

[[ -f "$TK_PACKAGE_PATH/Package.swift" ]] || tk_fail "Package.swift not found at $TK_PACKAGE_PATH"
git -C "$TK_PACKAGE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || tk_fail "API comparison requires a Git repository"

if [[ -z "$TK_API_BASELINE" ]]; then
    TK_API_BASELINE="$(
        git -C "$TK_PACKAGE_PATH" tag --merged HEAD --list --sort=-v:refname \
            | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' \
            | head -n 1 \
            || true
    )"
fi

if [[ -z "$TK_API_BASELINE" ]]; then
    if tk_is_enabled "$TK_API_REQUIRE_BASELINE"; then
        tk_fail "no semantic-version API baseline tag was found"
    fi
    tk_note "No semantic-version tag exists yet; API compatibility check skipped"
    exit 0
fi

git -C "$TK_PACKAGE_PATH" rev-parse --verify --quiet "$TK_API_BASELINE^{commit}" >/dev/null \
    || tk_fail "API baseline does not resolve to a commit: $TK_API_BASELINE"

TK_API_ARGUMENTS=(
    package
    --package-path "$TK_PACKAGE_PATH"
    diagnose-api-breaking-changes
    "$TK_API_BASELINE"
    --products "$TK_API_PRODUCT"
)

if [[ -n "$TK_API_TARGET" ]]; then
    TK_API_ARGUMENTS+=(--targets "$TK_API_TARGET")
fi

if [[ -n "$TK_API_ALLOWLIST" ]]; then
    if [[ "$TK_API_ALLOWLIST" != /* ]]; then
        TK_API_ALLOWLIST="$TK_PACKAGE_PATH/$TK_API_ALLOWLIST"
    fi
    [[ -f "$TK_API_ALLOWLIST" ]] || tk_fail "API allowlist not found: $TK_API_ALLOWLIST"
    TK_API_ARGUMENTS+=(--breakage-allowlist-path "$TK_API_ALLOWLIST")
fi

tk_note "Comparing $TK_API_PRODUCT public API with $TK_API_BASELINE"
swift "${TK_API_ARGUMENTS[@]}"
tk_note "Public API compatibility check completed successfully"
