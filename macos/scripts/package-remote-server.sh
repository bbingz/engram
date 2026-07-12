#!/bin/bash
set -euo pipefail

umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATE_DIR="$MACOS_DIR/EngramRemoteServer/Packaging"

usage() {
  cat >&2 <<'USAGE'
usage:
  package-remote-server.sh --derived-data <abs-dir> --configuration Release \
    --arch arm64 --source-revision <40-hex-sha> --output <new-empty-dir>
  package-remote-server.sh --verify-only <bundle>
USAGE
}

fail() {
  echo "package-remote-server: ERROR: $*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local count="$2"
  [[ "$count" -ge 2 ]] || fail "missing value for $option"
}

require_unset() {
  local option="$1"
  local value="$2"
  [[ -z "$value" ]] || fail "duplicate argument: $option"
}

is_directory_empty() {
  local directory="$1"
  [[ -z "$(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

thin_macho_to_arm64() {
  local binary="$1"
  local architectures temporary mode

  [[ -f "$binary" ]] || fail "Mach-O file is missing: $binary"
  architectures="$(/usr/bin/lipo -archs "$binary")" ||
    fail "cannot inspect architectures for $binary"
  case " $architectures " in
    *" arm64 "*) ;;
    *) fail "Mach-O file does not support arm64: $binary ($architectures)" ;;
  esac

  if [[ "$architectures" != "arm64" ]]; then
    temporary="${binary}.arm64.$$"
    mode="$(/usr/bin/stat -f '%Lp' "$binary")"
    /usr/bin/lipo "$binary" -thin arm64 -output "$temporary"
    /bin/chmod "$mode" "$temporary"
    /bin/mv -f "$temporary" "$binary"
  fi

  /usr/bin/lipo "$binary" -verify_arch arm64 >/dev/null
}

codesign_bundle() {
  /usr/bin/codesign --force --sign - "$1"
}

sign_runtime_dylibs() {
  local frameworks_directory="$1"
  local dylib

  while IFS= read -r dylib; do
    [[ -n "$dylib" ]] || continue
    codesign_bundle "$dylib"
  done < <(
    /usr/bin/find "$frameworks_directory" -maxdepth 1 -type f -name '*.dylib' -print |
      LC_ALL=C sort
  )
}

swift_stdlib_tool_path() {
  local tool
  tool="$(xcrun --find swift-stdlib-tool)" ||
    fail "active Xcode does not provide swift-stdlib-tool"
  [[ -x "$tool" ]] || fail "swift-stdlib-tool is not executable: $tool"
  printf '%s\n' "$tool"
}

print_swift_runtime_dependencies() {
  local executable="$1"
  local tool="$2"

  "$tool" --print \
    --scan-executable "$executable" \
    --platform macosx
}

copy_swift_runtime_dependencies() {
  local executable="$1"
  local frameworks_directory="$2"
  local tool="$3"
  local dependency destination basename

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    [[ "$dependency" == /* && -f "$dependency" ]] ||
      fail "swift-stdlib-tool returned an invalid dependency: $dependency"
    basename="$(basename "$dependency")"
    [[ "$basename" == libswift*.dylib ]] ||
      fail "swift-stdlib-tool returned an unexpected dependency: $dependency"
    destination="$frameworks_directory/$basename"
    if [[ -e "$destination" ]]; then
      /usr/bin/cmp -s "$dependency" "$destination" ||
        fail "Swift runtime basename collision: $basename"
    else
      /usr/bin/ditto "$dependency" "$destination"
    fi
  done < <(print_swift_runtime_dependencies "$executable" "$tool")

  [[ -f "$frameworks_directory/libswiftCompatibilitySpan.dylib" ]] ||
    fail "swift-stdlib-tool did not resolve libswiftCompatibilitySpan.dylib"
}

verify_dependency_closure_for_binary() {
  local bundle="$1"
  local binary="$2"
  local dependency suffix candidate binary_directory

  binary_directory="$(cd "$(dirname "$binary")" && pwd -P)"
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /System/Library/* | /usr/lib/*) ;;
      @rpath/*)
        suffix="${dependency#@rpath/}"
        candidate="$bundle/Frameworks/$suffix"
        [[ -e "$candidate" ]] ||
          fail "unresolved @rpath dependency for $binary: $dependency"
        ;;
      @executable_path/*)
        suffix="${dependency#@executable_path/}"
        candidate="$bundle/bin/$suffix"
        [[ -e "$candidate" ]] ||
          fail "unresolved @executable_path dependency for $binary: $dependency"
        ;;
      @loader_path/*)
        suffix="${dependency#@loader_path/}"
        candidate="$binary_directory/$suffix"
        [[ -e "$candidate" ]] ||
          fail "unresolved @loader_path dependency for $binary: $dependency"
        ;;
      *) fail "non-relocatable dependency for $binary: $dependency" ;;
    esac
  done < <(
    /usr/bin/otool -L "$binary" |
      /usr/bin/tail -n +2 |
      /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/'
  )
}

verify_dependency_closure() {
  local bundle="$1"
  local executable="$bundle/bin/EngramRemoteServer"
  local dylib

  verify_dependency_closure_for_binary "$bundle" "$executable"
  while IFS= read -r dylib; do
    [[ -n "$dylib" ]] || continue
    verify_dependency_closure_for_binary "$bundle" "$dylib"
  done < <(
    /usr/bin/find "$bundle/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print |
      LC_ALL=C sort
  )
}

verify_framework_rpath() {
  local executable="$1"
  /usr/bin/otool -l "$executable" |
    /usr/bin/awk '
      $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
      in_rpath && $1 == "path" {
        if ($2 == "@executable_path/../Frameworks") found = 1
        in_rpath = 0
      }
      END { exit(found ? 0 : 1) }
    ' || fail "executable is missing @executable_path/../Frameworks rpath"
}

verify_manifest_file_set() {
  local bundle="$1"
  local manifest_paths actual_paths sorted_paths

  manifest_paths="$(
    /usr/bin/awk '
      !/^[0-9a-f]{64}  [^[:space:]]+$/ { exit 2 }
      { sub(/^[0-9a-f]{64}  /, ""); print }
    ' "$bundle/SHA256SUMS"
  )" || fail "SHA256SUMS has an invalid line"
  sorted_paths="$(printf '%s\n' "$manifest_paths" | LC_ALL=C sort)"
  [[ "$manifest_paths" == "$sorted_paths" ]] ||
    fail "SHA256SUMS paths are not sorted"

  actual_paths="$(
    cd "$bundle"
    /usr/bin/find . -type f ! -name SHA256SUMS -print |
      /usr/bin/sed 's#^\./##' |
      LC_ALL=C sort
  )"
  [[ "$manifest_paths" == "$actual_paths" ]] ||
    fail "SHA256SUMS does not exactly cover package files"
}

generate_manifest() {
  local bundle="$1"
  (
    cd "$bundle"
    while IFS= read -r relative_path; do
      relative_path="${relative_path#./}"
      /usr/bin/shasum -a 256 "$relative_path"
    done < <(
      /usr/bin/find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort
    )
  ) > "$bundle/SHA256SUMS"
  /bin/chmod 0600 "$bundle/SHA256SUMS"
}

verify_metadata() {
  local metadata="$1"
  local schema product configuration architecture revision

  /usr/bin/plutil -convert xml1 -o /dev/null "$metadata"
  schema="$(/usr/bin/plutil -extract schemaVersion raw -o - "$metadata")"
  product="$(/usr/bin/plutil -extract product raw -o - "$metadata")"
  configuration="$(/usr/bin/plutil -extract configuration raw -o - "$metadata")"
  architecture="$(/usr/bin/plutil -extract architecture raw -o - "$metadata")"
  revision="$(/usr/bin/plutil -extract sourceRevision raw -o - "$metadata")"

  [[ "$schema" == "1" ]] || fail "unsupported BUILD-METADATA schema"
  [[ "$product" == "EngramRemoteServer" ]] || fail "unexpected metadata product"
  [[ "$configuration" == "Release" ]] || fail "package is not a Release build"
  [[ "$architecture" == "arm64" ]] || fail "package is not arm64"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "invalid metadata source revision"
  if /usr/bin/grep -Eiq 'token|secret|password|credential|at[_-]?rest[_-]?key' "$metadata"; then
    fail "BUILD-METADATA contains a credential-like field"
  fi
}

verify_templates() {
  local wrapper="$1"
  local launch_agent="$2"
  local expected_revision="$3"
  local wrapper_mode launch_agent_mode revision_count

  wrapper_mode="$(/usr/bin/stat -f '%Lp' "$wrapper")"
  launch_agent_mode="$(/usr/bin/stat -f '%Lp' "$launch_agent")"
  [[ "$wrapper_mode" == "700" ]] || fail "wrapper template mode must be 0700"
  [[ "$launch_agent_mode" == "600" ]] ||
    fail "LaunchAgent template mode must be 0600"
  /usr/bin/plutil -lint "$launch_agent" >/dev/null

  [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] ||
    fail "cannot verify templates against an invalid source revision"
  if /usr/bin/grep -q '__ENGRAM_REMOTE_SOURCE_REVISION__' "$wrapper"; then
    fail "wrapper template contains an unresolved source revision"
  fi
  revision_count="$(
    /usr/bin/awk '
      /^[[:space:]]*(export[[:space:]]+)?ENGRAM_REMOTE_SOURCE_REVISION[[:space:]]*=/ {
        count += 1
      }
      END { print count + 0 }
    ' "$wrapper"
  )"
  [[ "$revision_count" == "1" ]] ||
    fail "wrapper template must export exactly one source revision"
  /usr/bin/grep -Fqx \
    "export ENGRAM_REMOTE_SOURCE_REVISION='$expected_revision'" "$wrapper" ||
    fail "wrapper template source revision does not match BUILD-METADATA"

  if /usr/bin/grep -Eiq \
    '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(TOKEN|KEY|PASSWORD|SECRET|CREDENTIAL)[A-Za-z0-9_]*[[:space:]]*=' \
    "$wrapper"; then
    fail "deployment templates contain credential-like assignments"
  fi
  if /usr/bin/grep -Eiq \
    'ENGRAM_REMOTE_(ARCHIVE_)?(TOKEN|AT_REST_KEY)|EnvironmentVariables|password|credential|private[_-]?key' \
    "$wrapper" "$launch_agent"; then
    fail "deployment templates contain credential-like or environment material"
  fi
}

substitute_wrapper_revision() {
  local wrapper="$1"
  local revision="$2"
  local placeholder='__ENGRAM_REMOTE_SOURCE_REVISION__'
  local placeholder_count temporary

  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] ||
    fail "cannot substitute an invalid source revision"
  placeholder_count="$(
    /usr/bin/grep -o "$placeholder" "$wrapper" | /usr/bin/wc -l | /usr/bin/tr -d ' '
  )"
  [[ "$placeholder_count" == "1" ]] ||
    fail "wrapper template must contain exactly one source revision placeholder"
  temporary="${wrapper}.revision.$$"
  /usr/bin/sed "s/$placeholder/$revision/" "$wrapper" > "$temporary"
  /bin/chmod 0700 "$temporary"
  /bin/mv -f "$temporary" "$wrapper"
}

verify_package_layout() {
  local bundle="$1"
  local required

  for required in \
    "$bundle/bin/EngramRemoteServer" \
    "$bundle/bin/swift-nio_NIOPosix.bundle" \
    "$bundle/Frameworks/libswiftCompatibilitySpan.dylib" \
    "$bundle/templates/run-engram-remote.zsh.template" \
    "$bundle/templates/com.engram.remote-server.plist.template" \
    "$bundle/BUILD-METADATA.json" \
    "$bundle/SHA256SUMS"; do
    [[ -e "$required" ]] || fail "required package entry is missing: $required"
  done
  [[ -x "$bundle/bin/EngramRemoteServer" ]] || fail "server binary is not executable"
}

verify_arm64_only() {
  local binary="$1"
  local architectures

  /usr/bin/lipo "$binary" -verify_arch arm64 >/dev/null
  architectures="$(/usr/bin/lipo -archs "$binary")"
  [[ "$architectures" == "arm64" ]] ||
    fail "packaged Mach-O is not arm64-only: $binary ($architectures)"
}

verify_signatures_and_architecture() {
  local bundle="$1"
  local executable="$bundle/bin/EngramRemoteServer"
  local dylib

  verify_arm64_only "$executable"
  /usr/bin/codesign --verify --deep --strict "$executable"

  while IFS= read -r dylib; do
    [[ -n "$dylib" ]] || continue
    verify_arm64_only "$dylib"
    /usr/bin/codesign --verify --deep --strict "$dylib"
  done < <(
    /usr/bin/find "$bundle/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print |
      LC_ALL=C sort
  )
}

verify_package() {
  local bundle="$1"
  local canonical_bundle revision

  [[ -d "$bundle" && ! -L "$bundle" ]] || fail "verify-only bundle must be a directory"
  canonical_bundle="$(cd "$bundle" && pwd -P)"
  verify_package_layout "$canonical_bundle"
  verify_manifest_file_set "$canonical_bundle"
  (
    cd "$canonical_bundle"
    /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
  ) || fail "SHA256SUMS verification failed"
  verify_metadata "$canonical_bundle/BUILD-METADATA.json"
  revision="$(
    /usr/bin/plutil -extract sourceRevision raw -o - \
      "$canonical_bundle/BUILD-METADATA.json"
  )"
  verify_templates \
    "$canonical_bundle/templates/run-engram-remote.zsh.template" \
    "$canonical_bundle/templates/com.engram.remote-server.plist.template" \
    "$revision"
  verify_signatures_and_architecture "$canonical_bundle"
  verify_framework_rpath "$canonical_bundle/bin/EngramRemoteServer"
  verify_dependency_closure "$canonical_bundle"
  echo "package-remote-server: PASS $canonical_bundle"
}

write_metadata() {
  local destination="$1"
  local revision="$2"

  /usr/bin/printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "product": "EngramRemoteServer",' \
    '  "configuration": "Release",' \
    '  "architecture": "arm64",' \
    "  \"sourceRevision\": \"$revision\"" \
    '}' > "$destination"
  /bin/chmod 0600 "$destination"
}

package_remote_server() {
  local derived_data="$1"
  local configuration="$2"
  local revision="$3"
  local output="$4"
  local products_directory="$derived_data/Build/Products/$configuration"
  local source_executable="$products_directory/EngramRemoteServer"
  local source_resource_bundle="$products_directory/swift-nio_NIOPosix.bundle"
  local tool dylib

  local BUNDLE_EXECUTABLE="$output/bin/EngramRemoteServer"
  local BUNDLE_RESOURCE="$output/bin/swift-nio_NIOPosix.bundle"
  local BUNDLE_WRAPPER_TEMPLATE="$output/templates/run-engram-remote.zsh.template"
  local BUNDLE_LAUNCH_AGENT_TEMPLATE="$output/templates/com.engram.remote-server.plist.template"

  [[ -f "$source_executable" ]] || fail "missing Release executable: $source_executable"
  [[ -d "$source_resource_bundle" ]] ||
    fail "missing Release NIO resource bundle: $source_resource_bundle"
  [[ -f "$TEMPLATE_DIR/run-engram-remote.zsh.template" ]] ||
    fail "missing wrapper template"
  [[ -f "$TEMPLATE_DIR/com.engram.remote-server.plist.template" ]] ||
    fail "missing LaunchAgent template"

  /bin/mkdir -p "$output/bin" "$output/Frameworks" "$output/templates"
  /bin/cp "$source_executable" "$BUNDLE_EXECUTABLE"
  /usr/bin/ditto \
    "$products_directory/swift-nio_NIOPosix.bundle" "$BUNDLE_RESOURCE"
  /bin/cp "$TEMPLATE_DIR/run-engram-remote.zsh.template" "$BUNDLE_WRAPPER_TEMPLATE"
  /bin/cp \
    "$TEMPLATE_DIR/com.engram.remote-server.plist.template" \
    "$BUNDLE_LAUNCH_AGENT_TEMPLATE"
  substitute_wrapper_revision "$BUNDLE_WRAPPER_TEMPLATE" "$revision"
  /bin/chmod 0700 "$BUNDLE_EXECUTABLE"
  /bin/chmod 0700 "$BUNDLE_WRAPPER_TEMPLATE"
  /bin/chmod 0600 "$BUNDLE_LAUNCH_AGENT_TEMPLATE"

  thin_macho_to_arm64 "$BUNDLE_EXECUTABLE"

  tool="$(swift_stdlib_tool_path)"
  copy_swift_runtime_dependencies \
    "$BUNDLE_EXECUTABLE" "$output/Frameworks" "$tool"
  while IFS= read -r dylib; do
    [[ -n "$dylib" ]] || continue
    thin_macho_to_arm64 "$dylib"
  done < <(
    /usr/bin/find "$output/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print |
      LC_ALL=C sort
  )

  sign_runtime_dylibs "$output/Frameworks"
  codesign_bundle "$BUNDLE_EXECUTABLE"

  write_metadata "$output/BUILD-METADATA.json" "$revision"
  generate_manifest "$output"
  verify_package "$output"
}

if [[ "${1:-}" == "--verify-only" ]]; then
  [[ "$#" -eq 2 ]] || fail "--verify-only cannot be combined with other arguments"
  verify_package "$2"
  exit 0
fi

DERIVED_DATA=""
CONFIGURATION=""
ARCHITECTURE=""
SOURCE_REVISION=""
OUTPUT=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --derived-data)
      require_value "$1" "$#"
      require_unset "$1" "$DERIVED_DATA"
      DERIVED_DATA="$2"
      shift 2
      ;;
    --configuration)
      require_value "$1" "$#"
      require_unset "$1" "$CONFIGURATION"
      CONFIGURATION="$2"
      shift 2
      ;;
    --arch)
      require_value "$1" "$#"
      require_unset "$1" "$ARCHITECTURE"
      ARCHITECTURE="$2"
      shift 2
      ;;
    --source-revision)
      require_value "$1" "$#"
      require_unset "$1" "$SOURCE_REVISION"
      SOURCE_REVISION="$2"
      shift 2
      ;;
    --output)
      require_value "$1" "$#"
      require_unset "$1" "$OUTPUT"
      OUTPUT="$2"
      shift 2
      ;;
    --verify-only)
      fail "--verify-only cannot be combined with packaging arguments"
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$DERIVED_DATA" || -z "$CONFIGURATION" || -z "$ARCHITECTURE" ||
  -z "$SOURCE_REVISION" || -z "$OUTPUT" ]]; then
  usage
  fail "all packaging arguments are required"
fi

[[ "$DERIVED_DATA" == /* ]] || fail "--derived-data must be an absolute path"
[[ "$CONFIGURATION" == "Release" ]] || fail "only Release packaging is supported"
[[ "$ARCHITECTURE" == "arm64" ]] || fail "only arm64 packaging is supported"
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
  fail "--source-revision must be a lowercase 40-character hexadecimal commit"
[[ ! -L "$OUTPUT" ]] || fail "output directory must not be a symlink"
if [[ -e "$OUTPUT" ]]; then
  [[ -d "$OUTPUT" ]] || fail "output path must be a directory"
  is_directory_empty "$OUTPUT" || fail "output directory must be new or empty"
else
  /bin/mkdir -p "$OUTPUT"
fi

package_remote_server \
  "$DERIVED_DATA" "$CONFIGURATION" "$SOURCE_REVISION" "$OUTPUT"
