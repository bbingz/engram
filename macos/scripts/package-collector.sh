#!/bin/bash
set -euo pipefail

umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATE_DIR="$MACOS_DIR/EngramCollector/Packaging"
TEMPLATE_NAMES=(run-engram-collector.zsh.template com.engram.collector.plist.template)

verify_source_templates() {
  local name
  [[ -d "$MACOS_DIR/EngramCollector" && ! -L "$MACOS_DIR/EngramCollector" ]] ||
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
  package-collector.sh --derived-data <abs-dir> --configuration Release \
    --arch arm64 --source-revision <40-hex-sha> --output <new-empty-dir>
  package-collector.sh --verify-only <bundle>
  package-collector.sh --dry-run --derived-data <abs-dir> --configuration Release \
    --arch arm64 --source-revision <40-hex-sha> --output <abs-dir>
USAGE
}

fail() {
  echo "package-collector: ERROR: $*" >&2
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

forbidden_name() {
  case "$1" in
    EngramCoreRead | EngramCoreWrite | EngramService | Engram.app | \
    node_modules | daemon.js | index.js | web.js | node | dist | \
    EngramRemoteServer)
      return 0
      ;;
  esac
  return 1
}

assert_safe_relative_path() {
  local relative_path="$1"
  [[ -n "$relative_path" ]] || fail "SHA256SUMS has an empty path"
  [[ "$relative_path" != SHA256SUMS ]] || fail "SHA256SUMS must not list itself"
  case "$relative_path" in
    /* | */ | *..* | *\\*)
      fail "unsafe manifest path escapes package: $relative_path"
      ;;
  esac
  [[ "$relative_path" != *[[:space:]]* ]] ||
    fail "unsafe manifest path escapes package: $relative_path"
}

canonical_existing_path() {
  local path="$1"
  local dir base target hops
  hops=0
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
  local bundle="$1"
  local link target canonical_bundle canonical_target

  canonical_bundle="$(cd "$bundle" && pwd -P)"
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    target="$(/usr/bin/readlink "$link")" ||
      fail "cannot read symlink: $link"
    case "$target" in
      /*) ;;
      *) target="$(cd "$(dirname "$link")" && pwd -P)/$target" ;;
    esac
    canonical_target="$(canonical_existing_path "$target")" ||
      fail "symlink target is missing: $link -> $target"
    case "$canonical_target" in
      "$canonical_bundle" | "$canonical_bundle"/*) ;;
      *) fail "symlink escapes package: $link -> $canonical_target" ;;
    esac
  done < <(
    /usr/bin/find "$bundle" -type l -print | LC_ALL=C sort
  )
}

verify_no_forbidden_entries() {
  local bundle="$1"
  local path base

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    base="$(basename "$path")"
    if forbidden_name "$base"; then
      fail "forbidden package entry: $base"
    fi
    case "$path" in
      *EngramCoreRead*) fail "package contains EngramCoreRead" ;;
      *EngramCoreWrite*) fail "package contains EngramCoreWrite" ;;
      *EngramService*) fail "package contains EngramService" ;;
    esac
  done < <(
    /usr/bin/find "$bundle" -mindepth 1 -print | LC_ALL=C sort
  )
}

assert_unaliased_directory() {
  local path="$1"
  local label="$2"
  [[ -d "$path" && ! -L "$path" ]] ||
    fail "$label is a directory alias or missing: $path"
}

assert_unaliased_versioned_framework() {
  local framework="$1"
  local name="$2"
  local versions="$framework/Versions"
  local version_a="$versions/A"
  local entity="$version_a/$name"
  assert_unaliased_directory "$framework" "$(basename "$framework")"
  assert_unaliased_directory "$versions" "Versions in $(basename "$framework")"
  assert_unaliased_directory "$version_a" "Versions/A in $(basename "$framework")"
  [[ -f "$entity" && ! -L "$entity" ]] ||
    fail "missing Versions/A/$name entity in $(basename "$framework")"
}

framework_versioned_entity() {
  local framework="$1"
  local name="$2"
  assert_unaliased_versioned_framework "$framework" "$name"
  printf '%s\n' "$framework/Versions/A/$name"
}

verify_package_layout() {
  local bundle="$1"
  local required

  for required in \
    "$bundle/bin/EngramCollector" \
    "$bundle/Frameworks/EngramCollectorCore.framework" \
    "$bundle/Frameworks/EngramCollectorCore.framework/Versions/A/EngramCollectorCore" \
    "$bundle/Frameworks/GRDB-dynamic.framework" \
    "$bundle/Frameworks/GRDB-dynamic.framework/Versions/A/GRDB-dynamic" \
    "$bundle/BUILD-METADATA.json" \
    "$bundle/SHA256SUMS"; do
    [[ -e "$required" ]] || fail "required package entry is missing: $required"
  done
  [[ -x "$bundle/bin/EngramCollector" ]] || fail "collector binary is not executable"
  assert_unaliased_directory "$bundle/Frameworks" "Frameworks"
  assert_unaliased_versioned_framework \
    "$bundle/Frameworks/EngramCollectorCore.framework" "EngramCollectorCore"
  assert_unaliased_versioned_framework \
    "$bundle/Frameworks/GRDB-dynamic.framework" "GRDB-dynamic"
}

verify_manifest_file_set() {
  local bundle="$1"
  local manifest_paths actual_paths sorted_paths relative_path

  manifest_paths="$(
    /usr/bin/awk '
      !/^[0-9a-f]{64}  [^[:space:]]+$/ { exit 2 }
      { sub(/^[0-9a-f]{64}  /, ""); print }
    ' "$bundle/SHA256SUMS"
  )" || fail "SHA256SUMS has an invalid line"
  sorted_paths="$(printf '%s\n' "$manifest_paths" | LC_ALL=C sort)"
  [[ "$manifest_paths" == "$sorted_paths" ]] ||
    fail "SHA256SUMS paths are not sorted"

  while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    assert_safe_relative_path "$relative_path"
  done < <(printf '%s\n' "$manifest_paths")

  actual_paths="$(
    cd "$bundle"
    /usr/bin/find . -type f ! -path ./SHA256SUMS -print |
      /usr/bin/sed 's#^\./##' |
      LC_ALL=C sort
  )"
  [[ "$manifest_paths" == "$actual_paths" ]] ||
    fail "SHA256SUMS does not exactly cover package files"
}

verify_metadata() {
  local metadata="$1"
  local schema product role configuration architecture revision

  /usr/bin/plutil -convert xml1 -o /dev/null "$metadata"
  schema="$(/usr/bin/plutil -extract schemaVersion raw -o - "$metadata")"
  product="$(/usr/bin/plutil -extract product raw -o - "$metadata")"
  role="$(/usr/bin/plutil -extract role raw -o - "$metadata")"
  configuration="$(/usr/bin/plutil -extract configuration raw -o - "$metadata")"
  architecture="$(/usr/bin/plutil -extract architecture raw -o - "$metadata")"
  revision="$(/usr/bin/plutil -extract sourceRevision raw -o - "$metadata")"

  [[ "$schema" == "1" ]] || fail "unsupported BUILD-METADATA schema"
  [[ "$product" == "EngramCollector" ]] || fail "unexpected metadata product"
  [[ "$role" == "collector" ]] || fail "unexpected metadata role"
  [[ "$configuration" == "Release" ]] || fail "package is not a Release build"
  [[ "$architecture" == "arm64" ]] || fail "package is not arm64"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "invalid metadata source revision"
  if /usr/bin/grep -Eiq 'token|secret|password|credential|at[_-]?rest[_-]?key' "$metadata"; then
    fail "BUILD-METADATA contains a credential-like field"
  fi
}

is_macho() {
  local binary="$1"
  [[ -f "$binary" && ! -L "$binary" ]] || return 1
  /usr/bin/file -b "$binary" | /usr/bin/grep -q 'Mach-O'
}

verify_arm64_only() {
  local binary="$1"
  local architectures

  /usr/bin/lipo "$binary" -verify_arch arm64 >/dev/null
  architectures="$(/usr/bin/lipo -archs "$binary")"
  [[ "$architectures" == "arm64" ]] ||
    fail "packaged Mach-O is not arm64-only: $binary ($architectures)"
}

assert_safe_system_dependency() {
  local dependency="$1"
  local canonical
  case "$dependency" in
    /System/Library/* | /usr/lib/*) ;;
    *) fail "non-relocatable dependency: $dependency" ;;
  esac
  if [[ -e "$dependency" || -L "$dependency" ]]; then
    canonical="$(canonical_existing_path "$dependency")" ||
      fail "unsafe system load path: $dependency"
    case "$canonical" in
      /System/Library/* | /usr/lib/*) ;;
      *) fail "system dependency escapes whitelist: $dependency -> $canonical" ;;
    esac
  fi
}

assert_in_package_manifest_path() {
  local bundle="$1"
  local candidate="$2"
  local dependency="$3"
  local canonical_bundle canonical_candidate relative line path found

  canonical_bundle="$(cd "$bundle" && pwd -P)"
  canonical_candidate="$(canonical_existing_path "$candidate")" ||
    fail "unresolved packaged dependency: $dependency"
  case "$canonical_candidate" in
    "$canonical_bundle"/*) ;;
    *) fail "relocatable dependency escapes package: $dependency -> $canonical_candidate" ;;
  esac
  relative="${canonical_candidate#"$canonical_bundle"/}"
  [[ "$relative" != "$canonical_candidate" && -n "$relative" ]] ||
    fail "relocatable dependency escapes package: $dependency -> $canonical_candidate"
  [[ -f "$bundle/SHA256SUMS" ]] ||
    fail "missing SHA256SUMS for dependency closure"
  found=0
  while IFS= read -r line; do
    path="${line#*  }"
    if [[ "$path" == "$relative" ]]; then
      found=1
      break
    fi
  done < "$bundle/SHA256SUMS"
  [[ "$found" == 1 ]] ||
    fail "dependency is not in the package manifest: $relative"
  case "$relative" in
    Frameworks/EngramCollectorCore.framework/Versions/A/EngramCollectorCore | \
    Frameworks/GRDB-dynamic.framework/Versions/A/GRDB-dynamic) ;;
    *) fail "dependency is not a mandatory versioned framework entity: $relative" ;;
  esac
}

verify_dependency_closure_for_binary() {
  local bundle="$1"
  local binary="$2"
  local dependency suffix candidate binary_directory

  binary_directory="$(cd "$(dirname "$binary")" && pwd -P)"
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      *..*) fail "unsafe load path traversal: $dependency" ;;
    esac
    case "$dependency" in
      /System/Library/* | /usr/lib/*)
        assert_safe_system_dependency "$dependency"
        ;;
      @rpath/*)
        suffix="${dependency#@rpath/}"
        candidate="$bundle/Frameworks/$suffix"
        assert_in_package_manifest_path "$bundle" "$candidate" "$dependency"
        ;;
      @executable_path/*)
        suffix="${dependency#@executable_path/}"
        candidate="$bundle/bin/$suffix"
        assert_in_package_manifest_path "$bundle" "$candidate" "$dependency"
        ;;
      @loader_path/*)
        suffix="${dependency#@loader_path/}"
        candidate="$binary_directory/$suffix"
        assert_in_package_manifest_path "$bundle" "$candidate" "$dependency"
        ;;
      *) fail "non-relocatable dependency for $binary: $dependency" ;;
    esac
  done < <(
    /usr/bin/otool -L "$binary" |
      /usr/bin/tail -n +2 |
      /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/'
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

verify_native_closure() {
  local bundle="$1"
  local executable="$bundle/bin/EngramCollector"
  local binary

  if ! is_macho "$executable"; then
    fail "collector binary is not a native Mach-O; synthetic fixtures are not package proof"
  fi
  verify_arm64_only "$executable"
  /usr/bin/codesign --verify --deep --strict "$executable" ||
    fail "collector binary signature verification failed"
  verify_framework_rpath "$executable"
  verify_dependency_closure_for_binary "$bundle" "$executable"

  while IFS= read -r binary; do
    [[ -n "$binary" ]] || continue
    is_macho "$binary" ||
      fail "framework binary is not a native Mach-O: $binary"
    verify_arm64_only "$binary"
    /usr/bin/codesign --verify --deep --strict "$binary" ||
      fail "framework signature verification failed: $binary"
    verify_dependency_closure_for_binary "$bundle" "$binary"
  done < <(
    /usr/bin/find "$bundle/Frameworks" -type f \( -path '*/Versions/A/EngramCollectorCore' -o -path '*/Versions/A/GRDB-dynamic' \) -print |
      LC_ALL=C sort
  )
}

verify_package() {
  local bundle="$1"
  local canonical_bundle

  [[ -d "$bundle" && ! -L "$bundle" ]] || fail "verify-only bundle must be a directory"
  canonical_bundle="$(cd "$bundle" && pwd -P)"
  verify_package_layout "$canonical_bundle"
  verify_launch_templates "$canonical_bundle"
  verify_no_forbidden_entries "$canonical_bundle"
  verify_no_escaping_symlinks "$canonical_bundle"
  verify_manifest_file_set "$canonical_bundle"
  (
    cd "$canonical_bundle"
    /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
  ) || fail "SHA256SUMS verification failed"
  verify_metadata "$canonical_bundle/BUILD-METADATA.json"
  verify_native_closure "$canonical_bundle"
  echo "package-collector: PASS $canonical_bundle"
}

generate_manifest() {
  local bundle="$1"
  (
    cd "$bundle"
    while IFS= read -r relative_path; do
      relative_path="${relative_path#./}"
      /usr/bin/shasum -a 256 "$relative_path"
    done < <(
      /usr/bin/find . -type f ! -path ./SHA256SUMS -print | LC_ALL=C sort
    )
  ) > "$bundle/SHA256SUMS"
  /bin/chmod 0600 "$bundle/SHA256SUMS"
}

write_metadata() {
  local destination="$1"
  local revision="$2"

  /usr/bin/printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "product": "EngramCollector",' \
    '  "role": "collector",' \
    '  "configuration": "Release",' \
    '  "architecture": "arm64",' \
    "  \"sourceRevision\": \"$revision\"" \
    '}' > "$destination"
  /bin/chmod 0600 "$destination"
}

thin_macho_to_arm64() {
  local binary="$1"
  local architectures temporary mode

  is_macho "$binary" ||
    fail "cannot package a non-Mach-O as EngramCollector: $binary"
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

package_collector() {
  verify_source_templates
  local derived_data="$1"
  local configuration="$2"
  local revision="$3"
  local output="$4"
  local products_directory="$derived_data/Build/Products/$configuration"
  local source_executable="$products_directory/EngramCollector"
  local source_core="$products_directory/EngramCollectorCore.framework"
  local source_grdb="$products_directory/PackageFrameworks/GRDB-dynamic.framework"
  local dest_core dest_grdb core_entity grdb_entity

  [[ -f "$source_executable" ]] || fail "missing Release executable: $source_executable"
  [[ -e "$source_core" ]] || fail "missing EngramCollectorCore.framework"
  [[ -e "$source_grdb" ]] || fail "missing PackageFrameworks/GRDB-dynamic.framework"
  framework_versioned_entity "$source_grdb" "GRDB-dynamic" >/dev/null
  verify_no_escaping_symlinks "$source_core"
  verify_no_escaping_symlinks "$source_grdb"

  dest_core="$output/Frameworks/EngramCollectorCore.framework"
  dest_grdb="$output/Frameworks/GRDB-dynamic.framework"
  /bin/mkdir -p "$output/bin" "$output/Frameworks"
  copy_launch_templates "$output"
  /bin/cp "$source_executable" "$output/bin/EngramCollector"
  /usr/bin/ditto "$source_core" "$dest_core"
  /usr/bin/ditto "$source_grdb" "$dest_grdb"
  verify_no_escaping_symlinks "$output"

  /bin/chmod 0700 "$output/bin/EngramCollector"
  core_entity="$(framework_versioned_entity "$dest_core" "EngramCollectorCore")"
  grdb_entity="$(framework_versioned_entity "$dest_grdb" "GRDB-dynamic")"
  thin_macho_to_arm64 "$output/bin/EngramCollector"
  thin_macho_to_arm64 "$core_entity"
  thin_macho_to_arm64 "$grdb_entity"
  /usr/bin/codesign --force --sign - "$dest_grdb"
  /usr/bin/codesign --force --sign - "$dest_core"
  /usr/bin/codesign --force --sign - "$output/bin/EngramCollector"

  write_metadata "$output/BUILD-METADATA.json" "$revision"
  generate_manifest "$output"
  verify_package "$output"
}

print_dry_run() {
  local derived_data="$1"
  local output="$2"
  /usr/bin/printf '%s\n' \
    "package-collector: dry-run EngramCollector role=collector" \
    "derived-data: $derived_data" \
    "output: $output" \
    "would package bin/EngramCollector Frameworks/EngramCollectorCore.framework PackageFrameworks/GRDB-dynamic.framework Versions/A/GRDB-dynamic" \
    "would package templates/run-engram-collector.zsh.template templates/com.engram.collector.plist.template"
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
DRY_RUN=0

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
    --dry-run)
      [[ "$DRY_RUN" -eq 0 ]] || fail "duplicate argument: --dry-run"
      DRY_RUN=1
      shift
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
[[ "$OUTPUT" == /* ]] || fail "--output must be an absolute path"
[[ "$CONFIGURATION" == "Release" ]] || fail "only Release packaging is supported"
[[ "$ARCHITECTURE" == "arm64" ]] || fail "only arm64 packaging is supported"
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
  fail "--source-revision must be a lowercase 40-character hexadecimal commit"
[[ ! -L "$OUTPUT" ]] || fail "output directory must not be a symlink"
if [[ -e "$OUTPUT" ]]; then
  [[ -d "$OUTPUT" ]] || fail "output path must be a directory"
  is_directory_empty "$OUTPUT" || fail "output directory must be new or empty"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  print_dry_run "$DERIVED_DATA" "$OUTPUT"
  exit 0
fi

package_collector "$DERIVED_DATA" "$CONFIGURATION" "$SOURCE_REVISION" "$OUTPUT"
