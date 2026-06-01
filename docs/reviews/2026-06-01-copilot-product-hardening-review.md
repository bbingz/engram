# 2026-06-01 Copilot Product Hardening Review

Status: accepted for triage. This file records the Copilot multi-expert review
input so the security and product-hardening backlog survives cross-agent
handoff.

## Critical

1. Resume UI command injection risk.
   - Evidence cited by reviewer: `macos/Engram/Views/Resume/TerminalLauncher.swift`.
   - Problem: Resume builds terminal shell text with AppleScript escaping only;
     `cwd`, `command`, or `args` containing shell metacharacters can execute
     additional local commands when the user clicks Resume.
   - Required direction: shell-quote each shell token before AppleScript
     interpolation. Reuse the CLI resume escaping behavior where possible.
   - Status: fixed. `TerminalLauncher` now constructs shell-safe command lines
     before AppleScript interpolation and `EngramCLIResumeCommandTests` covers
     malicious shell metacharacters plus AppleScript escaping.

2. TypeScript MCP project mutators can bypass Swift single-writer.
   - Evidence cited by reviewer: `src/index.ts`,
     `src/core/daemon-client.ts`,
     `macos/Engram/Views/Settings/NetworkSettingsSection.swift`.
   - Problem: `project_move`, `project_archive`, `project_undo`, and
     `project_move_batch` can fallback to direct Node handlers when the daemon is
     unreachable unless strict single-writer is enabled.
   - Required direction: project migration mutators fail closed and require the
     Swift service pipeline regardless of the user-level fallback toggle.
   - Status: fixed. TS MCP project migration mutators now force the Swift
     service single-writer path and refuse direct fallback when the service is
     unavailable.

## Important

1. `project_move_batch` Swift/TS line protocol drift: Swift service and docs
   have moved toward JSON while the TS tool path still exposes YAML.
   - Status: fixed. TS MCP/API now require inline JSON in the legacy `yaml`
     field and reject YAML payloads; CLI file-based batch migration remains
     YAML-compatible.
2. TS `get_session` defaults include tool or blank messages, unlike Swift MCP,
   app, and export defaults.
   - Status: fixed. TS `get_session` now defaults to the shared visible
     transcript predicate.
3. HTTP transcript defaults show system prompts and agent communication that the
   app hides by default.
   - Status: fixed. TS HTTP transcript routes and Swift WebUI now use the shared
     non-empty user/assistant default and hide system prompt or agent
     communication content.
4. Web transcript pagination computes page state after visibility filtering,
   risking missing or repeated visible messages.
   - Status: fixed. TS HTTP and Swift WebUI pagination now advance by consumed
     adapter position while returning only visible messages.
5. Service stdout JSON events need newline buffering so pipe chunks do not drop
   partial JSON objects.
   - Status: fixed. `EngramServiceLauncher` buffers stdout by newline before
     decoding JSON events and logs decode errors with the raw JSON-looking line.
6. Swift service tests mutate global `HOME`, which can leak across parallel or
   failed tests.
   - Status: fixed. HOME-mutating service-core tests now use
     `ServiceCoreTestHomeScope`, a serialized scope that restores HOME on
     failure and prevents parallel tests from racing on process-global state.
7. `ServiceWriterGate` cancellation tests depend on fixed sleep instead of an
   event that proves the task entered the queue.
   - Status: fixed. The cancellation test waits for the writer-gate semaphore's
     queued waiter count instead of sleeping for a fixed duration.
8. `EmbeddingIndexer` tests need a real DB/vector-store integration case with a
   deterministic embedding client.
  - Status: fixed. `EmbeddingIndexer` now has an integration test using
     `Database`, `SqliteVecStore`, and a deterministic `EmbeddingClient`,
     covering persisted model metadata and restart skip behavior.
9. Adapter parity fixture checking should compare committed fixtures against
   regenerated canonical output.
   - Status: fixed. `check-adapter-parity-fixtures` regenerates fixtures into a
     temp tree and compares canonical JSON with volatile metadata normalized.
10. CI/release gates should harden screenshot regression skip/fail semantics,
    artifact path consistency, adapter parity freshness, and local-only release
    documentation paths.
  - Status: fixed for the cited CI gaps. CI now runs adapter parity freshness;
     screenshot comparison requires a manifest in UI jobs, fails on true size
     mismatches, and writes diffs under the uploaded `screenshots/diffs/`
     artifact path. Local-only release documentation was already corrected in
     the README refresh.

## 2026-06-01 Copilot Re-review Follow-up

Copilot's follow-up review confirmed the two original Critical items were fixed
and identified one remaining Critical plus three Important transcript/service
parity gaps.

### Critical

1. Service stdout event buffering still dropped JSON when a complete JSON chunk
   and its trailing newline arrived separately.
   - Evidence cited by reviewer:
     `macos/Engram/Core/EngramServiceLauncher.swift`.
   - Problem: the stdout handler trimmed and returned on a newline-only chunk
     before flushing the already-buffered JSON line.
   - Status: fixed. `EngramServiceLauncher` now appends every non-empty stdout
     data chunk to `ServiceOutputLineBuffer` before trimming complete lines for
     JSON decoding. `EngramServiceLauncherTests` covers the split
     JSON-then-newline case.

### Important

1. Swift MCP `get_session` did not reuse the system/agent-communication
   classifier.
   - Status: fixed. `MCPTranscriptReader` now applies the default visible
     transcript predicate through `SystemMessageClassifier` for adapter and
     fallback parser paths.
2. Service transcript export did not reuse the system/agent-communication
   classifier.
   - Status: fixed. `TranscriptExportService` now applies the same default
     visible transcript predicate before exporting JSON or Markdown.
3. Swift and TS system-message classifiers could drift on whitespace,
   source-specific Antigravity wrappers, Qwen prompts, local-command output, and
   skill/system wrappers.
   - Status: fixed. Shared transcript display fixtures now cover those cases,
     Swift consumes them through `MessageParserTests`, and TS
     `classifySystemContent` trims prefix input and source-gates the Antigravity
     `<SYSTEM_MESSAGE>` wrapper.

## 2026-06-01 Antigravity Legacy Follow-up

Copilot's second follow-up review found one remaining Important gap:
`antigravity-legacy` transcripts could still leak `<SYSTEM_MESSAGE>` content
because Swift MCP/export passed the original source string into
`SystemMessageClassifier`, while the classifier only treated `antigravity` as an
Antigravity source.

- Status: fixed. Swift and TS classifiers now treat `antigravity-legacy` as an
  Antigravity-family source for `<SYSTEM_MESSAGE>` classification. The shared
  fixture corpus includes an `antigravity-legacy` wrapper case, MCP
  `get_session` covers hiding a legacy wrapper, and service export covers hiding
  the same wrapper when exporting a legacy transcript.

## Minor

- Split oversized Swift service/MCP registry files by command domain once the
  security fixes are stable.
  - Status: fixed. Project migration service commands moved to
    `EngramServiceCommandHandler+ProjectMigration.swift`, and MCP project
    result ordering moved to `MCPToolRegistry+ProjectResults.swift`, reducing
    the main service command handler and MCP registry review surfaces without
    changing command contracts.
- Add smaller Swift test schemes for app and UI test ergonomics.
  - Status: fixed. `EngramTests` and `EngramUITests` are now first-class
    shared Xcode schemes generated from `macos/project.yml`.
- Replace fixture-generator tests that shell out to Unix `find` and hard-coded
  `./node_modules/.bin/tsx` with Node APIs and npm execution.
  - Status: fixed. Stage 2 fixture-generator tests now use Node filesystem
    traversal and `npm exec -- tsx`; active baseline docs and CI fixture checks
    no longer call a hard-coded local tsx binary.

## Execution Order

1. Fix TerminalLauncher shell quoting with malicious-character tests.
2. Make project migration MCP mutators fail closed when the Swift service is
   unavailable.
3. Reconcile `project_move_batch` JSON/YAML contract.
4. Unify transcript visibility predicates across app, MCP, export, HTTP, and TS
   reference paths.
5. Fix transcript pagination based on consumed adapter position, not filtered
   visible count.
6. Harden writer-gate tests, HOME isolation, fixture freshness, embedding indexer
   integration coverage, and CI gates.
7. Close Minor cleanup: split project migration Swift review surfaces, add
   focused app/UI test schemes, and remove fixture-generator test shell
   assumptions.
