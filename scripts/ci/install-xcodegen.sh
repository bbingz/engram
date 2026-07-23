#!/usr/bin/env bash

set -euo pipefail

version="${1:-}"
sha256="${2:-}"
runner_temp="${RUNNER_TEMP:-}"
github_path="${GITHUB_PATH:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "install-xcodegen: invalid version '${version:-<empty>}'" >&2
  exit 2
fi
if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "install-xcodegen: invalid SHA-256 '${sha256:-<empty>}'" >&2
  exit 2
fi
if [[ -z "$runner_temp" || ! -d "$runner_temp" ]]; then
  echo "install-xcodegen: RUNNER_TEMP must name an existing directory" >&2
  exit 2
fi
if [[ -z "$github_path" ]]; then
  echo "install-xcodegen: GITHUB_PATH is required" >&2
  exit 2
fi

install_root="$(mktemp -d "$runner_temp/xcodegen-${version}.XXXXXX")"
archive="$install_root/xcodegen.zip"
url="https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip"

curl --fail --silent --show-error --location \
  --retry 3 --retry-all-errors \
  --output "$archive" \
  "$url"
echo "$sha256  $archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$install_root"

binary="$install_root/xcodegen/bin/xcodegen"
if [[ ! -x "$binary" ]]; then
  echo "install-xcodegen: archive did not contain xcodegen/bin/xcodegen" >&2
  exit 1
fi

actual_version="$("$binary" --version)"
if [[ "$actual_version" != "Version: $version" ]]; then
  echo "install-xcodegen: expected Version: $version, got '$actual_version'" >&2
  exit 1
fi

echo "$install_root/xcodegen/bin" >> "$GITHUB_PATH"
echo "install-xcodegen: installed $actual_version"
