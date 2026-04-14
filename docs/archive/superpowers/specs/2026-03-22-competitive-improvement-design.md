# Competitive Analysis Improvement — Design Spec

> **Date**: 2026-03-22
> **Scope**: 24 features across security, UX, data layer, and infrastructure
> **Sources**: Agent Sessions (AS), ReadOut (RO) — competitive analysis
> **Architecture**: A — Node-first for data/tools; Swift for UI; dual-process coordination

---

## Overview

| # | Feature | Category | Layer | Necessity | Feasibility | Effort |
|---|---------|----------|-------|-----------|-------------|--------|
| 1 | API Key Keychain Migration | Security | Swift + Node config | High | High | Medium |
| 2 | Network Security Hardening | Security | Node middleware + Swift | High | High | Medium |
| 3 | RepoDetailView AppleScript Escaping | Security | Swift only | Medium | Trivial | Trivial |
| 4 | PRIVACY.md + SECURITY.md | Documentation | Docs only | Medium | Trivial | Low |
| 5 | get_context Aggregation Upgrade | Feature | Node MCP tool | High | High | Medium |
| 6 | Usage UI (Menu Bar Quota Bars) | Feature | Swift only | Medium | High | Medium |
| 7 | Session Resume Improvements | Feature | Swift + Node | Medium | High | Medium |
| 8 | SessionCard Context Menu | Feature | Swift only | Medium | High | Low |
| 9 | Empty State + Skeleton Loading | UX Polish | Swift only | Medium | High | Low |
| 10 | Onboarding | UX Polish | Swift only | Medium | High | Medium |
| 11 | UI Anti-Flicker | UX Polish | Swift only | High | Medium | Medium |
| 12 | Image Handling | Feature | TS adapter + Swift | Medium | High | Medium |
| 13 | Keyboard Shortcuts | UX Polish | Swift only | Medium | High | Medium |
| 14 | Cost Budget Alerts | Feature | TS monitor + Swift | Medium | High | Medium |
| 15 | Battery/Visibility-Aware Polling | Performance | TS daemon + Swift | Low | Medium | Medium |
| 16 | Transcript Enhancement | Feature | Swift only | High | Medium | High |
| 17 | Swift MessageParser Streaming | Performance | Swift only | High | High | Medium |
| 18 | Session Scoring | Feature | Node data layer | Medium | High | Medium |
| 19 | File Change Tracking | Feature | Node data + MCP tool | High | High | Medium |
| 20 | Executable Actions | Feature | Node + Swift | Medium | Medium | High |
| 21 | Cockpit HUD | Feature | Swift only | Low | Medium | Medium |
| 22 | Auto-Update + Homebrew | Infrastructure | CI + Swift | Medium | Medium | High |
| 23 | Infrastructure Health Checks | Feature | Node tools | Medium | High | Medium |
| 24 | Schema Drift Tests | Testing | Vitest + fixtures | High | High | Medium |

---

## Sprint Grouping

### Sprint 1: Security + Quick Wins (3-4 days)

| # | Feature | Effort | Notes |
|---|---------|--------|-------|
| 3 | RepoDetailView AppleScript Escaping | Trivial | No deps |
| 1 | API Key Keychain Migration | Medium | Must complete before #4 |
| 2 | Network Security Hardening | Medium | No deps |
| 4 | PRIVACY.md + SECURITY.md | Low | **Last in Sprint 1** — must wait for #1 Keychain to merge so docs accurately reflect storage model |

### Sprint 2: Data Layer + Tools (4-5 days)

| # | Feature | Effort |
|---|---------|--------|
| 5 | get_context Aggregation Upgrade | Medium |
| 17 | Swift MessageParser Streaming | Medium |
| 18 | Session Scoring | Medium |
| 19 | File Change Tracking | Medium |
| 24 | Schema Drift Tests | Medium |

> **#17 rationale**: Moved from Sprint 4 to Sprint 2 because it is a foundational refactor that #12 (Image Handling) depends on. Doing it alongside data layer work allows integrated testing of the streaming parser with the new file tracking pipeline.

### Sprint 3: UX Polish (3-4 days)

| # | Feature | Effort |
|---|---------|--------|
| 9 | Empty State + Skeleton Loading | Low |
| 10 | Onboarding | Medium |
| 11 | UI Anti-Flicker | Medium |
| 8 | SessionCard Context Menu | Low |

### Sprint 4: Interaction + Performance (3-4 days)

| # | Feature | Effort |
|---|---------|--------|
| 6 | Usage UI (Menu Bar Quota Bars) | Medium |
| 7 | Session Resume Improvements | Medium |
| 12 | Image Handling | Medium |
| 13 | Keyboard Shortcuts | Medium |

### Sprint 5: Monitoring + Enhancement (3-4 days)

| # | Feature | Effort |
|---|---------|--------|
| 14 | Cost Budget Alerts | Medium |
| 15 | Battery/Visibility-Aware Polling | Medium |
| 16 | Transcript Enhancement | High |
| 23 | Infrastructure Health Checks | Medium |

### Backlog (design only — not for immediate implementation)

| # | Feature | Effort |
|---|---------|--------|
| 20 | Executable Actions | High |
| 21 | Cockpit HUD | Medium |
| 22 | Auto-Update + Homebrew | High |

---

## Feature Specs

---

### 1. API Key Keychain Migration

**Summary**: Three API keys (`aiApiKey`, `titleApiKey`, `viking.apiKey`) are stored as plaintext in `~/.engram/settings.json`. Move them to the macOS Keychain via the `security` CLI tool so that the keys are encrypted at rest, protected by the user's login keychain, and never visible in JSON on disk.

**Necessity**: High — credential files are readable by any process under the same user. A stray `cat` or accidental git commit leaks keys.
**Feasibility**: High — `security` CLI is available on all macOS versions, and the daemon (Node) can call it via `child_process`.
**Effort**: Medium (3-4 hours)

#### Files to Modify

| File | Changes |
|------|---------|
| `macos/Engram/Views/Settings/SettingsIO.swift` | Add `KeychainHelper` enum with static get/set/delete methods |
| `macos/Engram/Views/Settings/AISettingsSection.swift` | Lines 8, 40, 72-77, 335-341: read/write `aiApiKey` and `titleApiKey` via KeychainHelper instead of settings dict |
| `macos/Engram/Views/Settings/NetworkSettingsSection.swift` | Lines 17, 49-50, 211-218: read/write `vikingApiKey` via KeychainHelper |
| `src/core/config.ts` | Add `readKeychainValue()` helper, modify `readFileSettings()` to overlay Keychain values |
| `src/daemon.ts` | No changes — settings flow is already via `readFileSettings()` |

#### New Code: KeychainHelper (Swift)

Add to `SettingsIO.swift` (same file, keeps settings I/O centralized):

```swift
enum KeychainHelper {
    private static let service = "com.engram.app"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Save a value to the Keychain. Returns true on success.
    /// Callers should verify via `get()` read-back for critical paths,
    /// or show an alert to the user on failure.
    @discardableResult
    static func set(_ key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete first to avoid duplicate errors
        delete(key)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

#### New Code: Node-side Keychain Reading

In `src/core/config.ts`, add:

```typescript
import { execFileSync } from 'child_process'

function readKeychainValue(key: string): string | undefined {
  if (process.platform !== 'darwin') return undefined
  try {
    const result = execFileSync('security', [
      'find-generic-password',
      '-s', 'com.engram.app',
      '-a', key,
      '-w', // output password only
    ], { encoding: 'utf-8', timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] })
    return result.trim() || undefined
  } catch {
    return undefined  // key not in keychain
  }
}
```

Modify `readFileSettings()` (line 197-218) to overlay after reading JSON:

```typescript
export function readFileSettings(): FileSettings {
  // ... existing JSON read + migration ...
  // Overlay Keychain values (take precedence over plaintext JSON)
  const kcAiApiKey = readKeychainValue('aiApiKey')
  if (kcAiApiKey) migrated.aiApiKey = kcAiApiKey
  const kcTitleApiKey = readKeychainValue('titleApiKey')
  if (kcTitleApiKey) migrated.titleApiKey = kcTitleApiKey
  const kcVikingApiKey = readKeychainValue('vikingApiKey')
  if (kcVikingApiKey) {
    if (!migrated.viking) migrated.viking = {}
    migrated.viking.apiKey = kcVikingApiKey
  }
  return migrated
}
```

#### AISettingsSection Changes

Currently `saveAISettings()` writes `aiApiKey` to settings JSON (line 340: `settings["aiApiKey"] = aiApiKey`). Change to:

```swift
// In saveAISettings():
if !aiApiKey.isEmpty {
    let saved = KeychainHelper.set("aiApiKey", value: aiApiKey)
    if !saved {
        // Show alert — key was NOT persisted
        // Fallback: keep in settings.json so user doesn't lose the key entirely
        settings["aiApiKey"] = aiApiKey
        return  // don't remove from JSON since Keychain write failed
    }
    // Verify read-back
    guard KeychainHelper.get("aiApiKey") == aiApiKey else {
        settings["aiApiKey"] = aiApiKey  // fallback
        return
    }
} else {
    KeychainHelper.delete("aiApiKey")
}
settings.removeValue(forKey: "aiApiKey")  // remove from plaintext JSON only after verified Keychain write
```

Same pattern for `titleApiKey` in `saveTitleSettings()` (line 378) and `vikingApiKey` in `saveVikingSettings()` (line 218 in NetworkSettingsSection). Each save path must: (1) attempt Keychain write, (2) verify read-back, (3) only then remove from JSON. On failure, fall back to JSON storage and optionally show an alert via `NSAlert`.

On load: `loadAISettings()` checks Keychain first, falls back to JSON for backward compat:

```swift
aiApiKey = KeychainHelper.get("aiApiKey")
    ?? (settings["aiApiKey"] as? String) ?? ""
```

#### Migration Strategy

**One-time migration** on app launch (in `SettingsIO.swift` or `AppDelegate`):

```swift
static func migrateKeysToKeychain() {
    guard let settings = readEngramSettings() else { return }
    let keysToMigrate: [(jsonKey: String, keychainKey: String, nestedPath: String?)] = [
        ("aiApiKey", "aiApiKey", nil),
        ("titleApiKey", "titleApiKey", nil),
        ("apiKey", "vikingApiKey", "viking"),
    ]
    var needsSave = false
    for entry in keysToMigrate {
        let value: String?
        if let nested = entry.nestedPath,
           let dict = settings[nested] as? [String: Any] {
            value = dict[entry.jsonKey] as? String
        } else {
            value = settings[entry.jsonKey] as? String
        }
        guard let v = value, !v.isEmpty else { continue }
        // Only migrate if not already in Keychain
        if KeychainHelper.get(entry.keychainKey) == nil {
            KeychainHelper.set(entry.keychainKey, value: v)
            // Verify read-back before marking for cleanup
            guard KeychainHelper.get(entry.keychainKey) == v else { continue }
            needsSave = true
        }
    }
    if needsSave {
        // Remove plaintext keys from settings.json only after verified Keychain write
        mutateEngramSettings { settings in
            settings.removeValue(forKey: "aiApiKey")
            settings.removeValue(forKey: "titleApiKey")
            if var viking = settings["viking"] as? [String: Any] {
                viking.removeValue(forKey: "apiKey")
                settings["viking"] = viking
            }
            settings["keychainMigrated"] = true
        }
    }
}
```

#### Verification

1. Before migration: confirm keys exist in `~/.engram/settings.json`
2. Launch app, check `security find-generic-password -s com.engram.app -a aiApiKey -w` returns the key
3. Confirm `~/.engram/settings.json` no longer contains `aiApiKey`, `titleApiKey`, or `viking.apiKey`
4. Restart daemon, verify auto-summary still works (daemon reads key via `readFileSettings()` -> `readKeychainValue()`)
5. Delete Keychain entry, verify UI shows empty API key field
6. Enter new key in Settings UI, verify it goes to Keychain (not JSON)

---

### 2. Network Security Hardening

**Summary**: The web server has 37+ endpoints. When `httpHost` is set to `0.0.0.0` with no CIDR, all endpoints are fully exposed without authentication. This spec adds: (a) mandatory CIDR when non-localhost, (b) bearer token authentication on write endpoints, and (c) CORS headers.

**Necessity**: High — exposed write endpoints (summary, backfill, mock, cleanup) can be triggered by any network peer.
**Feasibility**: High — Hono middleware is straightforward; token can auto-generate on first startup.
**Effort**: Medium (3-4 hours)

#### Files to Modify

| File | Changes |
|------|---------|
| `src/web.ts` | Lines 86-101: enhance CIDR middleware, add auth middleware, add CORS |
| `src/core/config.ts` | Add `httpBearerToken?: string` to `FileSettings` |
| `src/daemon.ts` | Auto-generate token on first startup if non-localhost |
| `macos/Engram/Core/DaemonClient.swift` | Add `Authorization` header to all requests |
| `macos/Engram/Views/Settings/SettingsIO.swift` | Read `httpBearerToken` for DaemonClient |

#### Design: Enhanced Middleware Stack

```typescript
// In createApp(), after CIDR middleware:

// 1. Refuse non-localhost binding without CIDR
if (host !== '127.0.0.1' && (!settings.httpAllowCIDR || settings.httpAllowCIDR.length === 0)) {
  console.error('[security] httpHost is non-localhost but httpAllowCIDR is empty. Falling back to 127.0.0.1.')
  // The daemon.ts should override host to '127.0.0.1' before calling serve()
  // This is a safety net: if createApp is called with bad config, refuse to start
}

// 2. CORS middleware — restrict to known origins
app.use('*', async (c, next) => {
  c.header('X-Content-Type-Options', 'nosniff')
  c.header('X-Frame-Options', 'DENY')
  const origin = c.req.header('origin')
  if (origin) {
    // Only allow localhost origins (browser WebUI)
    try {
      const url = new URL(origin)
      const isLocal = url.hostname === '127.0.0.1' || url.hostname === 'localhost' || url.hostname === '::1'
      if (isLocal) {
        c.header('Access-Control-Allow-Origin', origin)
        c.header('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
        c.header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
      }
    } catch { /* reject malformed origins */ }
    if (c.req.method === 'OPTIONS') return c.text('', 204)
  }
  await next()
})

// 3. Bearer token auth on write endpoints (POST, DELETE, PUT)
const bearerToken = settings.httpBearerToken
if (bearerToken) {
  const WRITE_METHODS = new Set(['POST', 'PUT', 'DELETE', 'PATCH'])
  app.use('/api/*', async (c, next) => {
    if (!WRITE_METHODS.has(c.req.method)) return next()
    // No exemptions — resume triggers TerminalLauncher (write operation)
    const authHeader = c.req.header('authorization')
    if (authHeader !== `Bearer ${bearerToken}`) {
      return c.json({ error: 'Unauthorized' }, 401)
    }
    await next()
  })
}
```

#### Token Auto-Generation

In `src/daemon.ts`, before starting the web server:

```typescript
import { randomBytes } from 'crypto'
import { writeFileSettings, readFileSettings } from './core/config.js'

// Auto-generate bearer token on first non-localhost startup
if (host !== '127.0.0.1' && !settings.httpBearerToken) {
  const token = randomBytes(32).toString('hex')
  writeFileSettings({ httpBearerToken: token })
  settings.httpBearerToken = token
  emit({ event: 'security', message: 'Bearer token auto-generated for non-localhost binding' })
}
```

#### Config Change

In `FileSettings` (line 76-78 of `config.ts`), add:

```typescript
httpBearerToken?: string;  // auto-generated bearer token for write API auth
// TODO: For consistency with #1 Keychain migration, httpBearerToken should
// eventually also be stored in Keychain (it is a credential). Current design
// keeps it in settings.json because DaemonClient needs to read it on the Swift
// side and the TS daemon needs it on startup. Migrating both readers to Keychain
// is a follow-up task after #1 is validated.
```

#### DaemonClient Auth Header

Modify `DaemonClient.swift` to read and attach the bearer token:

```swift
@MainActor
class DaemonClient: ObservableObject {
    private let baseURL: String
    private var bearerToken: String?

    init(port: Int = 3457) {
        self.baseURL = "http://127.0.0.1:\(port)"
        self.bearerToken = (readEngramSettings()?["httpBearerToken"] as? String)
    }

    private func buildRequest(_ path: String, method: String, body: (any Encodable)?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return request
    }

    func fetch<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        if let token = bearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

#### Write Endpoints Requiring Auth (when token is set)

All `POST`, `DELETE`, `PUT`, `PATCH` under `/api/*` — no exemptions. Resume triggers TerminalLauncher and is a write operation.

#### Verification

1. Start daemon with `httpHost: "0.0.0.0"` and no `httpAllowCIDR` — confirm it falls back to `127.0.0.1` with a warning
2. Set `httpHost: "0.0.0.0"`, `httpAllowCIDR: ["10.0.0.0/8"]` — confirm token auto-generated
3. `curl -X POST http://localhost:3457/api/summary` — should return 401
4. `curl -H "Authorization: Bearer $TOKEN" -X POST ...` — should succeed
5. GET endpoints remain accessible without token
6. Swift DaemonClient continues to work (reads token from settings)
7. Cross-origin requests from non-localhost are blocked

---

### 3. RepoDetailView AppleScript Escaping

**Summary**: `RepoDetailView.swift` line 55 interpolates `repo.path` directly into an AppleScript string: `"cd \"\(repo.path)\""`. A path containing backslashes, quotes, or special characters will break the AppleScript or potentially execute unintended commands. The fix is to use `TerminalLauncher.escapeForAppleScript()` which already exists at line 14 of `TerminalLauncher.swift`.

**Necessity**: Medium — exploitable only via crafted git repo paths, but defense-in-depth matters.
**Feasibility**: Trivial — the escape function already exists, just not called.
**Effort**: Trivial (5 minutes)

#### Files to Modify

| File | Line | Change |
|------|------|--------|
| `macos/Engram/Views/Workspace/RepoDetailView.swift` | 55 | Use escaped path in AppleScript |
| `macos/Engram/Views/Resume/TerminalLauncher.swift` | 14 | Make `escapeForAppleScript` `internal` (currently `private static`) |

#### Current Code (line 55)

```swift
let script = "tell application \"Terminal\" to do script \"cd \\\"\(repo.path)\\\" && claude\""
```

#### Fixed Code

First, change `TerminalLauncher.escapeForAppleScript` from `private static` to `static` (remove `private` on line 14):

```swift
static func escapeForAppleScript(_ s: String) -> String {
```

Then in `RepoDetailView.swift` line 55:

```swift
let safePath = TerminalLauncher.escapeForAppleScript(repo.path)
let script = "tell application \"Terminal\" to do script \"cd \\\"\(safePath)\\\" && claude\""
```

#### Verification

1. Create a git repo with path containing a double-quote character (e.g., `~/test"repo/`)
2. Navigate to RepoDetailView for that repo
3. Click "Claude" quick action button
4. Confirm Terminal opens with correct `cd` command (no AppleScript error)

---

### 4. PRIVACY.md + SECURITY.md

**Summary**: Create privacy policy and security documentation for Engram, modeled after the reference docs at `/Users/bing/-Code-/agent-sessions/docs/`.

**Necessity**: Medium — required for App Store compliance and user trust.
**Feasibility**: Trivial — documentation only.
**Effort**: Low (30 minutes)

#### New Files

| File | Purpose |
|------|---------|
| `docs/PRIVACY.md` | Privacy policy |
| `docs/SECURITY.md` | Security documentation |

#### PRIVACY.md Content

```markdown
# Privacy Policy (Engram)

Engram is a local-first app. Your data stays on your machine.

## Data Collection
- No telemetry
- No analytics
- No remote logging
- No advertising identifiers

## Data Processing
- Session logs are read from local directories (e.g., `~/.claude/`, `~/.codex/`).
- A local SQLite database (`~/.engram/index.sqlite`) indexes session metadata for search and navigation.
- All processing happens on-device.

## Data Sharing
- No data is sent to any server by default.
- **Optional features with network activity**:
  - **AI Summary**: If configured, session content is sent to your chosen AI provider (OpenAI, Anthropic, Gemini, or self-hosted Ollama) for summary generation. Only the API you configure receives data.
  - **OpenViking**: If enabled, session content is sent to your self-hosted OpenViking server for semantic search and embedding.
  - **Sync**: If enabled, session metadata is exchanged between your own machines via peer-to-peer HTTP sync.
- API keys are stored securely on your device (macOS Keychain when available, or local configuration file).

## Third-Party Services
- Engram does not bundle any third-party analytics, crash reporting, or tracking SDKs.
- Network requests are only made to services you explicitly configure.

## Data Deletion
- Delete `~/.engram/` to remove all Engram data.
- Engram does not modify or delete your original session files.

## Contact
[maintainer email]
```

#### SECURITY.md Content

```markdown
# Security (Engram)

Engram is a local-first session aggregator. Session data stays on your Mac.

## Data Access Model
- The app reads session logs from local directories you configure (or default CLI tool locations).
- The local SQLite database is stored at `~/.engram/index.sqlite` with WAL mode.
- The Node.js daemon serves a local HTTP API (default: `127.0.0.1:3457`).

## Credential Storage
- API keys (AI providers, OpenViking) are stored in the macOS Keychain (`com.engram.app` service).
- Settings file (`~/.engram/settings.json`) contains configuration only, no secrets.

## Network Security
- **Default**: HTTP API binds to `127.0.0.1` only (not accessible from the network).
- **Non-localhost binding**: When `httpHost` is set to `0.0.0.0`:
  - CIDR allowlist (`httpAllowCIDR`) is required; without it, the server falls back to localhost.
  - Bearer token authentication is auto-generated for write endpoints (POST/DELETE).
  - CORS restricts cross-origin requests to localhost.
- **Sync**: Peer-to-peer sync uses HTTP between machines you configure. Consider using a VPN or SSH tunnel for security.

## AppleScript / Process Execution
- Session resume uses AppleScript to launch terminal emulators. All user-provided paths are escaped to prevent injection.
- No shell evaluation of user input occurs outside of controlled `execFile` calls.

## Threat Model
- Engram trusts the local filesystem and the user's login session.
- The primary threat is unauthorized network access to the HTTP API when bound to non-localhost.
- Mitigations: CIDR allowlist, bearer token auth, CORS headers.

## Reporting
If you believe you have found a security issue, contact [maintainer email] with details and reproduction steps.
```

#### Verification

1. Documents render correctly in GitHub markdown preview
2. Privacy policy covers all network-active features (summary, Viking, sync)
3. Security doc accurately reflects the CIDR + bearer token implementation from item #2

---

### 5. get_context Aggregation Upgrade

**Summary**: `get_context` currently returns only historical session summaries. Upgrade it to also return live sessions, cost-today, recent tool usage, active alerts, and config issues — making it a true "environment snapshot" for AI agents starting work.

**Necessity**: High — the MCP tool is the primary entry point for AI agents; richer context means better session starts.
**Feasibility**: High — all data sources already exist (live sessions, costs, tool analytics, monitor alerts).
**Effort**: Medium (2-3 hours)

#### Files to Modify

| File | Changes |
|------|---------|
| `src/tools/get_context.ts` | Add new response fields, `include_environment` parameter, lazy computation |
| `src/index.ts` | Pass new deps to get_context handler |
| `src/web.ts` | Update `/api/context` endpoint if it exists (or add one) |

#### Enhanced Tool Schema

```typescript
export const getContextTool = {
  name: 'get_context',
  description: '为当前工作目录自动提取相关的历史会话上下文和环境状态。在开始新任务时调用。',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: '当前工作目录（绝对路径）' },
      task: { type: 'string', description: '当前任务描述（可选，用于语义搜索）' },
      max_tokens: { type: 'number', description: 'token 预算，默认 4000' },
      detail: { type: 'string', enum: ['abstract', 'overview', 'full'], description: '详情级别 (需要 OpenViking)' },
      include_environment: { type: 'boolean', description: '是否包含环境状态（活跃会话、今日费用、告警等），默认 true' },
    },
    additionalProperties: false,
  },
}
```

#### Enhanced Response Interface

```typescript
export interface GetContextResult {
  // Existing
  contextText: string
  sessionCount: number
  sessionIds: string[]

  // New (when include_environment !== false)
  environment?: {
    liveSessions: Array<{
      source: string
      project?: string
      currentActivity?: string
      model?: string
      activityLevel: string
    }>
    costToday: {
      totalUsd: number
      inputTokens: number
      outputTokens: number
    }
    recentTools: Array<{
      name: string
      callCount: number
    }>
    alerts: Array<{
      category: string
      severity: string
      title: string
    }>
    configIssues: string[]  // e.g. "No AI API key configured", "Viking unreachable"
  }
}
```

#### Enhanced Deps Interface

```typescript
export interface GetContextDeps {
  vectorStore?: VectorStore
  embed?: (text: string) => Promise<Float32Array | null>
  viking?: VikingBridge | null
  // New deps for environment data:
  liveMonitor?: { getSessions(): LiveSession[] }
  backgroundMonitor?: { getAlerts(): MonitorAlert[] }
  settings?: FileSettings
}
```

#### Implementation: Environment Snapshot

Add at the end of `handleGetContext()`, before the return:

```typescript
// Environment snapshot (lazy — only computed when requested)
if (params.include_environment !== false) {
  const env: NonNullable<GetContextResult['environment']> = {
    liveSessions: [],
    costToday: { totalUsd: 0, inputTokens: 0, outputTokens: 0 },
    recentTools: [],
    alerts: [],
    configIssues: [],
  }

  // Live sessions (filtered to current project)
  if (deps.liveMonitor) {
    env.liveSessions = deps.liveMonitor.getSessions()
      .filter(s => s.project === projectName || s.cwd === params.cwd)
      .map(s => ({
        source: s.source,
        project: s.project,
        currentActivity: s.currentActivity,
        model: s.model,
        activityLevel: s.activityLevel,
      }))
  }

  // Today's cost
  try {
    const costResult = handleGetCosts(db, {
      group_by: 'model',
      since: new Date().toISOString().slice(0, 10) + 'T00:00:00Z',
    })
    env.costToday = {
      totalUsd: costResult.totalCostUsd,
      inputTokens: costResult.totalInputTokens,
      outputTokens: costResult.totalOutputTokens,
    }
  } catch (e: any) {
    // Only silence "no such table" errors; log everything else
    if (!e.message?.includes('no such table')) {
      console.error('[get_context] environment query failed:', e.message)
    }
  }

  // Recent tools for this project
  try {
    const toolResult = handleToolAnalytics(db, {
      project: projectName,
      since: new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString(),
      group_by: 'tool',
    })
    env.recentTools = toolResult.tools.slice(0, 10).map((t: any) => ({
      name: t.toolName || t.tool_name || t.name,
      callCount: t.callCount || t.call_count || 0,
    }))
  } catch (e: any) {
    // Only silence "no such table" errors; log everything else
    if (!e.message?.includes('no such table')) {
      console.error('[get_context] environment query failed:', e.message)
    }
  }

  // Active alerts
  if (deps.backgroundMonitor) {
    env.alerts = deps.backgroundMonitor.getAlerts()
      .filter(a => !a.dismissed)
      .slice(0, 5)
      .map(a => ({ category: a.category, severity: a.severity, title: a.title }))
  }

  // Config issues
  if (deps.settings) {
    if (!deps.settings.aiApiKey) env.configIssues.push('No AI API key configured — auto-summary disabled')
    if (deps.settings.viking?.enabled && !deps.viking) env.configIssues.push('OpenViking enabled but unreachable')
  }

  result.environment = env
}
```

#### Contextual Text Appendix

When environment data is present, append a brief summary to `contextText` (within token budget):

```typescript
if (result.environment) {
  const envLines: string[] = []
  if (env.liveSessions.length > 0) {
    envLines.push(`活跃会话: ${env.liveSessions.map(s => `${s.source}${s.currentActivity ? ' (' + s.currentActivity + ')' : ''}`).join(', ')}`)
  }
  if (env.costToday.totalUsd > 0) {
    envLines.push(`今日费用: $${env.costToday.totalUsd.toFixed(2)}`)
  }
  if (env.alerts.length > 0) {
    envLines.push(`告警: ${env.alerts.map(a => a.title).join('; ')}`)
  }
  if (envLines.length > 0) {
    const envSection = '\n--- 环境状态 ---\n' + envLines.join('\n')
    if (totalChars + envSection.length <= maxChars) {
      contextParts.push(envSection)
    }
  }
}
```

#### Verification

1. Call `get_context` with `include_environment: true` — confirm environment fields populated
2. Call with `include_environment: false` — confirm no environment data
3. Check token budget is respected (environment section doesn't push over `max_tokens`)
4. Verify live sessions are filtered to the current project
5. Verify configIssues correctly detects missing API key

---

### 6. Usage UI (Menu Bar Quota Bars)

**Summary**: `IndexerProcess.usageData` is already populated by daemon events but only consumed by `PopoverUsageSection`. Upgrade the menu bar status item to show a compact usage indicator (highest quota percentage) alongside the session count, and ensure the popover usage section is more prominent.

**Necessity**: Medium — users need at-a-glance quota visibility to avoid hitting rate limits.
**Feasibility**: High — data pipeline already exists, just needs UI consumption.
**Effort**: Medium (2 hours)

#### Files to Modify

| File | Changes |
|------|---------|
| `macos/Engram/MenuBarController.swift` | Lines 288-302: enhance `updateBadge()` to include usage % |
| `macos/Engram/Views/PopoverView.swift` | Line 25: reorder usage section higher in the view hierarchy |
| `macos/Engram/Core/IndexerProcess.swift` | No changes needed — `usageData` is already `@Published` (see type below) |
| `macos/Engram/Views/Usage/PopoverUsageSection.swift` | Minor: add color-coded alert when any source > 80% |

#### usageData type reference

```swift
// IndexerProcess.usageData type:
// [UsageItem] where UsageItem has: metric (String), value (Double 0-100), source (String)
// value is always a percentage (0-100), not raw token count.
// Example: UsageItem(metric: "daily_tokens", value: 73.5, source: "claude-code")
// The menu bar and popover consume this to show quota bars and alert thresholds.
```

#### Menu Bar Badge Enhancement

Currently `updateBadge()` (line 288) shows `" {total} ● {liveCount}"`. Enhance to include highest usage %:

```swift
private func updateBadge() {
    let total = indexer.totalSessions

    // Find highest usage percentage across all sources
    let maxUsage = indexer.usageData.map(\.value).max() ?? 0

    Task {
        do {
            let response: LiveSessionsResponse = try await daemonClient.fetch("/api/live")
            let live = response.sessions.filter { $0.activityLevel == "active" }

            var parts: [String] = []
            if total > 0 { parts.append("\(total)") }

            // Usage indicator: show when any source is > 50%
            if maxUsage > 50 {
                let usageStr = "\(Int(maxUsage))%"
                parts.append(usageStr)
            }

            if !live.isEmpty {
                parts.append("\u{25CF} \(live.count)")
            }

            self.statusItem.button?.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")

            // Color the menu bar icon based on usage severity
            if maxUsage > 80 {
                self.statusItem.button?.contentTintColor = .systemRed
            } else if maxUsage > 50 {
                self.statusItem.button?.contentTintColor = .systemOrange
            } else {
                self.statusItem.button?.contentTintColor = nil  // default template tint
            }
        } catch {
            self.statusItem.button?.title = total > 0 ? " \(total)" : ""
            self.statusItem.button?.contentTintColor = nil
        }
    }
}
```

#### PopoverView Reordering

Move the `PopoverUsageSection` above the timeline (currently at line 25, between timeline and footer). Move it to after `healthSummary` (after line 23):

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 12) {
        headerSection
        statsSection
        healthSummary
        // Usage section promoted — now visible without scrolling
        if !indexer.usageData.isEmpty {
            Divider()
            PopoverUsageSection(usageData: indexer.usageData)
                .padding(.horizontal, 12)
        }
        Divider()
        timelineSection
        footerSection
    }
    // ...
}
```

#### PopoverUsageSection Alert Enhancement

Add an alert banner when any metric exceeds 80%:

```swift
// At the top of the body, before the USAGE header:
let criticalItems = usageData.filter { $0.value > 80 }
if !criticalItems.isEmpty {
    HStack(spacing: 4) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.system(size: 10))
        Text("\(criticalItems.count) quota\(criticalItems.count > 1 ? "s" : "") > 80%")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.red)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.red.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 4))
}
```

#### Verification

1. Configure usage probe sources (Claude, Codex)
2. Confirm menu bar shows usage % when any source exceeds 50%
3. Confirm menu bar icon tints red when any source exceeds 80%
4. Confirm popover shows usage section prominently above timeline
5. Confirm critical alert banner appears for >80% usage

---

### 7. Session Resume Improvements

**Summary**: Three issues: (a) Ghostty terminal launch is a no-op (just activates the app), (b) CLI `resume.ts` is not wired into the npm scripts, (c) only 3 sources support resume. Fix all three.

**Necessity**: Medium — resume is a key workflow feature, and Ghostty is increasingly popular.
**Feasibility**: High for Ghostty (it has a CLI `ghostty`); High for CLI wiring; Medium for extending sources.
**Effort**: Medium (2-3 hours)

#### Files to Modify

| File | Changes |
|------|---------|
| `macos/Engram/Views/Resume/TerminalLauncher.swift` | Lines 42-47: implement Ghostty via its CLI `--command` flag |
| `src/core/resume-coordinator.ts` | Lines 24-59: add more source mappings, fix Ghostty detection |
| `src/cli/resume.ts` | Lines 55-68: improve session matching (use project filter in API call) |
| `package.json` | Add `"resume"` script entry |

#### Fix: Ghostty Terminal Launch

Ghostty supports a `--command` or `-e` flag to run a command in a new window. Update `TerminalLauncher.swift`:

```swift
static func launch(command: String, args: [String], cwd: String, terminal: TerminalType) {
    let safeCwd = escapeForAppleScript(cwd)
    let safeCmd = ([command] + args).map { escapeForAppleScript($0) }.joined(separator: " ")

    // Ghostty: use CLI directly (no AppleScript support)
    if terminal == .ghostty {
        launchGhostty(command: safeCmd, cwd: cwd)
        return
    }

    let script: String
    switch terminal {
    case .terminal:
        // ... existing ...
    case .iterm:
        // ... existing ...
    case .ghostty:
        return  // handled above
    }
    // ... existing AppleScript execution ...
}

private static func launchGhostty(command: String, cwd: String) {
    let ghosttyPath = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
    let fullCmd = "cd \"\(cwd)\" && \(command)"
    if FileManager.default.fileExists(atPath: ghosttyPath) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ghosttyPath)
        proc.arguments = ["-e", "/bin/zsh", "-c", fullCmd]
        try? proc.run()
    } else {
        // Fallback: just open Ghostty
        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-a", "Ghostty"])
    }
}
```

#### resume-coordinator.ts: Extended Source Support

Add more sources (lines 25-35):

```typescript
const toolMap: Record<string, string> = {
  'claude-code': 'claude',
  'codex': 'codex',
  'gemini-cli': 'gemini',
  'aider': 'aider',
  'opencode': 'opencode',
}
```

For sources without `--resume` (cursor, vscode, windsurf), improve the fallback:

```typescript
case 'cursor':
  return { tool: 'cursor', command: 'cursor', args: [cwd], cwd }
case 'windsurf':
  return { tool: 'windsurf', command: 'windsurf', args: [cwd], cwd }
case 'vscode':
  return { tool: 'code', command: 'code', args: [cwd], cwd }
case 'aider': {
  const tool = detectTool(source)
  if (!tool) return { error: 'Aider CLI not found', hint: 'Install: pip install aider-chat' }
  return { tool: 'aider', command: tool.path, args: [], cwd }
}
```

#### CLI resume.ts: Better Project Matching

The current CLI (line 56) fetches `/api/sessions?limit=10` without filtering by project, then filters client-side. Improve by using the `project` query param:

```typescript
const url = `${baseUrl}/api/sessions?limit=20&project=${encodeURIComponent(project)}`
```

#### package.json: Add resume script

```json
{
  "scripts": {
    "resume": "node dist/cli/resume.js"
  }
}
```

#### Verification

1. Install Ghostty, select it in Resume dialog, click Resume — confirm new Ghostty window opens with the correct `cd && claude --resume` command
2. Test with Ghostty not installed — confirm graceful fallback (just opens Ghostty or shows error)
3. Test `npm run resume` from a project directory — confirm session list appears
4. Test resume for cursor source — confirm `cursor <cwd>` is launched
5. Verify iTerm and Terminal still work correctly (regression test)

---

### 8. SessionCard Context Menu

**Summary**: The `SessionTableView` already has a basic context menu (Rename, Delete) on `TableRow`. Extend it with: Resume, Open CWD in Finder, Reveal Log File, Copy Session ID, and Filter by Project. Also add the same menu to `SessionCard` for the popover/card-based views.

**Necessity**: Medium — right-click workflows are expected in macOS apps; currently missing key actions.
**Feasibility**: High — SwiftUI `.contextMenu` is straightforward.
**Effort**: Low (1-2 hours)

#### Files to Modify

| File | Changes |
|------|---------|
| `macos/Engram/Views/SessionList/SessionTableView.swift` | Lines 87-93: expand context menu |
| `macos/Engram/Components/SessionCard.swift` | Lines 8-48: add `.contextMenu` modifier |
| `macos/Engram/Views/SessionListView.swift` | Add callbacks for new context menu actions |

#### New: SessionContextMenu (Shared Component)

Create a reusable view builder to avoid duplicating menu items between `SessionTableView` and `SessionCard`:

```swift
// New file: macos/Engram/Components/SessionContextMenu.swift

import SwiftUI
import AppKit

struct SessionContextMenu: View {
    let session: Session
    var onRename: ((Session) -> Void)? = nil
    var onDelete: ((String) -> Void)? = nil
    var onResume: ((Session) -> Void)? = nil
    var onFilterProject: ((String) -> Void)? = nil

    var body: some View {
        // Resume session
        if ["claude-code", "codex", "gemini-cli"].contains(session.source) {
            Button {
                onResume?(session)
            } label: {
                Label("Resume Session", systemImage: "play.circle")
            }
            Divider()
        }

        // File system actions
        Button {
            if !session.cwd.isEmpty {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
            }
        } label: {
            Label("Open Working Directory", systemImage: "folder")
        }
        .disabled(session.cwd.isEmpty)

        Button {
            if !session.filePath.isEmpty {
                NSWorkspace.shared.selectFile(session.filePath, inFileViewerRootedAtPath: "")
            }
        } label: {
            Label("Reveal Log File", systemImage: "doc.text.magnifyingglass")
        }
        .disabled(session.filePath.isEmpty)

        Divider()

        // Copy actions
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.id, forType: .string)
        } label: {
            Label("Copy Session ID", systemImage: "doc.on.doc")
        }

        if let project = session.project {
            Button {
                onFilterProject?(project)
            } label: {
                Label("Filter by \"\(project)\"", systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        Divider()

        // Existing actions
        Button { onRename?(session) } label: {
            Label("Rename...", systemImage: "pencil")
        }

        Button(role: .destructive) { onDelete?(session.id) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
```

#### SessionTableView Integration

Replace existing context menu (lines 87-93):

```swift
ForEach(sessions) { session in
    TableRow(session)
        .contextMenu {
            SessionContextMenu(
                session: session,
                onRename: { s in onRename?(s) },
                onDelete: { id in onDelete?(id) },
                onResume: { s in onResume?(s) },
                onFilterProject: { p in onFilterProject?(p) }
            )
        }
}
```

Add new callback props to `SessionTableView`:

```swift
var onResume: ((Session) -> Void)?
var onFilterProject: ((String) -> Void)?
```

#### SessionCard Integration

Add context menu to `SessionCard` (after line 46, before `.buttonStyle(.plain)`):

```swift
.contextMenu {
    SessionContextMenu(
        session: session,
        onResume: onResume,
        onFilterProject: onFilterProject
    )
}
```

#### SessionListView Wiring

In `SessionListView`, wire the new callbacks when creating `SessionTableView`:

```swift
SessionTableView(
    sessions: filteredSessions,
    selectedSessionId: $selectedSessionId,
    sortOrder: $sortOrder,
    columns: columnStore,
    favoriteIds: favoriteIds,
    onToggleFavorite: { id, isFav in toggleFavorite(id: id, current: isFav) },
    onDelete: { id in deleteSession(id) },
    onRename: { session in renameTarget = session; renameText = session.customName ?? session.summary ?? "" },
    onResume: { session in showResumeSheet = true; resumeSession = session },
    onFilterProject: { project in selectedProject = project }
)
```

Add state for resume sheet:

```swift
@State private var showResumeSheet = false
@State private var resumeSession: Session?
```

And the sheet modifier:

```swift
.sheet(isPresented: $showResumeSheet) {
    if let session = resumeSession {
        ResumeDialog(session: session)
    }
}
```

#### Verification

1. Right-click a session in the table — confirm all 7 menu items appear
2. Click "Open Working Directory" — confirm Finder opens to the cwd
3. Click "Reveal Log File" — confirm Finder selects the session file
4. Click "Copy Session ID" — confirm UUID is in clipboard
5. Click "Filter by {project}" — confirm project filter is applied
6. Click "Resume Session" — confirm ResumeDialog appears
7. Verify context menu also works on `SessionCard` in non-table views
8. Verify disabled states: "Open CWD" disabled when cwd is empty, "Reveal Log" disabled when filePath is empty

---

### 9. Empty State + Skeleton Loading

**Summary**: Replace bare `ProgressView()` and blank areas with reusable `EmptyStateView` variants and a proper `SkeletonView` with shimmer animation. Currently, `SkeletonRow` exists at `macos/Engram/Components/SkeletonRow.swift` and `EmptyState` exists at `macos/Engram/Components/EmptyState.swift`, but they are minimal and inconsistently applied.

**Current state analysis**:
- `SkeletonRow` has a basic shimmer (`opacity` toggle with `easeInOut` repeat animation). It is used only in `HomeView.kpiSection` as a KPI placeholder (line 73).
- `EmptyState` accepts `icon`, `title`, `message`, and an optional `action` tuple. Used in `HomeView.recentSessionsSection` (line 132) and `SearchPageView` (lines 97-99).
- `SessionListView` has no empty state for the table area — it shows nothing when `filteredSessions` is empty.
- `SearchPageView` uses `EmptyState` but wraps it with `isSearching` logic inline (lines 91-101), mixing loading/empty/results states.

#### Design: Enhanced EmptyStateView

Extend the existing `EmptyState` component with contextual variants and animation support.

```swift
// macos/Engram/Components/EmptyState.swift — enhanced
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (label: String, action: () -> Void)? = nil
    var style: EmptyStateStyle = .standard

    enum EmptyStateStyle {
        case standard       // existing: centered, muted
        case compact        // smaller, for inline use (tables, sidebars)
        case firstRun       // larger icon, more prominent CTA
    }
    // ... body switches on style for font sizes, spacing, padding
}
```

#### Design: SkeletonView with configurable shapes

Replace the single `SkeletonRow` with a composable skeleton system:

```swift
// macos/Engram/Components/SkeletonView.swift
struct SkeletonView: View {
    var layout: SkeletonLayout = .row
    @State private var shimmerPhase: CGFloat = 0

    enum SkeletonLayout {
        case row           // existing: HStack of rectangles
        case card          // session card placeholder
        case kpi           // KPI card placeholder
        case chart         // chart area placeholder
        case paragraph(lines: Int)  // multi-line text block
    }

    var body: some View {
        // layout-specific skeleton shapes
        // all share the same shimmer gradient overlay
    }
}

// Shimmer modifier — reusable across all skeleton shapes
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .white.opacity(0.15), .clear]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 300)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
```

#### Application Points

1. **HomeView** (`macos/Engram/Views/Pages/HomeView.swift`):
   - KPI section (line 62-76): Replace `SkeletonRow()` with `SkeletonView(layout: .kpi)` — 4 cards with shimmer
   - Charts section: Show `SkeletonView(layout: .chart)` when `dailyActivity.isEmpty && isLoading`
   - Recent sessions: Show `SkeletonView(layout: .card)` repeated 3 times when `isLoading`

2. **SessionListView** (`macos/Engram/Views/SessionListView.swift`):
   - When `sessions.isEmpty && !showingTrash`, show `EmptyState(icon: "bubble.left.and.bubble.right", title: "No sessions", message: "Sessions will appear after the daemon indexes your coding tools", style: .standard)` inside `detailPanel` area
   - Add `isLoading` state (currently missing) to show skeletons during initial `loadSessions()`

3. **SearchPageView** (`macos/Engram/Views/Pages/SearchPageView.swift`):
   - Replace inline `ProgressView()` + text (line 92-95) with `SkeletonView(layout: .card)` repeated 3 times
   - Keep existing `EmptyState` usage for no-results and empty-query states

#### Files to create
```
macos/Engram/Components/SkeletonView.swift   # New composable skeleton + ShimmerModifier
```

#### Files to modify
```
macos/Engram/Components/EmptyState.swift     # Add EmptyStateStyle enum
macos/Engram/Components/SkeletonRow.swift    # Deprecate (keep for compat, delegate to SkeletonView)
macos/Engram/Views/Pages/HomeView.swift      # Use SkeletonView for all loading states
macos/Engram/Views/SessionListView.swift     # Add empty state for empty table, isLoading skeleton
macos/Engram/Views/Pages/SearchPageView.swift # Replace ProgressView with SkeletonView
```

**DB changes**: None.
**API changes**: None.
**Migration**: None.
**Verification**: Launch app with no DB / empty DB. Every page should show contextual skeleton or empty state — never a blank white screen. Manually confirm shimmer animation is smooth at 60fps.

---

### 10. Onboarding (新手引导)

**Summary**: Add a 3-screen first-run onboarding flow that detects installed session sources, verifies Node.js availability, and introduces core features. Currently, the app launches directly to the menu bar with no guidance. If Node.js is missing, the daemon silently fails (line 56 of `App.swift`: `print("Warning: daemon.js not bundled...")`).

**Current state analysis**:
- `App.swift` tries to find `node` at `UserDefaults.standard.string(forKey: "nodejsPath")`, `/usr/local/bin/node`, or `/opt/homebrew/bin/node` (lines 41-47).
- If `scriptPath` is empty (daemon.js not bundled), it prints a warning and continues (line 55-57).
- No `@AppStorage("hasOnboarded")` exists anywhere.
- No source detection from Swift side — the daemon detects sources via adapters, but Swift has no visibility into this before the daemon starts.

#### Design: OnboardingView

```swift
// macos/Engram/Views/OnboardingView.swift

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    @State private var nodeStatus: NodeStatus = .checking
    @State private var detectedSources: [DetectedSource] = []

    enum NodeStatus {
        case checking
        case found(path: String, version: String)
        case notFound
    }

    struct DetectedSource: Identifiable {
        let id: String       // source name
        let name: String     // display name
        let icon: String     // SF Symbol
        let detected: Bool
        let sessionDir: String
    }

    var body: some View {
        VStack {
            TabView(selection: $currentPage) {
                welcomePage.tag(0)        // "Welcome to Engram" + brief description
                sourcesPage.tag(1)        // Detected sources grid
                readyPage.tag(2)          // Node.js status + "Get Started"
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            // Navigation dots + buttons
            HStack {
                if currentPage > 0 {
                    Button("Back") { withAnimation { currentPage -= 1 } }
                }
                Spacer()
                if currentPage < 2 {
                    Button("Next") { withAnimation { currentPage += 1 } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        UserDefaults.standard.set(true, forKey: "hasOnboarded")
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(nodeStatus == .notFound) // Warn but don't block
                }
            }
            .padding()
        }
        .frame(width: 520, height: 440)
        .task { await detectEnvironment() }
    }
}
```

**Page 1 — Welcome**:
- App icon + "Welcome to Engram"
- Three feature highlights with icons: "Aggregate sessions", "Search across tools", "Track costs"

**Page 2 — Source Detection**:
- Grid of known source directories with check/cross status
- Detection logic: check `FileManager.default.fileExists(atPath:)` for each known path:

```swift
private func detectSources() -> [DetectedSource] {
    let home = NSHomeDirectory()
    let sources: [(id: String, name: String, icon: String, dir: String)] = [
        ("claude-code", "Claude Code", "brain.head.profile", "\(home)/.claude/projects"),
        ("codex", "Codex CLI", "terminal", "\(home)/.codex/sessions"),
        ("gemini-cli", "Gemini CLI", "sparkle", "\(home)/.gemini/tmp"),
        ("cursor", "Cursor", "cursorarrow.rays", "\(home)/Library/Application Support/Cursor"),
        ("copilot", "GitHub Copilot", "chevron.left.forwardslash.chevron.right", "\(home)/.copilot"),
        ("windsurf", "Windsurf", "wind", "\(home)/.windsurf"),
        ("cline", "Cline", "waveform", "\(home)/.cline/data/tasks"),
        ("opencode", "OpenCode", "terminal.fill", "\(home)/.opencode"),
    ]
    return sources.map { s in
        DetectedSource(
            id: s.id, name: s.name, icon: s.icon,
            detected: FileManager.default.fileExists(atPath: s.dir),
            sessionDir: s.dir
        )
    }
}
```

**Page 3 — System Check**:
- Node.js detection: run `Process` with `which node` and `node --version`
- Show green checkmark or red X with "Install Node.js" link
- If daemon.js is bundled: green. If not (dev mode): yellow warning.

```swift
private func checkNode() async {
    let paths = [
        UserDefaults.standard.string(forKey: "nodejsPath"),
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node"
    ].compactMap { $0 }

    for path in paths {
        if FileManager.default.fileExists(atPath: path) {
            // Run node --version
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["--version"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try? proc.run()
            proc.waitUntilExit()
            let version = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            nodeStatus = .found(path: path, version: version)
            return
        }
    }
    nodeStatus = .notFound
}
```

#### Integration with App.swift

```swift
// In AppDelegate.applicationDidFinishLaunching:
let hasOnboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
if !hasOnboarded {
    // Show onboarding window before menu bar setup
    showOnboardingWindow()
}
// Then proceed with normal startup
```

#### Files to create
```
macos/Engram/Views/OnboardingView.swift    # 3-page onboarding flow
```

#### Files to modify
```
macos/Engram/App.swift                     # Check hasOnboarded, show OnboardingView
macos/Engram/MenuBarController.swift       # Add showOnboardingWindow() or delegate to AppDelegate
```

**DB changes**: None (uses `UserDefaults`).
**API changes**: None.
**Migration**: Existing users already have `hasOnboarded = false` (default), but since they already have data, add a heuristic: if DB exists and has > 0 sessions at app launch, auto-set `hasOnboarded = true` to skip onboarding for existing users.
**Verification**: Delete `UserDefaults` key, launch app. Three screens appear. Node.js detected. Sources detected. "Get Started" completes. Subsequent launches skip onboarding.

---

### 11. UI Anti-Flicker (UI 防闪烁)

**Summary**: During daemon indexing, `SessionListView` reloads the full session list, causing the table to flash (all rows re-render) and the selection to jump. Implement a two-phase update strategy: hold stale rows until new data is ready, then diff-apply.

**Current state analysis**:
- `SessionListView` calls `loadSessions()` which replaces the entire `sessions` array (line 270: `sessions = try db.listSessions(...)`)
- The `filteredSessions` array is then fully recomputed (line 68-77: `updateFilteredSessions()`)
- `SessionTableView` receives the new array, causing SwiftUI to diff the entire list
- `filterFingerprint` changes trigger a debounced reload (line 106-114), but even the debounce does a full replacement
- `selectedSessionId` is preserved as state, but if the selected session disappears from the list during re-index, the selection breaks
- No "data is churning" concept exists

#### Design: Event-Driven Update with Selection Stability

The daemon already emits `{ event: "indexed", indexed: N, total: M }` JSON events to stdout, and Swift `IndexerProcess` already parses these events. Instead of polling on a timer or debouncing with a hardcoded delay, use the daemon's index-complete event as the reload trigger.

```swift
// Add to SessionListView

@State private var isDatasetChurning = false
@State private var lastStableSessionIds: Set<String> = []
@State private var settleTask: Task<Void, Never>? = nil

// Listen for daemon index-complete events instead of polling
.onReceive(indexer.$lastIndexEvent) { event in
    guard let event = event else { return }
    // Cancel any pending settle timer — a new event arrived
    settleTask?.cancel()
    isDatasetChurning = true
    // Short 100ms settle timer in case multiple events fire rapidly
    // (e.g., daemon indexes several sources in quick succession)
    settleTask = Task {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        await loadAndApply()
    }
}

private func loadAndApply() async {
    let newSessions: [Session]
    do {
        newSessions = try db.listSessions(subAgent: agentFilter, limit: 2000)
    } catch {
        return
    }
    await MainActor.run {
        applyUpdate(newSessions)
        isDatasetChurning = false
    }
}

private func applyUpdate(_ newSessions: [Session]) {
    // Preserve selection
    let previousSelection = selectedSessionId

    sessions = newSessions
    updateFilteredSessions()

    // Restore selection if the session still exists
    if let prev = previousSelection, newSessions.contains(where: { $0.id == prev }) {
        selectedSessionId = prev
    }

    lastStableSessionIds = Set(newSessions.map(\.id))
}
```

**Why event-driven instead of debouncing**:
- The daemon knows exactly when indexing completes — no need to guess with a timer
- The 100ms settle timer handles the edge case of rapid-fire events (multiple sources indexed within milliseconds)
- No hardcoded delays that feel sluggish on fast machines or too short on slow ones
- `IndexerProcess` already publishes daemon events; adding `@Published var lastIndexEvent` is a one-line change

**IndexerProcess change** — add published property:
```swift
// In IndexerProcess, add:
@Published var lastIndexEvent: DaemonEvent? = nil

// In handleEvent(), when event.event == "indexed":
case "indexed":
    lastIndexEvent = event
```

**Selection stability policy**:
1. If `selectedSessionId` still exists in new data: keep it selected
2. If `selectedSessionId` was removed (hidden/deleted): clear selection
3. During churn (`isDatasetChurning = true`): show a subtle overlay indicator ("Updating...") on the table header but don't replace rows until settled

**Visual indicator during churn**:
```swift
// In sidebarPanel, above SessionTableView:
if isDatasetChurning {
    HStack(spacing: 4) {
        ProgressView().controlSize(.mini)
        Text("Updating...")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 2)
    .transition(.opacity)
}
```

#### Files to modify
```
macos/Engram/Views/SessionListView.swift   # Replace loadSessions() with loadSessionsSmooth(), add churn detection
```

**DB changes**: None.
**API changes**: None.
**Migration**: None.
**Verification**: Start daemon indexing with a large dataset. Watch SessionListView — the table should not flash. Selection should remain stable during re-indexing. Manually delete a session while selected — selection should clear gracefully.

---

### 12. Image Handling (图片处理)

**Summary**: Claude Code session files contain `type: "image"` content blocks (base64 screenshots, uploaded images). These are currently silently dropped by both the TypeScript adapter and the Swift parser. Phase 1 adds placeholder text; Phase 2 adds inline thumbnail rendering.

**Current state analysis**:

TypeScript side (`src/adapters/claude-code.ts`):
- `extractContent()` (line 251-275) iterates content arrays. It handles `type === 'text'`, `type === 'thinking'`, `type === 'tool_use'`, and `type === 'tool_result'`. There is no case for `type === 'image'` — these items are simply skipped.

Swift side (`macos/Engram/Core/MessageParser.swift`):
- `extractMessageContent()` (line 297-316) handles `type == "text"` and `type == "thinking"` in content arrays. `type == "image"` items are ignored.

Claude Code session format for images:
```json
{
  "type": "image",
  "source": {
    "type": "base64",
    "media_type": "image/png",
    "data": "iVBORw0KGgo..."
  }
}
```

#### Phase 1: Placeholder Text

**TypeScript adapter change** (`src/adapters/claude-code.ts`):
```typescript
// In extractContent(), add after the tool_result case:
} else if (c.type === 'image') {
  const source = c.source as Record<string, unknown> | undefined
  const mediaType = (source?.media_type as string) || 'image/*'
  const dataLen = typeof source?.data === 'string' ? (source.data as string).length : 0
  const sizeKB = Math.round(dataLen * 0.75 / 1024) // base64 -> bytes
  parts.push(`[Image: ${mediaType}, ~${sizeKB}KB]`)
}
```

**Swift parser change** (`macos/Engram/Core/MessageParser.swift`):
```swift
// In extractMessageContent(), add after the thinking case:
} else if item["type"] as? String == "image" {
    if let source = item["source"] as? [String: Any] {
        let mediaType = source["media_type"] as? String ?? "image/*"
        let dataLen = (source["data"] as? String)?.count ?? 0
        let sizeKB = dataLen * 3 / 4 / 1024
        texts.append("[Image: \(mediaType), ~\(sizeKB)KB]")
    } else {
        texts.append("[Image]")
    }
}
```

#### Phase 2: Inline Thumbnails

Add image data extraction and thumbnail rendering in the transcript.

**New model** — extend `ChatMessage`:
```swift
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    let systemCategory: SystemCategory
    var imageAttachments: [ImageAttachment] = []  // NEW

    var isSystem: Bool { systemCategory != .none }
}

struct ImageAttachment: Identifiable {
    let id = UUID()
    let mediaType: String      // always "image/jpeg" for thumbnails
    let thumbnailData: Data?   // resized JPEG data (max 400px wide), nil if decode failed
    let sizeBytes: Int         // original image size estimated from base64 length

    var nsImage: NSImage? {
        guard let data = thumbnailData else { return nil }
        return NSImage(data: data)
    }
}
```

**Swift parser change** for Phase 2:
```swift
// In parseTypeMessageFormat, after building ChatMessage:
var imageAttachments: [ImageAttachment] = []
if let arr = msg["content"] as? [[String: Any]] {
    for item in arr where item["type"] as? String == "image" {
        if let source = item["source"] as? [String: Any],
           let data = source["data"] as? String {
            let mediaType = source["media_type"] as? String ?? "image/png"
            let originalSize = data.count * 3 / 4
            // Decode full base64 → resize → re-encode as JPEG for display.
            // Do NOT truncate raw base64 — cutting at an arbitrary character
            // boundary corrupts the image (invalid padding, partial pixel data).
            //
            // Memory note: A 4K PNG screenshot is ~5-8MB base64, which decodes to
            // ~30-50MB in memory (base64 String + decoded Data + NSImage bitmap).
            // If a session has 10+ images, the loop must ensure intermediate objects
            // are released promptly. Use autoreleasepool (ObjC bridging) or scoped
            // locals to prevent ARC from deferring deallocation across iterations.
            let thumbnailData: Data? = autoreleasepool {
                guard let rawData = Data(base64Encoded: data),
                      let nsImage = NSImage(data: rawData) else { return nil }
                let resized = nsImage.resize(maxWidth: 400)
                return resized.jpegData(compressionQuality: 0.7)
                // rawData, nsImage, resized all deallocated here at end of autoreleasepool
            }
            imageAttachments.append(ImageAttachment(
                mediaType: "image/jpeg",
                thumbnailData: thumbnailData,
                sizeBytes: originalSize
            ))
        }
    }
}
// Attach to ChatMessage
```

**NSImage resize helper** (add as extension):
```swift
extension NSImage {
    func resize(maxWidth: CGFloat) -> NSImage {
        let ratio = maxWidth / size.width
        guard ratio < 1 else { return self }  // already small enough
        let newSize = NSSize(width: size.width * ratio, height: size.height * ratio)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
```

**Transcript rendering** (`ColorBarMessageView.swift`):
```swift
// After the text content, render image thumbnails:
if !indexed.message.imageAttachments.isEmpty {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            ForEach(indexed.message.imageAttachments) { img in
                if let nsImage = img.nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.3))
                        )
                } else {
                    // Fallback for corrupted/truncated data
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 80, height: 60)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        )
                }
            }
        }
    }
    .frame(maxHeight: 130)
}
```

**Memory safety**: Base64 image data in session files can be megabytes. The decode-resize-discard pipeline ensures peak memory is limited to one full decoded image at a time; the retained thumbnail is a small JPEG (~10-30KB at 400px width). For the TypeScript side, we only emit the placeholder text, never the binary data. Full-resolution viewing could be added later via a popover that re-reads the source file on demand.

#### Files to modify
```
src/adapters/claude-code.ts                    # Phase 1: image placeholder in extractContent()
macos/Engram/Core/MessageParser.swift          # Phase 1: image placeholder; Phase 2: ImageAttachment extraction
macos/Engram/Views/Transcript/ColorBarMessageView.swift  # Phase 2: inline thumbnail rendering
```

#### Files to create (Phase 2 only)
```
macos/Engram/Models/ImageAttachment.swift      # ImageAttachment struct (could also be in ChatMessage file)
```

**DB changes**: None (images are in-memory only, parsed from source files).
**API changes**: None.
**Migration**: None.
**Verification**: Find a Claude Code session with screenshot uploads. Phase 1: see `[Image: image/png, ~45KB]` in transcript. Phase 2: see inline thumbnail. Verify memory stays stable with sessions containing 10+ large images.

---

### 13. Keyboard Shortcuts (键盘快捷键)

**Summary**: Add comprehensive keyboard navigation: Cmd+1-5 for sidebar pages, Ctrl+Cmd+R for session resume, Cmd+Shift+O to open session CWD in Finder, and more.

**Current state analysis**:
- `MainWindowView` has `.keyboardShortcut("k", modifiers: .command)` on the palette trigger (line 65)
- Hidden buttons in `SessionDetailView` (lines 186-199): Cmd+F (find), Cmd+G (next match), Cmd+Shift+G (prev match), Cmd+Option+C (copy all), Esc (close find)
- `MenuBarController` sets up `NSMenu` with standard shortcuts (Cmd+Q quit, Cmd+, settings, Cmd+W close) in `setupMainMenu()` (lines 320-355)
- `SidebarView` has no keyboard shortcut bindings
- `Screen` enum defines sections: Overview (home, search), Monitor (sessions, timeline, activity), Workspace (projects, sourcePulse, repos, workGraph), Config (skills, agents, memory, hooks)

#### Design: Keyboard Shortcut Map

| Shortcut | Action | Scope |
|----------|--------|-------|
| Cmd+1 | Go to Home | Main window |
| Cmd+2 | Go to Sessions | Main window |
| Cmd+3 | Go to Search | Main window |
| Cmd+4 | Go to Timeline | Main window |
| Cmd+5 | Go to Activity | Main window |
| Cmd+K | Command Palette | Main window (existing) |
| Cmd+, | Settings | Global (existing) |
| Cmd+R | Refresh/Re-index | Main window |
| Ctrl+Cmd+R | Resume selected session | Session detail |
| Cmd+Shift+O | Open session CWD in Finder | Session detail |
| Cmd+Shift+T | Open session CWD in Terminal | Session detail |
| Cmd+Shift+C | Copy session ID | Session detail |
| Cmd+F | Find in transcript | Session detail (existing) |
| Cmd+Option+C | Copy all transcript | Session detail (existing) |

#### Implementation: Menu bar registration

Add a "Navigate" menu to `setupMainMenu()` in `MenuBarController.swift`:

```swift
// In setupMainMenu():
let navMenu = NSMenu(title: String(localized: "Navigate"))
let navScreens: [(Screen, String)] = [
    (.home, "1"), (.sessions, "2"), (.search, "3"),
    (.timeline, "4"), (.activity, "5")
]
for (screen, key) in navScreens {
    let item = NSMenuItem(
        title: String(localized: "Go to \(screen.title)"),
        action: #selector(handleNavShortcut(_:)),
        keyEquivalent: key
    )
    item.tag = Screen.allCases.firstIndex(of: screen) ?? 0
    item.target = self
    navMenu.addItem(item)
}
navMenu.addItem(.separator())
let refreshItem = NSMenuItem(
    title: String(localized: "Refresh Index"),
    action: #selector(handleRefresh),
    keyEquivalent: "r"
)
refreshItem.target = self
navMenu.addItem(refreshItem)

let navMenuItem = NSMenuItem()
navMenuItem.submenu = navMenu
mainMenu.addItem(navMenuItem)
```

#### Implementation: Navigation via Notification

```swift
// New notification name
extension Notification.Name {
    static let navigateToScreen = Notification.Name("navigateToScreen")
}

// MenuBarController:
@objc private func handleNavShortcut(_ sender: NSMenuItem) {
    let screenIndex = sender.tag
    guard screenIndex < Screen.allCases.count else { return }
    let screen = Screen.allCases[screenIndex]
    NotificationCenter.default.post(name: .navigateToScreen, object: screen)
}

// MainWindowView:
.onReceive(NotificationCenter.default.publisher(for: .navigateToScreen)) { notification in
    if let screen = notification.object as? Screen {
        selectedScreen = screen
    }
}
```

#### Implementation: Session-specific shortcuts

In `SessionDetailView`, add hidden buttons:

```swift
.background {
    Group {
        // Existing shortcuts...

        // Ctrl+Cmd+R: Resume
        Button("") { showResume = true }
            .keyboardShortcut("r", modifiers: [.control, .command])

        // Cmd+Shift+O: Open in Finder
        Button("") { openInFinder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])

        // Cmd+Shift+T: Open in Terminal
        Button("") { openInTerminal() }
            .keyboardShortcut("t", modifiers: [.command, .shift])

        // Cmd+Shift+C: Copy session ID
        Button("") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.id, forType: .string)
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
    }
    .frame(width: 0, height: 0)
    .opacity(0)
}

private func openInFinder() {
    guard let cwd = session.cwd, !cwd.isEmpty else { return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
}

private func openInTerminal() {
    guard let cwd = session.cwd, !cwd.isEmpty else { return }
    let safeCwd = TerminalLauncher.escapeForAppleScript(cwd)
    let script = "tell application \"Terminal\" to do script \"cd \(safeCwd)\""
    if let appleScript = NSAppleScript(source: script) {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}
```

#### Files to modify
```
macos/Engram/MenuBarController.swift        # Add Navigate menu with Cmd+1-5, Cmd+R
macos/Engram/Views/MainWindowView.swift     # Listen for .navigateToScreen notification
macos/Engram/Views/SessionDetailView.swift  # Add resume, open in Finder/Terminal shortcuts
```

**DB changes**: None.
**API changes**: None.
**Migration**: None.
**Verification**: Open main window. Press Cmd+1 through Cmd+5 — sidebar selection changes. Cmd+K opens palette. Select a session, press Cmd+Shift+O — Finder opens at CWD. Cmd+Shift+T opens Terminal at CWD.

---

### 14. Cost Budget Alerts (成本预算告警)

**Summary**: Add configurable daily/monthly budget thresholds with in-app alert banners in the popover. The `BackgroundMonitor` already implements `checkDailyCost()` and emits alerts. This feature extends it with monthly budgets and adds Swift UI for displaying alerts.

**Current state analysis**:

Node side:
- `BackgroundMonitor` exists at `src/core/monitor.ts` with `checkDailyCost()` (line 83-113) that queries `session_costs` and creates alerts when daily spend exceeds `config.dailyCostBudget`.
- `MonitorConfig` in `src/core/config.ts` (lines 27-33) has `dailyCostBudget`, `longSessionMinutes`, but no `monthlyCostBudget`.
- Alerts are emitted as `{ event: 'alert', alert: {...} }` JSON events to stdout (daemon.ts line 213).

Swift side:
- `IndexerProcess` handles daemon events but does not parse `alert` events.
- `PopoverView` has no alert display.
- An `AlertBanner` component is used in `HomeView` (line 22-23) but is never populated.

#### Design: Config schema extension

```typescript
// In src/core/config.ts — extend MonitorConfig:
export interface MonitorConfig {
  enabled: boolean
  dailyCostBudget?: number          // USD, default 20
  monthlyCostBudget?: number        // USD, default 500 (NEW)
  longSessionMinutes?: number       // default 180
  notifyOnCostThreshold?: boolean   // default true
  notifyOnLongSession?: boolean     // default true
}
```

#### Design: Monthly cost check

```typescript
// In src/core/monitor.ts — new method:
private async checkMonthlyCost(): Promise<void> {
  const budget = this.config.monthlyCostBudget ?? 500
  try {
    const row = this.db.getRawDb().prepare(`
      SELECT COALESCE(SUM(c.cost_usd), 0) as totalCost
      FROM session_costs c
      JOIN sessions s ON c.session_id = s.id
      WHERE s.start_time >= date('now', 'start of month')
    `).get() as { totalCost: number } | undefined

    const totalCost = row?.totalCost ?? 0
    if (totalCost > budget) {
      const existingThisMonth = this.alerts.find(
        a => a.category === 'cost_threshold'
          && a.detail.includes('monthly')
          && a.timestamp.startsWith(new Date().toISOString().slice(0, 7))
      )
      if (!existingThisMonth) {
        const alert: MonitorAlert = {
          id: randomUUID(),
          category: 'cost_threshold',
          severity: totalCost > budget * 1.5 ? 'critical' : 'warning',
          title: `Monthly cost exceeded $${budget}`,
          detail: `Monthly spend: $${totalCost.toFixed(2)} (budget: $${budget})`,
          timestamp: new Date().toISOString(),
          dismissed: false,
        }
        this.alerts.push(alert)
        this.onAlert?.(alert)
      }
    }
  } catch { /* session_costs table may not exist yet */ }
}

// Add to check():
async check(): Promise<void> {
  // ... existing eviction logic ...
  await this.checkDailyCost()
  await this.checkMonthlyCost()  // NEW
  await this.checkUnpushedCommits()
  this.checkLongSessions()
  // ... cap logic ...
}
```

#### Design: Swift alert display

```swift
// In IndexerProcess.swift — parse alert events:
private func handleEvent(_ event: DaemonEvent) {
    switch event.event {
    // ... existing cases ...
    case "alert":
        // Parse alert from raw JSON
        break
    default:
        break
    }
}

// Extended DaemonEvent:
struct DaemonEvent: Decodable {
    // ... existing fields ...
    let alert: AlertPayload?
}

struct AlertPayload: Decodable {
    let id: String
    let category: String
    let severity: String
    let title: String
    let detail: String
    let timestamp: String
}
```

Add alert publishing to `IndexerProcess`:
```swift
@Published var activeAlerts: [AlertPayload] = []
```

**PopoverView alert banner**:
```swift
// In PopoverView, add after headerSection:
if !indexer.activeAlerts.isEmpty {
    VStack(spacing: 4) {
        ForEach(indexer.activeAlerts.prefix(3), id: \.id) { alert in
            HStack(spacing: 6) {
                Image(systemName: alert.severity == "critical"
                    ? "exclamationmark.triangle.fill"
                    : "exclamationmark.circle.fill")
                    .foregroundStyle(alert.severity == "critical" ? .red : .orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.title)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(alert.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismissAlert(id: alert.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(
                (alert.severity == "critical" ? Color.red : Color.orange)
                    .opacity(0.1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
```

**Web API**: Existing `GET /api/monitor/alerts` already exposes alerts. Add dismiss endpoint: `POST /api/monitor/alerts/:id/dismiss`.

**Settings UI** — Add to `GeneralSettingsSection` or a new `MonitorSettingsSection`:
```swift
Section("Budget Alerts") {
    Toggle("Enable budget alerts", isOn: $budgetAlertsEnabled)
    if budgetAlertsEnabled {
        HStack {
            Text("Daily budget")
            Spacer()
            TextField("", value: $dailyBudget, format: .currency(code: "USD"))
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
        }
        HStack {
            Text("Monthly budget")
            Spacer()
            TextField("", value: $monthlyBudget, format: .currency(code: "USD"))
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
        }
    }
}
```

#### Files to modify
```
src/core/config.ts                            # Add monthlyCostBudget to MonitorConfig
src/core/monitor.ts                           # Add checkMonthlyCost(), call in check()
macos/Engram/Core/IndexerProcess.swift        # Parse alert events, publish activeAlerts
macos/Engram/Views/PopoverView.swift          # Alert banner display
macos/Engram/Views/Pages/HomeView.swift       # Wire alertMessage from activeAlerts
macos/Engram/Views/Settings/GeneralSettingsSection.swift  # Budget config UI
```

**DB changes**: None (relies on existing `session_costs` table).
**API changes**: `POST /api/monitor/alerts/:id/dismiss` (new endpoint).
**Migration**: None.
**Verification**: Set `dailyCostBudget: 0.01` in settings.json. Wait for monitor cycle (or trigger via API). Alert appears in popover. Dismiss works. Monthly budget same test with `monthlyCostBudget: 0.01`.

---

### 15. Battery/Visibility-Aware Polling (电池/可见性感知轮询)

**Summary**: Reduce daemon polling frequency when macOS is on battery power or the app is not visible, to save energy and reduce disk I/O.

> **ROI note**: This feature has low ROI for the primary development setup (Mac Mini M2, always on AC power, no battery). The design below is intentionally simplified. Skip this unless targeting laptop users.

**Current state analysis**:

Daemon polling intervals (`src/daemon.ts`):
- Live session scan: 5s (line 208: `liveMonitor.start(5000)`)
- Background monitor: 600s / 10min (line 216: `backgroundMonitor.start(600_000)`)
- Periodic re-scan (non-watchable sources): 600s / 10min (line 221: `const RESCAN_INTERVAL = 10 * 60 * 1000`)
- Sync engine: configurable, min 1min (line 241)
- Badge update: 10s (MenuBarController line 64: `badgeTimer = Timer.scheduledTimer(withTimeInterval: 10, ...)`)

Watcher (`src/core/watcher.ts`):
- chokidar with `awaitWriteFinish: { stabilityThreshold: 2000, pollInterval: 500 }` (line 50-51)
- This is event-driven (inotify/FSEvents), not polling, so it is already efficient

Key insight: The daemon runs as a Node.js child process of the Swift app. Rather than building an HTTP-based hot-reconfiguration system (too complex for the benefit), the daemon can check power state once on startup and adjust base intervals accordingly.

#### Design: Simplified startup-time power check

Instead of a full `PowerAwareScheduler` with IOKit observers, HTTP POST endpoints, and hot-reconfiguration of timers, use a simple one-shot approach:

**Daemon side** — check `pmset -g batt` once on startup:

```typescript
// In src/daemon.ts, before starting monitors:
import { execFileSync } from 'child_process'

function isOnBattery(): boolean {
  if (process.platform !== 'darwin') return false
  try {
    const output = execFileSync('pmset', ['-g', 'batt'], { encoding: 'utf-8', timeout: 3000 })
    return output.includes("'Battery Power'")
  } catch {
    return false
  }
}

// Alternatively, check an environment variable set by the Swift app:
// const batteryMode = process.env.ENGRAM_POWER_MODE === 'battery'

const batteryMode = isOnBattery()
const pollingMultiplier = batteryMode ? 2 : 1

// Apply multiplier to base intervals
liveMonitor.start(5000 * pollingMultiplier)
backgroundMonitor.start(600_000 * pollingMultiplier)
const RESCAN_INTERVAL = 10 * 60 * 1000 * pollingMultiplier

if (batteryMode) {
  emit({ event: 'config', message: 'Battery mode detected — polling intervals doubled' })
}
```

**Swift side** — set environment variable before launching daemon:

```swift
// In IndexerProcess, when configuring the daemon Process:
let isOnBattery = ProcessInfo.processInfo.isLowPowerModeEnabled
process.environment?["ENGRAM_POWER_MODE"] = isOnBattery ? "battery" : "ac"
```

**Visibility** — the Swift badge timer can simply check whether any window is visible:

```swift
// In MenuBarController, adjust badge timer based on window visibility:
// If no windows are key/visible, reduce badge update frequency
let badgeInterval: TimeInterval = NSApp.keyWindow != nil ? 10 : 30
```

No hot-reconfiguration of daemon timers is needed. If the power state changes mid-session, the daemon continues at the startup-configured rate. The impact of running at 5s vs 10s polling is negligible compared to the complexity of a full reactive system.

#### Files to modify
```
src/daemon.ts                                 # One-shot pmset check, apply multiplier to intervals
macos/Engram/Core/IndexerProcess.swift        # Set ENGRAM_POWER_MODE env var
macos/Engram/MenuBarController.swift          # Adjust badgeTimer based on window visibility
```

**DB changes**: None.
**API changes**: None (no HTTP endpoint needed).
**Migration**: None.
**Verification**: On a MacBook, run `pmset -g batt` to confirm battery detection works. Start daemon on battery — confirm log shows "Battery mode detected." Confirm live scan interval is 10s instead of 5s. On a Mac Mini (always AC), confirm normal intervals are used.

---

### 16. Transcript Enhancement (Transcript 增强)

**Summary**: Extend the message type system to recognize semantic subtypes (tool call, tool result, thinking, code block, diff), add line numbers to code blocks, and enable "Open in IDE" jumps from file paths.

**Current state analysis**:

`MessageTypeClassifier` at `macos/Engram/Models/MessageTypeClassifier.swift`:
- 6 types: `user`, `assistant`, `tool`, `error`, `code`, `system` (line 5-11)
- Classification is content-based pattern matching (lines 40-63): checks for tool patterns, error patterns, code blocks
- No distinction between tool calls (assistant initiating) and tool results (user providing output)
- No "thinking" type — thinking content falls through to `assistant`
- No "diff" type — diffs are treated as code blocks

`ColorBarMessageView` at `macos/Engram/Views/Transcript/ColorBarMessageView.swift`:
- Renders each message with a colored left bar based on `messageType.color`
- Shows type label and index (e.g., "ASSISTANT #3")
- No file path detection or click-to-open

`ContentSegmentViews.swift` at `macos/Engram/Views/ContentSegmentViews.swift`:
- Has `SegmentedMessageView` that parses content into segments: `.text`, `.codeBlock(lang, code)`, `.heading(level, text)`
- Code blocks render with syntax highlighting via `CodeBlockView`

#### Design: Extended MessageType enum

```swift
enum MessageType: String, CaseIterable {
    case user
    case assistant
    case thinking     // NEW: extended thinking blocks
    case toolCall     // NEW: assistant invoking a tool (Read, Bash, etc.)
    case toolResult   // NEW: tool output returned to conversation
    case code         // assistant message dominated by code blocks
    case diff         // NEW: file modifications (Edit/Write output with +/- lines)
    case error
    case system

    var label: String {
        switch self {
        case .user:       return "User"
        case .assistant:  return "Assistant"
        case .thinking:   return "Thinking"
        case .toolCall:   return "Tool Call"
        case .toolResult: return "Tool Result"
        case .code:       return "Code"
        case .diff:       return "Diff"
        case .error:      return "Error"
        case .system:     return "System"
        }
    }

    var color: Color {
        switch self {
        case .user:       return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .assistant:  return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .thinking:   return Color(red: 0.45, green: 0.45, blue: 0.60)  // muted purple-gray
        case .toolCall:   return Color(red: 0.06, green: 0.73, blue: 0.51)  // teal (same as old tool)
        case .toolResult: return Color(red: 0.20, green: 0.60, blue: 0.45)  // darker teal
        case .code:       return Color(red: 0.39, green: 0.40, blue: 0.95)
        case .diff:       return Color(red: 0.85, green: 0.55, blue: 0.10)  // amber/orange
        case .error:      return Color(red: 0.94, green: 0.27, blue: 0.27)
        case .system:     return Color.secondary
        }
    }

    /// Types shown as filter chips in the transcript toolbar
    static var chipTypes: [MessageType] {
        [.user, .assistant, .thinking, .toolCall, .toolResult, .code, .diff, .error]
    }
}
```

#### Design: Enhanced classifier

```swift
struct MessageTypeClassifier {
    // ... existing patterns ...

    private static let thinkingIndicators: [String] = [
        "Let me think", "I need to consider", "Hmm,",
        // Also detect thinking blocks that fell through extractContent
    ]

    private static let diffPatterns: [String] = [
        "--- a/", "+++ b/",       // unified diff header
        "@@ -", "@@ +",          // hunk headers
    ]

    static func classify(_ message: ChatMessage) -> MessageType {
        if message.systemCategory == .systemPrompt { return .system }
        if message.systemCategory == .agentComm { return .toolCall }

        if message.role == "user" {
            // Distinguish tool results from real user messages
            let content = message.content
            if content.hasPrefix("`") && content.contains("`:") {
                // Pattern: "`Read`: /path/to/file.ts\n..." -> tool result
                return .toolResult
            }
            return .user
        }

        let content = message.content
        let prefix500 = String(content.prefix(500))

        // Thinking detection (content from thinking blocks that became text)
        if message.isThinkingContent {
            return .thinking
        }

        // Tool call detection: "`ToolName`: description" or "`ToolName`" at start
        if content.hasPrefix("`") {
            let firstLine = String(content.prefix(200).prefix(while: { $0 != "\n" }))
            if firstLine.contains("`:") || firstLine.hasSuffix("`") {
                // Check if it's a diff (Edit tool output)
                if containsDiffPattern(content) { return .diff }
                return .toolCall
            }
        }

        // Tool pattern detection (legacy format)
        if containsToolPattern(prefix500) {
            if containsExplicitToolError(content) { return .error }
            if containsDiffPattern(content) { return .diff }
            return .toolCall
        }

        if containsErrorPattern(prefix500) { return .error }
        if containsDiffPattern(String(content.prefix(2000))) { return .diff }
        if hasSignificantCodeBlock(content) { return .code }

        return .assistant
    }

    private static func containsDiffPattern(_ text: String) -> Bool {
        // Must have both a header line and a hunk marker
        let hasDiffHeader = text.contains("--- a/") || text.contains("+++ b/")
        let hasHunkMarker = text.contains("@@ -") || text.contains("@@ +")
        return hasDiffHeader && hasHunkMarker
    }
}
```

To support `isThinkingContent`, extend `ChatMessage`:
```swift
struct ChatMessage: Identifiable {
    // ... existing fields ...
    var isThinkingContent: Bool = false  // Set by parser when content came from thinking block
}
```

In `MessageParser.extractMessageContent()`, track when fallback to thinking content occurred:
```swift
// When only thinkingFallback is available (no text blocks):
if texts.isEmpty, let fallback = thinkingFallback {
    // Mark this message as thinking-derived
    // Return a tuple or set a flag
}
```

Since `ChatMessage` is a struct, the parser can set this flag during construction. The cleanest approach is to return metadata alongside content:

```swift
struct ParsedContent {
    let text: String
    let isThinkingFallback: Bool
    let imageAttachments: [ImageAttachment]  // from item #12
}
```

#### Design: Line numbers for code blocks

In `ContentSegmentViews.swift`, add line numbers to `CodeBlockView`:

```swift
// In CodeBlockView:
@AppStorage("showLineNumbers") var showLineNumbers: Bool = true

var body: some View {
    HStack(alignment: .top, spacing: 0) {
        if showLineNumbers {
            // Line number gutter
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...lineCount, id: \.self) { lineNum in
                    Text("\(lineNum)")
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(height: lineHeight)
                }
            }
            .padding(.horizontal, 6)
            .background(Color.secondary.opacity(0.05))

            Divider()
        }

        // Existing code content
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(8)
    }
}

private var lineCount: Int {
    code.components(separatedBy: "\n").count
}
```

#### Design: IDE jump from file paths

Detect file paths in tool call/result messages and make them clickable:

```swift
// macos/Engram/Views/Transcript/FilePathLink.swift

struct FilePathLink: View {
    let filePath: String

    var body: some View {
        Button(action: openInIDE) {
            HStack(spacing: 3) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                Text(shortenedPath)
                    .font(.system(size: 12, design: .monospaced))
                    .underline()
            }
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Finder") { openInFinder() }
            Button("Open in VS Code") { openInApp("Visual Studio Code") }
            Button("Open in Cursor") { openInApp("Cursor") }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(filePath, forType: .string)
            }
        }
    }

    private var shortenedPath: String {
        // Show last 2 path components: "src/core/db.ts"
        let components = filePath.split(separator: "/")
        if components.count > 2 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return filePath
    }

    private func openInIDE() {
        // Try VS Code first, then Cursor, then Finder
        let editors = ["Visual Studio Code", "Cursor", "Zed"]
        for editor in editors {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(for: editor)) != nil {
                openInApp(editor)
                return
            }
        }
        openInFinder()
    }

    private func openInApp(_ appName: String) {
        let url = URL(fileURLWithPath: filePath)
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleId(for: appName)
            )!,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func bundleId(for name: String) -> String {
        switch name {
        case "Visual Studio Code": return "com.microsoft.VSCode"
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        case "Zed": return "dev.zed.Zed"
        default: return ""
        }
    }

    private func openInFinder() {
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }
}
```

**Integration with ColorBarMessageView**:

For `.toolCall` and `.toolResult` messages, scan the content for file paths and render them as `FilePathLink`:

```swift
// In ColorBarMessageView, for tool messages:
case .toolCall, .toolResult:
    VStack(alignment: .leading, spacing: 4) {
        // Extract file path from first line (e.g., "`Read`: /path/to/file.ts")
        if let path = extractFilePath(indexed.message.content) {
            FilePathLink(filePath: path)
        }
        // Rest of content
        Text(highlightedText(indexed.message.content))
            .font(.system(size: fontSize))
            .textSelection(.enabled)
    }
```

```swift
private func extractFilePath(_ content: String) -> String? {
    // Pattern: "`ToolName`: /absolute/path" or "`ToolName`: relative/path.ext"
    let firstLine = String(content.prefix(300).prefix(while: { $0 != "\n" }))
    // Look for path after "`: "
    if let colonRange = firstLine.range(of: "`: ") {
        let pathCandidate = String(firstLine[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if pathCandidate.contains("/") || pathCandidate.contains(".") {
            return pathCandidate
        }
    }
    return nil
}
```

#### Files to create
```
macos/Engram/Views/Transcript/FilePathLink.swift  # Clickable file path with IDE jump
```

#### Files to modify
```
macos/Engram/Models/MessageTypeClassifier.swift    # Extended enum + enhanced classify()
macos/Engram/Models/IndexedMessage.swift           # Update chipTypes reference
macos/Engram/Core/MessageParser.swift              # Track thinking fallback, return ParsedContent
macos/Engram/Views/Transcript/ColorBarMessageView.swift  # Handle new types, add FilePathLink
macos/Engram/Views/Transcript/TranscriptToolbar.swift    # Update chip display for new types
macos/Engram/Views/Transcript/MessageTypeChip.swift      # Handle new type colors
macos/Engram/Views/ContentSegmentViews.swift       # Add line numbers to CodeBlockView
macos/Engram/Views/SessionDetailView.swift         # Update typeVisibility init for new types
```

**DB changes**: None.
**API changes**: None.
**Migration**: None — the classifier changes are pure Swift-side rendering. Existing sessions will be re-classified on next view.
**Verification**: Open a Claude Code session with tool calls, thinking blocks, and file edits. Verify: thinking messages show with muted purple bar; tool calls show teal with tool name; tool results show darker teal; diffs show amber with +/- highlighting. Click a file path — opens in VS Code/Cursor. Code blocks show line numbers. Toggle line numbers off in settings.

---

### 17. Swift MessageParser Streaming (流式读取)

**Summary**: Replace `String(contentsOfFile:)` in `MessageParser.swift` with a streaming `FileHandle`-based reader that processes JSONL files in 64KB chunks with line buffering, preventing OOM on large session files (some Claude Code sessions exceed 100MB).

**Problem**: `MessageParser.readLines()` (line 286-289 of `MessageParser.swift`) calls `String(contentsOfFile:encoding:)` which loads the entire file into memory. For a 150MB JSONL file, this allocates ~300MB (UTF-16 internal representation) before splitting into lines. This is the same OOM vector the Node side solved with `createReadStream` + `readline.createInterface` in `ClaudeCodeAdapter.readLines()` (`src/adapters/claude-code.ts` lines 230-236).

#### Files to modify
- `macos/Engram/Core/MessageParser.swift` — replace `readLines()` helper + all format parsers that call it

#### New class — StreamingJSONLReader

```swift
/// Reads JSONL files in fixed-size chunks, yielding one line at a time.
/// Handles lines up to 8MB; drops lines exceeding the limit with a log warning.
final class StreamingJSONLReader: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let chunkSize: Int        // 64 * 1024 = 65536
    private let maxLineLength: Int    // 8 * 1024 * 1024
    private var buffer: Data          // carry-over bytes from previous chunk
    private var eof: Bool
    private var closed: Bool = false

    init?(filePath: String, chunkSize: Int = 64 * 1024, maxLineLength: Int = 8 * 1024 * 1024) {
        guard let fh = FileHandle(forReadingAtPath: filePath) else { return nil }
        self.fileHandle = fh
        self.chunkSize = chunkSize
        self.maxLineLength = maxLineLength
        self.buffer = Data()
        self.eof = false
    }

    /// Explicitly close the file handle. **MUST** be called by the caller — use `defer { reader.close() }`.
    /// fileHandle is private, so this is the only public way to release the file descriptor.
    /// Safe to call multiple times (idempotent via `closed` flag).
    /// Do NOT rely on deinit — ARC timing is non-deterministic, especially when `for line in reader`
    /// breaks early (the iterator may be retained by a temporary Sequence wrapper).
    func close() {
        guard !closed else { return }
        closed = true
        try? fileHandle.close()
    }

    deinit {
        // Safety net only — callers should use explicit close()
        close()
    }

    func next() -> String? {
        while true {
            // Search buffer for newline
            if let newlineIndex = buffer.firstIndex(of: 0x0A /* \n */) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])
                if lineData.count > maxLineLength {
                    // Skip oversized line — log warning via os_log
                    continue
                }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                return trimmed
            }
            // No newline in buffer — read more
            if eof {
                // Return remaining buffer as final line
                if buffer.isEmpty { return nil }
                let remaining = buffer
                buffer = Data()
                if remaining.count > maxLineLength { return nil }
                let line = String(data: remaining, encoding: .utf8) ?? ""
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            // Buffer overflow guard
            if buffer.count > maxLineLength {
                // Discard buffer up to next newline or max
                buffer = Data()
                continue
            }
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { eof = true; continue }
            buffer.append(chunk)
        }
    }
}
```

#### Integration into existing parsers

The current `readLines()` helper returns `[String]?`. The new `StreamingJSONLReader` is a `Sequence<String>`. Refactor each parser to accept a generic sequence instead of an array:

1. **`readLines()` replacement**: Change from `private static func readLines(_ filePath:) -> [String]?` to return `StreamingJSONLReader?`:
   ```swift
   private static func streamLines(_ filePath: String) -> StreamingJSONLReader? {
       return StreamingJSONLReader(filePath: filePath)
   }
   ```

2. **Parser changes** — all 5 JSONL-based parsers (`parseTypeMessageFormat`, `parseRoleDirectFormat`, `parseCopilotFormat`, `parseCodexFormat`) currently use `lines.compactMap { ... }`. Replace with:
   ```swift
   private static func parseTypeMessageFormat(filePath: String, source: String) -> [ChatMessage] {
       guard let reader = streamLines(filePath) else { return [] }
       defer { reader.close() }
       var messages: [ChatMessage] = []
       for line in reader {
           guard let obj = parseJSON(line), /* ... same logic ... */ else { continue }
           messages.append(chatMessage)
       }
       return messages
   }
   ```

3. **Whole-file parsers** — `parseGeminiFormat` and `parseClineFormat` read entire JSON files (not JSONL). These use `Data(contentsOf:)` which is appropriate for their format (typically small). No change needed.

4. **SQLite-based parsers** — `parseCursorFormat` and `parseOpenCodeFormat` use GRDB queries. No change needed.

#### Performance characteristics
- Memory: O(chunkSize + maxLineLength) = ~8.06MB worst case, vs O(fileSize) before
- Speed: Negligible difference for files <10MB. For files >50MB, avoids swap pressure
- Line limit: 8MB per line covers the largest known Claude Code JSONL entries (tool results with full file contents)

#### Async limitation note

This is a synchronous `Sequence`. For future async/await integration, consider converting to `AsyncSequence`. The current synchronous design is appropriate because `MessageParser` runs on a detached `Task`, not the main actor -- so blocking `FileHandle.readData(ofLength:)` calls do not block the UI thread. If `MessageParser` is ever moved to the main actor, this must be converted to `AsyncSequence` with non-blocking reads.

**DB changes**: None.
**API changes**: None — this is an internal Swift refactor. `MessageParser.parse()` public API is unchanged.
**Migration**: None.

**Verification**:
1. Create a synthetic 200MB JSONL file with 50,000 lines. Confirm Engram.app opens the session without memory spike (Xcode Instruments allocation profile should stay under 20MB for the parser)
2. Verify all existing adapter formats still parse correctly — test with real session files from each source
3. Confirm 8MB line limit logs a warning but does not crash
4. Edge case: file with no trailing newline, file with CRLF line endings, empty file

---

### 18. Session Scoring (Session 评分)

**Summary**: Compute a quality score (0-100) for each session based on turn ratio, tool success rate, session density, and duration. Store in the `sessions` table and use it for `get_context` result ranking.

#### Files to modify
- `src/core/session-tier.ts` — add `computeScore()` function alongside `computeTier()`
- `src/core/db.ts` — add `quality_score` column, add setter/getter methods
- `src/core/indexer.ts` — call `computeScore()` during indexing
- `src/tools/get_context.ts` — use score for sorting sessions

#### Scoring algorithm

New function in `src/core/session-tier.ts`:

```typescript
export interface ScoreInput {
  messageCount: number
  userMessageCount: number
  assistantMessageCount: number
  toolMessageCount: number
  startTime: string | null
  endTime: string | null
  tier: SessionTier
  summary: string | null
  toolSuccessRate?: number  // 0-1, optional (requires tool result analysis)
}

/**
 * Quality score 0-100 for session ranking.
 * Components:
 *   - Turn ratio (30 pts): balanced user:assistant ratio -> higher score
 *   - Session density (25 pts): messages per minute (sweet spot 1-5/min)
 *   - Tool engagement (20 pts): tool usage as % of total messages
 *   - Duration bonus (15 pts): sessions 5-60min get full marks
 *   - Content richness (10 pts): summary length as proxy for substance
 */
export function computeScore(input: ScoreInput): number {
  let score = 0

  // 1. Turn ratio (30 pts): ideal is 40-60% user messages
  const totalConversational = input.userMessageCount + input.assistantMessageCount
  if (totalConversational > 0) {
    const userRatio = input.userMessageCount / totalConversational
    // Parabolic curve: peak at 0.5, zero at 0 and 1
    score += Math.round(30 * (1 - Math.pow(2 * userRatio - 1, 2)))
  }

  // 2. Session density (25 pts): msgs/min, sweet spot 1-5
  const durationMin = durationMinutes(input.startTime, input.endTime)
  if (durationMin > 0) {
    const density = input.messageCount / durationMin
    if (density >= 1 && density <= 5) score += 25
    else if (density > 5) score += Math.max(10, Math.round(25 - (density - 5) * 2))
    else score += Math.round(25 * density)
  } else if (input.messageCount >= 3) {
    score += 10  // no timestamps but has content
  }

  // 3. Tool engagement (20 pts)
  if (input.messageCount > 0) {
    const toolRatio = input.toolMessageCount / input.messageCount
    score += Math.round(20 * Math.min(1, toolRatio * 3))  // caps at ~33% tool messages
  }

  // 4. Duration bonus (15 pts): 5-60 min sweet spot
  if (durationMin >= 5 && durationMin <= 60) {
    score += 15
  } else if (durationMin > 60) {
    score += Math.max(5, Math.round(15 - (durationMin - 60) / 30))
  } else if (durationMin > 0) {
    score += Math.round(15 * durationMin / 5)
  }

  // 5. Content richness (10 pts): summary length as proxy
  if (input.summary) {
    const len = input.summary.length
    score += Math.min(10, Math.round(len / 20))
  }

  // Tier multiplier: skip sessions get 0
  if (input.tier === 'skip') return 0
  if (input.tier === 'lite') return Math.round(score * 0.5)

  return Math.min(100, score)
}
```

#### DB migration

Add column to `sessions` table in `db.ts:migrate()`:
```sql
-- In the idempotent migration block:
if (!colNames.has('quality_score')) {
  this.db.exec('ALTER TABLE sessions ADD COLUMN quality_score INTEGER')
  this.db.exec('CREATE INDEX IF NOT EXISTS idx_sessions_quality_score ON sessions(quality_score)')
}
```

#### DB methods

Add to `Database` class:
```typescript
updateSessionScore(id: string, score: number): void {
  this.db.prepare('UPDATE sessions SET quality_score = ? WHERE id = ?').run(score, id)
}
```

#### Indexer integration

In `indexer.ts`, after building the snapshot:
```typescript
// After snapshot write:
const score = computeScore({
  messageCount: info.messageCount,
  userMessageCount: info.userMessageCount,
  assistantMessageCount: info.assistantMessageCount,
  toolMessageCount: info.toolMessageCount,
  startTime: info.startTime,
  endTime: info.endTime ?? null,
  tier: snapshot.tier,
  summary: info.summary ?? null,
})
this.db.updateSessionScore(info.id, score)
```

#### get_context integration

Add a `sort_by` parameter to `get_context` to allow explicit score-based ranking while preserving backward-compatible recency ordering:

In `getContextTool.inputSchema.properties`, add:
```typescript
sort_by: { type: 'string', enum: ['recency', 'score'], description: '排序方式：recency（默认，按时间倒序）或 score（按质量评分倒序）' },
```

In `src/tools/get_context.ts`, add sort-by-score when explicitly requested:
```typescript
// After retrieving sessions (line 41-44), sort based on sort_by parameter:
const sortBy = params.sort_by ?? 'recency'  // default: recency for backward compat

if (sortBy === 'score') {
  sessions.sort((a, b) => {
    // Primary: quality score descending
    const scoreA = (a as any).qualityScore ?? 0
    const scoreB = (b as any).qualityScore ?? 0
    if (scoreA !== scoreB) return scoreB - scoreA
    // Secondary: recency
    return b.startTime.localeCompare(a.startTime)
  })
} else {
  // Default: recency (existing behavior, no change)
  sessions.sort((a, b) => b.startTime.localeCompare(a.startTime))
}
```

This requires `SessionInfo` to include `qualityScore`. Add to `rowToSession()` in `db.ts`:
```typescript
qualityScore: (row.quality_score as number) ?? undefined,
```

And add to `SessionInfo` interface in `src/adapters/types.ts`:
```typescript
qualityScore?: number
```

#### Backfill

Add `backfillScores()` method following existing `backfillTiers()` / `backfillCosts()` patterns:
```typescript
backfillScores(): void {
  // SQL-based approximate scoring for existing sessions without quality_score
  this.db.exec(`
    UPDATE sessions SET quality_score = CASE
      WHEN tier = 'skip' THEN 0
      WHEN tier = 'lite' THEN 25
      WHEN message_count >= 20 AND user_message_count > 0 THEN
        MIN(100, 30 + (tool_message_count * 3) + MIN(15, message_count / 2))
      ELSE MIN(80, 20 + (message_count * 2) + (tool_message_count * 3))
    END
    WHERE quality_score IS NULL
  `)
}
```

**Web API**: Extend `GET /api/sessions` response to include `qualityScore` (no new endpoint needed).

**Verification**:
1. Unit test `computeScore()` with fixture data: a 50-message session with balanced turns should score >70, a 2-message skip session should score 0
2. Verify `get_context` returns higher-scored sessions first for the same project
3. Verify backfill runs idempotently on startup
4. Check Swift reads `quality_score` column via GRDB without schema mismatch

---

### 19. File Change Tracking (文件变更追踪)

**Summary**: Extract file paths from `tool_use` blocks (Read, Write, Edit, Glob, Grep) during indexing, store in a new `session_files` table, and expose via a new `file_activity` MCP tool.

#### Files to modify
- `src/core/db.ts` — new `session_files` table + query methods
- `src/core/indexer.ts` — extract file paths from tool call inputs during accumulation
- `src/adapters/types.ts` — add `filePath` field to `ToolCall` interface
- `src/adapters/claude-code.ts` — populate `ToolCall.filePath` from input
- New file: `src/tools/file_activity.ts` — new MCP tool
- `src/index.ts` — register new tool
- `src/web.ts` — new API endpoint

#### DB migration — new session_files table

```sql
CREATE TABLE IF NOT EXISTS session_files (
  session_id TEXT NOT NULL,
  file_path TEXT NOT NULL,
  operation TEXT NOT NULL,     -- 'read' | 'write' | 'edit'
  call_count INTEGER DEFAULT 1,
  PRIMARY KEY (session_id, file_path, operation),
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_session_files_path ON session_files(file_path);
CREATE INDEX IF NOT EXISTS idx_session_files_session ON session_files(session_id);
```

#### ToolCall interface enhancement

`src/adapters/types.ts`:
```typescript
export interface ToolCall {
  name: string
  input?: string     // existing: truncated JSON of input
  output?: string    // existing
  filePath?: string  // NEW: extracted file_path for Read/Write/Edit tools
}
```

#### Adapter extraction

In `claude-code.ts`, the existing `streamMessages()` already extracts tool calls (lines 195-203). Enhance to also extract `filePath`:
```typescript
const calls = rawContent
  .filter((c: any) => c.type === 'tool_use' && c.name)
  .map((c: any) => {
    const tc: ToolCall = {
      name: c.name as string,
      input: c.input ? JSON.stringify(c.input).slice(0, 500) : undefined,
    }
    // Extract file path for file-touching tools
    if (c.input && typeof c.input === 'object') {
      const fp = c.input.file_path as string | undefined
      if (fp && (c.name === 'Read' || c.name === 'Write' || c.name === 'Edit')) {
        tc.filePath = fp
      }
    }
    return tc
  })
```

#### Indexer accumulator enhancement

In `Indexer.accumulateFromStream()`:
```typescript
// Add fileCounts to accumulator type:
private static newAccumulator() {
  return {
    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
    toolCounts: new Map<string, number>(),
    fileCounts: new Map<string, Map<string, number>>(),  // file_path -> operation -> count
  }
}

private static accumulateFromStream(msg: Message, acc: ReturnType<typeof Indexer.newAccumulator>): void {
  // ... existing token + tool accumulation ...
  if (msg.toolCalls) {
    for (const tc of msg.toolCalls) {
      acc.toolCounts.set(tc.name, (acc.toolCounts.get(tc.name) || 0) + 1)
      // File tracking
      if (tc.filePath) {
        const op = tc.name === 'Read' ? 'read' : tc.name === 'Write' ? 'write' : tc.name === 'Edit' ? 'edit' : null
        if (op) {
          if (!acc.fileCounts.has(tc.filePath)) acc.fileCounts.set(tc.filePath, new Map())
          const ops = acc.fileCounts.get(tc.filePath)!
          ops.set(op, (ops.get(op) || 0) + 1)
        }
      }
    }
  }
}
```

#### DB methods

Add to `Database` class:
```typescript
upsertSessionFiles(sessionId: string, files: Map<string, Map<string, number>>): void {
  const stmt = this.db.prepare(
    'INSERT OR REPLACE INTO session_files (session_id, file_path, operation, call_count) VALUES (?, ?, ?, ?)'
  )
  const tx = this.db.transaction(() => {
    for (const [filePath, ops] of files) {
      for (const [op, count] of ops) {
        stmt.run(sessionId, filePath, op, count)
      }
    }
  })
  tx()
}

getFileActivity(params: { project?: string; filePath?: string; since?: string; limit?: number }): Array<{
  filePath: string; readCount: number; writeCount: number; editCount: number; sessionCount: number; lastAccessed: string
}> {
  // Performance note: With 100K+ rows, prefix LIKE is acceptable (index-friendly).
  // Substring LIKE without leading % must be avoided — it forces a full table scan.
  const conditions: string[] = ['1=1']
  const sqlParams: Record<string, unknown> = {}
  // Project is already resolved via resolveProjectAliases before this call — use exact match
  if (params.project) { conditions.push('s.project = @project'); sqlParams.project = params.project }
  // File path: exact match when no wildcard, prefix LIKE only when trailing %
  if (params.filePath) {
    if (params.filePath.includes('%')) {
      // Caller explicitly wants prefix/pattern match (e.g., "src/core/%")
      conditions.push('sf.file_path LIKE @filePath')
      sqlParams.filePath = params.filePath
    } else {
      // Exact match — much faster with index
      conditions.push('sf.file_path = @filePath')
      sqlParams.filePath = params.filePath
    }
  }
  if (params.since) { conditions.push('s.start_time >= @since'); sqlParams.since = params.since }
  const limit = params.limit ?? 50

  return this.db.prepare(`
    SELECT
      sf.file_path AS filePath,
      SUM(CASE WHEN sf.operation = 'read' THEN sf.call_count ELSE 0 END) AS readCount,
      SUM(CASE WHEN sf.operation = 'write' THEN sf.call_count ELSE 0 END) AS writeCount,
      SUM(CASE WHEN sf.operation = 'edit' THEN sf.call_count ELSE 0 END) AS editCount,
      COUNT(DISTINCT sf.session_id) AS sessionCount,
      MAX(s.start_time) AS lastAccessed
    FROM session_files sf
    JOIN sessions s ON sf.session_id = s.id
    WHERE ${conditions.join(' AND ')}
    GROUP BY sf.file_path
    ORDER BY (writeCount + editCount) DESC, readCount DESC
    LIMIT @limit
  `).all({ ...sqlParams, limit }) as any[]
}
```

#### MCP tool — file_activity

`src/tools/file_activity.ts`:
```typescript
export const fileActivityTool = {
  name: 'file_activity',
  description: 'Show which files were read/written/edited across sessions for a project.',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: 'Project root directory' },
      file_path: { type: 'string', description: 'Filter by specific file path (substring match)' },
      since: { type: 'string', description: 'ISO 8601 start date filter' },
      limit: { type: 'number', description: 'Max results (default 50)' },
    },
    additionalProperties: false,
  },
}

export async function handleFileActivity(
  db: Database,
  params: { cwd: string; file_path?: string; since?: string; limit?: number }
): Promise<{ files: FileActivityEntry[]; totalFiles: number }> {
  const projectName = basename(params.cwd.replace(/\/$/, ''))
  const projectNames = db.resolveProjectAliases([projectName])
  const files = db.getFileActivity({
    project: projectNames[0],
    filePath: params.file_path,
    since: params.since,
    limit: params.limit,
  })
  return { files, totalFiles: files.length }
}
```

**Web API**: `GET /api/file-activity?project=engram&since=2026-03-01`

**Backfill**: Add `backfillFileActivity()` following the `backfillCosts()` pattern — re-read session files for sessions with no `session_files` rows and `tier != 'skip'`.

**Verification**:
1. Unit test: parse the existing `session-with-usage.jsonl` fixture — it has Read and Edit tool_use blocks. Verify `filePath` is extracted as `src/auth.ts`
2. Integration test: index a session, verify `session_files` table has correct rows
3. MCP tool test: `file_activity` returns sorted files with correct counts
4. Verify cascading deletes: deleting a session removes its `session_files` rows

---

### 20. Executable Actions (可执行操作) — Backlog

> **Backlog — not for immediate implementation**

**Summary**: A new MCP tool `execute_action` that can perform safe system actions (open directories, copy to clipboard, open terminal) with a human-in-the-loop confirmation step before execution.

#### Architecture

```
MCP Client (Claude Code)          Engram Daemon               macOS App
       |                              |                          |
       |-- execute_action ----------->|                          |
       |   {type: "open_dir",        |-- HTTP POST /api/action-->|
       |    path: "/Users/..."}      |   {pending approval}     |
       |                              |                          |
       |<-- {status: "pending",       |                          |
       |    approvalUrl: "..."}      |                          |
       |                              |    +----------------+    |
       |                              |    | Confirm/Deny   | <-- user
       |                              |    +----------------+    |
       |                              |<-- POST /api/action/:id/ |
       |                              |    approve               |
       |                              |-- execute action ------->|
       |<-- {status: "completed"}     |                          |
```

#### Action types

```typescript
type ActionType = 'open_directory' | 'copy_clipboard' | 'open_terminal' | 'open_url' | 'reveal_in_finder'

interface ActionRequest {
  type: ActionType
  params: Record<string, string>  // type-specific params
  reason: string                  // why the AI wants to do this
  timeout?: number                // approval timeout in seconds (default 30)
}

interface ActionResult {
  id: string
  status: 'pending' | 'approved' | 'denied' | 'expired' | 'completed' | 'failed'
  error?: string
}
```

#### Confirmation flow

1. MCP tool receives request, creates action record with `status: pending`
2. Daemon pushes event to Swift app via SSE: `{ event: "action_request", data: {...} }`
3. Swift shows a system notification or in-app modal with action details + approve/deny buttons
4. User approves — daemon executes action via `NSWorkspace` / `NSPasteboard`
5. Result returned to MCP tool (which has been polling or waiting on SSE)

#### Security constraints

- Allowlist of action types — no arbitrary command execution
- `open_directory` / `reveal_in_finder`: must be under user's home directory
- `open_url`: must be `https://` only
- `copy_clipboard`: payload size limit 1MB
- All actions logged for audit trail

#### macOS execution layer (Swift)

```swift
enum ActionExecutor {
    static func execute(_ action: ActionRequest) throws {
        switch action.type {
        case "open_directory":
            NSWorkspace.shared.open(URL(fileURLWithPath: action.params["path"]!))
        case "copy_clipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(action.params["text"]!, forType: .string)
        case "open_terminal":
            // Open Terminal.app with cd to path
        case "open_url":
            NSWorkspace.shared.open(URL(string: action.params["url"]!)!)
        case "reveal_in_finder":
            NSWorkspace.shared.selectFile(action.params["path"], inFileViewerRootedAtPath: "")
        }
    }
}
```

---

### 21. Cockpit HUD — Backlog

> **Backlog — not for immediate implementation**

**Summary**: A floating HUD window showing live agent status, inspired by gaming HUD overlays. Always-on-top, translucent, minimal footprint.

#### Window configuration

```swift
struct CockpitHUD: Scene {
    var body: some Scene {
        Window("Cockpit", id: "cockpit") {
            CockpitView()
        }
        .windowStyle(.plain)           // no title bar
        .windowLevel(.floating)        // always on top
        .defaultSize(width: 320, height: 200)
        .windowResizability(.contentSize)
    }
}
```

#### Presence sources (data from existing LiveSessionMonitor)

- Active sessions: source icon, project name, current tool activity, duration
- Cost: today's running total from `BackgroundMonitor`
- Alerts: active alert count badge

#### UI layout

```
+--------------------------------+
| * 3 active    $4.82 today      |  Status bar
+--------------------------------+
| [b] engram   Reading db.ts  3m |  Live session 1
| [g] weather  Bash: npm test 1m |  Live session 2
| [y] docs     idle           8m |  Live session 3
+--------------------------------+
| ! 1 alert                      |  Alert summary
+--------------------------------+
```

#### Interaction model

- Click session row -> opens session detail in main window
- Click cost -> opens cost breakdown page
- Click alert badge -> shows alert list
- Drag to reposition, position persists via `@AppStorage`
- Cmd+H toggles HUD visibility from menu bar

**Data flow**: `DaemonClient.fetchLiveSessions()` every 5s + SSE stream for real-time updates. No new daemon infrastructure needed — reuses existing `/api/live/stream` SSE endpoint.

---

### 22. Auto-Update + Homebrew (自动更新) — Backlog

> **Backlog — not for immediate implementation**

**Summary**: Automatic updates via Sparkle 2 framework with EdDSA signing, plus distribution via Homebrew tap.

#### Architecture

```
GitHub Release Pipeline:
  tag v1.2.3
    -> GitHub Actions builds .app
    -> codesign + notarize
    -> generate EdDSA signature (sign_update tool)
    -> create Engram-1.2.3.dmg
    -> upload to GitHub Release
    -> update appcast.xml in repo
    -> push to homebrew tap
```

**EdDSA signing** (Sparkle 2's preferred method over DSA):
- Generate key pair: `./bin/generate_keys` (Sparkle CLI)
- Store public key in `Info.plist` as `SUPublicEDKey`
- Store private key in GitHub Actions secret `SPARKLE_EDDSA_KEY`
- CI signs: `./bin/sign_update Engram-1.2.3.dmg --ed-key-file $KEY_FILE`

**appcast.xml** (hosted in GitHub Pages or raw GitHub):
```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Engram</title>
    <item>
      <title>Version 1.2.3</title>
      <sparkle:version>123</sparkle:version>
      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
      <sparkle:edSignature>BASE64_SIG</sparkle:edSignature>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/.../Engram-1.2.3.dmg"
                 length="SIZE" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

**Homebrew tap** (`homebrew-engram`):
```ruby
cask "engram" do
  version "1.2.3"
  sha256 "HASH"
  url "https://github.com/.../releases/download/v#{version}/Engram-#{version}.dmg"
  name "Engram"
  desc "Cross-tool AI session aggregator"
  homepage "https://github.com/..."
  app "Engram.app"
  depends_on macos: ">= :sonoma"
end
```

**CI pipeline** (GitHub Actions):
```yaml
jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
      - run: xcodegen generate
      - run: xcodebuild -scheme Engram -configuration Release archive
      - run: # codesign with Developer ID
      - run: # notarize with notarytool
      - run: # create DMG
      - run: # sign with Sparkle EdDSA
      - run: # update appcast.xml
      - uses: softprops/action-gh-release@v2
```

**Swift integration** — add to `EngramApp.swift`:
```swift
import Sparkle

@main
struct EngramApp: App {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
    // Add "Check for Updates..." to app menu
}
```

---

### 23. Infrastructure Health Checks (基础设施健康检查)

**Summary**: Extend the existing `lint_config` tool with three new check categories: stale git branches, zombie daemon processes, and dependency vulnerabilities. Integrate alert output with the existing `BackgroundMonitor` system.

#### Files to modify
- `src/tools/lint_config.ts` — add new check functions
- `src/core/monitor.ts` — add new alert categories
- `src/core/config.ts` — add `healthCheck` config section

#### New check categories in lint_config.ts

```typescript
// Extend LintIssue severity to include 'critical'
export interface LintIssue {
  file: string
  line: number
  severity: 'error' | 'warning' | 'info' | 'critical'
  category: 'config' | 'git' | 'process' | 'dependency'  // NEW
  message: string
  suggestion?: string
}

// New check functions:

async function checkStaleBranches(cwd: string): Promise<LintIssue[]> {
  const issues: LintIssue[] = []
  try {
    // Run: git branch --merged main --format='%(refname:short) %(committerdate:iso8601)'
    const { stdout } = await execAsync('git branch --merged main --format="%(refname:short) %(committerdate:iso8601)"', { cwd })
    const thirtyDaysAgo = Date.now() - 30 * 86400000
    for (const line of stdout.trim().split('\n')) {
      if (!line.trim()) continue
      const [branch, ...dateParts] = line.split(' ')
      if (branch === 'main' || branch === 'master' || branch === '*') continue
      const dateStr = dateParts.join(' ')
      const branchDate = new Date(dateStr).getTime()
      if (branchDate < thirtyDaysAgo) {
        issues.push({
          file: '.git', line: 0,
          severity: 'info',
          category: 'git',
          message: `Branch \`${branch}\` is merged and >30 days old`,
          suggestion: `Run \`git branch -d ${branch}\` to clean up`,
        })
      }
    }
  } catch { /* not a git repo or git not available */ }
  return issues
}

async function checkZombieProcesses(): Promise<LintIssue[]> {
  const issues: LintIssue[] = []
  try {
    // Check for stale engram daemon processes
    const { stdout } = await execAsync('pgrep -f "engram.*daemon" -l')
    const processes = stdout.trim().split('\n').filter(Boolean)
    if (processes.length > 1) {
      issues.push({
        file: 'process', line: 0,
        severity: 'warning',
        category: 'process',
        message: `${processes.length} engram daemon processes running (expected 1)`,
        suggestion: 'Kill stale processes with `pkill -f "engram.*daemon"`',
      })
    }
  } catch { /* pgrep returns non-zero if no matches */ }
  return issues
}

async function checkDependencyVulnerabilities(cwd: string): Promise<LintIssue[]> {
  const issues: LintIssue[] = []
  const pkgLockPath = join(cwd, 'package-lock.json')
  if (!existsSync(pkgLockPath)) return issues
  try {
    const { stdout } = await execAsync('npm audit --json', { cwd, timeout: 30000 })
    const audit = JSON.parse(stdout)
    const vulns = audit.vulnerabilities ?? {}
    let highCount = 0, criticalCount = 0
    for (const [pkg, info] of Object.entries(vulns) as any[]) {
      if (info.severity === 'critical') criticalCount++
      else if (info.severity === 'high') highCount++
    }
    if (criticalCount > 0) {
      issues.push({
        file: 'package-lock.json', line: 0,
        severity: 'critical',
        category: 'dependency',
        message: `${criticalCount} critical npm vulnerabilities found`,
        suggestion: 'Run `npm audit fix` or review with `npm audit`',
      })
    }
    if (highCount > 0) {
      issues.push({
        file: 'package-lock.json', line: 0,
        severity: 'warning',
        category: 'dependency',
        message: `${highCount} high-severity npm vulnerabilities found`,
      })
    }
  } catch { /* npm audit may fail in offline environments */ }
  return issues
}
```

#### Integration into handleLintConfig()

```typescript
export async function handleLintConfig(params: { cwd: string }): Promise<{ issues: LintIssue[]; score: number }> {
  const { cwd } = params
  const issues: LintIssue[] = []

  // Existing config checks...
  // (current file reference + npm script checks)

  // New infrastructure checks (run in parallel)
  const [gitIssues, processIssues, depIssues] = await Promise.all([
    checkStaleBranches(cwd),
    checkZombieProcesses(),
    checkDependencyVulnerabilities(cwd),
  ])
  issues.push(...gitIssues, ...processIssues, ...depIssues)

  // Updated scoring with category weights
  const score = Math.max(0, 100 - issues.reduce((s, i) => {
    const weight = i.severity === 'critical' ? 15 : i.severity === 'error' ? 10 : i.severity === 'warning' ? 3 : 1
    return s + weight
  }, 0))

  return { issues, score }
}
```

#### BackgroundMonitor integration

Add new alert categories to `MonitorAlert`:
```typescript
export interface MonitorAlert {
  id: string
  category: 'cost_threshold' | 'long_session' | 'high_error_rate' | 'unpushed_commits'
    | 'stale_branches' | 'zombie_process' | 'dependency_vuln'  // NEW
  severity: 'info' | 'warning' | 'critical'
  // ... rest unchanged
}
```

Add periodic health check in `BackgroundMonitor.check()`:
```typescript
async check(): Promise<void> {
  // ... existing checks ...
  await this.checkInfraHealth()
}

private async checkInfraHealth(): Promise<void> {
  // Only run once per hour (not every 10 minutes)
  const lastHealthCheck = this.lastHealthCheckAt ?? 0
  if (Date.now() - lastHealthCheck < 3600_000) return
  this.lastHealthCheckAt = Date.now()

  const zombies = await checkZombieProcesses()
  for (const issue of zombies) {
    this.emitAlert('zombie_process', issue.severity as any, issue.message, issue.message)
  }
}
```

**get_context integration** — surface critical health alerts in `get_context` response:
```typescript
// At the end of handleGetContext, if there are critical alerts:
const alerts = monitor?.getAlerts().filter(a => !a.dismissed && a.severity === 'critical') ?? []
if (alerts.length > 0) {
  contextParts.push(`\n! ${alerts.length} critical alerts: ${alerts.map(a => a.title).join(', ')}`)
}
```

**Verification**:
1. Unit test `checkStaleBranches()` with a test repo containing merged branches
2. Unit test `checkZombieProcesses()` — verify it handles no-match (exit code 1) gracefully
3. Integration test: `handleLintConfig()` returns issues from all categories
4. Verify `BackgroundMonitor` does not run health checks more than once per hour
5. Verify scoring: critical vulnerability drops score by 15, stale branch (info) by 1

---

### 24. Schema Drift Tests (Schema drift 测试)

**Summary**: Add per-adapter `schema_drift.jsonl` fixture files containing forward-compatible schema variations (new fields, changed types, missing optional fields) to verify adapters gracefully handle schema evolution. Three fixtures per adapter: `v_future_fields.jsonl`, `v_missing_optional.jsonl`, `v_changed_types.jsonl`.

#### Files to create
- `tests/fixtures/<adapter>/schema_drift/v_future_fields.jsonl` — for each adapter
- `tests/fixtures/<adapter>/schema_drift/v_missing_optional.jsonl` — for each adapter
- `tests/fixtures/<adapter>/schema_drift/v_changed_types.jsonl` — for each adapter
- `tests/adapters/schema-drift.test.ts` — unified test file

**Existing test pattern** (from `tests/adapters/claude-code.test.ts`):
- Tests instantiate the adapter directly
- Call `parseSessionInfo(fixturePath)` and assert metadata fields
- Call `streamMessages(fixturePath)` and assert message roles/content
- Real fixture files in `tests/fixtures/<adapter>/`
- No mocking

#### Fixture format — three categories per adapter

**Category 1: `v_future_fields.jsonl`** — new fields added by upstream tool:
```jsonl
// claude-code example: new fields like "tokenMetrics", "costEstimate", "parentAgentId"
{"type":"user","message":{"role":"user","content":"test"},"timestamp":"2026-04-01T10:00:00.000Z","sessionId":"drift-001","cwd":"/test","tokenMetrics":{"windowSize":200000},"parentAgentId":"parent-001","costEstimate":{"usd":0.05}}
{"type":"assistant","message":{"id":"msg-1","role":"assistant","model":"claude-sonnet-5-0","content":[{"type":"text","text":"response"}],"usage":{"input_tokens":100,"output_tokens":50},"reasoning_effort":"high","tools_available":["Read","Write"]},"timestamp":"2026-04-01T10:00:01.000Z","sessionId":"drift-001"}
```
Each adapter gets its own future-fields fixture mimicking its specific JSON schema with plausible new fields.

**Category 2: `v_missing_optional.jsonl`** — optional fields absent:
```jsonl
// claude-code example: no timestamp, no cwd, no model, no usage
{"type":"user","message":{"content":"test"},"sessionId":"drift-002"}
{"type":"assistant","message":{"content":"response"},"sessionId":"drift-002"}
```
Tests that adapters handle gracefully when `timestamp`, `cwd`, `model`, `usage` are all absent.

**Category 3: `v_changed_types.jsonl`** — type variations:
```jsonl
// claude-code example: content as string instead of array, timestamp as epoch number
{"type":"user","message":{"role":"user","content":"test"},"timestamp":1743580800000,"sessionId":"drift-003","cwd":"/test"}
{"type":"assistant","message":{"role":"assistant","content":"response string instead of array","model":"claude-sonnet-4-6","usage":{"input_tokens":"100","output_tokens":"50"}},"timestamp":"2026-04-01T10:00:01.000Z","sessionId":"drift-003"}
```
Tests that adapters handle string-where-number-expected, number-where-string-expected, etc.

#### Adapter matrix — which adapters get which fixtures

| Adapter | Format | Future Fields | Missing Optional | Changed Types |
|---------|--------|:---:|:---:|:---:|
| claude-code | JSONL | Y | Y | Y |
| codex | JSONL | Y | Y | Y |
| iflow | JSONL | Y | Y | Y |
| copilot | JSONL | Y | Y | Y |
| kimi | JSONL | Y | Y | Y |
| windsurf | JSONL | Y | Y | Y |
| antigravity | JSONL | Y | Y | Y |
| qwen | JSONL | Y | Y | Y |
| gemini-cli | JSON | Y | Y | Y |
| cline | JSON | Y | Y | Y |
| cursor | SQLite | -- | -- | -- |
| opencode | SQLite | -- | -- | -- |

SQLite-based adapters (cursor, opencode) are excluded because their schema is controlled by the source tool's SQLite DB — schema drift would be a DB migration issue, not a fixture issue.

#### Unified test file — tests/adapters/schema-drift.test.ts

```typescript
import { describe, it, expect } from 'vitest'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'
import { existsSync } from 'fs'
// Import all JSONL-based adapters
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js'
import { CodexAdapter } from '../../src/adapters/codex.js'
// ... etc

const __dirname = dirname(fileURLToPath(import.meta.url))

interface DriftTestCase {
  name: string
  adapter: SessionAdapter
  fixtureDir: string
}

const testCases: DriftTestCase[] = [
  { name: 'claude-code', adapter: new ClaudeCodeAdapter(), fixtureDir: 'claude-code' },
  { name: 'codex', adapter: new CodexAdapter(), fixtureDir: 'codex' },
  // ... all JSONL-based adapters
]

const DRIFT_CATEGORIES = ['v_future_fields', 'v_missing_optional', 'v_changed_types'] as const

// Meta-test: ensure all JSONL-based adapters have schema_drift fixtures.
// This fails loudly when a fixture is missing, preventing silent gaps in coverage.
const fixtureDir = join(__dirname, '../fixtures')
describe('Schema drift fixture completeness', () => {
  it('all JSONL adapters have schema_drift fixtures', () => {
    for (const tc of testCases) {
      for (const cat of DRIFT_CATEGORIES) {
        const path = join(fixtureDir, tc.fixtureDir, 'schema_drift', `${cat}.jsonl`)
        expect(existsSync(path), `Missing fixture: ${tc.name}/${cat}`).toBe(true)
      }
    }
  })
})

for (const tc of testCases) {
  describe(`Schema drift: ${tc.name}`, () => {
    for (const category of DRIFT_CATEGORIES) {
      const fixturePath = join(__dirname, '../fixtures', tc.fixtureDir, 'schema_drift', `${category}.jsonl`)

      // Use it.skip instead of silently continuing — makes missing fixtures visible in test output
      if (!existsSync(fixturePath)) {
        it.skip(`${category}: fixture not yet created`)
        continue
      }

      describe(category, () => {
        it('parseSessionInfo does not throw', async () => {
          const info = await tc.adapter.parseSessionInfo(fixturePath)
          // May return null (graceful skip) but must not throw
          // If it does return info, basic fields should be populated
          if (info) {
            expect(info.id).toBeTruthy()
            expect(info.source).toBeTruthy()
          }
        })

        it('streamMessages does not throw and yields valid messages', async () => {
          const messages = []
          // Must not throw — unknown fields should be silently ignored
          for await (const msg of tc.adapter.streamMessages(fixturePath)) {
            messages.push(msg)
          }
          // Should yield at least some messages (the fixture has valid core structure)
          // For v_missing_optional, 0 messages is acceptable if core fields are truly missing
          for (const msg of messages) {
            expect(['user', 'assistant', 'system', 'tool']).toContain(msg.role)
            expect(typeof msg.content).toBe('string')
          }
        })

        it('no uncaught errors in tool call extraction', async () => {
          // Specifically tests that toolCalls parsing handles drift gracefully
          const messages = []
          for await (const msg of tc.adapter.streamMessages(fixturePath)) {
            messages.push(msg)
          }
          for (const msg of messages) {
            if (msg.toolCalls) {
              for (const tc of msg.toolCalls) {
                expect(typeof tc.name).toBe('string')
              }
            }
          }
        })
      })
    }
  })
}
```

#### Test assertions — the key principle is **no throws**

1. `parseSessionInfo()` must not throw on unknown fields — it may return `null` (graceful skip) or partial `SessionInfo`
2. `streamMessages()` must not throw — it may yield fewer messages or messages with empty content
3. `usage` and `toolCalls` extraction must not throw on type mismatches — they may be `undefined`
4. No assertion on exact values — only structural validity (role is one of the known values, content is a string)

**Fixture generation guide** — for each adapter, study its format in `tests/fixtures/<adapter>/sample.jsonl` and create drift variants:
- `v_future_fields`: Take existing sample, add 3-5 plausible new fields at each nesting level
- `v_missing_optional`: Take existing sample, remove all non-essential fields (keep only the minimum needed for the parser to not crash)
- `v_changed_types`: Take existing sample, change types of 2-3 fields (string->number, array->string, object->null)

**Verification**:
1. All 10 JSONL-based adapters pass all 3 drift categories without any test failures
2. If an adapter does throw on drift, the test catches it — revealing a hardening opportunity
3. New adapters added in the future must include `schema_drift/` fixtures (enforced by a `describe.each` pattern)
4. Run: `npm test -- --grep "Schema drift"` — should be green across all adapters

---

## Rollback & Backward Compatibility

### #1 Keychain Migration

If a user downgrades to an older version after Keychain migration, the old version reads `settings.json` which now has the API keys removed. The old version will see empty keys and API features will stop working.

**Mitigation**:
- The migration writes a `keychainMigrated: true` flag to `settings.json` (see updated `migrateKeysToKeychain()` above). This flag is informational for diagnostics.
- Downgrade instructions: run `security delete-generic-password -s com.engram.app -a aiApiKey` (and similarly for `titleApiKey`, `vikingApiKey`) then re-enter keys in the old version's Settings UI.
- The old version ignores the unknown `keychainMigrated` key harmlessly.

### #18/#19 DB Schema Changes

New columns (`quality_score` on `sessions`) and new tables (`session_files`) are purely additive:
- `ALTER TABLE sessions ADD COLUMN quality_score REAL` — old versions ignore unknown columns (SQLite behavior).
- `CREATE TABLE IF NOT EXISTS session_files (...)` — old versions never query this table, so it is invisible to them.
- `DROP TABLE` is never needed. FTS rebuild only happens on `FTS_VERSION` bump, which old versions do not trigger.

### General Principle

All migrations in this spec are forward-only and additive (`ALTER TABLE ADD COLUMN`, `CREATE TABLE IF NOT EXISTS`). Old versions of Engram continue to work with the new schema because SQLite ignores unknown columns in `SELECT *` and explicit column lists. No destructive schema changes (DROP, RENAME, ALTER TYPE) are used.

---

## Performance Baselines

Quantitative thresholds for performance-sensitive features. CI or manual benchmarks should verify these on every release.

| Feature | Metric | Threshold | Notes |
|---------|--------|-----------|-------|
| #17 StreamingJSONLReader | Peak memory for 100MB JSONL file | < 30MB | Measured on M2; streaming parser must not buffer entire file |
| #17 StreamingJSONLReader | Parse time for 100MB JSONL file | < 5s | On M2 with SSD; wall-clock time including JSON decode |
| #5 get_context with `include_environment` | Response time (end-to-end) | < 200ms | All data from local DB and cached environment; no network calls |
| #19 file_activity query | Query time for 100K `session_files` rows | < 50ms | Indexed query; measured with `EXPLAIN QUERY PLAN` confirming index use |
| #24 Schema drift tests | Total test suite time increase | < 2s | Additive cost over baseline `npm test`; fixture files are small by design |

---

## Cross-Cutting Concerns

### Build Impact

- **Sprint 1** (#1-4): Swift + TypeScript changes. Run `xcodegen generate` after adding `SessionContextMenu.swift`. Run `npm run build` after TS changes.
- **Sprint 2** (#5, 17, 18, 19, 24): Mixed. `npm run build` and `npm test` for TS; Swift-only for #17 (MessageParser streaming).
- **Sprint 3** (#8-11): Swift only. `xcodegen generate` after adding `SkeletonView.swift`, `OnboardingView.swift`.
- **Sprint 4** (#6, 7, 12, 13): Mixed. Both `npm run build` and `xcodegen generate`.
- **Sprint 5** (#14-16, 23): Mixed. Both build systems.

### Testing Strategy

| Item | Test Type | Automated |
|------|-----------|-----------|
| #1 | Manual keychain verification + daemon startup | No |
| #2 | Unit test `ipMatchesCIDR`, add auth middleware test | Yes |
| #3 | Manual test with special-character paths | No |
| #4 | Markdown rendering check | No |
| #5 | Vitest: `handleGetContext` with `include_environment: true` | Yes |
| #6-8 | Manual UI testing | No |
| #9-11 | Manual visual testing (skeleton, empty states, anti-flicker) | No |
| #12 | Vitest: `extractContent()` produces `[Image: ...]` placeholder | Yes |
| #13 | Manual keyboard shortcut testing | No |
| #14 | Vitest: `checkMonthlyCost()` with mock DB | Yes |
| #15 | Manual battery/AC transitions | No |
| #16 | Vitest: `MessageTypeClassifier` with new types | Yes |
| #17 | Manual + Xcode Instruments memory profiling | No |
| #18 | Vitest: `computeScore()` with fixture data | Yes |
| #19 | Vitest: file path extraction + DB integration | Yes |
| #23 | Vitest: all three check functions | Yes |
| #24 | Vitest: schema drift across 10 adapters | Yes |

### Implementation Order

```
Sprint 1:
  #3 (trivial, standalone) -> #4 (docs, standalone)
  #1 (keychain) -> #2 (network security, uses keychain for token storage)

Sprint 2:
  #5, #18, #19, #24 (all independent)
  #17 (foundational refactor — #12 depends on it)

Sprint 3:
  #9 (skeleton) -> #10 (onboarding, uses EmptyState styles)
  #11, #8 (independent)

Sprint 4:
  #6, #7, #12, #13 (all independent; #12 uses streaming parser from #17)

Sprint 5:
  #14 (cost alerts, depends on session_costs from readout spec)
  #15, #16, #23 (independent)
```

### Critical Files for Implementation

- `macos/Engram/Views/Settings/SettingsIO.swift` — Add KeychainHelper, migration logic (#1)
- `src/web.ts` — Auth middleware, CORS, CIDR enforcement (#2), polling endpoint (#15)
- `src/tools/get_context.ts` — Aggregation upgrade (#5)
- `macos/Engram/Views/Resume/TerminalLauncher.swift` — Ghostty fix (#7), escape function visibility (#3)
- `macos/Engram/Views/SessionList/SessionTableView.swift` — Context menu expansion (#8)
- `macos/Engram/Views/SessionListView.swift` — Target for both #9 (empty states) and #11 (anti-flicker)
- `macos/Engram/Core/MessageParser.swift` — Shared by #12 (image handling), #16 (thinking flag), #17 (streaming)
- `macos/Engram/Models/MessageTypeClassifier.swift` — Core logic for #16 (transcript enhancement)
- `macos/Engram/MenuBarController.swift` — Hub for #10 (onboarding), #13 (keyboard shortcuts), #15 (badge timer)
- `src/core/session-tier.ts` — Core file for #18 (scoring)
- `src/core/indexer.ts` — Central integration point for #18 and #19
- `src/tools/lint_config.ts` — Core file for #23 (health checks)
- `src/core/monitor.ts` — Foundation for #14 (cost budget alerts) and #23 (health checks)
- `tests/adapters/claude-code.test.ts` — Pattern reference for #24 (schema drift tests)

### Files to Create (All Sprints)

```
macos/Engram/Components/SessionContextMenu.swift       # #8
macos/Engram/Components/SkeletonView.swift             # #9
macos/Engram/Views/OnboardingView.swift                # #10
macos/Engram/Models/ImageAttachment.swift              # #12 (Phase 2)
macos/Engram/Core/PowerAwareScheduler.swift            # #15
macos/Engram/Views/Transcript/FilePathLink.swift       # #16
src/tools/file_activity.ts                             # #19
docs/PRIVACY.md                                        # #4
docs/SECURITY.md                                       # #4
tests/adapters/schema-drift.test.ts                    # #24
tests/fixtures/*/schema_drift/*.jsonl                  # #24
```
