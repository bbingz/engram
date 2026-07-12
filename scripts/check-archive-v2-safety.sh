#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${ENGRAM_ARCHIVE_V2_GATE_ROOT:-$SCRIPT_ROOT}"

fail() {
  echo "archive v2 safety gate failed: $*" >&2
  exit 1
}

command -v rg >/dev/null 2>&1 || fail "ripgrep is required"
command -v node >/dev/null 2>&1 || fail "Node.js is required"

BACKEND="$ROOT_DIR/macos/EngramCoreWrite/ArchiveV2/ArchiveReplicaBackend.swift"
ROUTES="$ROOT_DIR/macos/EngramRemoteServer/Core/ArchiveRoutes.swift"
[[ -f "$BACKEND" ]] || fail "missing ArchiveReplicaBackend.swift"
[[ -f "$ROUTES" ]] || fail "missing ArchiveRoutes.swift"

backend_delete_hits="$(rg -n --no-heading \
  '\bfunc[[:space:]]+(delete|remove|purge|vacuum|gc)[A-Za-z0-9_]*[[:space:]]*\(' \
  "$BACKEND" || true)"
if [[ -n "$backend_delete_hits" ]]; then
  printf '%s\n' "$backend_delete_hits" >&2
  fail "ArchiveReplicaBackend exposes a delete-like capability"
fi

archive_files=()
append_archive_files() {
  local directory="$1"
  local name_pattern="$2"
  [[ -d "$directory" ]] || return 0
  while IFS= read -r path; do
    archive_files+=("$path")
  done < <(find "$directory" -maxdepth 1 -type f -name "$name_pattern" -print | sort)
}

append_archive_files "$ROOT_DIR/macos/EngramCoreWrite/ArchiveV2" '*.swift'
append_archive_files "$ROOT_DIR/macos/EngramRemoteServer/Core" 'Archive*.swift'
append_archive_files "$ROOT_DIR/macos/EngramService/Core" 'Archive*.swift'
append_archive_files "$ROOT_DIR/macos/EngramService/Core" 'EngramServiceCommandHandler+Archive*.swift'

(( ${#archive_files[@]} > 0 )) || fail "no archive v2 production files found"

legacy_pattern='OffloadRepo|OffloadRunner|RemoteSyncCoordinator|RemoteStorageBackend|EngramRemoteBackend|commitOffloaded|commitRehydrated|offload_queue|rehydrate_queue|vacuumFreelistThreshold'
legacy_hits="$(rg -n --no-heading "$legacy_pattern" "${archive_files[@]}" || true)"
if [[ -n "$legacy_hits" ]]; then
  printf '%s\n' "$legacy_hits" >&2
  fail "legacy offload coupling is forbidden in archive v2 modules"
fi

node - "$ROOT_DIR" "${archive_files[@]}" <<'NODE'
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');

const root = process.argv[2];
const archiveSourceReclaimer = resolve(
  root,
  'macos/EngramCoreWrite/ArchiveV2/ArchiveSourceReclaimer.swift',
);
const immutableArchiveCAS = resolve(
  root,
  'macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift',
);
const archiveStore = resolve(
  root,
  'macos/EngramRemoteServer/Core/ArchiveStore.swift',
);
const archiveTranscriptResolver = resolve(
  root,
  'macos/EngramService/Core/ArchiveTranscriptResolver.swift',
);

const primitivePatterns = [
  { name: 'Darwin.unlink', pattern: /\bDarwin\s*\.\s*unlink\s*\(/g },
  { name: 'unlinkat', pattern: /\bunlinkat\s*\(/g },
  {
    name: 'FileManager.default.removeItem',
    pattern: /\bFileManager\s*\.\s*default\s*\.\s*removeItem\s*\(/g,
  },
  { name: 'receiver.removeItem', pattern: /\.\s*removeItem\s*\(/g },
];

function maskComments(source) {
  const output = [...source];
  let blockDepth = 0;
  let inLineComment = false;
  let stringDelimiterLength = 0;

  for (let index = 0; index < source.length; index += 1) {
    const next = source[index + 1];
    if (inLineComment) {
      if (source[index] === '\n') {
        inLineComment = false;
      } else {
        output[index] = ' ';
      }
      continue;
    }
    if (blockDepth > 0) {
      if (source[index] === '/' && next === '*') {
        output[index] = ' ';
        output[index + 1] = ' ';
        blockDepth += 1;
        index += 1;
      } else if (source[index] === '*' && next === '/') {
        output[index] = ' ';
        output[index + 1] = ' ';
        blockDepth -= 1;
        index += 1;
      } else if (source[index] !== '\n') {
        output[index] = ' ';
      }
      continue;
    }
    if (stringDelimiterLength === 3) {
      if (source.slice(index, index + 3) === '\"\"\"') {
        stringDelimiterLength = 0;
        index += 2;
      }
      continue;
    }
    if (stringDelimiterLength === 1) {
      if (source[index] === '\\') {
        index += 1;
      } else if (source[index] === '\"') {
        stringDelimiterLength = 0;
      }
      continue;
    }
    if (source[index] === '/' && next === '/') {
      output[index] = ' ';
      output[index + 1] = ' ';
      inLineComment = true;
      index += 1;
    } else if (source[index] === '/' && next === '*') {
      output[index] = ' ';
      output[index + 1] = ' ';
      blockDepth = 1;
      index += 1;
    } else if (source.slice(index, index + 3) === '\"\"\"') {
      stringDelimiterLength = 3;
      index += 2;
    } else if (source[index] === '\"') {
      stringDelimiterLength = 1;
    }
  }
  return output.join('');
}

function lineAt(source, index) {
  return source.slice(0, index).split('\n').length;
}

function closingParen(source, openParen) {
  let depth = 0;
  for (let index = openParen; index < source.length; index += 1) {
    if (source[index] === '(') depth += 1;
    if (source[index] !== ')') continue;
    depth -= 1;
    if (depth === 0) return index;
  }
  return -1;
}

function failPrimitive(path, line, primitive) {
  console.error(`${path}:${line}:${primitive}`);
  console.error(
    'archive v2 safety gate failed: forbidden archive deletion primitive; only named temporary cleanup is allowed',
  );
  process.exit(1);
}

let sourceReclaimerUnlinkCount = 0;
let immutableObjectUnlinkCount = 0;

for (const path of process.argv.slice(3)) {
  const source = readFileSync(path, 'utf8');
  const scanSource = maskComments(source);
  const callsByOpenParen = new Map();

  for (const { name, pattern } of primitivePatterns) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(scanSource)) !== null) {
      const relativeOpenParen = match[0].lastIndexOf('(');
      const openParen = match.index + relativeOpenParen;
      if (!callsByOpenParen.has(openParen)) {
        callsByOpenParen.set(openParen, { name, start: match.index, openParen });
      }
    }
  }

  const calls = [...callsByOpenParen.values()].sort(
    (left, right) => left.start - right.start,
  );
  for (const { name, start, openParen } of calls) {
    const closeParen = closingParen(scanSource, openParen);
    if (closeParen < 0) failPrimitive(path, lineAt(source, start), name);
    const argument = scanSource
      .slice(openParen + 1, closeParen)
      .replace(/\s+/g, '');

    if (
      name === 'Darwin.unlink' &&
      path === archiveSourceReclaimer &&
      argument === 'quarantineURL.path'
    ) {
      sourceReclaimerUnlinkCount += 1;
      continue;
    }
    if (
      name === 'Darwin.unlink' &&
      path === immutableArchiveCAS &&
      argument === 'objectURL.path'
    ) {
      immutableObjectUnlinkCount += 1;
      continue;
    }
    if (
      name === 'Darwin.unlink' &&
      path === immutableArchiveCAS &&
      argument === 'temporaryURL.path'
    ) {
      continue;
    }
    if (
      name === 'Darwin.unlink' &&
      path === archiveStore &&
      argument === 'temporaryURL.path'
    ) {
      continue;
    }
    if (
      name === 'FileManager.default.removeItem' &&
      path === archiveTranscriptResolver &&
      argument === 'at:replay.directoryURL'
    ) {
      continue;
    }
    failPrimitive(path, lineAt(source, start), name);
  }
}

if (sourceReclaimerUnlinkCount !== 1) {
  console.error(
    'archive v2 safety gate failed: ArchiveSourceReclaimer quarantine unlink must occur exactly once',
  );
  process.exit(1);
}
if (immutableObjectUnlinkCount !== 1) {
  console.error(
    'archive v2 safety gate failed: ImmutableArchiveCAS object unlink must occur exactly once',
  );
  process.exit(1);
}
NODE

remote_server_files=()
while IFS= read -r path; do
  remote_server_files+=("$path")
done < <(find "$ROOT_DIR/macos/EngramRemoteServer" -type f -name '*.swift' -print | sort)
(( ${#remote_server_files[@]} > 0 )) || fail "no remote-server production Swift files found"

# Scan the entire production server surface, not only Archive*.swift. The
# legacy mutable v1 route and the two v2 auth->405 guards are the complete,
# explicit allowlist; moving a successful v2 route to an innocuous filename
# must not bypass this gate.
# Scan across newlines and reject common generic registration spellings too, so
# neither formatting nor a method-based route can evade the explicit allowlist.
node - "${remote_server_files[@]}" <<'NODE'
const { readFileSync } = require('node:fs');

const directDelete = /\brouter\s*\.\s*delete\s*\(/g;
const genericPatterns = [
  /\brouter\s*\.\s*(?:on|add|route|register)\s*\([\s\S]{0,512}?\bmethod\s*:\s*(?:(?:(?:[A-Za-z_][A-Za-z0-9_]*|`[^`\r\n]+`)\s*\.\s*)+|\.\s*)(?:delete|DELETE)\b/g,
  /\brouter\s*\.\s*(?:on|add|route|register)\s*\(\s*(?:(?:(?:[A-Za-z_][A-Za-z0-9_]*|`[^`\r\n]+`)\s*\.\s*)+|\.\s*)(?:delete|DELETE)\b/g,
  /\brouter\s*\.\s*(?:on|add|route|register)\s*\([\s\S]{0,512}?\bmethod\s*:\s*["']DELETE["']/g,
];
const expectedEnumeratedGuardBody = [
  'request, _ in await observed(request, endpoint: endpoint, telemetry: telemetry) {',
  'guard authorized(request, token: token) else { return unauthorized() }',
  'return errorResponse(status: .methodNotAllowed, code: "method_not_allowed") }',
].join(' ');
const expectedWildcardGuardBody = [
  'request, _ in await observed(request, endpoint: "unknown", telemetry: telemetry) {',
  'guard authorized(request, token: token) else { return unauthorized() }',
  'return errorResponse(status: .methodNotAllowed, code: "method_not_allowed") }',
].join(' ');

let legacyCount = 0;
let v2Count = 0;

function lineAt(source, index) {
  return source.slice(0, index).split('\n').length;
}

function closureBody(source, start) {
  const open = source.indexOf('{', start);
  if (open < 0) return null;
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] !== '}') continue;
    depth -= 1;
    if (depth !== 0) continue;
    return source
      .slice(open + 1, index)
      .replace(/\/\/.*$/gm, '')
      .replace(/\s+/g, ' ')
      .trim();
  }
  return null;
}

for (const path of process.argv.slice(2)) {
  const source = readFileSync(path, 'utf8');
  directDelete.lastIndex = 0;
  let match;
  while ((match = directDelete.exec(source)) !== null) {
    const argument = source.slice(directDelete.lastIndex).trimStart();
    const isLegacy =
      path.endsWith('/Core/EngramRemoteServerApp.swift') &&
      /^["']\/v1\/bundles\/:key["']\s*\)/.test(argument);
    const isEnumeratedGuard =
      path.endsWith('/Core/ArchiveRoutes.swift') &&
      /^RouterPath\s*\(\s*path\s*\)\s*\)/.test(argument);
    const isWildcardGuard =
      path.endsWith('/Core/ArchiveRoutes.swift') &&
      /^["']\/v2\/archive\/\*\*["']\s*\)/.test(argument);

    if (isLegacy) {
      legacyCount += 1;
      continue;
    }
    if (isEnumeratedGuard || isWildcardGuard) {
      const body = closureBody(source, directDelete.lastIndex);
      const expectedBody = isEnumeratedGuard
        ? expectedEnumeratedGuardBody
        : expectedWildcardGuardBody;
      if (body !== expectedBody) {
        console.error(
          'archive v2 safety gate failed: v2 DELETE guards must contain only auth rejection and 405',
        );
        process.exit(1);
      }
      v2Count += 1;
      continue;
    }

    console.error(`${path}:${lineAt(source, match.index)}:${match[0].replace(/\s+/g, ' ')}`);
    console.error(
      'archive v2 safety gate failed: unexpected v2 DELETE handler outside the explicit legacy-v1/v2-405 allowlist',
    );
    process.exit(1);
  }

  for (const pattern of genericPatterns) {
    pattern.lastIndex = 0;
    const genericMatch = pattern.exec(source);
    if (!genericMatch) continue;
    console.error(`${path}:${lineAt(source, genericMatch.index)}:${genericMatch[0].replace(/\s+/g, ' ').slice(0, 240)}`);
    console.error(
      'archive v2 safety gate failed: unexpected remote-server DELETE registration',
    );
    process.exit(1);
  }
}

if (legacyCount !== 1) {
  console.error(
    'archive v2 safety gate failed: legacy v1 DELETE allowlist must contain exactly /v1/bundles/:key',
  );
  process.exit(1);
}
if (v2Count !== 2) {
  console.error(
    'archive v2 safety gate failed: unexpected v2 DELETE handler count (expected only two explicit 405 guards)',
  );
  process.exit(1);
}
NODE

method_not_allowed_count="$(rg -c 'return errorResponse\(status: \.methodNotAllowed, code: "method_not_allowed"\)' "$ROUTES")"
[[ "$method_not_allowed_count" -eq 2 ]] \
  || fail "both v2 DELETE guards must return method_not_allowed"
rg -q 'router\.delete\(RouterPath\(path\)\)' "$ROUTES" \
  || fail "missing enumerated v2 DELETE 405 guard"
rg -q 'router\.delete\("/v2/archive/\*\*"\)' "$ROUTES" \
  || fail "missing wildcard v2 DELETE 405 guard"

node - "$ROUTES" <<'NODE'
const { readFileSync } = require('node:fs');

const source = readFileSync(process.argv[2], 'utf8');
const marker = 'router.delete';
const expectedEnumeratedBody = [
  'request, _ in await observed(request, endpoint: endpoint, telemetry: telemetry) {',
  'guard authorized(request, token: token) else { return unauthorized() }',
  'return errorResponse(status: .methodNotAllowed, code: "method_not_allowed") }',
].join(' ');
const expectedWildcardBody = [
  'request, _ in await observed(request, endpoint: "unknown", telemetry: telemetry) {',
  'guard authorized(request, token: token) else { return unauthorized() }',
  'return errorResponse(status: .methodNotAllowed, code: "method_not_allowed") }',
].join(' ');

let cursor = 0;
let checked = 0;
while ((cursor = source.indexOf(marker, cursor)) >= 0) {
  const open = source.indexOf('{', cursor + marker.length);
  if (open < 0) process.exit(2);

  let depth = 0;
  let close = -1;
  for (let index = open; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') {
      depth -= 1;
      if (depth === 0) {
        close = index;
        break;
      }
    }
  }
  if (close < 0) process.exit(2);

  const body = source
    .slice(open + 1, close)
    .replace(/\/\/.*$/gm, '')
    .replace(/\s+/g, ' ')
    .trim();
  const registration = source.slice(cursor + marker.length, open);
  const expectedBody = /^\s*\(\s*RouterPath\s*\(\s*path\s*\)\s*\)\s*$/.test(
    registration,
  )
    ? expectedEnumeratedBody
    : /^\s*\(\s*["']\/v2\/archive\/\*\*["']\s*\)\s*$/.test(registration)
      ? expectedWildcardBody
      : null;
  if (body !== expectedBody) {
    console.error(
      'archive v2 safety gate failed: v2 DELETE guards must contain only auth rejection and 405',
    );
    process.exit(1);
  }
  checked += 1;
  cursor = close + 1;
}

if (checked !== 2) process.exit(2);
NODE

echo "archive v2 safety gate ok"
