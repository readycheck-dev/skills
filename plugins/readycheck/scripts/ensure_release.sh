#!/bin/bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ReadyCheck release packages are currently published for macOS only." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLUGIN_RELEASE_URL_FILE="$PLUGIN_ROOT/.claude-plugin/release-url"
CACHE_ROOT="${READYCHECK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/readycheck}"
INSTALL_ROOT="$CACHE_ROOT/runtime"
DEFAULT_ASSET_URL="https://github.com/readycheck-dev/ReadyCheck/releases/latest/download/readycheck-plugin-latest-macos.zip"

if [[ -f "$PLUGIN_RELEASE_URL_FILE" ]]; then
    FILE_ASSET_URL="$(tr -d '\r' < "$PLUGIN_RELEASE_URL_FILE")"
    if [[ -n "$FILE_ASSET_URL" ]]; then
        DEFAULT_ASSET_URL="$FILE_ASSET_URL"
    fi
fi

ASSET_URL="${READYCHECK_RELEASE_URL:-$DEFAULT_ASSET_URL}"

is_valid_runtime_root() {
    local root="$1"
    [[ -n "$root" && -x "$root/bin/ada" && -f "$root/.claude-plugin/plugin.json" ]]
}

find_local_runtime_root() {
    local current="$PLUGIN_ROOT"
    while [[ "$current" != "/" ]]; do
        local candidate="$current/dist"
        if is_valid_runtime_root "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        current="$(dirname "$current")"
    done
    return 1
}

if [[ -n "${READYCHECK_RUNTIME_DIR:-}" ]]; then
    if is_valid_runtime_root "$READYCHECK_RUNTIME_DIR"; then
        printf '%s\n' "$READYCHECK_RUNTIME_DIR"
        exit 0
    fi

    echo "READYCHECK_RUNTIME_DIR does not point to a valid ReadyCheck runtime: $READYCHECK_RUNTIME_DIR" >&2
    exit 1
fi

if is_valid_runtime_root "$PLUGIN_ROOT"; then
    printf '%s\n' "$PLUGIN_ROOT"
    exit 0
fi

LOCAL_RUNTIME_ROOT="$(find_local_runtime_root || true)"
if [[ -n "$LOCAL_RUNTIME_ROOT" ]]; then
    printf '%s\n' "$LOCAL_RUNTIME_ROOT"
    exit 0
fi

if is_valid_runtime_root "$INSTALL_ROOT"; then
    printf '%s\n' "$INSTALL_ROOT"
    exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/readycheck-release.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ZIP_PATH="$TMP_DIR/readycheck-plugin-latest-macos.zip"
EXTRACT_DIR="$TMP_DIR/extracted"
STAGING_DIR="$CACHE_ROOT/runtime.staging"

mkdir -p "$CACHE_ROOT"

if ! curl -fL "$ASSET_URL" -o "$ZIP_PATH"; then
    cat >&2 <<'EOF'
Unable to download the latest ReadyCheck release package.

Make sure a GitHub release exists with the asset:
  readycheck-plugin-latest-macos.zip

The asset is produced by .github/workflows/release.yml.
EOF
    exit 1
fi

mkdir -p "$EXTRACT_DIR"
unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"

if [[ ! -x "$EXTRACT_DIR/bin/ada" || ! -f "$EXTRACT_DIR/.claude-plugin/plugin.json" ]]; then
    echo "Downloaded ReadyCheck release package is missing the expected plugin layout." >&2
    exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$EXTRACT_DIR/." "$STAGING_DIR/"
rm -rf "$INSTALL_ROOT"
mv "$STAGING_DIR" "$INSTALL_ROOT"

printf '%s\n' "$INSTALL_ROOT"
