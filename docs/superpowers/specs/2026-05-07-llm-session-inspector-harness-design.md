# LLM Session Inspector Harness Design

Date: 2026-05-07
Status: Landed for implementation planning

## Goal

Engram should treat AI summaries as one part of a broader session inspector and handoff harness.

The harness should answer these questions for a local AI coding session:

- What happened in this session?
- What is derived by Engram, and what comes from the original transcript?
- Is the session still active, done, waiting, errored, abandoned, or unknown?
- Which parent or child agent sessions belong with it?
- Which summary, title, embedding, cost, and tool facts can be trusted, and with what provenance?
- How can the user safely resume or hand off the work without pretending Engram is the upstream agent runner?

## References

### Internal

- `src/core/ai-client.ts`: summary prompt rendering, message sampling, OpenAI / Anthropic / Gemini request construction, audit recording.
- `src/core/title-generator.ts`: title prompt, Ollama / OpenAI-compatible title calls, title parsing, audit recording.
- `src/core/embeddings.ts`: embedding providers and explicit vector-space selection.
- `src/core/ai-audit.ts`: local audit log with trace, caller, model, token, session, request, response, and error fields.
- `src/tools/generate_summary.ts`: MCP summary generation and `sessions.summary` writeback.
- `src/tools/get_context.ts`: context assembly and token budget behavior.
- `src/tools/handoff.ts`: project handoff brief with recent sessions, cost, and suggested prompt.
- `src/core/resume-coordinator.ts`: local resume command builder.
- `src/core/parent-detection.ts`: parent suggestion and dispatch pattern scoring.
- `src/core/session-tier.ts`: skip / lite / normal / premium tier rules.
- `docs/archive/superpowers/specs/2026-03-10-ai-summary-redesign.md`
- `docs/archive/superpowers/specs/2026-04-13-agent-session-grouping-design.md`
- `docs/superpowers/specs/2026-05-06-project-analytics-dashboard-design.md`

### External

- Agent Kitchen: repo grouping, one-line LLM summaries, status classification, live git status, repo timelines, one-click resume.
- Agent Sessions: local-first multi-tool session browser, transcript search, resume command copy, live cockpit.
- ccusage: session-level token and cost analysis with last activity and JSON output.
- Claude Code: `/compact`, `/context`, `/usage`, `/cost`, `/recap`, `/resume`, `/branch`, subagent context isolation, and compaction boundaries.
- Codex: `codex resume`, `/resume`, `/fork`, `/compact`, `/agent`, `/status`, local transcript history, plan history, approvals, config-level compaction settings.

## Approved Direction

Build a local-first `Session Inspector Harness`.

This is not a replacement UI for Claude Code, Codex, Gemini, or any other upstream agent. Engram remains a read-only session memory, search, analytics, and handoff layer. It can generate derived summaries, status labels, commands, and briefs, but it must keep the original local transcript as the highest evidence source.

The first implementation should produce a stable inspector DTO and test harness. UI refinements and new MCP tools can be layered on top once the DTO is proven.

## Product Contract

### Source Of Truth

- Original local transcript and DB rows are factual inputs.
- `summary`, `generated_title`, status labels, handoff text, compact context, cost estimates, and health signals are derived views.
- Derived fields must carry provenance and confidence when they can mislead.
- Missing facts must remain missing or `unknown`; do not invent successful values.

### Summary

Engram currently stores summary in `sessions.summary`, populated either by adapter first-user-message extraction or by LLM-generated summary writeback. The harness must separate these concepts:

- `firstMessageSummary`: adapter-derived initial user message or equivalent local fallback.
- `storedSummary`: current `sessions.summary` value.
- `llmSummary`: LLM-generated summary, when provenance is known.
- `compactSummary`: upstream compact or recap summary if it is observable in a source transcript or hook payload.
- `displayTitle`: UI fallback chain, currently `customName > generatedTitle > summary`.
- `generatedTitle`: title LLM output, distinct from summary and handoff.

The spec does not require immediate storage for all fields. It requires the inspector output to distinguish them when the underlying facts are available, and to mark absent provenance explicitly.

### Status

The inspector should expose a best-effort status label:

```ts
type SessionStatusLabel =
  | 'done'
  | 'in_progress'
  | 'waiting'
  | 'errored'
  | 'abandoned'
  | 'unknown';
```

Status is not proof that the work is complete. It is a browsing signal derived from observable facts such as end time, recent activity, final turn shape, failed tools, active live-session probes, parent-child state, or source-specific markers.

The DTO must include:

- `status.label`
- `status.confidence`: `high | medium | low`
- `status.source`: `rule | live_probe | llm | fallback | unknown`
- `basisTags`: short strings such as `has_end_time`, `recent_mtime`, `final_assistant_turn`, `failed_tool`, `live_waiting`, `child_rollup`, `no_messages`
- `status.observedAt`: timestamp for live or probe-derived status

### Parent And Child Sessions

Engram already uses depth-1 parent-child grouping for agent sessions. The inspector must keep that boundary:

- Confirmed deterministic links are facts.
- Heuristic links are suggestions until confirmed.
- Child sessions are hidden from top-level lists by default but remain searchable.
- Parent summaries may include child rollup facts, but child transcript content must not be silently merged into the parent.
- Project dashboard and session KPI defaults count primary visible sessions. Child agent activity is a separately labeled total.

### Resume

Resume is a command generation feature, not a guarantee of restoration.

The inspector should expose:

- `resume.capability`: `supported | legacy | fallback | unsupported`
- `resume.command`, `resume.args`, `resume.cwd` when available
- `resume.evidence`: `official_doc | local_help | observed_jsonl | heuristic | fallback`
- `resume.warning` when the command surface is version-sensitive

Known command facts for this spec:

- Claude Code supports `claude --resume <session>` and `claude --continue` style flows.
- Codex current official command surface is `codex resume <SESSION_ID>` and related flags. The existing Engram `codex --resume <id>` behavior should be treated as legacy until verified.
- Unsupported sources should fall back to opening the project directory or showing the original transcript, not to a fake resume command.

### Compact And Handoff

The harness should model compaction as a boundary:

- Upstream compact summaries, when observable, are separate from Engram-generated summaries.
- `get_context` and `handoff` outputs are Engram compact views. They must show what was included, what was omitted, and the effective budget.
- Compact or handoff output should prefer current-task facts, recent sessions, explicit user decisions, warnings, and high-value memories over low-value environment noise.
- Engram must not claim to preserve upstream private context state. It only produces human-readable handoff and executable resume commands.

### Cost

Costs are local estimates unless explicitly marked otherwise.

The inspector should expose:

- token totals by input, output, cache read, and cache creation where available
- `estimatedCostUsd`
- `costSource`: `engram_pricing | provider_reported | unknown`
- `pricedCoverage`
- `unknownModelCount`
- `costWarning` for missing usage, unknown pricing, mixed models, or child-agent exclusion

Unknown model pricing must not be displayed as real `$0`.

### Privacy

Default behavior:

- Do not write full raw prompt, full raw transcript, request body, or response body to audit storage.
- Keep using `AiAuditWriter` body logging gates, sanitizer, max body size, and retention controls.
- If body logging is enabled, golden fixtures and UI output must prove API keys, Gemini URL keys, Authorization headers, and secret-like strings are redacted.
- LLM summary inputs should be sampled and truncated. The inspector should expose the sampling policy, not the full sampled body by default.

## Inspector DTO

The first implementation should introduce an internal DTO before changing UI broadly:

```ts
interface SessionInspector {
  session: {
    id: string;
    source: string;
    project?: string;
    cwd?: string;
    model?: string;
    startTime?: string;
    endTime?: string;
    messageCount: number;
    filePath?: string;
    tier?: 'skip' | 'lite' | 'normal' | 'premium';
    agentRole?: string;
  };
  provenance: {
    transcript: 'local_file' | 'database_snapshot' | 'missing';
    title: DerivedFieldProvenance;
    cost: DerivedFieldProvenance;
    parentLink: DerivedFieldProvenance;
  };
  summaries: {
    displayTitle?: string;
    firstMessageSummary?: string;
    storedSummary?: string;
    llmSummary?: string;
    compactSummary?: string;
    summaryMessageCount?: number;
    isSummaryStale?: boolean;
    provenance: {
      firstMessageSummary: SummaryProvenance;
      storedSummary: SummaryProvenance;
      llmSummary: SummaryProvenance;
      compactSummary: SummaryProvenance;
    };
  };
  status: {
    label: SessionStatusLabel;
    confidence: 'high' | 'medium' | 'low';
    source: 'rule' | 'live_probe' | 'llm' | 'fallback' | 'unknown';
    basisTags: string[];
    observedAt?: string;
  };
  agentGraph: {
    parentSessionId?: string;
    suggestedParentId?: string;
    linkSource?: 'path' | 'manual';
    childCount: number;
    suggestedChildCount: number;
    childRollup?: {
      sources: Record<string, number>;
      tokenTotal?: number;
      estimatedCostUsd?: number;
    };
  };
  llm: {
    auditRecordCount: number;
    lastAuditAt?: string;
    callers: Array<'summary' | 'title' | 'embedding'>;
    lastError?: string;
    promptVersion?: string;
    resolvedSummaryConfig?: {
      preset?: string;
      maxTokens: number;
      temperature: number;
      sampleFirst: number;
      sampleLast: number;
      truncateChars: number;
    };
    trigger?: 'manual' | 'auto' | 'indexing' | 'unknown';
  };
  resume: {
    capability: 'supported' | 'legacy' | 'fallback' | 'unsupported';
    tool?: string;
    command?: string;
    args?: string[];
    cwd?: string;
    evidence: 'official_doc' | 'local_help' | 'observed_jsonl' | 'heuristic' | 'fallback';
    warning?: string;
  };
  cost: {
    inputTokens?: number;
    outputTokens?: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
    estimatedCostUsd?: number;
    source: 'engram_pricing' | 'provider_reported' | 'unknown';
    pricedCoverage?: number;
    unknownModelCount?: number;
    warning?: string;
  };
}
```

Supporting types:

```ts
type SummaryProvenance =
  | 'adapter_first_message'
  | 'engram_llm_manual'
  | 'engram_llm_auto'
  | 'upstream_compact'
  | 'fallback'
  | 'unknown';

type DerivedFieldProvenance =
  | 'database'
  | 'ai_audit'
  | 'source_transcript'
  | 'rule'
  | 'heuristic'
  | 'fallback'
  | 'unknown';
```

DTO fields should be additive. Consumers must tolerate missing optional fields.

## Architecture

### Core Boundary

Add a pure inspector builder in `src/core/` or `src/tools/` support code. It should gather facts from existing surfaces:

- `sessions`
- `session_costs`
- `session_tools`
- `ai_audit_log`
- parent link repository
- live-session snapshot, if available
- resume command builder
- adapter metadata where needed

The builder should not call external LLM providers. LLM calls remain in summary, title, and embedding modules. The inspector only reports their artifacts and audit trail.

### LLM Request Harness

The existing summary, title, and embedding paths should converge on shared harness semantics without forcing a single provider abstraction too early:

- Each operation records `sessionId` when known.
- Each operation records `caller`, `operation`, `traceId`, `provider`, `model`, `durationMs`, token counts, error, and relevant metadata.
- Summary records resolved config: preset, max tokens, temperature, sample first/last, truncate chars, message count, trigger source.
- Title generation should receive session id when called from indexing, so title audit can be correlated back to the session.
- Embedding calls should include session and chunk metadata when available.
- No operation silently falls back to a different provider/model vector space.

### Swift Boundary

Swift should keep DB reads read-only and avoid introducing a second interpretation of LLM state.

Active UI surface:

- Session detail inspector panel or section.
- Show summary/title/status/provenance/cost/resume/parent-child facts.
- Query daemon or DB read model, not raw external providers.
- Continue using `nonisolated` + `readInBackground` for DB reads.

If the current `SessionDetailView.generateSummary()` state has no visible trigger, the implementation must either wire a visible action and status display or remove dead UI state. This cleanup does **not** depend on the inspector panel and may ship independently.

#### Bridge Note (2026-05-07): TypeScript-backed bridge does not exist in shipped app — Option A shipped instead

Task 5 originally assumed the Swift app could route inspector requests to the same TypeScript-backed contract exposed by Task 3. Investigation during Task 5a confirmed that bridge does not exist in the shipped .app:

- `EngramServiceLauncher` (`macos/Engram/Core/EngramServiceLauncher.swift`) launches `Contents/Helpers/EngramService` — a Swift-native helper, not a Node process.
- `EngramServiceRunner.run()` (`macos/EngramService/Core/EngramServiceRunner.swift`) wires `UnixSocketServiceServer` + `ServiceWriterGate` + `SQLiteEngramServiceReadProvider`. No HTTP listener, no port advertisement, no Node child.
- Stage 5 single-stack verification removed the Node bundle build (`macos/scripts/build-node-bundle.sh`) and the `Contents/Resources/node/...` artifacts from the .app. The `web_ready` event handling in `EngramServiceStatusStore` and `IndexerProcess.swift` is dead code under the current architecture.

This was not resolved by reintroducing a TypeScript-backed bridge — that bridge **still does not exist** inside the .app. Instead, the user selected **Option A** (Swift-native inspector parity) from the three-way decision point in the plan document (Option A: Swift-native parity, Option B: defer Swift panel, Option C: re-bundle Node bridge). Option C was **not** adopted.

The Swift app now reaches the inspector DTO over the existing Unix-socket service path:

- `EngramServiceClient.inspectSession(id:)` issues an `inspectSession` IPC command across the existing socket transport.
- `EngramServiceCommandHandler` dispatches to `SQLiteEngramServiceReadProvider.inspectSession(_:)`, which derives `EngramServiceSessionInspector` via GRDB read-only queries.
- `SessionDetailView` renders a compact `SessionInspectorPanel` from the returned DTO. No HTTP, no Node, no `URLSession`/`Process()`/`which` invocation in the inspector code path.

The contract is enforced by tests, not by code sharing: the Swift `EngramServiceSessionInspector` and the TypeScript `SessionInspector` are deliberately parallel implementations, with `tests/fixtures/mcp-golden/session_inspector.fixture.json` as the single source of truth (decoded by the Swift parity test in `EngramServiceInspectorTests`). The MCP `inspect_session` tool and HTTP `GET /api/sessions/:id/inspect` route remain the dev-time surfaces for the same DTO.

### MCP And HTTP Boundary

Preferred first external surface:

- Add an internal builder plus one stable read endpoint or MCP tool only when needed by UI/tests.
- If a new tool is added, name it `inspect_session` rather than overloading `generate_summary`.
- If no new tool is added in the first implementation, golden fixtures should extend existing `get_session` and `generate_summary` contracts instead of creating a parallel contract family.

`generate_summary` remains a write operation on Engram's derived summary field. It should not become the inspector surface.

## Data And Schema Notes

The first implementation should reuse `ai_audit_log` before adding new tables. It already contains `trace_id`, `caller`, `operation`, `duration_ms`, `model`, `provider`, tokens, bodies, errors, `session_id`, and `meta`.

Possible minimal migrations:

- No migration if the first slice can store summary config and trigger in `ai_audit_log.meta`.
- Add only indexed columns that are needed for common queries and cannot be served from `meta`.
- Do not add another audit table for summary/title/embedding.

If summary provenance becomes a persisted product requirement, prefer explicit fields on the session-derived side rather than overloading `sessions.summary`:

- `summary_source`
- `summary_generated_at`
- `summary_prompt_hash`
- `summary_trigger`

Those fields are not required for the first builder-only slice.

## Harness Tests

### New Test Files

Add:

- `tests/core/llm-inspector-harness.test.ts`
- `tests/fixtures/llm-inspector/session.json`
- `tests/fixtures/llm-inspector/provider-responses/openai-summary.success.json`
- `tests/fixtures/llm-inspector/provider-responses/anthropic-summary.success.json`
- `tests/fixtures/llm-inspector/provider-responses/gemini-summary.success.json`
- `tests/fixtures/llm-inspector/provider-responses/ollama-title.success.json`
- `tests/fixtures/llm-inspector/provider-responses/openai-title.success.json`
- `tests/fixtures/llm-inspector/expected-audit/summary.json`
- `tests/fixtures/llm-inspector/expected-audit/title.json`
- `tests/fixtures/llm-inspector/expected-audit/embedding.json`

If a public MCP tool or HTTP endpoint is added:

- Add or extend a fixture under `tests/fixtures/mcp-golden/`.
- Prefer `session_inspector.fixture.json` only if `inspect_session` exists.
- Otherwise extend existing `get_session` or `generate_summary` golden outputs.

### Golden Vs Constraint Assertions

Use golden fixtures for:

- The final inspector DTO or public MCP/HTTP contract.
- Normalized audit rows after redaction.
- Transcript-to-inspector aggregation for a fixed fixture DB.

Use constraint assertions for:

- Provider request body shapes.
- Token mapping by provider.
- Prompt sampling first/last/truncation behavior.
- URL and body redaction.
- `durationMs >= 0`.
- Missing usage fields.
- Embedding dimensions and provider/model isolation.
- Title parsing.

Do not snapshot full provider request bodies when field-presence and privacy assertions are enough.

### Fixture Rules

- No real provider calls.
- No real `~/.engram/index.sqlite`.
- Use fixture DB copies for write tools.
- Fixed UTC timestamps.
- Normalize random UUIDs, trace IDs, durations, temp paths, and generated ids.
- Redact Authorization headers, Gemini URL keys, API keys, and secret-like request or response body values.
- Add fixture rules to `tests/fixtures/mcp-golden/README.md` when public golden output changes.

### Verification Commands

Focused implementation verification:

```bash
npm run test -- tests/core/ai-client.test.ts tests/core/title-generator.test.ts tests/core/embeddings.test.ts tests/core/ai-audit.test.ts tests/core/llm-inspector-harness.test.ts
npm run generate:mcp-contract-fixtures
npm run test -- tests/tools tests/web/ai-audit-api.test.ts
npm run build
npm run lint
```

If the implementation only adds fixture/golden contract coverage:

```bash
npm run generate:mcp-contract-fixtures
npm run test -- tests/core/llm-inspector-harness.test.ts tests/tools
```

## Acceptance Criteria

- Inspector output distinguishes transcript facts, display title, first-message summary, stored summary, LLM summary, compact summary, and generated title.
- Each summary-like field has its own provenance. The implementation must not use one generic `summary` source for all summary values.
- Summary/title/embedding audit records are session-correlatable when called from a session path.
- Summary audit metadata includes resolved prompt/config, sampling policy, message count, and manual/auto/indexing trigger when known.
- Body logging remains disabled by default and redacted when enabled.
- Status labels include confidence and basis tags.
- Parent/child/suggested parent facts are shown without changing depth-1 grouping semantics.
- Primary session metrics and child agent metrics are not silently merged.
- Resume output for Codex uses the current `codex resume` surface in the implementation slice that touches `resume-coordinator`.
- Unknown cost/pricing is explicit.
- Public contract tests use fixture DB and mocks only.
- No implementation path requires external LLM calls for CI.

## Phased Rollout

### Phase 0: Contract And Builder

- Define `SessionInspector` types.
- Build an inspector from existing DB facts and audit logs.
- Add harness fixtures and tests.
- Do not add UI yet unless needed to prove the DTO.

### Phase 1: LLM Audit Correlation

- Ensure summary, title, and embedding paths pass `sessionId` when available.
- Store summary resolved config and trigger in audit `meta`.
- Keep request/response body logging gated.
- Add tests for success, provider error, network error, and missing usage.

### Phase 2: Read-Only UI And API Surface

- Add a session detail inspector panel or a stable `inspect_session` endpoint/tool.
- Show provenance, status, parent-child rollup, cost confidence, and resume command.
- Keep Swift reads non-blocking.

### Phase 3: Cross-View Consistency

- Use the same primary/child/suggested/tier definitions in Home, Sessions, Search, Timeline, Project Dashboard, MCP tools, and handoff.
- Search remains flat but shows parent breadcrumbs.
- Project dashboards keep child agent activity separate from primary session counts.

### Phase 4: Suggestion Layer

- Add cost optimization, usage health, summary freshness, and handoff quality suggestions.
- Suggestions must include basis tags and uncertainty.
- Do not automatically execute model changes, compaction rewrites, cleanup, or resume commands.

## Out Of Scope

- Replacing upstream agent chat, edit, permission, approval, or execution UI.
- Launching external CLIs as part of the harness.
- Reverse-engineering private upstream compaction prompts or system prompts.
- Treating LLM status labels as proof that work is complete.
- Uploading full raw transcripts to cloud providers by default.
- Adding OTLP, DuckDB, or another telemetry backend.
- Recursive agent trees beyond depth 1.
- Making Engram cost estimates equal official bills.
- Syncing parent links or inspector derivations as authoritative cross-device facts.

## Risks

- Upstream format drift can break resume, compact, usage, or subagent inference.
- Status labels can overstate certainty if low-confidence states are hidden.
- Summary hallucination can look like evidence if provenance is not visible.
- Cost estimates can mislead when usage fields are missing or model prices are unknown.
- Heuristic parent links can pollute top-level session counts if promoted too aggressively.
- UI scope can drift into an agent control console; keep the first slices read-only and evidence-backed.
