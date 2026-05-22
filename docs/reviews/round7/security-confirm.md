# Round 7 — Security Confirmation (Defensive)

Empirical confirmation of round-6 §10 security findings against the **live,
running** EngramService on the author's own machine, plus enforced (not theater)
fix designs. All probing was authorized defensive testing on the user's own
host. No offensive payloads were run; no real transcript bodies were dumped.

Date: 2026-05-22. Repo: `/Users/bing/-Code-/engram`.

## Live environment snapshot (probed)

- Running service: PID 54338 = `/Applications/Engram.app/Contents/Helpers/EngramService`
  (confirmed via `lsof -nP -iTCP:3457 -sTCP:LISTEN` → that PID owns the listen socket).
- Signing of the *deployed/running* build: `Apple Development: zhibing zhao (AE7P4G8656)`,
  TeamIdentifier `J25GS8J4XM`; `codesign --verify --strict` → exit 0.
- `~/.engram/settings.json`: mode `0600` (correct); AI keys stored as `@keychain`
  on this machine (so for *this signed* build the Keychain path is active).
- `~/.engram/run/` exists, owned 0700 (validated by `ServiceWriterGate.validateRuntimeDirectory`);
  the service socket lives there.

---

## C1 — CONFIRMED CRITICAL: always-on unauthenticated Web UI on 127.0.0.1:3457 serving UNREDACTED transcripts

### Status: empirically reachable + no auth + no redaction. Confirmed live.

**Reachability (live probe, no body dump):**

```
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3457/health   → 200
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3457/          → 200
curl ... -H 'Host: evil.example.com'   http://127.0.0.1:3457/health    → 200   (Host not validated)
curl ... -H 'Origin: http://evil.example.com' .../health               → 200   (Origin not validated)
```

The spoofed `Host`/`Origin` returning 200 directly confirms the DNS-rebinding /
CSRF surface: a malicious web page the user visits can issue cross-origin
`fetch`/`<img>`/navigation to `http://127.0.0.1:3457/` and the server answers it.

**Unconditional startup (no opt-in):**
`EngramServiceRunner.run()` — `EngramServiceRunner.swift:61-90` — spawns
`webTask` that constructs `EngramWebUIServer(databasePath:)` and calls
`.run()` with **no settings gate, no flag, no env check**. It always binds.

**No auth / no Host / no Origin in the handler:**
`EngramWebUIServer.run()` — `EngramWebUIServer.swift:39-63` — registers exactly
three routes (`GET /`, `GET /session/:id`, `GET /health`) on a bare
`Hummingbird.Router()` with **no middleware**, no `Authorization` check, no
bearer/token param, no `Host`/`Origin` validation. Every handler answers any
client that can open a TCP connection to the loopback port. On a multi-user
host, *any* local user (or any process of any uid that can reach loopback) can
read it; loopback bind is not access control.

**No redaction (contrast with export):**
- Web transcript render: `EngramWebUIServer.renderMessageHTML` —
  `EngramWebUIServer.swift:247-264` — emits `escape(message.content)`. `escape()`
  (`:428-435`) is **HTML-entity escaping only** (`& < > " '`). It does NOT remove
  secrets.
- Export render: `TranscriptExportService.exportContent` —
  `TranscriptExportService.swift:107-113` — maps every message through
  `redactSensitiveContent` (`:145-161`) which strips `api_key/authorization/
  bearer/password/secret/credential/token` assignments, `Authorization: Bearer`,
  and `sk-/ghp_/xox[baprs]-` tokens before writing.

So the Web UI serves **raw, unredacted** transcripts that even the explicit
export path scrubs. `GET /session/:id` (`:43-48` → `sessionPage` `:128-182`)
pages the full message stream.

### Enforced fix (C1)

1. **Default-off, opt-in.** In `EngramServiceRunner.run()` (`:61`), gate the
   `webTask` behind a settings flag (e.g. `settings.json:"webUiEnabled": false`
   default). When disabled, never bind 3457. (Removes the always-listening
   surface entirely for the common case.)
2. **Per-launch bearer token in the 0700 run dir.** When enabled, generate a
   128-bit random token at service start, write it to
   `runtimeDirectory.appendingPathComponent("web-token")` with `0o600` (the dir
   is already 0700 — see `ServiceWriterGate.swift:130` / `EngramServiceRunner.swift:36`).
   Pass it into `EngramWebUIServer.init`. Add a Hummingbird middleware that
   rejects (`401`) any request whose `Authorization: Bearer <token>` (or
   `?token=` for the top-level page) does not constant-time-match. The app's own
   "Open Web UI" action reads the token file and opens
   `http://127.0.0.1:3457/?token=…`.
3. **Host/Origin validation middleware.** Reject any request whose `Host` header
   is not `127.0.0.1:3457`/`localhost:3457`, and whose `Origin` (when present) is
   not the same. This closes DNS-rebinding even before the token check.
4. **Apply the same `redactSensitiveContent` to web render.** Move
   `redactSensitiveContent` into a shared location (e.g. `EngramCore`) and call
   it inside `renderMessageHTML` so web output is never less-redacted than
   export. (Even with auth, defense-in-depth for shoulder-surf / proxy logs.)

Concrete touch points: `EngramServiceRunner.swift:61-90` (gate + token gen),
`EngramWebUIServer.swift:19-64` (init takes token; add middleware before routes),
`EngramWebUIServer.swift:247-264` (wrap content in redactor).

---

## C2 — CONFIRMED CRITICAL: project_move / archive / batch unconfined arbitrary dir move + JSONL byte-rewrite

### Status: confirmed by code trace. No allow-list anywhere on src/dst.

**The full path from MCP to `rename(2)` has no confinement:**

1. MCP exposes the tools to any client: `MCPToolRegistry.swift:567` registers
   `project_move` with required args `["src","dst"]`; `:1142-1143` route
   `project_move`/`project_archive`; `force` is read straight from the client at
   `:1040` (`arguments["force"]?.boolValue ?? false`) for move/archive/batch.
2. Handler does NO check: `EngramServiceCommandHandler.projectMove` —
   `EngramServiceCommandHandler.swift:880-898` — passes `request.src`/`request.dst`
   verbatim into `ProjectMoveOrchestrator.run`. Same for
   `projectArchive` (`:900-938`) and `projectMoveBatch` (`:970-985`).
3. Orchestrator's only guards: `ProjectMoveOrchestrator.run` —
   `Orchestrator.swift:207-220` — checks (a) non-empty, (b) `src != dst`,
   (c) dst-not-inside-src, (d) src-not-inside-dst. `canonicalize` (`:789-791`) is
   only `URL.standardizedFileURL` (collapses `..`), **not** a root confinement.
   **There is no allow-list.** Step 1 (`SafeMoveDir.run(src:dst:)`, `:345`) then
   `rename(2)`s the arbitrary `src` to the arbitrary `dst`.

**Contrast:** `linkSessions` *does* confine, via
`isAllowedSessionFilePath` — `EngramServiceCommandHandler.swift:1194-1254` —
which requires the path be under `$HOME`, rejects sensitive components
(`.ssh/.aws/.gnupg/.kube/.docker/.1password/Library/Keychains`, `:1256-1259`),
and matches a per-source suffix allow-list. **None of that is applied to
project_move.**

**force:true bypasses the git guard:**
`Orchestrator.swift:223-226` — `if git.dirty && !options.force { throw gitDirty }`.
With `force:true` the dirty-tree guard is skipped entirely; the move proceeds on
a dirty repo. The flag flows MCP → handler → `RunProjectMoveOptions.force`
unmodified.

**Malicious MCP call (described, NOT executed):**
A single `project_move` tool call with
`{"src":"<any dir the service uid can rename>","dst":"<any writable dst>","force":true}`
will `rename(2)` that arbitrary directory to the attacker-chosen destination
(git guard bypassed). Because `src`/`dst` are unconfined, this is an arbitrary
local directory relocation reachable by any MCP client the user has wired to
`EngramMCP`.

**JSONL substring-rewrite blast radius:**
After the dir move, Step 3 (`Orchestrator.swift:382-428`) walks `SessionSources.roots(...)`
and calls `JsonlPatch.patchFile(at:oldPath:newPath:)` on every file containing
the `src` substring. `JsonlPatch` (`JsonlPatch.swift:1-12`) does a **byte-level
substring replace** of `src`→`dst` wherever followed by a path-terminator.
Blast radius of the *patch* is bounded to files under the session roots (good),
but: (a) any session JSONL whose content merely *mentions* the `src` string —
even inside a code block or unrelated prose — gets silently rewritten; (b) the
*directory rename* itself (Step 1) is the unbounded primitive.

### Enforced fix (C2)

Add a confinement check in the handler **before** calling the orchestrator, for
`projectMove`/`projectArchive`/`projectMoveBatch` (and undo's computed src/dst):

- Canonicalize `src` and `dst` with `realpath`-style resolution (resolve
  symlinks, not just `..`).
- Require both to be **project working-directory roots** the user owns —
  realistically: reject any path under the sensitive set already encoded in
  `containsSensitivePathComponent` (`:1256-1259`), reject paths outside `$HOME`
  unless an explicit user-confirmed override, and reject `dst` that would land
  inside a session-source root (`SessionSources.roots`) so a move can't inject
  into the index store. Mirror the *structure* of `isAllowedSessionFilePath`.
- Treat `force` as a request to skip the **git-dirty** check only; it must NOT
  skip the confinement/canonicalization check.

Concrete touch points: add `validateProjectMovePaths(src:dst:)` and call it at
`EngramServiceCommandHandler.swift:884` (projectMove), `:924` (archive resolved
dst), `:954` (undo reverse), and inside `Batch.run` per entry
(`Batch.swift`). Keep the orchestrator's existing inside-out checks as a second
layer.

---

## H1 — CONFIRMED HIGH: no authz on mutating commands; `unauthorized` is dead code; any same-uid process drives every mutation

### Status: confirmed. `.unauthorized` is never thrown.

**`unauthorized` never thrown:** grep for `throw … unauthorized` across the
non-build Swift product path returns **zero** sites. The only occurrences of
`unauthorized` are:
- the enum case declaration — `EngramServiceError.swift:7`,
- the wire round-trip mapping — `EngramServiceError.swift:22, 78-79`,
- the error→envelope encode switch — `EngramServiceCommandHandler.swift:372`
  (this only *formats* an already-thrown error; nothing reaches it).

So the authorization error type is pure dead code; no command ever rejects a
caller.

**Any peer accepted:** `UnixSocketServiceServer.start()` —
`UnixSocketServiceServer.swift:42` — `accept(descriptor, nil, nil)` accepts any
connecting peer with **no `getpeereid`/`LOCAL_PEERCRED` check**, then
`:61` runs `handler(request)` unconditionally. The dispatch in
`EngramServiceCommandHandler.handle` (`:181-214` and the rest) executes
`projectMove`, `projectArchive`, `projectMoveBatch`, `hideSession`, link/unlink,
etc. with no caller identity. Any process of the same uid that can `connect(2)`
to `~/.engram/run/engram-service.sock` drives every mutation.

(M1 corroborated: the socket *file* mode is left to umask — only the *dir* is
0700 enforced. The dir 0700 limits cross-uid access in practice, but the socket
inode mode should be set explicitly too.)

### Enforced fix (H1)

1. **`getpeereid` peer-cred check** right after `accept` in
   `UnixSocketServiceServer.swift:42`: call `getpeereid(client, &euid, &egid)`
   and reject (close) any peer whose euid != `geteuid()`. This makes "same-uid
   trust" an *enforced* boundary instead of an implicit one.
2. **Capability token for destructive commands.** For the mutating set
   (project_move/archive/batch/undo, hide, link/unlink), require a per-launch
   capability token (same mechanism as the C1 web token, stored in the 0700 run
   dir, `0600`). The app/MCP helper reads it and includes it in the request
   envelope; the handler `throw EngramServiceError.unauthorized(...)` (finally
   wiring the dead case) when it is missing/mismatched. Read-only commands stay
   token-free.
3. Set the socket inode to `0600` explicitly after bind (addresses M1).

If the project decides same-uid trust is acceptable, that is a legitimate
posture — but it must be **documented explicitly** and the dead `unauthorized`
case removed, rather than left implying an enforcement that does not exist.

---

## H2 — CONFIRMED HIGH: plaintext API-key fallback for any "unsigned" build, no UI warning

### Status: confirmed by code; live build happens to use Keychain.

`KeychainHelper.isUnsignedBuild` — `SettingsIO.swift:40-51` — returns `true`
when **either** the bundle path contains `DerivedData` **or**
`SecStaticCodeCheckValidity` is not `errSecSuccess`. This conflates a Debug build
with any ad-hoc / improperly-signed release: an ad-hoc-signed release that fails
strict validity also trips it.

When `true`, `get`/`set`/`delete` all early-return and skip the Keychain
(`:54, 71, 85`). The save path then writes the **raw key** into `settings.json`:
`AISettingsSection.saveAISettings` — `AISettingsSection.swift:383-396` — line
`391` does `mutateEngramSettings { $0["aiApiKey"] = aiApiKey }` (plaintext) in
the `else` of "Keychain unavailable", with **no warning surfaced to the user**.
Same pattern for `titleApiKey` (`:434-443`).

`settings.json` is 0600 (verified), so it is protected from other uids — but it
is plaintext-at-rest, included in any `~/.engram` backup/sync, and the user is
never told the key is not in the Keychain.

Live state: the running build is `/Applications/Engram.app`, `Apple Development`
signed, `codesign --verify --strict` exit 0 → `isUnsignedBuild` is **false** for
it, and `aiApiKey` is `@keychain` on disk. So this specific machine is not
currently leaking; the defect is the silent fallback for the
DerivedData/ad-hoc population and the absent warning.

### Enforced fix (H2)

1. **Don't conflate Debug with ad-hoc release.** Narrow `isUnsignedBuild` to a
   real "Keychain truly unavailable" probe (attempt a throwaway
   `SecItemAdd`/`SecItemCopyMatching` round-trip once and cache the result),
   instead of treating "path contains DerivedData OR strict-validity failed" as
   "skip Keychain". An ad-hoc-signed release should still use the Keychain.
2. **Visible plaintext warning.** When the code genuinely falls back to plaintext
   (`AISettingsSection.swift:391`/`:436` branch taken), surface a persistent UI
   warning (e.g. an inline caution row in `AISettingsSection`) stating the key is
   stored unencrypted in `~/.engram/settings.json`. Never store plaintext
   silently.
3. **Keychain-when-signed policy.** Make the signed-build path the default and
   require an explicit user opt-in (with the warning) to fall back to plaintext.

Concrete touch points: `SettingsIO.swift:40-51` (probe rewrite),
`AISettingsSection.swift:383-396, 434-443` (warning + opt-in gate).

---

## Cross-cutting

- **Shared run-dir token primitive.** C1 (web bearer) and H1 (capability token)
  should share one per-launch-token mechanism stored in the already-0700
  `runtimeDirectory` (`EngramServiceRunner.swift:36`, `ServiceWriterGate.swift:130`).
  One implementation, two consumers.
- **Shared redactor.** C1 fix and the existing export redactor
  (`TranscriptExportService.swift:145-161`) should be one function so web,
  export (and ideally any future surface) are never inconsistent.
- **M2 (round 6) corroborated incidentally:** error envelopes echo raw
  `localizedDescription` (`UnixSocketServiceServer.swift:68`,
  handler `:372` family) — paths/SQL can leak over IPC and into the web UI's
  transcript-error block (`EngramWebUIServer.swift:266-292`). Sanitize before
  emitting.

## Probing method note

All confirmations are either code reads (file:line cited) or single read-only
`curl` HEAD-style status probes (`-o /dev/null`, only HTTP status captured) and
`codesign`/`stat`/`lsof` inspections. No `/session/:id` body was retrieved; no
mutation command was sent to the service; no offensive payload was executed.
