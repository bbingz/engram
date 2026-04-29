#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PATTERN='DaemonClient|DaemonHTTPClientCore|IndexerProcess|http://127\.0\.0\.1|http://localhost|localhost:|/api/[A-Za-z0-9_./?=&{}()\-:]*'

MIGRATED_STAGE3_FILES=(
  "macos/Engram/Views/SearchView.swift"
  "macos/Engram/Views/Pages/SearchPageView.swift"
  "macos/Engram/Views/GlobalSearchOverlay.swift"
  "macos/Engram/Views/CommandPaletteView.swift"
  "macos/Engram/Views/Pages/SourcePulseView.swift"
  "macos/Engram/Views/Pages/MemoryView.swift"
  "macos/Engram/Views/Pages/SkillsView.swift"
  "macos/Engram/Views/Pages/HooksView.swift"
  "macos/Engram/Views/Replay/SessionReplayView.swift"
)

LEGACY_COMPAT_FILES=(
  "macos/Engram/App.swift"
  "macos/Engram/Core/AppEnvironment.swift"
  "macos/Engram/Core/DaemonClient.swift"
  "macos/Engram/Core/EngramLogger.swift"
  "macos/Engram/Core/IndexerProcess.swift"
  "macos/Engram/MenuBarController.swift"
  "macos/Engram/Views/MainWindowView.swift"
  "macos/Engram/Views/Pages/HomeView.swift"
  "macos/Engram/Views/Pages/HygieneView.swift"
  "macos/Engram/Views/Pages/SessionsPageView.swift"
  "macos/Engram/Views/Pages/TimelinePageView.swift"
  "macos/Engram/Views/Resume/ResumeDialog.swift"
  "macos/Engram/Views/SessionDetailView.swift"
  "macos/Engram/Views/SessionListView.swift"
  "macos/Engram/Views/Settings/AISettingsSection.swift"
  "macos/Engram/Views/Settings/GeneralSettingsSection.swift"
  "macos/Engram/Views/Settings/NetworkSettingsSection.swift"
  "macos/Engram/Views/PopoverView.swift"
  "macos/Shared/Networking/DaemonHTTPClientCore.swift"
)

PROJECT_OP_FILES=(
  "macos/Engram/Views/Pages/ProjectsView.swift"
  "macos/Engram/Views/Projects/ArchiveSheet.swift"
  "macos/Engram/Views/Projects/RenameSheet.swift"
  "macos/Engram/Views/Projects/UndoSheet.swift"
)

STAGE4_MCP_FILES=(
  "macos/EngramMCP/Core/MCPConfig.swift"
  "macos/EngramMCP/Core/MCPToolRegistry.swift"
)

contains_path() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

is_external_provider_hit() {
  local path="$1"
  local text="$2"

  # Cascade and Ollama own their localhost/API paths; they are not Node daemon
  # regressions and should not hide true Engram /api/* callsites.
  [[ "$path" == "macos/Shared/EngramCore/Adapters/Cascade/CascadeClient.swift" ]] && return 0
  [[ "$path" == "macos/Engram/Views/Settings/AISettingsSection.swift" && "$text" == *"localhost:11434"* ]] && return 0
  [[ "$path" == "macos/Engram/Views/Settings/AISettingsSection.swift" && "$text" == *"/api/tags"* ]] && return 0

  # The CLI talks to the Swift MCP Unix-socket bridge; this is an HTTP header,
  # not daemon localhost transport.
  [[ "$path" == "macos/EngramCLI/main.swift" && "$text" == *"Host: localhost"* ]] && return 0

  return 1
}

classify_hit() {
  local path="$1"
  local text="$2"

  if is_external_provider_hit "$path" "$text"; then
    echo "IGNORE_EXTERNAL_PROVIDER"
  elif contains_path "$path" "${MIGRATED_STAGE3_FILES[@]}"; then
    echo "FAIL_MIGRATED_STAGE3"
  elif contains_path "$path" "${PROJECT_OP_FILES[@]}"; then
    echo "ALLOW_PROJECT_OP_STAGE4"
  elif contains_path "$path" "${STAGE4_MCP_FILES[@]}"; then
    echo "ALLOW_MCP_STAGE4"
  elif contains_path "$path" "${LEGACY_COMPAT_FILES[@]}"; then
    echo "ALLOW_LEGACY_COMPAT"
  else
    echo "FAIL_UNCLASSIFIED"
  fi
}

format_hit() {
  local path="$1"
  local line="$2"
  local text="$3"
  printf '%s:%s: %s\n' "$path" "$line" "$text"
}

declare -a migrated_failures=()
declare -a unclassified_failures=()
declare -a legacy_hits=()
declare -a project_hits=()
declare -a mcp_hits=()

while IFS=: read -r path line text; do
  [[ -z "${path:-}" || -z "${line:-}" ]] && continue
  category="$(classify_hit "$path" "$text")"
  case "$category" in
    IGNORE_EXTERNAL_PROVIDER)
      ;;
    FAIL_MIGRATED_STAGE3)
      migrated_failures+=("$(format_hit "$path" "$line" "$text")")
      ;;
    FAIL_UNCLASSIFIED)
      unclassified_failures+=("$(format_hit "$path" "$line" "$text")")
      ;;
    ALLOW_LEGACY_COMPAT)
      legacy_hits+=("$(format_hit "$path" "$line" "$text")")
      ;;
    ALLOW_PROJECT_OP_STAGE4)
      project_hits+=("$(format_hit "$path" "$line" "$text")")
      ;;
    ALLOW_MCP_STAGE4)
      mcp_hits+=("$(format_hit "$path" "$line" "$text")")
      ;;
  esac
done < <(
  rg -n --no-heading "$PATTERN" \
    macos/Engram \
    macos/EngramMCP \
    macos/EngramCLI \
    macos/Shared \
    --glob '*.swift' \
    --glob '!macos/Engram/TestSupport/**' \
    --glob '!macos/EngramTests/**' \
    --glob '!macos/EngramMCPTests/**' \
    --glob '!macos/EngramServiceCoreTests/**' \
    --glob '!**/.build/**' || true
)

if (( ${#migrated_failures[@]} > 0 || ${#unclassified_failures[@]} > 0 )); then
  {
    echo "Stage 3 daemon cutover scan failed"
    if (( ${#migrated_failures[@]} > 0 )); then
      echo
      echo "Already migrated Stage 3 files must use EngramServiceClient, not DaemonClient/raw /api/IndexerProcess:"
      printf '%s\n' "${migrated_failures[@]}"
    fi
    if (( ${#unclassified_failures[@]} > 0 )); then
      echo
      echo "Unclassified production daemon references need migration or an explicit allowlist comment in scripts/check-stage3-daemon-cutover.sh:"
      printf '%s\n' "${unclassified_failures[@]}"
    fi
    echo
    echo "Provider-localhost false positives are ignored only for known Ollama/Cascade/Unix-socket bridge paths."
  } >&2
  exit 1
fi

echo "Stage 3 daemon cutover scan ok"
echo
echo "Allowed legacy compatibility hits (Stage 3 migration debt; replace with EngramServiceClient/service state):"
if (( ${#legacy_hits[@]} > 0 )); then
  printf '%s\n' "${legacy_hits[@]}"
else
  echo "none"
fi
echo
echo "Allowed Stage 4 project-op hits (temporary daemon bridge for move/archive/undo/recover surfaces):"
if (( ${#project_hits[@]} > 0 )); then
  printf '%s\n' "${project_hits[@]}"
else
  echo "none"
fi
echo
echo "Allowed Stage 4 MCP hits (temporary daemon bridge; no direct DB fallback allowed):"
if (( ${#mcp_hits[@]} > 0 )); then
  printf '%s\n' "${mcp_hits[@]}"
else
  echo "none"
fi
