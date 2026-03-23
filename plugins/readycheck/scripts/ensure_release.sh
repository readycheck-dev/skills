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
RUNTIMES_ROOT="$CACHE_ROOT/runtime"
DEFAULT_ASSET_URL="https://github.com/readycheck-dev/ReadyCheck/releases/latest/download/readycheck-plugin-latest-macos.zip"

if [[ -f "$PLUGIN_RELEASE_URL_FILE" ]]; then
    FILE_ASSET_URL="$(tr -d '\r' < "$PLUGIN_RELEASE_URL_FILE")"
    if [[ -n "$FILE_ASSET_URL" ]]; then
        DEFAULT_ASSET_URL="$FILE_ASSET_URL"
    fi
fi

ASSET_URL="${READYCHECK_RELEASE_URL:-$DEFAULT_ASSET_URL}"

extract_plugin_manifest_version() {
    local manifest_path="$1"
    python3 - "$manifest_path" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
try:
    manifest = json.loads(manifest_path.read_text())
except FileNotFoundError:
    raise SystemExit(1)

version = manifest.get("version", "")
if version:
    print(version)
PY
}

extract_release_version_from_url() {
    local asset_url="$1"

    if [[ "$asset_url" =~ /releases/download/v([0-9]+\.[0-9]+\.[0-9]+)/readycheck-plugin-([0-9]+\.[0-9]+\.[0-9]+)-macos\.zip$ ]]; then
        if [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    if [[ "$asset_url" =~ /readycheck-plugin-([0-9]+\.[0-9]+\.[0-9]+)-macos\.zip$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

download_release_asset() {
    local asset_url="$1"
    local zip_path="$2"
    local github_auth="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    local github_pattern='^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)$'

    if [[ "$asset_url" =~ $github_pattern ]]; then
        local repo="${BASH_REMATCH[1]}"
        local tag="${BASH_REMATCH[2]}"
        local asset_name="${BASH_REMATCH[3]}"

        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            gh release download "$tag" --repo "$repo" --pattern "$asset_name" --output "$zip_path"
            return 0
        fi
    fi

    if [[ -n "$github_auth" ]]; then
        curl -fL \
            -H "Authorization: Bearer $github_auth" \
            -H "Accept: application/octet-stream" \
            "$asset_url" \
            -o "$zip_path"
        return 0
    fi

    curl -fL "$asset_url" -o "$zip_path"
}

is_valid_runtime_root() {
    local root="$1"
    [[ -n "$root" && -x "$root/bin/ada" && -f "$root/.claude-plugin/plugin.json" ]]
}

runtime_matches_requested_release() {
    local root="$1"
    local asset_url="$2"
    local metadata_path="$root/.readycheck-release.json"

    is_valid_runtime_root "$root" || return 1
    [[ -f "$metadata_path" ]] || return 1

    python3 - "$metadata_path" "$asset_url" <<'PY'
import json
import pathlib
import sys

metadata_path = pathlib.Path(sys.argv[1])
asset_url = sys.argv[2]
metadata = json.loads(metadata_path.read_text())

if metadata.get("asset_url") != asset_url:
    raise SystemExit(1)
PY
}

write_release_metadata() {
    local metadata_path="$1"
    local asset_url="$2"
    local version="$3"

    python3 - "$metadata_path" "$asset_url" "$version" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

metadata_path = pathlib.Path(sys.argv[1])
asset_url = sys.argv[2]
version = sys.argv[3]

metadata = {
    "asset_url": asset_url,
    "version": version,
    "installed_at": datetime.now(timezone.utc).isoformat(),
}

metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
PY
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

REQUESTED_RELEASE_VERSION="$(extract_release_version_from_url "$ASSET_URL" || true)"
CACHE_LOOKUP_ROOT="$RUNTIMES_ROOT/${REQUESTED_RELEASE_VERSION:-latest}"
LATEST_LINK="$RUNTIMES_ROOT/latest"

if runtime_matches_requested_release "$CACHE_LOOKUP_ROOT" "$ASSET_URL"; then
    printf '%s\n' "$CACHE_LOOKUP_ROOT"
    exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/readycheck-release.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ZIP_PATH="$TMP_DIR/readycheck-plugin-latest-macos.zip"
EXTRACT_DIR="$TMP_DIR/extracted"

mkdir -p "$CACHE_ROOT"

if ! download_release_asset "$ASSET_URL" "$ZIP_PATH"; then
    cat >&2 <<'EOF'
Unable to download the ReadyCheck release package.

For private GitHub repositories, authenticate with `gh auth login`
or set `GH_TOKEN` / `GITHUB_TOKEN` before running the plugin.

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

EXTRACTED_RELEASE_VERSION="$(extract_plugin_manifest_version "$EXTRACT_DIR/.claude-plugin/plugin.json" || true)"
if [[ -n "$REQUESTED_RELEASE_VERSION" && -n "$EXTRACTED_RELEASE_VERSION" && "$REQUESTED_RELEASE_VERSION" != "$EXTRACTED_RELEASE_VERSION" ]]; then
    echo "Downloaded ReadyCheck release package version does not match the pinned release URL." >&2
    echo "Requested version:  $REQUESTED_RELEASE_VERSION" >&2
    echo "Downloaded version: $EXTRACTED_RELEASE_VERSION" >&2
    exit 1
fi

FINAL_RELEASE_VERSION="${REQUESTED_RELEASE_VERSION:-${EXTRACTED_RELEASE_VERSION:-latest}}"
FINAL_INSTALL_ROOT="$RUNTIMES_ROOT/$FINAL_RELEASE_VERSION"
STAGING_DIR="$CACHE_ROOT/runtime.staging.$FINAL_RELEASE_VERSION"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$EXTRACT_DIR/." "$STAGING_DIR/"
write_release_metadata "$STAGING_DIR/.readycheck-release.json" "$ASSET_URL" "$FINAL_RELEASE_VERSION"

mkdir -p "$RUNTIMES_ROOT"
rm -rf "$FINAL_INSTALL_ROOT"
mv "$STAGING_DIR" "$FINAL_INSTALL_ROOT"

if [[ -z "$REQUESTED_RELEASE_VERSION" ]]; then
    ln -sfn "$FINAL_RELEASE_VERSION" "$LATEST_LINK"
fi

printf '%s\n' "$FINAL_INSTALL_ROOT"
