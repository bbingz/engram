# Design Doc: Embedding Guardrails (Circuit Breaker)

- **Status**: Accepted
- **Owner**: Codex
- **Date**: 2026-07-09
- **Related**: Wave-6 task 9; P1 F1 in `docs/p1-semantic-memory-design-2026-06.md`;
  TS reference `src/core/embeddings.ts` `ollamaDown`; follow-up
  `docs/followups.md` (`ai_audit_log` desensitization precondition)

## Problem

Swift already has an opt-in online embedding client
(`OpenAICompatibleEmbeddingClient`) and session/insight embedding backfills in
`EngramServiceRunner`. When the configured provider is down, every maintenance
cycle and every semantic/hybrid search still hammers the network. That wastes
time, can hit rate limits, and turns a temporary outage into continuous noise
in service logs.

The TypeScript reference already soft-trips after a failed Ollama call
(`ollamaDown` + 60s cooldown in `src/core/embeddings.ts`). Product Swift has
no equivalent guardrail (P1 F1 partial).

## Goals / Non-goals

- Goals:
  - Wrap `provider.embed()` with a per-provider circuit breaker: closed → open
    after **N consecutive transport failures**, cooldown, then half-open probe.
  - Thread-safe under concurrent backfills and search embeds.
  - Telemetry via `os_log` subsystem `com.engram.service` (category `ai`) plus
    in-memory counters exposed through the existing `telemetry` diagnostics
    surface (same ephemeral process-memory model as `ServiceTelemetryCollector`
    / `EngramServiceStatus` — not DB-backed).
  - When the breaker is open, backfill skips cleanly: jobs remain
    `pending` / `failed_retryable` and retry later; never permanently fail a
    job solely because the breaker is open; no busy-loop.
- Non-goals:
  - **No `ai_audit_log` rows** for embed calls (explicit descope). Body
    desensitization for that table remains a follow-up before any writer lands
    (`docs/followups.md`).
  - No schema/migrations, no new IPC command, no UI chrome, no cost-token
    accounting expansion, no change to FTS index-job retry budgets.
  - No local embedding provider or sqlite-vec work.

## Current state

At commit `c99c5b07`:

- Client: `macos/Shared/EngramCore/AI/EmbeddingClient.swift` —
  `OpenAICompatibleEmbeddingClient.embed(_:)` throws `EmbeddingError` on
  config/HTTP/malformed failures; no cooldown.
- Settings: `macos/Shared/EngramCore/AI/EmbeddingSettings.swift` loads opt-in
  config from env / `settings.json`.
- Session backfill: `SessionEmbeddingBackfill.pendingSessions` selects
  `session_index_jobs` where `job_kind = 'embedding'` and
  `status IN ('pending', 'failed_retryable')`; embed runs outside the writer
  gate; success → `markCompleted`, empty chunks → `markNotApplicable`
  (`macos/EngramCoreWrite/Indexing/InsightEmbeddingBackfill.swift`).
- Insight backfill: pending rows without `insight_embeddings`; no job table —
  skip simply means rows stay without embeddings until a later cycle.
- Runner wiring: `EngramServiceRunner.backfillSessionEmbeddingsOnce` /
  `backfillInsightEmbeddingsOnce` construct a fresh provider per call via
  `providerFactory` (`macos/EngramService/Core/EngramServiceRunner.swift`).
  Best-effort wrappers catch errors and log; they do **not** call
  `markRetryable` / `failed_permanent` on embed failure today.
- Search path: `SQLiteEngramServiceReadProvider.semanticSearch` also calls
  `provider.embed([query])` with the same factory pattern.
- Diagnostics: `ServiceTelemetryCollector` + `telemetry` IPC command return
  ephemeral `ServiceTelemetrySnapshot`; logs via `ServiceLogger` →
  `com.engram.service`.

## Proposed design

### Breaker parameters

| Param | Value | Rationale |
|-------|-------|-----------|
| **N (failure threshold)** | `5` | Require a short streak of transport failures before opening; avoids tripping on a single blip while still protecting quickly. |
| **Cooldown** | `60s` | Matches TS `ollamaDown` recovery window. |
| **Half-open** | single in-flight probe | First allow after cooldown; success → closed (reset consecutive failures); failure → re-open with a fresh cooldown. Concurrent requests during open/half-open probe are rejected without calling the network. |

### Transport vs non-transport failures

Count toward N only:

- `URLError` (timeouts, DNS, connection refused, etc.)
- `EmbeddingError.http(status)` where `status >= 500` or `status == 429`
- Any other non-`EmbeddingError` thrown by the session layer (treated as transport-ish)

Do **not** open the breaker for:

- `EmbeddingError.notConfigured`
- `EmbeddingError.malformedResponse`
- `EmbeddingError.http(4xx)` other than 429 (auth/config bugs)
- `EmbeddingError.circuitOpen` (rejection while already open)

### Components

1. **`EmbeddingCircuitBreaker`** (`macos/Shared/EngramCore/AI/EmbeddingCircuitBreaker.swift`)
   - Process-injectable store (shared instance at service startup; tests pass a
     private store). Per-provider key = `baseURL|model`.
   - `NSLock`-guarded state machine: `closed` / `open` / `halfOpen`.
   - Injectable `now: () -> Date` for unit tests.
   - In-memory counters per provider: consecutive failures, total transport
     failures, successes, opens, rejections, half-open probes, last open time.

2. **`GuardedEmbeddingProvider`** (same file)
   - Decorator over `any EmbeddingProvider`.
   - `embed`: `try store.allowRequest(key)` → call inner →
     `recordSuccess` / `recordTransportFailure`.
   - Throws `EmbeddingError.circuitOpen` when open (or half-open without the
     probe slot).

3. **`EmbeddingError.circuitOpen`**
   - Added to the existing public error enum so callers can branch without
     string matching.

4. **Service wiring**
   - One shared `EmbeddingCircuitBreaker` owned by service process (static /
     injected into runner factory + read provider factory).
   - Default `providerFactory` wraps `OpenAICompatibleEmbeddingClient` with
     `GuardedEmbeddingProvider`.
   - `backfill*Once`: on `circuitOpen`, return `0` immediately (no write phase,
     no job mutation). Best-effort logs at `ServiceLogger` category `.ai`.
   - Semantic search: same wrap; open breaker → degrade to keyword/nil path
     (existing `try?` / nil fallback behavior).

5. **Telemetry**
   - `os_log` via `ServiceLogger` (subsystem `com.engram.service`, category
     `ai`) on state transitions: open, half-open probe allowed, close after
     probe success, re-open after probe failure. Optional notice when a batch
     is skipped because open.
   - Extend `ServiceTelemetrySnapshot` with
     `embeddingBreakers: [EmbeddingBreakerTelemetry]` (provider key, state,
     counters). Collector snapshot merges breaker store snapshots. Still
     ephemeral — resets on service restart. **No DB, no `ai_audit_log`.**

### Job states when breaker is open (session embedding jobs)

| Job status before | On open-breaker skip | Notes |
|-------------------|----------------------|-------|
| `pending` | stays `pending` | Selected again on next maintenance cycle after recovery. |
| `failed_retryable` | stays `failed_retryable` | Breaker skip does not call `markRetryable`; `retry_count` unchanged. |
| `completed` / `not_applicable` / `failed_permanent` | not selected | Unchanged. |

Insight embeddings have no job row: open breaker simply leaves rows without
`insight_embeddings` until a later successful cycle.

Invariant: open breaker never writes `failed_permanent` and never increments
`retry_count`.

No busy-loop: backfill still rides the existing initial + periodic scan cadence
(seconds/minutes), not a tight retry spin.

## Invariants affected

None of the numbered invariants in `docs/invariants.md` change. Single-writer
discipline is preserved (network I/O remains outside the writer gate; skip
path performs no writes). No new ledger entry required.

## Alternatives considered

- **Trip after first failure (literal TS port)** — simpler, but online
  providers are flakier than local Ollama; N=5 reduces false opens.
- **Mark jobs `failed_retryable` on open** — would burn retry budget toward
  `failed_permanent` for a provider outage; rejected by task wording.
- **`ai_audit_log` per embed** — explicitly descoped until desensitization is
  designed (`docs/followups.md`).
- **Actor-only breaker** — fine for async, but half-open single-flight is
  clearer with a short critical section via `NSLock` used from both sync
  admission and async completion.

## Test plan

- Unit (`EngramCoreTests`):
  - Opens after N consecutive transport failures.
  - Half-open probe success closes; probe failure re-opens.
  - Concurrent tasks observe a consistent open state / counters (mock
    provider).
  - Non-transport errors do not open the breaker.
- Integration (`EngramServiceCoreTests`):
  - Open breaker: session embedding jobs remain `pending` (or
    `failed_retryable` if already), `retry_count` unchanged, zero chunks
    written.
  - Telemetry snapshot includes breaker counters after trips.
- Intentionally not tested: live third-party HTTP; os_log delivery to Console.

## Rollout

- App + service rebuild (no migration). Breaker starts closed; state is
  process-local.
- Revert: remove decorator wiring / new file; telemetry field is additive and
  optional for older clients if decoding is lenient (in-process DTOs only).

## Risks and open questions

- **Risk (low)**: N=5 / 60s may need tuning for aggressive rate limits —
  counters in telemetry make that observable.
- **Risk (low)**: Shared store across search + backfill means a backfill outage
  also degrades semantic query embeds for that provider key — intentional.
- Open: none blocking implementation.
