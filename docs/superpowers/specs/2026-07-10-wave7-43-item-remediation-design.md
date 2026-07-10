# Wave 7 43-Item Remediation Design

**Date:** 2026-07-10  
**Baseline:** `main` at `a011e2fb`  
**Input:** multi-expert audit with 42 findings plus the user-reported scan I/O issue  
**Delivery:** sequential remediation waves, then one release build, local install, and runtime smoke

## Goal

Close every source-confirmed finding from the 2026-07-10 audit, add an OS-cooperative indexing schedule that reduces idle filesystem I/O, preserve Engram's Swift-only product boundaries, and leave the installed application verified against the final source.

The finding count is 43:

- `C01`
- `H01` through `H12`
- `M01` through `M20`
- `L01` through `L09`
- `S01` adaptive scan scheduling and maintenance decoupling

An audit claim is not implemented merely to satisfy the count. Each item must first be classified from current source as `CONFIRMED`, `PARTIAL`, or `OVERTURNED`. Confirmed and partial items require code, test, or documentation remediation. Overturned items require exact source evidence and a closeout note.

## Constraints

- Swift product behavior remains authoritative. Do not recreate Node product entrypoints.
- App and MCP writes continue through `EngramServiceClient` and `ServiceWriterGate`.
- Do not edit `macos/Engram.xcodeproj`; edit `macos/project.yml` and regenerate with XcodeGen only if target membership changes.
- Parser behavior changes require fixture/parity coverage.
- `subagent` and `dispatched` sessions remain `tier = 'skip'` throughout ambiguous, unlink, and cascade transitions.
- Stable identities and fingerprints must not use `hashValue`.
- Every behavioral fix follows red-green-refactor. The failing test must be observed before production code is changed.
- Each wave is independently testable and committed. Do not mix later-wave cleanup into an earlier wave.
- Do not build, install, launch, or restart Engram until all six waves and the final verification gate are complete.
- Preserve unrelated user changes. The untracked audit report is input evidence, not an implementation scratch file.

## Architecture

### Wave 7A: Index and FTS Integrity

Scope: `C01`, `H01`, `H10`, `M03`, `M04`, `L04`, `L05`.

1. Startup deferral must never advance `file_index_state` to an unparsed file identity. The existing identity remains dirty so a later recent scan can recover it.
2. Active-file grace uses the same rule: deferral is not success. A future scan must see the identity mismatch.
3. A failed tail parse falls through to full parse in the same pass when full parse remains safe; terminal parser limits remain terminal.
4. FTS shadow rebuild finalization must be lossless. Before swap, every visible session must have rebuilt content or preserved live-table rows. Permanent and not-applicable jobs cannot silently delete searchable content.
5. The authoritative snapshot fingerprint incorporates normalized searchable message content in the existing parse pass. No second transcript read is allowed. Tail indexing must extend a deterministic content fingerprint or fall back to a full parse when the old fingerprint cannot be extended safely.
6. FTS job completion is impossible after message truncation. Formula-versioned quality backfill may update stale non-zero scores without rewriting current-version rows every launch.

### Wave 7B: Parent and Tier Lifecycle

Scope: `H04`, `H05`, `M17`, `M18`.

Define one lifecycle invariant: any row with `agent_role IN ('subagent', 'dispatched')` remains `tier = 'skip'` unless an explicit future product decision changes the role itself.

- Ambiguous suggestions retain dispatched role and skip tier.
- Parent deletion and `clearParentSession` clear relationship fields but preserve skip tier for both agent roles.
- Suggestion dismissal records a durable manual decision so startup backfills do not immediately recreate it.
- Polycli inference requires dispatch-specific evidence; same cwd and temporal overlap alone are insufficient.

### Wave 7C: Service, IPC, and Cancellation

Scope: `H02`, `H03`, `M01`, `M02`, `M05`, `L01`, `L02`, `L03`, `S01`.

Split service work into explicit operation classes:

- short user mutation: bounded writer wait;
- long maintenance: no false 60-second `WriterBusy`, but cancellation-aware and batch-bounded;
- pure read: never increments `databaseGeneration`;
- external or filesystem mutation: returns only after completion or reports a structured partial/cancelled result.

`generateSummary` must leave headroom between provider timeout and IPC frame timeout. `linkSessions` and project batch operations check cancellation between bounded units and report partial progress deterministically.

Replace the fixed five-minute compound loop with a scheduling policy:

- initial scan remains a one-time recovery path;
- incremental scan target interval starts at 15 minutes;
- consecutive zero-change scans back off to 30 then 60 minutes;
- a changed scan returns the target to 15 minutes;
- macOS `NSBackgroundActivityScheduler` runs at background QoS with tolerance and honors `shouldDefer`;
- Low Power Mode or serious/critical thermal state defers discretionary work;
- parent backfill and repo discovery run only after indexed changes;
- embedding, FTS drain, backup, optimize, telemetry, and other maintenance use their own due/backlog gates rather than running because a filesystem scan fired;
- cancellation is checked between phases;
- one-hour fallback guarantees eventual discovery;
- manual refresh bypasses idle backoff but not safety or single-writer rules.

The scheduler policy is a pure, injectable unit. Tests use a fake system-condition provider and fake clock; production code does not spawn `tmutil`, `mdutil`, or poll process names.

### Wave 7D: Semantic, MCP, and Security

Scope: `H06`, `H07`, `H09`, `M06` through `M16`, `L06`, `L07`.

- `generate_summary` is a mutating MCP tool and must never advertise `readOnlyHint: true`.
- Query embeddings require exact stored model and dimension compatibility. Mismatch fails closed with a structured reason.
- Service fallback warnings distinguish unavailable provider, missing corpus, model mismatch, and breaker state. MCP and service policies are documented separately where behavior intentionally differs.
- MCP semantic requests use the shared circuit-breaker behavior.
- Candidate caps are explicit approximation semantics; full-corpus claims are removed unless a measured implementation supports them.
- `memoryFileContent` resolves canonical paths, requires containment under `~/.claude/projects/*/memory/`, and rejects symlinks and non-regular files.
- Embedding API keys migrate to Keychain-backed storage, are included in diagnostic redaction, and are never written back as plaintext. Service settings rewrites enforce mode `0600`.
- Transcript redaction behavior becomes explicit and consistent across MCP reads and export, with a compatibility decision recorded in tests and docs.
- MCP structured error codes and result payloads retain `transcriptTooLarge`, memory type, role-filter, and project-root count truth.

### Wave 7E: SwiftUI Behavior

Scope: `H11`, `H12`, `M19`, `L08`.

- Command palette distinguishes an empty local result from double-source failure.
- Export keeps the result list and selection visible, exposes in-flight/success/failure state, and offers Finder reveal parity.
- Favorite toggling is symmetric in Browse and Starred views.
- Live session timestamps use the shared fractional-or-whole-seconds ISO parser.

No page redesign is included. Changes remain inside established view models, detached read patterns, accessibility identifiers, and existing visual language.

### Wave 7F: Claims, Gates, and Closeout

Scope: `H08`, `M10`, `M11`, `M20`, `L09` plus the final audit ledger.

- App UI is intentionally keyword-only; service and MCP semantic behavior is described accurately.
- `list_sessions`, `get_session.roles`, value-band availability, and project-review root counts match runtime.
- The invariant ledger executes behavioral assertions rather than checking path existence only.
- Nightly performance checks either enforce a versioned baseline with documented tolerance or state explicitly that they are observe-only.
- The audit closeout lists all 43 items with verdict, commit, tests, and remaining risk.

## Data and Migration Safety

- Schema additions use idempotent GRDB migrations and preserve existing database contents.
- FTS rebuild swaps remain transactional. The live table is not dropped until lossless shadow readiness is proven.
- Keychain migration reads legacy plaintext once, writes the secret to Keychain, removes plaintext only after confirmed write, and remains repeatable after interruption.
- Settings writes use an atomic temporary file and permissions are set before rename.
- Cancellation never claims rollback for already completed filesystem symlinks; responses expose completed and remaining counts.

## Testing Strategy

Each finding receives a named regression test or a source-grounded documentation assertion. Required suites are selected by blast radius:

- Indexing/database: `EngramCoreTests`
- Service and IPC: `EngramServiceCore`
- MCP contracts: `EngramMCPTests`
- App behavior and shared policies: `EngramTests`
- UI behavior where unit seams are insufficient: focused `EngramUITests`

After every wave, run its focused suite and `git diff --check`. After Wave 7F, run all Swift schemes listed in `AGENTS.md`, release verification, and packaged MCP golden smoke.

## Final Release Gate

Only after every wave is green:

1. Regenerate the Xcode project if `project.yml` changed.
2. Run the full Swift test matrix.
3. Run `macos/scripts/build-release.sh --local-only` with a new build number.
4. Run release verification and confirm the bundle contains no Node runtime artifacts.
5. Replace `/Applications/Engram.app` using `macos/scripts/deploy-local.sh`.
6. Launch Engram.
7. Verify app and service processes, socket creation, service health, installed plist version, code signature, and packaged `EngramMCP` `initialize` plus `tools/list`.
8. Observe at least one scheduling status response without forcing an early full scan.

## Non-Goals

- Reintroducing TypeScript product services.
- Adding vector search to the Swift app UI.
- Replacing the current database or FTS architecture.
- Detecting Spotlight or Time Machine by private APIs, process-name polling, or recurring shell commands.
- Broad visual redesign.

