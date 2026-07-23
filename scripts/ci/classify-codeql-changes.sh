#!/usr/bin/env bash

set -euo pipefail

base_sha="${1:-}"
head_sha="${2:-HEAD}"
output_file="${3:-/dev/stdout}"

typescript=true
swift_product=true
swift_remote_server=true

if [[ -n "$base_sha" && ! "$base_sha" =~ ^0+$ ]] &&
   git cat-file -e "$base_sha^{commit}" 2>/dev/null &&
   git cat-file -e "$head_sha^{commit}" 2>/dev/null; then
  typescript=false
  swift_product=false
  swift_remote_server=false

  while IFS= read -r path; do
    case "$path" in
      .github/workflows/codeql.yml|scripts/ci/classify-codeql-changes.sh|scripts/ci/install-xcodegen.sh|scripts/ci/verify-codeql-gate.sh)
        typescript=true
        swift_product=true
        swift_remote_server=true
        ;;
      *.cjs|*.js|*.jsx|*.mjs|*.ts|*.tsx|package.json|package-lock.json|tsconfig*.json)
        typescript=true
        ;;
      macos/project.yml|macos/Engram.xcodeproj/project.pbxproj|macos/Engram.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
        swift_product=true
        swift_remote_server=true
        ;;
      macos/Shared/EngramCore/ArchiveV2/ArchiveHash.swift|macos/Shared/EngramCore/ArchiveV2/ArchiveCanonicalJSON.swift|macos/Shared/EngramCore/ArchiveV2/ArchiveModels.swift|macos/Shared/EngramCore/ArchiveV2/ArchiveRemoteTelemetry.swift)
        swift_product=true
        swift_remote_server=true
        ;;
      macos/EngramRemoteServer/*)
        swift_remote_server=true
        ;;
      macos/*)
        swift_product=true
        ;;
    esac
  done < <(git diff --name-only "$base_sha" "$head_sha")
fi

{
  echo "typescript=$typescript"
  echo "swift_product=$swift_product"
  echo "swift_remote_server=$swift_remote_server"
} >> "$output_file"
