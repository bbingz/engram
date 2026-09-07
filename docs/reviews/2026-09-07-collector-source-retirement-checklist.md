# Collector source-retirement checklist

Date: 2026-09-07. Scope: the local, synthetic W6 candidate in
`collector-server-web-20260905`, based on `70e362fa` plus the current drained-queue
optimization and final-session oracle changes. This is not a measured Release revision.
This is a coverage gate, not a host inventory, cutover approval, or a claim that
any host is fully lightweight. W7 remains separately authorized.

## Evidence and interpretation

- The 17 registered Swift sources are enumerated by
  `macos/Shared/EngramCore/Adapters/SourceName.swift:3` and
  `SessionAdapterFactory.swift:59`. The factory paths below are code defaults,
  not observed paths or enabled settings on any host. `<home>` means the
  adapter's explicitly resolved home, not a discovered user directory.
- `macos/EngramCollectorCore/CollectorRuntime.swift:511` and
  `CollectorPublicationWorker.swift:120` accept only `codex` and `claude-code`
  roots. Their collector representation is a stable, exact single-file
  generation, discovered through the bounded inventory/native-event path.
- `CollectorPrivacyProof.swift:155` requires unambiguous source/native identity,
  cwd, exclusion-policy eligibility and captured-generation binding.
  Primitive support for derived Claude sources at line 168 is not runtime
  enablement: Runtime policy comes only from its two accepted root sources.
  Worker line 476 uses `forceClaudeCodeSource: false`; a nondefault Claude
  profile must not be assumed equivalent to the default profile.
- `CollectorPrivacyProofTests.swift:20` covers both initial formats;
  `CollectorInventoryOwnerTests.swift:397` checks both root identities.
  Those are component contracts, not host capture/HQ evidence.
- Actual synthetic Codex real-binary evidence: two generations across Collector,
  independent HQ/M1 RemoteServers, HQ Service and Web IPC passed in
  `/tmp/engram-binary-shadow-first-root-v3.{log,xcresult}`. The later private
  HTTPS/browser run passed two tests with zero failures at 09:34 CST in
  `/tmp/engram-binary-browser-root-v2.{log,xcresult}`; rendered evidence is in
  `output/playwright/binary-shadow-20260907/browser-v2-findings.md`.
  These receipts are local-only, synthetic, and do not prove any real source
  root, Claude profile, tailnet path, or production HQ record.
- Tests CI for exact revision `70e362fa` passed in run `34081472925`:
  https://github.com/bbingz/engram/actions/runs/34081472925. This does not cover
  later uncommitted performance changes. The `9e90471b` full 30-minute synthetic
  window failed CPU (2.144809% of one core versus 2%); the optimized Release
  window and healthy-tailnet measurement remain unverified. See `CHANGELOG.md`
  for retained failure evidence and current local regression results.

## Registered sources

For **every row**, host enablement, approved real roots, latest successful real
capture, latest real HQ index, and retirement approval are `UNVERIFIED`.
The old ingestion path must remain enabled wherever the source is enabled.
No absence-of-support row may be interpreted as an absence-of-use finding.

| Source | Factory default root or dependency | Collector discovery / representation | Privacy and parser/replay evidence | Replacement gate / unsupported reason |
|---|---|---|---|---|
| codex | `<home>/.codex/sessions` | Bounded inventory + native events; exact single-file generations | Generation-bound privacy component tests; synthetic two-generation native/HQ/Web receipt above | Local synthetic subset only; three runtime roots below and real capture/HQ evidence unverified |
| claude-code | Claude profile resolver from `<home>/.engram/settings.json` | Bounded inventory + native events; exact single-file generations | Generation-bound privacy/root component tests; real-binary Claude replay not yet verified | Default and nondefault profiles need separate approved root and replay evidence |
| minimax | Derived from resolved Claude adapter | No accepted Collector runtime root | Primitive derived-source opt-in test only; runtime policy does not enable it | Unsupported runtime source; do not relabel as claude-code |
| lobsterai | Derived from resolved Claude adapter | No accepted Collector runtime root | Primitive allow-list entry; no Lobster-specific eligibility/replay proof | Unsupported runtime source; do not relabel as claude-code |
| gemini-cli | `<home>/.gemini/tmp` plus `projects.json` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| opencode | `<home>/.local/share/opencode/opencode.db` | No scoped consistent database export | No Collector replacement privacy/replay proof | Unsupported runtime source; copying a live main DB without WAL is not coverage |
| iflow | `<home>/.iflow/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| qwen | `<home>/.qwen/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| qoder | `<home>/.qoder/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| kimi | `<home>/.kimi/sessions` plus `kimi.json` | No verified composite dependency manifest | No Collector replacement privacy/replay proof | Unsupported runtime source |
| commandcode | `<home>/.commandcode/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| cline | `<home>/.cline/data/tasks` | No verified composite dependency manifest | No Collector replacement privacy/replay proof | Unsupported runtime source |
| cursor | `<home>/Library/Application Support/Cursor/User/globalStorage/state.vscdb` plus `.cursor` | No scoped consistent DB/composite export | No Collector replacement privacy/replay proof | Unsupported runtime source; main-file-only copies do not cover WAL/dependencies |
| vscode | `<home>/Library/Application Support/Code/User/workspaceStorage` | No scoped consistent DB/composite export | No Collector replacement privacy/replay proof | Unsupported runtime source |
| windsurf | `<home>/.engram/cache/windsurf` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source; no live provider API access authorized |
| antigravity | `.engram/cache/antigravity`, `.gemini/antigravity/conversations`, `.gemini/antigravity-cli/brain`, all under `<home>` | No verified composite dependency manifest | No Collector replacement privacy/replay proof | Unsupported runtime source; no live provider API access authorized |
| copilot | `<home>/.copilot/session-state` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |

## Codex runtime roots and diagnostics stay separate

No real agent runtime was inspected for this checklist. A synthetic Codex-format
JSONL fixture is not evidence about any of the following installed runtimes.
The shared six diagnostic fields are deliberately recorded separately.

| Runtime | Executable path | Version | Config home | Config file | Actually loaded instruction chain | Session start time | Approved source roots / capture / HQ |
|---|---|---|---|---|---|---|---|
| Standard Codex CLI | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED / UNVERIFIED / UNVERIFIED |
| Orca-launched Codex | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED / UNVERIFIED / UNVERIFIED |
| OpenAI-bundled Codex | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED / UNVERIFIED / UNVERIFIED |

## Missing adapters tracked separately

Grok and Pi are not members of the current registered 17-source enum. Their
approved roots, enabled use and replacement status are `UNVERIFIED`; they are
missing adapter coverage, not regressions in registered adapters. Do not scan
their real stores or infer they are unused without the bounded host transaction.

## Per-host retirement verifier, not executed

1. Obtain authorization for named hosts and exact source/config roots. Inventory
   enabled sources and Claude profiles without reading credentials or widening
   discovery; record each source instance and the three Codex runtimes separately.
2. For every enabled instance, record approved roots, actual discovery mechanism,
   exact representation/dependency set, privacy-policy revision, and a parser/
   replay fixture. Database exports must include a consistent WAL-aware snapshot;
   composite sources require a verified dependency manifest. Cache-only sources
   must not silently become live API readers.
3. Record dated generation, canonical manifest/publication digest, both independent
   durable ACKs, and the matching HQ generation/ledger/FTS/search/transcript proof.
   Compare exact bytes, messages, roles, timestamps, usage and tiering; include
   append/rename/restart, exclusion and last-good-data preservation checks.
4. Keep old ingestion for every unproved or unsupported enabled source. Stop
   retirement on any gap; do not change jobs/configs, mark a host lightweight,
   or use this local checklist as production transaction authority.

CHECKS_RUN: current enum/factory/runtime/worker/privacy source inspection; existing
local synthetic log receipts read. Table-to-enum coverage is checked separately.

CHECKS_NOT_RUN: real host enablement/root inventory, all real-source capture/HQ
checks, Claude real-binary acceptance, Grok/Pi inventory, optimized 30-minute
Release measurement, healthy-tailnet latency, retirement and W7.

WHY_NOT: host operations require the separately authorized bounded transaction;
synthetic/component evidence is intentionally not promoted into real coverage.

EVIDENCE_PATH: the source and test/log paths above; governing design section 3
at `docs/superpowers/specs/2026-09-05-collector-server-web-design.md:430` and W6
at `docs/superpowers/plans/2026-09-05-collector-server-web.md:1184`.
