# Design Doc: Diagnostic Bundle Export

- **Status**: In review
- **Owner**: Codex
- **Date**: 2026-07-08
- **Related**: Wave 5 task 6, `CHANGELOG.md`

## Problem

Engram has useful troubleshooting state spread across the app bundle, the Swift
service, the SQLite index, service logs, and `~/.engram/settings.json`, but there
is no one-click way for a user to export a small support artifact. Asking users
to copy each piece manually is slow and error-prone, while raw database or log
exports would expose more local session data than the app needs for a first-pass
diagnostic.

The immediate need is an app-only export that captures aggregate health signals
without adding a new product surface or changing the service write model.

## Goals / Non-goals

- Goals: add an "Export Diagnostics..." button in Settings that writes one
  pretty-printed JSON file through an `NSSavePanel`.
- Goals: include app version/build, macOS version, current `EngramServiceStatus`,
  aggregate database counts, database file size, sanitized recent service log
  lines, and redacted settings content.
- Goals: keep the bundle composer pure and injectable so JSON shape, redaction,
  and service-unreachable behavior are unit-testable without UI.
- Non-goals: no MCP surface, no zip archive, no new dependency, no raw database
  bundle, no per-session rows, no project paths, no automatic upload, no network
  calls, and no shelling out to `log show`.

## Current state

At commit `a15b806aa03b`, Settings already has an About section in
`macos/Engram/Views/Settings/AboutSettingsSection.swift:4` and displays app
version from `Bundle.main` at
`macos/Engram/Views/Settings/AboutSettingsSection.swift:18`.

The app already reads through `DatabaseManager` in the About database panel at
`macos/Engram/Views/Settings/AboutSettingsSection.swift:31`. The read facade
provides `readInBackground`, aggregate `stats()`, and `dbSizeBytes()` in
`macos/Engram/Core/Database.swift:781` and
`macos/Engram/Core/Database.swift:792`.

The service client already exposes `status()` and `serviceLogs(...)` read
commands in `macos/Shared/Service/EngramServiceClient.swift:25` and
`macos/Shared/Service/EngramServiceClient.swift:75`. The status DTO is
`EngramServiceStatus` in `macos/Shared/Service/EngramServiceModels.swift:47`.
The service log DTO explicitly documents that its message is already sanitized in
`macos/Shared/Service/EngramServiceModels.swift:1070`; the log stream view
already consumes the same sanitized ring through service IPC in
`macos/Engram/Views/Observability/LogStreamView.swift:128`.

Settings are read from `~/.engram/settings.json` through `readEngramSettings()`
in `macos/Engram/Views/Settings/SettingsIO.swift:122`. The app stores AI keys
under `aiApiKey` and `titleApiKey`, preferring Keychain and falling back to JSON
only for unsigned/ad-hoc builds, in
`macos/Engram/Views/Settings/AISettingsSection.swift:324` and
`macos/Engram/Views/Settings/AISettingsSection.swift:373`.

The privacy policy states that Engram is local-first with zero telemetry, stores
non-sensitive settings in `~/.engram/settings.json`, and stores API keys in the
macOS Keychain under service `com.engram.app` rather than plaintext settings
(`docs/PRIVACY.md`). It also documents optional remote offload. Current service
code reads the remote server URL from settings and the bearer token from
Keychain or environment, while the privacy policy still flags the token-bearing
remote-offload boundary as sensitive.

## Proposed design

Add an app-target `DiagnosticBundleComposer` that accepts injected app info,
service status, database stats, recent sanitized service log lines, and a
settings dictionary, then returns pretty-printed sorted JSON `Data`. The
composer owns the diagnostic JSON shape and redacts sensitive settings keys
before encoding. The current app-owned sensitive settings keys are `aiApiKey`
and `titleApiKey`; the redaction list also defensively covers exact
remote-offload token key names in case a legacy or manually edited settings file
contains one. Redaction is exact-key and recursive so non-secret keys such as
`usageTokenLimits` remain intact.

Add a read-only `diagnosticStats()` helper to `DatabaseManager`. It will return
only aggregate counts: sessions by source, sessions by tier, index jobs by
status, and database file size. The SQL remains under existing
`readInBackground`; it does not open a writer, return session rows, or include
paths. If an older database lacks `session_index_jobs`, the job-status map is
empty instead of failing the export.

Add a Diagnostics group to `AboutSettingsSection` with a single "Export
Diagnostics..." button. The button opens an `NSSavePanel`, gathers app info from
`Bundle` and `ProcessInfo`, calls `EngramServiceClient.status()`, calls
`serviceLogs(..., limit: 200)`, reads `diagnosticStats()`, reads settings with
`readEngramSettings()`, composes JSON, and writes the selected file atomically.
If the status call fails, the bundle still writes a `service` object with a
`state: "unreachable"` marker and a bounded error message. If service logs are
unavailable, the bundle writes an empty `recentLogs` array rather than failing.

There are no data or schema changes. There are no service, MCP, or CLI protocol
changes. There are no backfills.

## Invariants affected

- Single-Writer Discipline: preserved. The new database helper uses existing
  app read APIs and does not open a SQLite writer.
- Service Socket Security: preserved. The app uses existing read-only service
  IPC commands (`status` and `serviceLogs`) and does not add mutating commands or
  bypass capability-token handling.
- Tier Visibility: preserved. The diagnostic bundle exports aggregate tier
  counts only; it does not change list or search visibility semantics.

No new invariant is introduced because the change adds a bounded app export
surface without new persistent behavior, schema, service command, or product
write path.

## Alternatives considered

Shipping a zip with the raw database and logs was rejected because it would
include session rows, paths, and raw local data that are unnecessary for the
minimal support artifact.

Adding an MCP tool was rejected because the task is app-only and a remote MCP
surface would expand the privacy and authorization footprint.

Reading unified logs with `log show` was rejected because the service already
keeps a sanitized in-process ring, and shelling out would capture broader OS log
data than needed.

Uploading diagnostics automatically was rejected because `docs/PRIVACY.md`
commits to zero telemetry and local-first behavior.

## Test plan

- Add focused `EngramTests` for the pure composer: top-level keys are present,
  planted API keys/tokens never appear in output, and a service-unreachable
  marker still produces valid JSON.
- Add a read-facade test for `diagnosticStats()` using a temporary database,
  visible and hidden sessions, multiple tiers, and `session_index_jobs` rows.
- Intentionally do not UI-test `NSSavePanel`; the UI work is thin wiring around
  the tested composer and existing system save panel.
- No Swift/TypeScript parity fixtures are needed because this is Swift app-only
  behavior with no retained TypeScript mirror.

## Rollout

The change ships with the next macOS app build. No version/tag bump, migration,
backfill, or service restart is required. Reverting removes the Settings button,
the app-only composer, the read-only database helper, and the focused tests; no
user data or schema state needs cleanup.

## Risks and open questions

The main privacy risk is accidentally including secrets from settings. The first
guard is the exact-key recursive redaction list, including the currently
implemented AI keys and documented remote-offload token names. The second guard
is a unit test that plants secret values and asserts the encoded JSON never
contains them.

The main reliability risk is a stopped or mismatched service. The bundle treats
status failure as data, not fatal export failure, and writes a valid JSON file
with a `service` unreachable marker.

Open question during implementation: if future settings add another secret key,
that key must be added to `DiagnosticBundleComposer.sensitiveSettingsKeys` in
the same change that introduces it.
