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
append_archive_files "$ROOT_DIR/macos/EngramCaptureShared" '*.swift'
append_archive_files "$ROOT_DIR/macos/EngramRemoteServer/Core" 'Archive*.swift'
append_archive_files "$ROOT_DIR/macos/EngramService/Core" 'Archive*.swift'
append_archive_files "$ROOT_DIR/macos/EngramService/Core" 'EngramServiceCommandHandler+Archive*.swift'
append_archive_files "$ROOT_DIR/macos/EngramService/Core" 'ServiceCapture*.swift'
for directory in "$ROOT_DIR"/macos/EngramService/Core/ServiceCapture*; do
  if [[ -d "$directory" ]]; then
    while IFS= read -r path; do archive_files+=("$path"); done < <(rg --files "$directory" -g '*.swift' | sort)
  fi
done
for directory in EngramCollectorCore EngramCollector EngramCoreWrite/CaptureIngest; do
  if [[ -d "$ROOT_DIR/macos/$directory" ]]; then
    while IFS= read -r path; do archive_files+=("$path"); done < <(rg --files "$ROOT_DIR/macos/$directory" -g '*.swift' | sort)
  fi
done

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
const { createHash } = require('node:crypto');

const root = process.argv[2];
const archiveSourceReclaimer = resolve(
  root,
  'macos/EngramCoreWrite/ArchiveV2/ArchiveSourceReclaimer.swift',
);
const immutableArchiveCASPaths = new Set([
  resolve(root, 'macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift'),
  resolve(root, 'macos/EngramCaptureShared/ImmutableArchiveCAS.swift'),
]);
const archiveTranscriptResolver = resolve(
  root,
  'macos/EngramService/Core/ArchiveTranscriptResolver.swift',
);

const primitivePatterns = [
  { name: 'destructive CAS wrapper', pattern: /\b(?:removeObject|finalizeUnlink|evictEligibleObjects|removeContents)\s*\(/g },
  { name: 'Darwin.unlink', pattern: /\bDarwin\s*\.\s*unlink\s*\(/g },
  { name: 'Darwin.remove or rmdir', pattern: /\bDarwin\s*\.\s*(?:remove|rmdir)\s*\(/g },
  { name: 'bare unlink, remove or rmdir', pattern: /(?<![.\w])(?:unlink|remove|rmdir)\s*\(/g },
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


function functionRanges(source, name) {
  const declaration = new RegExp('\\bfunc\\s+' + name + '\\s*\\(', 'g');
  const found = [...source.matchAll(declaration)];
  return found.flatMap(({ index: start }) => {
    const open = source.indexOf('{', start);
    let depth = 0, quoted = false, triple = false;
    for (let i = open; i < source.length; i += 1) {
      if (triple) {
        if (source.slice(i, i + 3) === '"""') { triple = false; i += 2; }
        continue;
      }
      if (quoted) {
        if (source[i] === '\\') { i += 1; continue; }
        if (source[i] === '"') quoted = false;
        continue;
      }
      if (source.slice(i, i + 3) === '"""') { triple = true; i += 2; continue; }
      if (source[i] === '"') { quoted = true; continue; }
      if (source[i] === '{') depth += 1;
      if (source[i] === '}' && --depth === 0) return [{ start, end: i + 1 }];
    }
    return [];
  });
}

// Each digest covers the complete reviewed function, not merely its argument
// spelling. Edits require review and mutation tests before updating the digest.
const reviewedFunctions = [
  ['macos/EngramCaptureShared/ImmutableArchiveCAS.swift', 'stage', 'a7bea85d3a6b6b2055546475423311f1e3758582fc335bf3368bf7773449502a'],
  ['macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift', 'stage', 'a7bea85d3a6b6b2055546475423311f1e3758582fc335bf3368bf7773449502a'],
  ['macos/EngramCaptureShared/ImmutableArchiveCAS.swift', 'discardStaged', 'ff8afe2a45757dc1d9b6c744dab6d9693e8ca8e8ba2d0f4e06573caca278a2b8'],
  ['macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift', 'discardStaged', 'ff8afe2a45757dc1d9b6c744dab6d9693e8ca8e8ba2d0f4e06573caca278a2b8'],
  ['macos/EngramRemoteServer/Core/ArchiveStore.swift', 'publishPublicationMetadata', '51ec6f1323f8c86c3aa11c3791cba0887b124a73247d19033ff80cd705e5fb99'],
  ['macos/EngramRemoteServer/Core/ArchiveStore.swift', 'publish', '5ea291a5e2f9467c39d5ba121144d4304228e2de6de8ca2036f0cd0042e44ace'],
  ['macos/EngramRemoteServer/Core/ArchiveStore.swift', 'writeEnvelopeCache', '035919f7904ae9c33c4f9dd9b82fef2980c593364e75042508229bfdaf91e080'],
  ['macos/EngramService/Core/ArchiveReclamationCoordinator.swift', 'executeCycle', '48b63a042a59e87af9a0c3aacdaa1de519a2774274a79fc9251d3a090e18a6f0'],
  ['macos/EngramCollectorCore/CollectorSQLiteSnapshotLease.swift', 'createOwnedStaging', 'dc6b306a8b3a3687682e54551e93ed59de7f13c93c73eb7e5c4406b2f40a2f8b'],
  ['macos/EngramCollectorCore/CollectorSQLiteSnapshotLease.swift', 'destroyOwnedStaging', 'cb189c59e4d7c3ce49facedea231e999c03452ab7efe300d744946a72185be67'],
  ['macos/EngramCoreWrite/CaptureIngest/CaptureIngestReplay.swift', 'cleanup', '22c9d3889e6cc4ea7070cc1a53aada82790b22adeeb31331c7d8946c1f6a12e7'],
  ['macos/EngramCoreWrite/CaptureIngest/CaptureIngestReplay.swift', 'removeContents', '3e0749b753e59c1ed3e2a495f6e5043e580f19f83b825b8e1bb427c8a90abfeb'],
  ['macos/EngramCollectorCore/CollectorSpoolGCFiles.swift', 'finalizeUnlink', 'a8218d00ee1332037e93d29fe2f64030a3efa3cea060b119b59c70ffca1a27f1'],
  ['macos/EngramCollectorCore/CollectorSpoolGCExecutor.swift', 'finalize', '124ae7e649661b4ba657e71d4ad69e8af474040354e685509f81bca35104661f'],
  ['macos/EngramCoreWrite/ArchiveV2/ArchiveCASEvictor.swift', 'evictEligibleObjects', '154b243fbeb3c27671f57bd18135c17e709ee611efc81d8d2848bccef3deb65f'],
];
function reviewedCall(path, source, index) {
  return reviewedFunctions.some(([relative, name, digest]) => {
    if (path !== resolve(root, relative)) return false;
    return functionRanges(source, name).some(range => index >= range.start && index < range.end &&
      createHash('sha256').update(source.slice(range.start, range.end).replace(/\s+/g, '')).digest('hex') === digest);
  });
}

let sourceReclaimerUnlinkCount = 0;
let immutableObjectUnlinkCount = 0;

for (const path of process.argv.slice(3)) {
  const source = readFileSync(path, 'utf8');
  const scanSource = maskComments(source);
  if (immutableArchiveCASPaths.has(path) && /public\s+func\s+removeObject/.test(scanSource) &&
      !/#if\s+!ENGRAM_COLLECTOR_CORE\s+public\s+func\s+removeObject/.test(scanSource)) {
    failPrimitive(path, 1, 'unguarded collector CAS removal API');
  }
  const protectedSQL = /\b(?:DELETE\s+FROM|DROP\s+TABLE(?:\s+IF\s+EXISTS)?)\s+(?:["`\[]?[A-Za-z_][A-Za-z0-9_]*["`\]]?\s*\.\s*)?["`\[]?(?:archive_captures|collector_publications|collector_publication_replicas|collector_gc_runs|collector_gc_objects|collector_spool_object_residency)\b/i;
  if (protectedSQL.test(scanSource)) failPrimitive(path, 1, 'protected capture/publication SQL');
  if (/\/EngramCollector(?:Core)?\//.test(path) && /\b(?:ArchiveCASEvictor|ArchiveSourceReclaimer)\b/.test(scanSource)) {
    failPrimitive(path, 1, 'legacy reclamation wrapper');
  }
  const callsByOpenParen = new Map();

  for (const { name, pattern } of primitivePatterns) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(scanSource)) !== null) {
      // A declaration is not a call. Its body is still scanned independently.
      if (/\bfunc\s*$/.test(scanSource.slice(0, match.index))) continue;
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

    if (reviewedCall(path, scanSource, start)) continue;
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
      immutableArchiveCASPaths.has(path) &&
      argument === 'objectURL.path'
    ) {
      immutableObjectUnlinkCount += 1;
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
# legacy mutable v1 route, two v2 auth->405 guards, optional exact Web logout
# wrapper, and optional exact Web-write DELETEs (alias, session unlink,
# suggestion dismiss) are the complete allowlist; moving a successful v2
# route to another file must not bypass this gate.
# Scan across newlines and reject common generic registration spellings too, so
# neither formatting nor a method-based route can evade the explicit allowlist.
node - "$ROOT_DIR" "${remote_server_files[@]}" <<'NODE'
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const webAuthRoutes = resolve(
  process.argv[2], 'macos/EngramRemoteServer/Core/WebAuthRoutes.swift',
);
const webWriteRoutes = resolve(
  process.argv[2], 'macos/EngramRemoteServer/Core/WebWriteRoutes.swift',
);

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
const expectedWebLogoutBody =
  'request, _ in await logout(request, boundary: boundary, sessions: sessions)';
const expectedWebAliasDeleteBody =
  'request, _ in try await mutate(request, keys: removeKeys) { data in try await surface.removeAlias(try JSONDecoder().decode(EngramServiceWebRemoveAliasRequest.self, from: data)) }';
const expectedWebUnlinkDeleteBody =
  'request, context in try await mutate(request, keys: unlinkKeys) { _ in try await surface.unlink(try EngramServiceWebUnlinkRequest( sessionId: try pathSessionID(context.parameters.get("id")) )) }';
const expectedWebSuggestionDeleteBody =
  'request, context in try await mutate(request, keys: suggestionKeys) { data in let body = try JSONDecoder().decode(SuggestedParentBody.self, from: data) return try await surface.dismissSuggestion(try EngramServiceWebDismissSuggestionRequest( sessionId: try pathSessionID(context.parameters.get("id")), suggestedParentId: body.suggestedParentId )) }';

let legacyCount = 0;
let v2Count = 0;
let webLogoutCount = 0;
let webAliasDeleteCount = 0;
let webUnlinkDeleteCount = 0;
let webSuggestionDeleteCount = 0;

function lineAt(source, index) {
  return source.slice(0, index).split('\n').length;
}

function closureBody(source, start, stripComments = true) {
  const open = source.indexOf('{', start);
  if (open < 0) return null;
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] !== '}') continue;
    depth -= 1;
    if (depth !== 0) continue;
    const body = source.slice(open + 1, index);
    return (stripComments ? body.replace(/\/\/.*$/gm, '') : body)
      .replace(/\s+/g, ' ')
      .trim();
  }
  return null;
}

for (const path of process.argv.slice(3)) {
  const source = readFileSync(path, 'utf8');
  if (path.endsWith('/EngramRemoteServer/StorageOnlyMain.swift')) {
    const start = source.indexOf('    private func handleArchiveV2(');
    const end = source.indexOf('\n    private ', start + 1);
    const body = source.slice(start, end < 0 ? source.length : end).replace(/\/\/.*$/gm, '').replace(/\s+/g, ' ');
    const required = 'if req.method == "DELETE" { let endpoint = Self.deleteEndpointName(path: req.path) return observed(req, endpoint: endpoint, archiveMutation: false) { guard Self.authorized(req, token: token) else { return Self.archiveUnauthorized() } return Self.archiveError(status: 405, reason: "Method Not Allowed", code: "method_not_allowed") } }';
    const beforeDispatch = body.split('if req.path.hasPrefix')[0];
    const prefix = 'private func handleArchiveV2( _ req: HTTPRequest, archive: EngramRemoteArchiveConfig, store: ArchiveStore ) -> HTTPResponse { let token = archive.bearerToken ';
    if (start < 0 || beforeDispatch.trim() !== prefix + required || (body.match(/"DELETE"/g) || []).length !== 1) {
      console.error('archive v2 safety gate failed: storage-only manual v2 DELETE must authorize then return 405 before dispatch');
      process.exit(1);
    }
  }
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
    const isWebLogout =
      resolve(path) === webAuthRoutes &&
      /^"\/web\/api\/auth"\s*\)\s*\{/.test(argument);
    const isWebAliasDelete =
      resolve(path) === webWriteRoutes &&
      /^"\/web\/api\/settings\/aliases"\s*\)\s*\{/.test(argument);
    const isWebUnlinkDelete =
      resolve(path) === webWriteRoutes &&
      /^"\/web\/api\/sessions\/:id\/link"\s*\)\s*\{/.test(argument);
    const isWebSuggestionDelete =
      resolve(path) === webWriteRoutes &&
      /^"\/web\/api\/sessions\/:id\/suggestion"\s*\)\s*\{/.test(argument);

    if (isLegacy) {
      legacyCount += 1;
      continue;
    }
    if (isWebLogout) {
      // The exact new wrapper permits no comments or additional operations.
      if (closureBody(source, directDelete.lastIndex, false) !== expectedWebLogoutBody ||
          ++webLogoutCount > 1) {
        console.error(
          'archive v2 safety gate failed: Web logout must be one exact session-only wrapper',
        );
        process.exit(1);
      }
      continue;
    }
    if (isWebAliasDelete) {
      if (closureBody(source, directDelete.lastIndex) !== expectedWebAliasDeleteBody ||
          ++webAliasDeleteCount > 1) {
        console.error(
          'archive v2 safety gate failed: Web alias DELETE must be one exact settings wrapper',
        );
        process.exit(1);
      }
      continue;
    }
    if (isWebUnlinkDelete) {
      if (closureBody(source, directDelete.lastIndex) !== expectedWebUnlinkDeleteBody ||
          ++webUnlinkDeleteCount > 1) {
        console.error(
          'archive v2 safety gate failed: Web unlink DELETE must be one exact parent-link wrapper',
        );
        process.exit(1);
      }
      continue;
    }
    if (isWebSuggestionDelete) {
      if (closureBody(source, directDelete.lastIndex) !== expectedWebSuggestionDeleteBody ||
          ++webSuggestionDeleteCount > 1) {
        console.error(
          'archive v2 safety gate failed: Web suggestion DELETE must be one exact dismiss wrapper',
        );
        process.exit(1);
      }
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
