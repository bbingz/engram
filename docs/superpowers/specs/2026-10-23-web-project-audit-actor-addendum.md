# Web project audit actor propagation

Status: implemented and verified locally, 2026-10-23; not pushed/deployed. Addendum to
[identity auth phase 2](2026-10-08-web-tailscale-identity-auth-design.md#6-phase-2-actor-propagation-separate-pr).

## Current-source corrections and scope

At the pre-change baseline, Web project commands overwrote attribution with
`mcp`; batch execution wrote `batch` even when its request carried another
actor. The migration log already stored unrestricted TEXT, but the Swift actor
enum only represented cli/mcp/swift-ui/batch. Forwarding a new DTO field alone is
insufficient. Alias add/remove have neither an actor field nor an audit-log
write in the current service, contrary to the older design assumption. Alias
history requires its own storage/retention decision and remains a separate
follow-up; this batch does not claim the whole phase 2 is complete.

## Contract

- Scope: move, archive, undo and move-batch attribution through RemoteServer,
  capability-protected IPC and the existing migration log; no schema changes.
- RemoteServer derives the value from the authenticated editor session: the
  bound identity login, or `web-editor` for credential mode. It never trusts a
  browser JSON actor or a later identity header. Existing browser key allowlists,
  CSRF checks, viewer restrictions and capability-token requirements stay active.
- Web DTOs accept an optional actor for wire compatibility. An absent actor
  from an older RemoteServer means `web-editor`, never `mcp`. Nonempty supplied
  actors must match the existing identity syntax (1-254 printable ASCII bytes,
  no whitespace, quote or backslash). Invalid data fails before filesystem work.
- Use an explicit internal audit override on native command handlers so the
  native CLI/MCP actor parsing contract is unchanged. The override participates
  in operation fingerprints, including batches, and reaches every item log.
- Audit attribution is metadata, not new authority. Existing local capability
  holders remain trusted; no extra IPC command or broader allowlist is added.
- Deploy both service and RemoteServer before claiming identity attribution on
  a host: an older service may ignore the additive DTO field. Historical rows
  are not rewritten. Existing binaries remain rollback candidates; only newly
  emitted actor values change, and the existing schema stores them as text.

## Acceptance and failure handling

1. HTTP tests fail on current source for all four project routes in credential
   and identity mode. A forged subsequent identity header cannot change the
   session actor; JSON actor injection is rejected before the writer.
2. Isolated real project move/archive/undo/batch fixtures fail on current source
   when their migration-log actors are read back. Missing actor becomes
   `web-editor`; malformed actors fail decoding. Cross-actor reuse of one
   operation ID must conflict instead of returning another actor's result.
3. Exercise encoded DTOs across the local capability-protected socket and run
   affected Web, registry and native batch regressions. Keep hosted, production
   and UI/render acceptance separate; no runtime UI layout changes are involved.
4. A failed check leaves the item open. Record RED/GREEN and any revised scope
   in the canonical follow-up and CHANGELOG/MEMO before a local commit.

## Local verification receipt

HTTP RED: 1 test / 8 expected attribution assertions. Service RED: 2 tests /
8 expected assertions (invalid actor decoding, audit readback and replay).
Final GREEN: 60 RemoteServer HTTP/auth/IPC tests; 29 service/operation-registry
and long-operation IPC tests; 34 native batch/migration-store tests, all with
zero failures. Lint and invariants passed. Evidence lives under
`/tmp/engram-leader-web-actor-20261023/`. These runs do not prove hosted CI,
production rollout or alias auditing. No schema migration or historical-row
rewrite occurred.

Continuation correction: the first component GREEN did not traverse the real
Service dispatcher, whose optional payload-key allowlists omitted actor. The
existing audit/replay regression now uses the real Web client, socket listener
and dispatcher before SQL readback. It reproduced invalid at `6d30437a`; after
adding actor to all four IPC allowlists, 18 related service tests passed.
Evidence: `/tmp/engram-leader-web-dispatch-20261023/`. Browser actor injection
remains rejected by the unchanged HTTP body allowlists.
