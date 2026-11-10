#!/bin/bash
# Build the storage-only EngramRemoteServer for 10.0.0.9 (Intel Mac mini, macOS 12).
# Hummingbird requires macOS 14, so this binary uses EngramRemoteServer/StorageOnlyMain.swift
# (a minimal HTTP/1.1 front end) over the same ArchiveStore/BlobStore/config sources.
# It is outside xcodegen/CI: run the x86_64 EngramRemoteServerCore tests under Rosetta
# (xcodebuild test -scheme EngramRemoteServerCore -destination 'platform=macOS,arch=x86_64'
# ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO) before deploying a new build.
#
# usage: macos/scripts/build-storage-only-remote-server.sh <output-binary> [--typecheck]
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT="${1:?output path required}"
cd "$MACOS_DIR"

core=()
for f in EngramRemoteServer/Core/*.swift; do
  grep -q -E '^import (Hummingbird|HTTPTypes|NIO)' "$f" || core+=("$f")
done
shared=(
  Shared/EngramCore/ArchiveV2/ArchiveHash.swift
  Shared/EngramCore/ArchiveV2/ArchiveCanonicalJSON.swift
  Shared/EngramCore/ArchiveV2/ArchiveCursorLegacySession.swift
  Shared/EngramCore/ArchiveV2/ArchiveModels.swift
  Shared/EngramCore/ArchiveV2/ArchiveSourceDescriptor.swift
  Shared/EngramCore/ArchiveV2/CollectorPublicationModels.swift
  Shared/EngramCore/ArchiveV2/ArchiveRemoteTelemetry.swift
  Shared/Security/SecureRegularFile.swift
)
mode=(-O -o "$OUTPUT")
[[ "${2:-}" == "--typecheck" ]] && mode=(-typecheck)
xcrun swiftc "${mode[@]}" -swift-version 5 -target x86_64-apple-macos12.0 -parse-as-library \
  EngramRemoteServer/StorageOnlyMain.swift "${core[@]}" "${shared[@]}"
