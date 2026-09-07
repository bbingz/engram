#!/bin/bash
set -euo pipefail

umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATE_DIR="$MACOS_DIR/EngramService/Packaging"
TEMPLATE_NAMES=(run-engram-service-index.zsh.template com.engram.service-index.plist.template)

FRAMEWORK_NAMES=(GRDB-dynamic EngramCoreRead EngramCoreWrite EngramServiceCore)

verify_source_templates() {
  local name
  [[ -d "$MACOS_DIR/EngramService" && ! -L "$MACOS_DIR/EngramService" ]] ||
    fail "source template role directory is missing or aliased"
  [[ -d "$TEMPLATE_DIR" && ! -L "$TEMPLATE_DIR" ]] ||
    fail "source Packaging template directory is missing or aliased"
  for name in "${TEMPLATE_NAMES[@]}"; do
    [[ -f "$TEMPLATE_DIR/$name" && ! -L "$TEMPLATE_DIR/$name" ]] ||
      fail "source template is missing or not an unaliased regular file: $name"
  done
}

verify_launch_templates() {
  local bundle="$1" name mode expected_mode platform
  verify_source_templates
  [[ -d "$bundle/templates" && ! -L "$bundle/templates" ]] ||
    fail "package templates directory is missing or aliased"
  platform="$(/usr/bin/uname -s)"
  for name in "${TEMPLATE_NAMES[@]}"; do
    [[ -f "$bundle/templates/$name" && ! -L "$bundle/templates/$name" ]] ||
      fail "package template is missing or not an unaliased regular file: $name"
    case "$platform" in
      Darwin) mode="$(/usr/bin/stat -f '%Lp' "$bundle/templates/$name")" ;;
      Linux) mode="$(/usr/bin/stat -c '%a' "$bundle/templates/$name")" ;;
      *) fail "cannot verify template modes on unsupported platform: $platform" ;;
    esac
    case "$name" in
      *.zsh.template) expected_mode=700 ;;
      *.plist.template) expected_mode=600 ;;
    esac
    [[ "$mode" == "$expected_mode" ]] ||
      fail "package template mode must be 0$expected_mode: $name"
    /usr/bin/cmp -s "$bundle/templates/$name" "$TEMPLATE_DIR/$name" ||
      fail "package template does not exactly match trusted source template: $name"
  done
}

copy_launch_templates() {
  local output="$1" name
  /bin/mkdir -p "$output/templates"
  for name in "${TEMPLATE_NAMES[@]}"; do
    /bin/cp "$TEMPLATE_DIR/$name" "$output/templates/$name"
    case "$name" in
      *.zsh.template) /bin/chmod 0700 "$output/templates/$name" ;;
      *.plist.template) /bin/chmod 0600 "$output/templates/$name" ;;
    esac
  done
}

usage() {
  cat >&2 <<'USAGE'
usage:
  package-service.sh --derived-data <abs-dir> --configuration Release \
    --arch arm64 --source-revision <40-hex-sha> --output <new-empty-dir>
  package-service.sh --verify-only <bundle>
  package-service.sh --dry-run --derived-data <abs-dir> --configuration Release \
    --arch arm64 --source-revision <40-hex-sha> --output <abs-dir>
USAGE
}

fail() {
  echo "package-service: ERROR: $*" >&2
  exit 1
}

require_value() {
  [[ "$2" -ge 2 ]] || fail "missing value for $1"
}

require_unset() {
  [[ -z "$2" ]] || fail "duplicate argument: $1"
}

is_directory_empty() {
  [[ -z "$(/usr/bin/find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

assert_safe_relative_path() {
  local path="$1"
  [[ -n "$path" && "$path" != SHA256SUMS ]] || fail "unsafe manifest path: $path"
  case "$path" in
    /* | */ | *..* | *\\* | *[[:space:]]*) fail "unsafe manifest path escapes package: $path" ;;
  esac
  case "/$path/" in
    *//* | */./*) fail "unsafe manifest path escapes package: $path" ;;
  esac
}

canonical_existing_path() {
  local path="$1" dir base target hops=0
  while true; do
    [[ -e "$path" || -L "$path" ]] || return 1
    if [[ -d "$path" ]]; then
      (cd "$path" && pwd -P)
      return 0
    fi
    dir="$(cd "$(dirname "$path")" && pwd -P)" || return 1
    base="$(basename "$path")"
    if [[ -L "$dir/$base" ]]; then
      hops=$((hops + 1))
      [[ "$hops" -lt 32 ]] || return 1
      target="$(/usr/bin/readlink "$dir/$base")" || return 1
      case "$target" in
        /*) path="$target" ;;
        *) path="$dir/$target" ;;
      esac
      continue
    fi
    printf '%s/%s\n' "$dir" "$base"
    return 0
  done
}

verify_no_escaping_symlinks() {
  local bundle="$1" links link target canonical_bundle canonical_target
  canonical_bundle="$(cd "$bundle" && pwd -P)"
  links="$(/usr/bin/find "$bundle" -type l -print | LC_ALL=C sort)" ||
    fail "cannot enumerate package symlinks"
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    target="$(/usr/bin/readlink "$link")" || fail "cannot read symlink: $link"
    case "$target" in
      /*) ;;
      *) target="$(dirname "$link")/$target" ;;
    esac
    canonical_target="$(canonical_existing_path "$target")" || fail "symlink target is missing: $link"
    case "$canonical_target" in
      "$canonical_bundle" | "$canonical_bundle"/*) ;;
      *) fail "symlink escapes package: $link" ;;
    esac
  done <<< "$links"
}

verify_no_forbidden_entries() {
  local bundle="$1" entries path base
  entries="$(/usr/bin/find "$bundle" -mindepth 1 -print | LC_ALL=C sort)" ||
    fail "cannot enumerate package entries"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    base="$(basename "$path")"
    case "$base" in
      Engram.app | EngramMCP | EngramCollector | EngramCollectorCore | \
      EngramCollectorCore.framework | EngramRemoteServer | EngramRemoteServerCore.framework | \
      node | node_modules | dist | daemon.js | index.js | web.js)
        fail "forbidden package role entry: $base" ;;
    esac
  done <<< "$entries"
}

assert_unaliased_directory() {
  [[ -d "$1" && ! -L "$1" ]] || fail "$2 is a directory alias or missing: $1"
}

framework_versioned_entity() {
  local framework="$1" name="$2"
  assert_unaliased_directory "$framework" "$name.framework"
  assert_unaliased_directory "$framework/Versions" "Versions in $name.framework"
  assert_unaliased_directory "$framework/Versions/A" "Versions/A in $name.framework"
  [[ -f "$framework/Versions/A/$name" && ! -L "$framework/Versions/A/$name" ]] ||
    fail "missing regular Versions/A/$name entity in $name.framework"
  printf '%s\n' "$framework/Versions/A/$name"
}

verify_package_layout() {
  local bundle="$1" name required
  assert_unaliased_directory "$bundle/bin" "bin"
  assert_unaliased_directory "$bundle/Frameworks" "Frameworks"
  for required in bin/EngramService BUILD-METADATA.json SHA256SUMS; do
    [[ -f "$bundle/$required" && ! -L "$bundle/$required" ]] ||
      fail "required package entry is missing or aliased: $required"
  done
  [[ -x "$bundle/bin/EngramService" ]] || fail "service binary is not executable"
  for name in "${FRAMEWORK_NAMES[@]}"; do
    framework_versioned_entity "$bundle/Frameworks/$name.framework" "$name" >/dev/null
  done
}

verify_manifest_file_set() {
  local bundle="$1" manifest_paths actual_paths sorted_paths path
  manifest_paths="$(/usr/bin/awk '
    !/^[0-9a-f]{64}  [^[:space:]]+$/ { exit 2 }
    { sub(/^[0-9a-f]{64}  /, ""); print }
  ' "$bundle/SHA256SUMS")" || fail "SHA256SUMS has an invalid line"
  sorted_paths="$(printf '%s\n' "$manifest_paths" | LC_ALL=C sort)"
  [[ "$manifest_paths" == "$sorted_paths" ]] || fail "SHA256SUMS paths are not sorted"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    assert_safe_relative_path "$path"
  done <<< "$manifest_paths"
  actual_paths="$(
    cd "$bundle"
    /usr/bin/find . -type f ! -path ./SHA256SUMS -print |
      /usr/bin/sed 's#^\./##' | LC_ALL=C sort
  )" || fail "cannot enumerate manifest files"
  [[ "$manifest_paths" == "$actual_paths" ]] || fail "SHA256SUMS does not exactly cover package files"
}

verify_metadata() {
  local metadata="$1" schema product role configuration architecture revision
  /usr/bin/plutil -convert xml1 -o /dev/null "$metadata" || fail "invalid BUILD-METADATA"
  schema="$(/usr/bin/plutil -extract schemaVersion raw -o - "$metadata")"
  product="$(/usr/bin/plutil -extract product raw -o - "$metadata")"
  role="$(/usr/bin/plutil -extract role raw -o - "$metadata")"
  configuration="$(/usr/bin/plutil -extract configuration raw -o - "$metadata")"
  architecture="$(/usr/bin/plutil -extract architecture raw -o - "$metadata")"
  revision="$(/usr/bin/plutil -extract sourceRevision raw -o - "$metadata")"
  [[ "$schema" == 1 ]] || fail "unsupported metadata schema"
  [[ "$product" == EngramService ]] || fail "unexpected metadata product"
  [[ "$role" == index ]] || fail "unexpected metadata role"
  [[ "$configuration" == Release ]] || fail "unexpected metadata configuration: expected Release"
  [[ "$architecture" == arm64 ]] || fail "unexpected metadata architecture: expected arm64"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "invalid metadata source revision"
  if /usr/bin/grep -Eiq 'token|secret|password|credential|at[_-]?rest[_-]?key' "$metadata"; then
    fail "BUILD-METADATA contains a credential-like field"
  fi
}

is_macho() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  /usr/bin/file -b "$1" | /usr/bin/grep -q 'Mach-O'
}

verify_arm64_only() {
  local binary="$1" architectures
  /usr/bin/lipo "$binary" -verify_arch arm64 >/dev/null
  architectures="$(/usr/bin/lipo -archs "$binary")"
  [[ "$architectures" == arm64 ]] || fail "packaged Mach-O is not arm64-only: $binary"
}

assert_safe_system_dependency() {
  local dependency="$1" canonical
  case "/$dependency/" in
    */../* | */./*) fail "unsafe system load path: $dependency" ;;
  esac
  case "$dependency" in
    /System/Library/* | /usr/lib/*) ;;
    *) fail "non-relocatable dependency: $dependency" ;;
  esac
  # A dyld shared-cache library may legitimately have no standalone file.
  if [[ -e "$dependency" || -L "$dependency" ]]; then
    canonical="$(canonical_existing_path "$dependency")" || fail "unsafe system load path: $dependency"
    case "$canonical" in
      /System/Library/* | /usr/lib/*) ;;
      *) fail "system dependency escapes whitelist: $dependency" ;;
    esac
  fi
}

assert_in_package_manifest_path() {
  local bundle="$1" candidate="$2" dependency="$3" canonical relative
  canonical="$(canonical_existing_path "$candidate")" || fail "unresolved packaged dependency: $dependency"
  case "$canonical" in
    "$bundle"/*) relative="${canonical#"$bundle"/}" ;;
    *) fail "relocatable dependency escapes package: $dependency" ;;
  esac
  case "$relative" in
    Frameworks/EngramServiceCore.framework/Versions/A/EngramServiceCore | \
    Frameworks/EngramCoreRead.framework/Versions/A/EngramCoreRead | \
    Frameworks/EngramCoreWrite.framework/Versions/A/EngramCoreWrite | \
    Frameworks/GRDB-dynamic.framework/Versions/A/GRDB-dynamic) ;;
    *) fail "dependency is not a mandatory versioned framework entity: $relative" ;;
  esac
  /usr/bin/awk -v path="$relative" '
    { sub(/^[0-9a-f]{64}  /, ""); if ($0 == path) found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$bundle/SHA256SUMS" || fail "dependency is not in the package manifest: $relative"
}

verify_dependency_closure_for_binary() {
  local bundle="$1" binary="$2" dependencies dependency candidate
  dependencies="$(/usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 |
    /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')" || fail "cannot inspect native dependencies: $binary"
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /System/Library/* | /usr/lib/*) assert_safe_system_dependency "$dependency"; continue ;;
      @rpath/*) candidate="$bundle/Frameworks/${dependency#@rpath/}" ;;
      @executable_path/*) candidate="$bundle/bin/${dependency#@executable_path/}" ;;
      @loader_path/*) candidate="$(dirname "$binary")/${dependency#@loader_path/}" ;;
      *) fail "non-relocatable dependency for $binary: $dependency" ;;
    esac
    assert_in_package_manifest_path "$bundle" "$candidate" "$dependency"
  done <<< "$dependencies"
}

has_framework_rpath() {
  /usr/bin/otool -l "$1" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
      if ($2 == "@executable_path/../Frameworks") found = 1
      in_rpath = 0
    }
    END { exit(found ? 0 : 1) }
  '
}

native_rpaths() {
  /usr/bin/otool -l "$1" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

verify_closed_rpaths() {
  local binary="$1" paths path
  paths="$(native_rpaths "$binary")" || fail "cannot inspect native rpaths: $binary"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == '@executable_path/../Frameworks' ]] || fail "non-relocatable native rpath: $path"
  done <<< "$paths"
}

normalize_copied_rpaths() {
  local binary="$1" paths path
  paths="$(native_rpaths "$binary")" || fail "cannot inspect copied native rpaths: $binary"
  while IFS= read -r path; do
    [[ -n "$path" && "$path" != '@executable_path/../Frameworks' ]] || continue
    /usr/bin/install_name_tool -delete_rpath "$path" "$binary"
  done <<< "$paths"
}

verify_native_closure() {
  local bundle="$1" executable="$1/bin/EngramService" name binary
  is_macho "$executable" || fail "service binary is not a native Mach-O; synthetic fixtures are not package proof"
  verify_arm64_only "$executable"
  /usr/bin/codesign --verify --deep --strict "$executable" || fail "service signature verification failed"
  has_framework_rpath "$executable" || fail "executable is missing @executable_path/../Frameworks rpath"
  verify_closed_rpaths "$executable"
  verify_dependency_closure_for_binary "$bundle" "$executable"
  for name in "${FRAMEWORK_NAMES[@]}"; do
    binary="$(framework_versioned_entity "$bundle/Frameworks/$name.framework" "$name")"
    is_macho "$binary" || fail "framework binary is not a native Mach-O: $binary"
    verify_arm64_only "$binary"
    /usr/bin/codesign --verify --deep --strict "$bundle/Frameworks/$name.framework" ||
      fail "framework signature verification failed: $name"
    verify_closed_rpaths "$binary"
    verify_dependency_closure_for_binary "$bundle" "$binary"
  done
}

verify_package() {
  local bundle="$1" canonical
  [[ -d "$bundle" && ! -L "$bundle" ]] || fail "verify-only bundle must be a directory"
  canonical="$(cd "$bundle" && pwd -P)"
  verify_package_layout "$canonical"
  verify_launch_templates "$canonical"
  verify_no_forbidden_entries "$canonical"
  verify_no_escaping_symlinks "$canonical"
  verify_manifest_file_set "$canonical"
  (cd "$canonical" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null) || fail "SHA256SUMS verification failed"
  verify_metadata "$canonical/BUILD-METADATA.json"
  verify_native_closure "$canonical"
  echo "package-service: PASS $canonical"
}

generate_manifest() {
  local bundle="$1" files path
  files="$(cd "$bundle" && /usr/bin/find . -type f ! -path ./SHA256SUMS -print | LC_ALL=C sort)" ||
    fail "cannot enumerate package files"
  (
    cd "$bundle"
    while IFS= read -r path; do
      path="${path#./}"
      assert_safe_relative_path "$path"
      /usr/bin/shasum -a 256 "$path"
    done <<< "$files"
  ) > "$bundle/SHA256SUMS"
  /bin/chmod 0600 "$bundle/SHA256SUMS"
}

write_metadata() {
  /usr/bin/printf '%s\n' '{' \
    '  "schemaVersion": 1,' '  "product": "EngramService",' \
    '  "role": "index",' '  "configuration": "Release",' \
    '  "architecture": "arm64",' "  \"sourceRevision\": \"$2\"" '}' > "$1"
  /bin/chmod 0600 "$1"
}

thin_macho_to_arm64() {
  local binary="$1" architectures temporary mode
  is_macho "$binary" || fail "cannot package a non-Mach-O as EngramService: $binary"
  architectures="$(/usr/bin/lipo -archs "$binary")" || fail "cannot inspect architectures: $binary"
  case " $architectures " in
    *" arm64 "*) ;;
    *) fail "Mach-O does not support arm64: $binary" ;;
  esac
  if [[ "$architectures" != arm64 ]]; then
    temporary="${binary}.arm64.$$"
    mode="$(/usr/bin/stat -f '%Lp' "$binary")"
    /usr/bin/lipo "$binary" -thin arm64 -output "$temporary"
    /bin/chmod "$mode" "$temporary"
    /bin/mv -f "$temporary" "$binary"
  fi
  verify_arm64_only "$binary"
}

package_service() {
  verify_source_templates
  local products="$1/Build/Products/$2" revision="$3" output="$4"
  local source_executable="$products/EngramService" source_framework name binary
  [[ -f "$source_executable" && ! -L "$source_executable" ]] || fail "missing regular Release executable: $source_executable"
  # Preflight source framework identity/containment before copying or signing.
  for name in "${FRAMEWORK_NAMES[@]}"; do
    source_framework="$products/$name.framework"
    [[ "$name" != GRDB-dynamic ]] || source_framework="$products/PackageFrameworks/GRDB-dynamic.framework"
    framework_versioned_entity "$source_framework" "$name" >/dev/null
    verify_no_escaping_symlinks "$source_framework"
  done
  is_macho "$source_executable" || fail "cannot package a non-Mach-O as EngramService: $source_executable"
  /bin/mkdir -p "$output/bin" "$output/Frameworks"
  copy_launch_templates "$output"
  /bin/cp "$source_executable" "$output/bin/EngramService"
  /bin/chmod 0700 "$output/bin/EngramService"
  for name in "${FRAMEWORK_NAMES[@]}"; do
    source_framework="$products/$name.framework"
    [[ "$name" != GRDB-dynamic ]] || source_framework="$products/PackageFrameworks/GRDB-dynamic.framework"
    /usr/bin/ditto "$source_framework" "$output/Frameworks/$name.framework"
  done
  verify_no_escaping_symlinks "$output"
  thin_macho_to_arm64 "$output/bin/EngramService"
  # Only the copied executable is made relocatable, before its final signature.
  normalize_copied_rpaths "$output/bin/EngramService"
  if ! has_framework_rpath "$output/bin/EngramService"; then
    /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$output/bin/EngramService"
  fi
  for name in "${FRAMEWORK_NAMES[@]}"; do
    binary="$(framework_versioned_entity "$output/Frameworks/$name.framework" "$name")"
    thin_macho_to_arm64 "$binary"
    normalize_copied_rpaths "$binary"
    /usr/bin/codesign --force --sign - "$output/Frameworks/$name.framework"
  done
  /usr/bin/codesign --force --sign - "$output/bin/EngramService"
  write_metadata "$output/BUILD-METADATA.json" "$revision"
  generate_manifest "$output"
  verify_package "$output"
}

if [[ "${1:-}" == --verify-only ]]; then
  [[ "$#" -eq 2 ]] || fail "--verify-only cannot be combined with other arguments"
  verify_package "$2"
  exit 0
fi

DERIVED_DATA=""
CONFIGURATION=""
ARCHITECTURE=""
SOURCE_REVISION=""
OUTPUT=""
DRY_RUN=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --derived-data)
      require_value "$1" "$#"; require_unset "$1" "$DERIVED_DATA"
      DERIVED_DATA="$2"; shift 2 ;;
    --configuration)
      require_value "$1" "$#"; require_unset "$1" "$CONFIGURATION"
      CONFIGURATION="$2"; shift 2 ;;
    --arch)
      require_value "$1" "$#"; require_unset "$1" "$ARCHITECTURE"
      ARCHITECTURE="$2"; shift 2 ;;
    --source-revision)
      require_value "$1" "$#"; require_unset "$1" "$SOURCE_REVISION"
      SOURCE_REVISION="$2"; shift 2 ;;
    --output)
      require_value "$1" "$#"; require_unset "$1" "$OUTPUT"
      OUTPUT="$2"; shift 2 ;;
    --dry-run)
      [[ "$DRY_RUN" -eq 0 ]] || fail "duplicate argument: --dry-run"
      DRY_RUN=1; shift ;;
    --verify-only) fail "--verify-only cannot be combined with packaging arguments" ;;
    *) usage; fail "unknown argument: $1" ;;
  esac
done
if [[ -z "$DERIVED_DATA" || -z "$CONFIGURATION" || -z "$ARCHITECTURE" || -z "$SOURCE_REVISION" || -z "$OUTPUT" ]]; then
  usage
  fail "all packaging arguments are required"
fi
[[ "$DERIVED_DATA" == /* ]] || fail "--derived-data must be an absolute path"
[[ "$OUTPUT" == /* ]] || fail "--output must be an absolute path"
[[ "$CONFIGURATION" == Release ]] || fail "only Release packaging is supported"
[[ "$ARCHITECTURE" == arm64 ]] || fail "only arm64 packaging is supported"
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "--source-revision must be a lowercase 40-character hexadecimal commit"
[[ ! -L "$OUTPUT" ]] || fail "output directory must not be a symlink"
if [[ -e "$OUTPUT" ]]; then
  [[ -d "$OUTPUT" ]] || fail "output path must be a directory"
  is_directory_empty "$OUTPUT" || fail "output directory must be new or empty"
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  /usr/bin/printf '%s\n' "package-service: dry-run EngramService role=index" \
    "derived-data: $DERIVED_DATA" "output: $OUTPUT" \
    "would package bin/EngramService and versioned frameworks: ${FRAMEWORK_NAMES[*]}" \
    "would package templates/run-engram-service-index.zsh.template templates/com.engram.service-index.plist.template"
  exit 0
fi
package_service "$DERIVED_DATA" "$CONFIGURATION" "$SOURCE_REVISION" "$OUTPUT"
