# Web alias mutation audit

Status: implemented and verified locally, 2026-10-23; not pushed/deployed.
Completes the alias storage gap identified by the
[project actor addendum](2026-10-23-web-project-audit-actor-addendum.md).

## Current source and scope

Web aliases use ServiceWebMetadataProducer's exact raw-pair mutations, separately
from native manageProjectAlias's basename normalization. At the pre-change
baseline they had no durable actor record. Project migration_log is an undo/recovery journal for filesystem
operations and must not receive synthetic alias migrations.

Add bounded, service-owned history for successful Web alias state transitions.
Native alias changes, project-move aliases, authentication attempts and unchanged
requests remain outside this log's claim. No audit browser API or UI is introduced.

## Contract

- Both Web alias DTOs carry optional actor metadata. RemoteServer obtains it
  from the authenticated editor session and injects it after the existing browser
  body allowlist. A later Tailscale header cannot replace the bound session actor;
  browser actor fields remain invalid. Credential mode and older RemoteServer
  requests without the field use web-editor. Reuse the project audit actor syntax:
  1-254 printable non-whitespace ASCII bytes excluding quote and backslash.
- The capability-protected dispatcher admits the optional field. Validation fails
  before mutation. Actor metadata grants no additional authority; existing project
  visibility, exact-pair resolution, writer gate and CSRF checks stay active.
- Add web_alias_audit_log through the normal idempotent Swift schema path:
  monotonically increasing integer id, UTC created_at, action (add/remove), actor,
  published alias and published canonical identities. Store neither raw paths,
  transcript content, credentials nor whole request bodies.
- Insert exactly one row when an authorized request changes a pair. Repeated adds,
  absent removes and refused requests produce no history. Removal keeps its record
  after the alias row disappears. Opaque published identities allow correlation
  without retaining a removed raw path; this is not an anonymous audit.
- Mutation, audit insertion and retention execute in one writer.write transaction.
  Any audit insertion or pruning failure rolls the entire mutation back and
  surfaces the existing generic service-unavailable error. No false success.
- Retain the newest 10,000 transitions by insertion id. Prune within the same
  transaction after recording each new transition. Ordering does not depend on
  wall-clock monotonicity. This bounded local diagnostic history is not a permanent
  compliance ledger. No historical backfill or timer is added.
- Existing databases gain the table without rewriting aliases. Repeat migration
  preserves history. Older binaries can ignore the additive table but do not
  provide audit guarantees; deployment acceptance must verify Service and
  RemoteServer together. An older Service rejects the newly supplied actor key;
  upgrade Service before RemoteServer. An older RemoteServer with the new Service
  remains usable with web-editor attribution. Existing business responses remain
  wire-compatible; rolling back Service alone can interrupt new Web alias writes.
- The log belongs to the local service database, not the user-state import/export
  contract. Whole-database backups retain it; a user-data-only restore does not
  promise to carry diagnostic history. No new remote data surface is authorized.

## Acceptance and failure handling

1. Behavioral RED: existing code loses actor metadata/has no history; test via
   DTO decoding, authenticated HTTP and the actual service dispatcher.
2. Verify add/remove actor readback, omission fallback, no-op/refusal silence,
   published identities only, and sibling raw-pair preservation.
3. Fail audit insertion and pruning with SQLite triggers and verify rollback of
   the alias row and history. Seed 10,000 rows and verify exact retention order.
4. Verify old-schema migration plus repeat migration preserve business data/history.
5. Exercise real HTTP -> Web client -> capability socket -> dispatcher -> writer
   -> SQL readback, alongside identity-mode HTTP actor binding and browser override
   rejection. Run affected DTO, route, migration and alias tests.
6. Update followups, CHANGELOG and MEMO with actual checks and limitations. Failed
   gates leave the item open; no hosted or production claim from local tests.

## Local verification receipt

RED: 12 selected Service tests reported 20 failures (four missing-table errors
and 16 invalid-actor assertions); HTTP reported four missing-actor assertions.
GREEN: 13 Service tests, including real HTTP/socket/dispatcher/SQL and real
capability-socket attribution/error readback; 46 HTTP/client/auth/project tests;
20 migration tests. All passed with zero failures. Audit insert/prune triggers
proved rollback, and 10,000 seeded transitions proved clock-independent retention.
Lint, invariant/module/convention and diff checks passed. Evidence:
`/tmp/engram-leader-alias-audit-20261023/` (`service-red`, `http-red`,
`service-green`, `http-green`, `migrations-green` logs/xcresults).
No all-target suite, hosted CI, browser render, production schema upgrade or
mixed-version host rollout was exercised. No source files were added, so project
generation was unnecessary. Both deployment components still need a host receipt.
