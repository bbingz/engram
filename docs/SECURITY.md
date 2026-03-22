# Engram Security

**Last updated**: 2026-03-22

## Architecture

Engram runs as two local processes:
1. **Node.js daemon** — indexes sessions, serves HTTP API, runs background tasks
2. **SwiftUI app** — menu bar UI, communicates with daemon via localhost HTTP

## Credential Storage

API keys (AI provider, Viking, title generation) are stored in the **macOS Keychain** (service: `com.engram.app`). The `settings.json` file contains a `"@keychain"` sentinel — never the actual key value.

Legacy plaintext keys are automatically migrated to Keychain on first launch after upgrade, with read-back verification before the plaintext value is removed.

## Network Security

### Default (localhost)
- Daemon binds to `127.0.0.1:3457` — accessible only from the local machine
- No authentication required for localhost connections

### Non-localhost Binding
When configured with `httpHost: "0.0.0.0"`:
- **CIDR whitelist required** — daemon refuses to start if `httpAllowCIDR` is empty
- **Bearer token authentication** — all write endpoints (POST/PUT/DELETE/PATCH) require `Authorization: Bearer <token>`
- Token is auto-generated on first non-localhost startup and stored in `settings.json`
- **CORS protection** — cross-origin requests from non-localhost origins are rejected
- Origin validation uses `URL` parsing (not prefix matching) to prevent bypass

### Content Filtering
Before transmitting data to external services (Viking, AI providers), content is filtered:
- System injections (`<INSTRUCTIONS>`, `<system-reminder>`, etc.) are stripped
- Secrets are redacted: `PGPASSWORD`, `MYSQL_PWD`, `sk-` API keys, Bearer tokens
- Session content is capped at 2MB with head-heavy truncation

## Database

- SQLite in WAL mode at `~/.engram/index.sqlite`
- Node owns the schema; Swift reads via GRDB (read-only pool)
- Swift writes only to extension tables (`favorites`, `tags`)
- All SQL queries use parameterized statements (no string interpolation)

## Code Signing

Development builds use ad-hoc signing (`-`). Production builds should be signed with a Developer ID certificate and notarized via Apple.

## Reporting Vulnerabilities

If you discover a security issue, please report it via GitHub Issues at the project repository.
