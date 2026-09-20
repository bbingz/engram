let meta = #{
    name: "engram-multi-review",
    description: "High-fanout residual-bug review of the Engram Swift product with adversarial verification",
    when_to_use: "When the user wants a multi-agent code review of Engram and confirmed findings for a sibling Codex pane to fix",
    phases: [
        #{ title: "Map", detail: "map HEAD, recent adapter-cap PRs, invariants, and residual follow-ups" },
        #{ title: "Review", detail: "32 read-only domain reviewers in parallel" },
        #{ title: "Verify", detail: "fail-closed adversarial skeptics on the highest-severity findings" },
        #{ title: "Synthesize", detail: "deduped confirmed-findings report for Codex" },
    ],
};

let map_schema = #{
    "type": "object",
    "required": ["head", "hotspots", "claimed_done", "open_risks", "recent_prs"],
    "properties": #{
        "head": #{ "type": "string" },
        "hotspots": #{
            "type": "array",
            "maxItems": 16,
            "items": #{ "type": "string" },
        },
        "claimed_done": #{
            "type": "array",
            "maxItems": 16,
            "items": #{ "type": "string" },
        },
        "open_risks": #{
            "type": "array",
            "maxItems": 16,
            "items": #{ "type": "string" },
        },
        "recent_prs": #{
            "type": "array",
            "maxItems": 16,
            "items": #{ "type": "string" },
        },
    },
};

let findings_schema = #{
    "type": "object",
    "required": ["dimension", "findings"],
    "properties": #{
        "dimension": #{ "type": "string" },
        "findings": #{
            "type": "array",
            "maxItems": 6,
            "items": #{
                "type": "object",
                "required": ["id", "severity", "file", "issue", "suggestion", "confidence"],
                "properties": #{
                    "id": #{ "type": "string" },
                    "severity": #{ "type": "string", "enum": ["critical", "high", "med", "low"] },
                    "file": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                    "suggestion": #{ "type": "string" },
                    "confidence": #{ "type": "string", "enum": ["high", "med", "low"] },
                },
            },
        },
    },
};

let verdict_schema = #{
    "type": "object",
    "required": ["real", "severity", "reason", "evidence"],
    "properties": #{
        "real": #{ "type": "boolean" },
        "severity": #{ "type": "string", "enum": ["critical", "high", "med", "low", "none"] },
        "reason": #{ "type": "string" },
        "evidence": #{ "type": "string" },
    },
};

let report_schema = #{
    "type": "object",
    "required": ["markdown", "summary", "confirmed_count", "rejected_count", "codex_fix_brief"],
    "properties": #{
        "markdown": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "confirmed_count": #{ "type": "integer" },
        "rejected_count": #{ "type": "integer" },
        "codex_fix_brief": #{ "type": "string" },
    },
};

let root = "/Users/bing/-Code-/engram";
if args != () && args.root != () && type_of(args.root) == "string" {
    root = args.root;
    root.trim();
    if root == "" {
        root = "/Users/bing/-Code-/engram";
    }
}

phase("Map");
log("Mapping Engram residual-risk surface at " + root);

let map_prompt = "";
map_prompt += "You are mapping residual risk for Engram at absolute path: " + root + "\n";
map_prompt += "READ-ONLY. Use git log, git show, read_file, grep, list_dir. Never edit files.\n";
map_prompt += "Working tree is expected clean on main. Product runtime is Swift under macos/.\n";
map_prompt += "Must inspect at least:\n";
map_prompt += "1) git log --oneline -30 and git status --porcelain\n";
map_prompt += "2) docs/invariants.md, docs/followups.md (open rows only), docs/TODO.md, docs/roadmap.md\n";
map_prompt += "3) Recent adapter stream/parseSessionInfo cap PRs around #417-#427 and MessageParser prefix handling #420\n";
map_prompt += "4) macos/Shared/EngramCore/Adapters/ParserLimits.swift and SessionAdapterFactory.swift\n";
map_prompt += "head: current HEAD hash you actually saw.\n";
map_prompt += "hotspots: files/modules most likely still buggy after the cap series.\n";
map_prompt += "claimed_done: follow-ups/docs that claim the defect is closed, with PR if seen.\n";
map_prompt += "open_risks: remaining PARSEINFO slices, ARCH-001, R6, or other still-open items you actually read.\n";
map_prompt += "recent_prs: recent merged PRs relevant to residual risk (hash or number you saw).\n";
map_prompt += "Do not invent hashes or PR numbers. Empty arrays only after you inspected the files.\n";

let map_r = agent(map_prompt, #{
    label: "map-surface",
    capability_mode: "read-only",
    output_schema: map_schema,
});

let head_blob = "";
let hotspots_blob = "[]";
let claimed_blob = "[]";
let open_blob = "[]";
let prs_blob = "[]";
if map_r != () && map_r.success && map_r.output != () {
    head_blob = map_r.output.head;
    hotspots_blob = json_encode(map_r.output.hotspots);
    claimed_blob = json_encode(map_r.output.claimed_done);
    open_blob = json_encode(map_r.output.open_risks);
    prs_blob = json_encode(map_r.output.recent_prs);
    log("Map complete at HEAD " + head_blob);
} else {
    log("Map agent failed or empty — reviewers will still scan the tree");
}

phase("Review");

let dims = [
    #{
        key: "app-lifecycle",
        title: "app lifecycle and service launch",
        focus: "macos/Engram/App.swift, MenuBarController.swift, Core/EngramServiceLauncher.swift, Core/LaunchAgent.swift, Core/AppEnvironment.swift — startup, service spawn, onboarding routing, termination close of the service client",
    },
    #{
        key: "service-runner",
        title: "service runner and indexing loop",
        focus: "macos/EngramService/Core/EngramServiceRunner.swift, IndexingBackgroundActivityScheduler.swift, IndexingSchedulePolicy.swift — startup order, backfills before todayParents, indexing loop, web readiness, maintenance",
    },
    #{
        key: "writer-gate",
        title: "single-writer gate",
        focus: "macos/EngramService/Core/ServiceWriterGate.swift, macos/Shared/Service/EngramServiceClient.swift — invariant 1; no direct SQLite writers in app/MCP; mutating commands serialized; timeout vs long FS ops (R6 residual)",
    },
    #{
        key: "service-commands",
        title: "service command handler",
        focus: "macos/EngramService/Core/EngramServiceCommandHandler.swift and +ProjectMigration/+ArchiveV2/+RemoteSync/+ArchiveTranscript — IPC command routing, parent-link must not upgrade skip, capability token on mutating commands",
    },
    #{
        key: "service-read",
        title: "service read and keyword search",
        focus: "macos/EngramService/Core/EngramServiceReadProvider.swift — keyword FTS/LIKE, lite excluded from search, skip hidden, semantic/hybrid only when embeddings usable, CJK LIKE fallback",
    },
    #{
        key: "ipc-security",
        title: "unix socket security",
        focus: "macos/Shared/Service/UnixSocketEngramServiceTransport.swift, macos/EngramService/IPC/UnixSocketServiceServer.swift, ServiceSecurityHardeningTests — invariant 8: 0700 runtime dir, 0600 socket, peer UID, capability token",
    },
    #{
        key: "mcp-registry",
        title: "MCP tool registry and stdio",
        focus: "macos/EngramMCP/Core/MCPToolRegistry.swift, macos/EngramMCP/main.swift, macos/Shared/MCP/MCPProtocol.swift — object-root structuredContent, mutating tools via service client, no Node MCP path",
    },
    #{
        key: "mcp-database",
        title: "MCP database contracts",
        focus: "macos/EngramMCP/Core/MCPDatabase.swift — search min length, list visibility, get_session pagination/redaction, get_context timezone, skip/lite filters, alias list object root",
    },
    #{
        key: "adapters-claude-codex",
        title: "Claude Code and Codex adapters",
        focus: "macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift, CodexAdapter.swift, ClaudeCodeProfileResolver.swift — parseSessionInfo/stream caps, subagents path parent, originator dispatched/skip, empty-session noVisibleMessages",
    },
    #{
        key: "adapters-gemini-cursor-vscode",
        title: "Gemini Cursor VS Code adapters",
        focus: "macos/Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift, CursorAdapter.swift, VsCodeAdapter.swift — parseSessionInfo cap fail-closed, truncation metadata, sidecar parent, cwd ownership, JSON fsync",
    },
    #{
        key: "adapters-opencode-copilot",
        title: "OpenCode and Copilot adapters",
        focus: "macos/Shared/EngramCore/Adapters/Sources/OpenCodeAdapter.swift, CopilotAdapter.swift — per-session size not whole DB, checkpoint index.md caps, empty-session, discovery/aux files",
    },
    #{
        key: "adapters-jsonl-rest",
        title: "Qwen Kimi Qoder CommandCode adapters",
        focus: "macos/Shared/EngramCore/Adapters/Sources/QwenAdapter.swift, KimiAdapter.swift, QoderAdapter.swift, CommandCodeAdapter.swift — remaining PARSEINFO cap holes, injection classifiers, empty-session, stream vs batch parity",
    },
    #{
        key: "adapters-archived-cache",
        title: "archived and cache-only adapters",
        focus: "ClineAdapter, IflowAdapter, WindsurfAdapter, AntigravityAdapter, ClaudeCodeDerivedSourceAdapter minimax/lobsterai, SessionAdapterFactory — default-off archived sources, cache-only Windsurf, Antigravity transcript/cache, factory registration count 17",
    },
    #{
        key: "stream-caps",
        title: "parser limits and MessageParser prefix",
        focus: "macos/Shared/EngramCore/Adapters/ParserLimits.swift, StreamingLineReader.swift, macos/Engram/Core/MessageParser.swift, RecentlyModifiedSessionAdapter if present — streamMessages/parseSessionInfo fail-closed on cap, MessageParser keeps adapter prefix when stream cap throws (#420), FTS/index/MCP full-read fail-closed",
    },
    #{
        key: "indexing-core",
        title: "indexer writer and FTS",
        focus: "macos/EngramCoreWrite/Indexing/, macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift, FTSRebuildPolicy.swift, EngramMigrations.swift — snapshot writes, FTS versioning invariant 5, truncation fail-closed, skip artifact removal",
    },
    #{
        key: "startup-backfills",
        title: "startup backfills and polycli parents",
        focus: "macos/EngramCoreWrite/Indexing/StartupBackfills.swift — ordered idempotent backfills invariant 9, polycli provider-parent skip, Codex originator, suggested parents, manual unlink invariant 10",
    },
    #{
        key: "session-tier",
        title: "session tiering and visibility",
        focus: "macos/Shared/EngramCore/Indexing/SessionTier.swift, SessionVisibility filters in CoreRead/app/MCP — skip hidden, lite list-visible search-excluded, subagent stay skip invariant 2 and 3",
    },
    #{
        key: "parent-detection",
        title: "parent detection and linking",
        focus: "macos/Shared/EngramCore/Indexing/ParentDetection.swift, setParentSession in command handler, ExpandableSessionCard — detectionVersion parity invariant 4, setParentSession must not upgrade child tier, suggested vs confirmed",
    },
    #{
        key: "project-move",
        title: "project move archive undo",
        focus: "macos/EngramCoreWrite/ProjectMove/, EngramServiceCommandHandler+ProjectMigration.swift — transactional move/archive/undo/batch, sequential MCP tools, gitdir marker, encoding parity",
    },
    #{
        key: "core-read",
        title: "CoreRead and app DatabaseManager",
        focus: "macos/EngramCoreRead/, macos/Engram/Core/Database.swift — nonisolated + readInBackground, skip/lite filters, ARCH-001 remaining pool/DTO migration honesty, no main-thread GRDB",
    },
    #{
        key: "embeddings-search",
        title: "embeddings and hybrid search",
        focus: "macos/Shared/EngramCore/AI/, SessionSemanticSearchPolicy, insight backfill dual-write, R4 terminalization, brute-force cosine KNN, no sqlite-vec product path, no mixing embedding models",
    },
    #{
        key: "archive-v2",
        title: "archive v2 and reclamation",
        focus: "macos/EngramCoreWrite/ArchiveV2/, macos/EngramService/Core/ArchiveV2*.swift, ArchiveReclamationCoordinator.swift — replica drain, abort/CAS, default-off fresh installs, no remote deletion/GC",
    },
    #{
        key: "remote-sync",
        title: "remote sync and remote server",
        focus: "macos/EngramCoreWrite/RemoteSync/, macos/EngramService/Core/RemoteSyncCoordinator.swift, macos/EngramRemoteServer/ — TLS fail-closed, private host checks, catalog caps, status persist throttle",
    },
    #{
        key: "ui-sessions",
        title: "session list and grouping UI",
        focus: "macos/Engram/Views/Pages/HomeView.swift, SessionsPageView.swift, TimelinePageView.swift, Components/ExpandableSessionCard.swift, AgentsView.swift — parent-null top-level filter, skip hidden, favorite symmetry, browse reload coalescer",
    },
    #{
        key: "ui-transcript",
        title: "transcript and message parsing UI",
        focus: "macos/Engram/Views/Transcript/, SessionDetailView.swift, Core/MessageParser.swift, ContentSegmentParser.swift, ToolCallParser.swift — paging, find, copy conversation, child list must not steal viewport, filter off-main",
    },
    #{
        key: "ui-search-settings",
        title: "search settings sources onboarding",
        focus: "macos/Engram/Views/Pages/SearchPageView.swift, Settings/, SourcePulseView.swift, Onboarding/, CommandPaletteView.swift — keyword-only unless embeddings, no false hybrid, archived sources UI, keychain plaintext only DEBUG",
    },
    #{
        key: "concurrency",
        title: "MainActor and background reads",
        focus: "DatabaseManager nonisolated, Task.detached view loads, AISettingsPersister off-main, hashValue ban for cache keys, writer-gate vs UI timeouts, popover live-session bounds",
    },
    #{
        key: "tests-parity",
        title: "Swift tests and adapter parity",
        focus: "macos/EngramCoreTests/AdapterParityTests.swift, IndexerParityTests.swift, macos/EngramMCPTests/, fixtures under tests/fixtures — parser output changes need fixture/parity; tests must not touch ~/.engram invariant 6; named _repro for bugfixes",
    },
    #{
        key: "ts-product-leak",
        title: "TypeScript leftover product-path regressions",
        focus: "src/ remaining CLIs/tools/adapters — must not be product startup; no node/npm in app bundle; no reintroduced schema-compat gate; TS search semantic is reference; flag any shipped path that still shells out to node",
    },
    #{
        key: "ci-release",
        title: "CI release and xcodegen",
        focus: "macos/project.yml, macos/scripts/release-verify.sh, .github/workflows/test.yml — do not edit xcodeproj directly, bundle hygiene invariant 7, npm audit soft-fail, Node 24",
    },
    #{
        key: "cli-resume",
        title: "CLI resume and export",
        focus: "macos/EngramCLI/main.swift, TranscriptExportService.swift, Resume/TerminalLauncher.swift, Warp tab 0600 — resume commands, export caps, no production writes from CLI except via service",
    },
    #{
        key: "docs-honesty",
        title: "docs vs code honesty",
        focus: "docs/followups.md open rows (ARCH-001, R6, ALIAS-P2), docs/invariants.md anchors, Agents.md adapter count 17 — do not treat closed follow-ups as bugs unless CURRENT code still has the defect; flag overclaims",
    },
];

let review_jobs = [];
for d in dims {
    let p = "";
    p += "You are a read-only domain expert reviewing Engram (native Swift macOS product).\n";
    p += "Repo root (absolute): " + root + "\n";
    p += "Dimension key: " + d.key + "\n";
    p += "Dimension title: " + d.title + "\n";
    p += "Focus: " + d.focus + "\n";
    p += "Context from map (may be partial):\n";
    p += "head=" + head_blob + "\n";
    p += "hotspots=" + hotspots_blob + "\n";
    p += "claimed_done=" + claimed_blob + "\n";
    p += "open_risks=" + open_blob + "\n";
    p += "recent_prs=" + prs_blob + "\n";
    p += "REQUIREMENTS:\n";
    p += "1) Use read_file/grep/list_dir and read-only git. NEVER edit files, NEVER commit, NEVER run mutating commands.\n";
    p += "2) Current Swift code is truth. TypeScript under src/ is reference/dev only unless a shipped path still depends on it.\n";
    p += "3) Hunt residual bugs: fail-open caps, skip-tier upgrades, writer-gate bypass, search lying about semantic mode, visibility leaks of skip sessions, main-thread DB, insecure socket, truncated transcripts indexed as complete.\n";
    p += "4) At most 6 findings. Each must cite a real file path and a concrete defect still in CURRENT code.\n";
    p += "5) severity critical/high/med/low. confidence high/med/low. id like " + d.key + "-1.\n";
    p += "6) suggestion must be a specific code fix, not 'consider refactoring'.\n";
    p += "7) Empty findings[] ONLY after you actually inspected the focus files.\n";
    p += "8) Do not restate closed follow-ups unless you prove the fix is incomplete or wrong in current HEAD.\n";
    p += "9) dimension field must equal: " + d.key + "\n";
    p += "10) Prefer bugs over nits. Skip style-only comments.\n";
    review_jobs.push(#{
        prompt: p,
        label: "review:" + d.key,
        capability_mode: "read-only",
        output_schema: findings_schema,
    });
}

log("Launching " + review_jobs.len().to_string() + " parallel reviewers");
let review_results = parallel(review_jobs);

let all_findings = [];
let review_failures = 0;
let di = 0;
for r in review_results {
    if r == () || !r.success || r.output == () || r.output.findings == () {
        review_failures += 1;
        log("Reviewer slot failed: " + dims[di].key);
    } else {
        for f in r.output.findings {
            all_findings.push(#{
                id: f.id,
                severity: f.severity,
                file: f.file,
                issue: f.issue,
                suggestion: f.suggestion,
                confidence: f.confidence,
                dimension: dims[di].key,
            });
        }
        log("Reviewer " + dims[di].key + " returned " + r.output.findings.len().to_string() + " findings");
    }
    di += 1;
}

log("Raw findings: " + all_findings.len().to_string() + "; failed reviewers: " + review_failures.to_string());

if all_findings.len() == 0 {
    let empty_md = "";
    empty_md += "# Engram multi-review — no raw findings\n\n";
    empty_md += "Repo: `" + root + "`\n\n";
    empty_md += "All reviewers returned empty findings, or all failed.\n";
    empty_md += "Reviewer failures: " + review_failures.to_string() + "\n\n";
    empty_md += "## Map snapshot\n\n";
    empty_md += "- head: " + head_blob + "\n";
    empty_md += "- hotspots: " + hotspots_blob + "\n";
    empty_md += "- open_risks: " + open_blob + "\n";
    let path = write_scratch_file("engram-multi-review.md", empty_md);
    complete(#{
        summary: "No findings (or all reviewers failed)",
        path: path,
        confirmed: [],
        rejected: [],
        review_failures: review_failures,
        confirmed_count: 0,
        rejected_count: 0,
        codex_fix_brief: "No confirmed defects. Do not change code.",
    });
}

const MAX_VERIFY = 64;
let ordered = [];
let sevs = ["critical", "high", "med", "low"];
for s in sevs {
    for f in all_findings {
        if f.severity == s {
            ordered.push(f);
        }
    }
}
for f in all_findings {
    let known = false;
    for s in sevs {
        if f.severity == s { known = true; }
    }
    if !known { ordered.push(f); }
}

let to_verify = [];
let dropped = 0;
for f in ordered {
    if to_verify.len() < MAX_VERIFY {
        to_verify.push(f);
    } else {
        dropped += 1;
    }
}
if dropped > 0 {
    log("Dropped " + dropped.to_string() + " lower-priority findings from verify (cap " + MAX_VERIFY.to_string() + ")");
}

phase("Verify");
log("Verifying " + to_verify.len().to_string() + " findings fail-closed");

let vjobs = [];
let vi = 0;
for f in to_verify {
    let encoded = json_encode(f);
    let vp = "";
    vp += "Adversarially VERIFY a claimed defect in Engram.\n";
    vp += "Repo root: " + root + "\n";
    vp += "Claimed finding JSON: " + encoded + "\n";
    vp += "Rules:\n";
    vp += "1) READ-ONLY. Open the cited file with read_file/grep. Independently re-check the claim.\n";
    vp += "2) real=true ONLY if you personally inspect concrete evidence the defect still exists in CURRENT Swift/product code.\n";
    vp += "3) If already fixed, misunderstanding, test-only, docs-only, TypeScript-reference-only, or weak evidence → real=false.\n";
    vp += "4) evidence must quote file:line or a short snippet you read. Empty evidence means real must be false.\n";
    vp += "5) severity: reassess if real; use none when real=false.\n";
    vp += "6) Prefer disconfirming. Fail closed. Subagent skip, single-writer, and socket-security claims need extra scrutiny against docs/invariants.md.\n";
    vjobs.push(#{
        prompt: vp,
        label: "verify-" + vi.to_string() + "-" + f.id,
        capability_mode: "read-only",
        output_schema: verdict_schema,
    });
    vi += 1;
}

let verdicts = parallel(vjobs);

let confirmed = [];
let rejected = [];
let vidx = 0;
for v in verdicts {
    let f = to_verify[vidx];
    if v != () && v.success && v.output != () && v.output.real == true && v.output.evidence != () && v.output.evidence != "" {
        let sev = v.output.severity;
        if sev == () || sev == "" || sev == "none" {
            sev = f.severity;
        }
        confirmed.push(#{
            id: f.id,
            severity: sev,
            file: f.file,
            issue: f.issue,
            suggestion: f.suggestion,
            confidence: f.confidence,
            dimension: f.dimension,
            evidence: v.output.evidence,
            reason: v.output.reason,
        });
    } else {
        let why = "unverified";
        if v != () && v.success && v.output != () && v.output.reason != () {
            why = v.output.reason;
        }
        rejected.push(#{
            id: f.id,
            file: f.file,
            issue: f.issue,
            reason: why,
        });
    }
    vidx += 1;
}

log(confirmed.len().to_string() + "/" + to_verify.len().to_string() + " findings survived verification");

phase("Synthesize");

let confirmed_json = json_encode(confirmed);
let rejected_json = json_encode(rejected);
let synth_prompt = "";
synth_prompt += "Synthesize a confirmed-findings report for Engram so a sibling Codex agent can fix them.\n";
synth_prompt += "Repo: " + root + "\n";
synth_prompt += "HEAD from map: " + head_blob + "\n";
synth_prompt += "Reviewer failures: " + review_failures.to_string() + "\n";
synth_prompt += "Dropped from verify cap: " + dropped.to_string() + "\n";
synth_prompt += "Confirmed JSON:\n" + confirmed_json + "\n";
synth_prompt += "Rejected JSON:\n" + rejected_json + "\n";
synth_prompt += "Write markdown with:\n";
synth_prompt += "1) Executive summary\n";
synth_prompt += "2) Confirmed issues table: id, severity, file, issue, suggestion, evidence\n";
synth_prompt += "3) Recommended fix order (critical then high, independent files first)\n";
synth_prompt += "4) Explicitly list rejected/false-positive items so Codex does NOT 'fix' them\n";
synth_prompt += "codex_fix_brief: a self-contained prompt Codex can execute: TDD, Swift-first, no xcodeproj edits (edit project.yml), do not upgrade skip tiers, writes via service only, add _repro tests, cite invariants when relevant.\n";
synth_prompt += "If confirmed is empty, say so and tell Codex not to change code.\n";
synth_prompt += "Do not invent extra bugs. Only use the confirmed JSON plus rejected for the false-positive section.\n";
synth_prompt += "confirmed_count and rejected_count must match the JSON array lengths.\n";

let synth_r = agent(synth_prompt, #{
    label: "synthesize-report",
    capability_mode: "read-only",
    output_schema: report_schema,
});

let markdown = "";
let summary = "";
let brief = "";
let confirmed_count = confirmed.len();
let rejected_count = rejected.len();
if synth_r != () && synth_r.success && synth_r.output != () {
    markdown = synth_r.output.markdown;
    summary = synth_r.output.summary;
    brief = synth_r.output.codex_fix_brief;
    if synth_r.output.confirmed_count != () {
        confirmed_count = synth_r.output.confirmed_count;
    }
    if synth_r.output.rejected_count != () {
        rejected_count = synth_r.output.rejected_count;
    }
} else {
    summary = confirmed.len().to_string() + " confirmed findings after verification";
    brief = "Fix only the confirmed findings JSON. Do not edit files that were only in the rejected list.";
    markdown = "# Engram multi-review\n\n" + summary + "\n\n## Confirmed\n\n" + confirmed_json + "\n\n## Rejected\n\n" + rejected_json + "\n";
}

if markdown == "" {
    markdown = "# Engram multi-review\n\n(empty synthesizer markdown)\n";
}

let report_path = write_scratch_file("engram-multi-review.md", markdown);
complete(#{
    summary: summary,
    path: report_path,
    confirmed: confirmed,
    rejected: rejected,
    review_failures: review_failures,
    dropped_unverified: dropped,
    confirmed_count: confirmed_count,
    rejected_count: rejected_count,
    codex_fix_brief: brief,
    head: head_blob,
});
