# Engram Security

**Last updated**: 2026-04-24

## Architecture

Engram's macOS runtime runs as two local Swift processes:
1. **EngramService** — owns indexing, SQLite writes, background tasks, and service commands
2. **SwiftUI app** — menu bar UI, communicates with EngramService over a Unix domain socket

Node/TypeScript code is retained as development, fixture, and migration reference material. It is not bundled into the default macOS app runtime.

## Credential Storage

API keys (AI provider, title generation) are stored in the **macOS Keychain** (service: `com.engram.app`). The `settings.json` file contains a `"@keychain"` sentinel — never the actual key value.

Legacy plaintext keys are automatically migrated to Keychain on first launch after upgrade, with read-back verification before the plaintext value is removed.

## Network Security

### Default (local Unix socket)
- EngramService listens on a Unix domain socket under `~/.engram/run/engram-service.sock`
- The default macOS app runtime does not expose a localhost HTTP API
- The socket is local to the current user account and is not reachable from the network

### Optional legacy HTTP tooling
Some retained development/reference tooling still understands the older HTTP settings. Do not rely on those paths for the default macOS app runtime. If any local HTTP tool is explicitly enabled for development, keep it bound to localhost unless the following controls are present:
- **CIDR whitelist** for non-localhost binding
- **Bearer token authentication** for write endpoints
- **CORS protection** for browser-originated requests

### Content Filtering
Before transmitting data to external AI providers, content is filtered:
- System injections (`<INSTRUCTIONS>`, `<system-reminder>`, etc.) are stripped
- Secrets are redacted: `PGPASSWORD`, `MYSQL_PWD`, `sk-` API keys, Bearer tokens
- Session content is capped at 2MB with head-heavy truncation

## Database

- SQLite in WAL mode at `~/.engram/index.sqlite`
- EngramService owns data-plane writes through `ServiceWriterGate`
- The SwiftUI app and MCP tools route mutating operations through the service boundary
- App-local settings, Keychain items, and launch-agent registration remain app-owned
- All SQL queries use parameterized statements (no string interpolation)

## Code Signing

Development builds use ad-hoc signing (`-`). Production builds should be signed with a Developer ID certificate and notarized via Apple.

## Reporting Vulnerabilities

If you discover a security issue, please report it via GitHub Issues at the project repository.
