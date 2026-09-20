let meta = #{
    name: "engram-review-round6",
    description: "Round-6 Engram review: audit Codex Wave AB-AJ closeout against round-5 IDs",
    when_to_use: "After Codex claims round-5 Wave AB-AJ report-scope implementation is complete on the dirty tree",
    phases: [
        #{ title: "Map", detail: "map dirty working tree vs HEAD and Codex AB-AJ closeout claims" },
        #{ title: "FixAudit", detail: "one skeptic per unique round-5 confirmed ID" },
        #{ title: "Hunt", detail: "gap hunters for incomplete AB-AJ patches and remaining round-5 IDs" },
        #{ title: "VerifyNew", detail: "fail-closed verify of newly hunted findings" },
        #{ title: "Synthesize", detail: "still-open plus newly confirmed only" },
    ],
};

let map_schema = #{
    "type": "object",
    "required": ["head", "dirty_summary", "claimed_fixed", "hotspots"],
    "properties": #{
        "head": #{ "type": "string" },
        "dirty_summary": #{ "type": "string" },
        "claimed_fixed": #{ "type": "string" },
        "hotspots": #{
            "type": "array",
            "maxItems": 16,
            "items": #{ "type": "string" },
        },
    },
};

let audit_schema = #{
    "type": "object",
    "required": ["id", "still_open", "severity", "reason", "evidence"],
    "properties": #{
        "id": #{ "type": "string" },
        "still_open": #{ "type": "boolean" },
        "severity": #{ "type": "string", "enum": ["critical", "high", "med", "low", "none"] },
        "reason": #{ "type": "string" },
        "evidence": #{ "type": "string" },
    },
};

let findings_schema = #{
    "type": "object",
    "required": ["dimension", "findings"],
    "properties": #{
        "dimension": #{ "type": "string" },
        "findings": #{
            "type": "array",
            "maxItems": 5,
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
    "required": ["markdown", "summary", "still_open_count", "new_confirmed_count", "codex_fix_brief"],
    "properties": #{
        "markdown": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "still_open_count": #{ "type": "integer" },
        "new_confirmed_count": #{ "type": "integer" },
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

let skip_fix_audit = false;
if args != () && args.skip_fix_audit == true { skip_fix_audit = true; }

let r5_path = root + "/.grok/engram-review-round5-2026-08-23.md";
let r4_path = root + "/.grok/engram-review-round4-2026-08-22.md";

let audit_ids = [
    "embed-isolate-4",
    "jsonl-produced-cap-1",
    "cli-socket-helper-1",
    "invariant-6-prod-3",
    "invariant-6-prod-4",
    "embed-isolate-1",
    "embed-isolate-2",
    "jsonl-produced-cap-regress-1",
    "jsonl-produced-cap-2",
    "jsonl-produced-cap-3",
    "loadall-cap-1",
    "loadall-cap-2",
    "loadall-cap-3",
    "live-export-terminal-2",
    "diff-regression-1",
    "docs-honesty-regress-1",
    "changelog-retract-1",
    "changelog-retract-2",
    "r4-dropped-55-1",
    "cli-socket-helper-2",
    "cli-socket-helper-3",
    "secrets-nofollow-4",
    "mcp-hermetic-regress-1",
    "mcp-hermetic-regress-2",
    "mcp-hermetic-regress-3",
    "uitest-home-search-2",
    "uitest-home-search-3",
    "invariant-6-prod-1",
    "invariant-6-prod-2",
    "invariant-6-prod-5",
    "diff-regression-3",
    "docs-honesty-regress-2",
    "subagent-layout-regress-1",
    "opencode-parent-regress-1",
    "opencode-parent-2",
    "opencode-parent-3",
    "skip-upgrade-1",
    "skip-upgrade-2",
    "secrets-nofollow-5",
    "apikey-empty-1",
    "apikey-empty-4",
    "live-export-terminal-1",
    "live-export-terminal-regress-1",
    "r4-dropped-55-3",
    "r4-dropped-55-2",
    "session-detail-id-5",
    "redact-archive-regress-1",
    "redact-archive-regress-2",
    "redact-archive-1",
    "redact-archive-2",
    "probe-hidden-regress-1",
    "xcodeproj-untracked-regress-1",
    "copilot-composite-regress-1",
    "usage-indexed-at-regress-1",
    "usage-indexed-at-regress-2",
    "usage-indexed-at-regress-3",
    "project-move-encode-1",
    "project-move-encode-2",
    "observability-ring-regress-1",
    "insights-chain-1",
    "cursor-title-regress-1",
    "timeline-project-regress-1",
    "timeline-project-1",
    "transcript-find-tools-regress-1",
    "human-driven-list-1",
    "human-driven-list-2",
    "human-driven-list-3",
    "uitest-home-search-1",
    "uitest-home-search-5",
    "fts-drained-1",
    "shutdown-truncate-3",
    "remote-catalog-1",
    "docs-honesty-1",
];

phase("Map");
log("Mapping Codex AB-AJ dirty tree at " + root);

let map_prompt = "";
map_prompt += "READ-ONLY map of Engram at " + root + "\n";
map_prompt += "Use git status, git diff --stat HEAD, git rev-parse HEAD origin/main, read_file. Never edit.\n";
map_prompt += "HEAD and origin/main should still be d97d0257. Round-5 report: " + r5_path + "\n";
map_prompt += "Codex claimed Wave AB-AJ report-scope complete, ~310 dirty files, tests green, no commit/push/rebase. Explicitly not an inventory-wide zero-bug claim. Retracted false S-AA closeout last.\n";
map_prompt += "Return head (actual hash), dirty_summary, claimed_fixed (CHANGELOG/MEMO honesty about AB-AJ vs remaining round-5 IDs), hotspots (files most likely still incomplete vs round-5 Wave AB first: GuardedEmbeddingProvider dimension, Claude scanTail, socket HOME-first, defaultAdapters production home).\n";
map_prompt += "Do not invent hashes. Ignore /tmp/*.xcresult. Ignore leftover .git/REBASE_HEAD if no rebase in progress.\n";

let map_r = agent(map_prompt, #{
    label: "map-abaj-tree",
    capability_mode: "read-only",
    output_schema: map_schema,
});

let head_blob = "";
let dirty_blob = "";
let claimed_blob = "";
let hotspots_blob = "[]";
if map_r != () && map_r.success && map_r.output != () {
    if map_r.output.head != () { head_blob = map_r.output.head; }
    if map_r.output.dirty_summary != () { dirty_blob = map_r.output.dirty_summary; }
    if map_r.output.claimed_fixed != () { claimed_blob = map_r.output.claimed_fixed; }
    if map_r.output.hotspots != () { hotspots_blob = json_encode(map_r.output.hotspots); }
    log("Map complete");
} else {
    log("Map failed — continuing");
}
if head_blob == () { head_blob = ""; }
if dirty_blob == () { dirty_blob = ""; }
if claimed_blob == () { claimed_blob = ""; }
if hotspots_blob == () { hotspots_blob = "[]"; }

phase("FixAudit");
let still_open = [];
let closed_ok = 0;
let audit_failures = 0;

if skip_fix_audit {
    log("Skipping fix-audit (args.skip_fix_audit)");
} else {
    log("Auditing " + audit_ids.len().to_string() + " round-5 IDs against current working tree");
    let ajobs = [];
    for cid in audit_ids {
        let p = "";
        p += "Audit whether a ROUND-5 confirmed Engram bug is still present AFTER Codex Wave AB-AJ uncommitted fixes.\n";
        p += "Repo: " + root + "\n";
        p += "Finding id: " + cid + "\n";
        p += "Round-5 report (read the row and Wave AB-AJ cluster for this id): " + r5_path + "\n";
        p += "Rules:\n";
        p += "1) READ-ONLY. git diff HEAD -- cited file(s) AND read_file CURRENT working-tree source.\n";
        p += "2) still_open=true ONLY if the original defect still exists in the WORKING TREE.\n";
        p += "3) If Codex actually fixed it, or original claim is now wrong: still_open=false, severity none.\n";
        p += "4) Incomplete, inverted, tests-only (repro does not hit production path), or regressing patches => still_open=true. Quote file:line.\n";
        p += "5) Empty evidence => still_open must be false. Prefer disconfirming.\n";
        p += "6) id field must equal " + cid + "\n";
        p += "7) Do not reopen rejected false-positives: no SIGKILL, no get_session skip filter, no H05 unlink rewrite, no Gemini chats/ parent, no dispatched on every OpenCode fork, no LIKE whole mixed query, no write secrets after proc.run().\n";
        ajobs.push(#{
            prompt: p,
            label: "audit:" + cid,
            capability_mode: "read-only",
            output_schema: audit_schema,
        });
    }
    let ares = parallel(ajobs);
    let ai = 0;
    for r in ares {
        let cid = audit_ids[ai];
        if r == () || !r.success || r.output == () {
            audit_failures += 1;
            log("Fix-audit failed: " + cid);
        } else if r.output.still_open == true && r.output.evidence != () && r.output.evidence != "" {
            let sev = r.output.severity;
            if sev == () || sev == "" || sev == "none" { sev = "med"; }
            still_open.push(#{
                id: cid,
                severity: sev,
                issue: r.output.reason,
                evidence: r.output.evidence,
                kind: "still-open",
            });
        } else {
            closed_ok += 1;
        }
        ai += 1;
    }
    log("Still open: " + still_open.len().to_string() + "; closed: " + closed_ok.to_string() + "; audit failures: " + audit_failures.to_string());
}

phase("Hunt");

let dims = [
    #{ key: "subagent-layout", title: "relative subagentLayout production path", focus: "SessionTier.compute SwiftIndexer.isProvableSkip Database Agents filter Claude resume Qoder isSubagent — substring /subagents/ vs relative helper; scanForIndexing+compute repro path" },
    #{ key: "fts-shadow-skip", title: "sessions_fts_rebuild skip cleanup", focus: "SessionSnapshotWriter.deleteIndexArtifacts sessions_fts_rebuild vs StartupBackfills; finalizeRebuildIfReady swap" },
    #{ key: "mcp-hermetic", title: "MCP tests inherit HOME", focus: "ServiceUnavailableMutatingToolTests.callTool ProcessInfo.environment ENGRAM_MCP_DB_PATH invariant 6; EngramMCPExecutableTests remaining spawn helpers; UITest launchEnvironment HOME" },
    #{ key: "secrets-nofollow", title: "token and ai-secrets nofollow", focus: "ServiceCapabilityToken.load generateAndWrite EmbeddingSettings.runtimeSecretValues removeRuntimeAISecrets writeRuntimeAISecrets leftover scan custom socket parent" },
    #{ key: "probe-hidden", title: "semantic probe hidden_at busy_timeout", focus: "SessionVectorSearchAvailability.probe db hidden_at; probe databasePath second queue readerConfiguration SQLITE_BUSY" },
    #{ key: "workitem-localtime", title: "service work-item cutoff", focus: "readProjectWorkItems vs Database implementationTimeline date now localtime" },
    #{ key: "xcodeproj-untracked", title: "xcodegen drift untracked", focus: "check-xcodeproj-drift.sh porcelain untracked Engram.xcodeproj; pbxproj dirty without xcodegen" },
    #{ key: "session-detail-id", title: "SessionDetail A-B reuse", focus: "MainWindowView .id(session.id) .task(id) cancel parent related unstructured mutation RPCs live token vs captured lets" },
    #{ key: "opencode-parent", title: "OpenCode parent_id skip-null", focus: "parent persisted if host missing; dispatched only TaskTool title; child-first indexAll never skip+NULL; agent=build" },
    #{ key: "copilot-composite", title: "Copilot FileIndexDecision skip", focus: "usesCompositeInputs bypass; scanForIndexing one-pass; 120s grace composite mtime" },
    #{ key: "mixed-token", title: "App MCP mixed-token and insights FTS", focus: "DatabaseManager MCPDatabase keywordSearch CJK+Latin; insights_fts AI usage; hybrid empty KNN throw; snippets MATCH first token" },
    #{ key: "loadall-cap", title: "Load-all maxMessages", focus: "Codex messages limit!=nil; Copilot StreamMessagesResult shortcut; Cline Iflow windowed metadata truncatedAt; parseWindowed catch empty-complete" },
    #{ key: "live-export-terminal", title: "live export primer CocoaError", focus: "TranscriptExportService fallback complete; CancellationError; Warp toml unlink defer" },
    #{ key: "apikey-empty", title: "API key empty-delete", focus: "applyAPIKey missing settings.json Keychain; isLoadingSettings 400ms swallow paste; persist non-key field" },
    #{ key: "popover-locators", title: "live scan vs adapter locators", focus: "Antigravity system_generated logs; OpenCode db::id; Gemini chats jsonl skip engram.json; openLive file_path fallback" },
    #{ key: "embed-isolate", title: "embedding isolate non-OpenAI", focus: "SiliconFlow vLLM FastAPI detail; dimensions omit; batch split; backoff only provider-scoped; param dimensions stays http" },
    #{ key: "usage-indexed-at", title: "usageAggregates indexed_at window", focus: "COALESCE end_time indexed_at; git_repos session_count throttle due empty; slash prefix /tmp vs private/tmp" },
    #{ key: "project-move-encode", title: "shared encoding collision and tilde", focus: "claude qoder qwen encode foo_bar foo-bar; expandHome trim; SharedEncodingCollisionError" },
    #{ key: "observability-ring", title: "error ring KPI 24h", focus: "ObservabilityLogUnion limit 200; CoreWrite category; fractional ISO8601; OSLogReader currentProcess" },
    #{ key: "insights-chain", title: "deleteInsight supersede chain", focus: "A-B-C delete B reactivates A; selectedInsight stale; reconcile dangling superseded_by" },
    #{ key: "cursor-title", title: "Cursor nested summary vs generated_title", focus: "COALESCE first mechanical title; TS nested object TypeError" },
    #{ key: "timeline-project", title: "sessionTimeline project filter", focus: "2000 global LIMIT post-filter selectedProject; picker DISTINCT" },
    #{ key: "transcript-find-tools", title: "find highlight tool system", focus: "ToolCallView ToolResultView CollapsibleSystemBubble searchText matchIndices" },
    #{ key: "jsonl-produced-cap", title: "Iflow Qoder CommandCode produced cap", focus: "countsTowardMessageLimit only Claude Codex Copilot; sidecar burn 10k" },
    #{ key: "remote-catalog", title: "catalog fail-open empty 200", focus: "GET v1 catalog continue on get errors; decodeCatalog never throws" },
    #{ key: "cli-socket-helper", title: "archive CLI socket and MCP helper", focus: "EngramCLIArchiveRunner no socketPath; execSwiftMCPHelper Applications fallback; ENGRAM_SERVICE_SOCKET" },
    #{ key: "uitest-home-search", title: "UITest HOME and mock search", focus: "launchEnvironment HOME migrate scrub production settings; mock-daemon SearchSmoke OR-pass" },
    #{ key: "fts-drained", title: "recoverableFtsJobCount drained", focus: "batchProgress==0 vs count==0; cline pending while Claude enabled; shouldDefer 15m" },
    #{ key: "shutdown-truncate", title: "SIGTERM TRUNCATE 30s", focus: "checkpointTruncate ignore cancellation; launcher 2s writerBusy; do not SIGKILL" },
    #{ key: "docs-honesty", title: "AGENTS CLAUDE CHANGELOG honesty", focus: "root AGENTS.md keyword-only vs hybrid; CLAUDE.md sqlite-vec; CHANGELOG AB-AJ honesty vs remaining round-5 IDs after S-AA retraction" },
    #{ key: "human-driven-list", title: "resources/list visibility", focus: "listVisible topLevel HumanDrivenFilter; suggested children starve catalog" },
    #{ key: "pipe-drain-skip", title: "XCTSkip missing drain marker", focus: "testLauncherDrainsServiceOutputPipes XCTSkip vs XCTAssertTrue" },
    #{ key: "deploy-local-mcp", title: "deploy-local EngramMCP abort", focus: "wait loop abort client-respawned EngramMCP; hygiene Frameworks" },
    #{ key: "redact-archive", title: "archive redact before utf8Prefix", focus: "MCP archive page PEM spanning 160KiB; live get_session redact-then-cap" },
    #{ key: "diff-regression", title: "new regressions in 310-file AB-AJ dump", focus: "git diff HEAD — Guarded dimension freeze, Claude tail metering, HOME-first socket, defaultAdapters production home, throw-after-prefix, skip-tier upgrades" },
    #{ key: "invariant-6-prod", title: "any remaining production ~/.engram opens", focus: "tests and UITests and MCP spawn and CLI that still touch ~/.engram without temp HOME" },
    #{ key: "skip-upgrade", title: "setParentSession skip upgrade", focus: "parent-link ops must not lift skip; OpenCode dispatched forks; subagent stay skip invariant 2" },
    #{ key: "writer-gate-bypass", title: "new SQLite writers in app MCP", focus: "invariant 1 ServiceWriterGate; CLI archive writes; MCP save_insight" },
    #{ key: "r5-dropped-51", title: "round-5 dropped_new 51", focus: "Hunt OTHER remaining bugs in files not covered by the 73 IDs: EngramCLI remaining, RemoteServer routes, Replay, Onboarding, HygieneView, Session relations" },
    #{ key: "changelog-retract", title: "CHANGELOG MEMO AB-AJ closeout claim", focus: "Confirm false S-AA closeout was retracted. If AB-AJ residuals remain, CHANGELOG/MEMO must not claim inventory-wide zero-bug" },
];

let hunt_jobs = [];
for d in dims {
    let p = "";
    p += "You are a read-only ROUND-6 gap hunter for Engram.\n";
    p += "Repo: " + root + "\n";
    p += "Dimension: " + d.key + " — " + d.title + "\n";
    p += "Focus: " + d.focus + "\n";
    p += "HEAD: " + head_blob + "\n";
    p += "Dirty tree: " + dirty_blob + "\n";
    p += "Codex claim: " + claimed_blob + "\n";
    p += "Hotspots: " + hotspots_blob + "\n";
    p += "Round-5 report: " + r5_path + "\n";
    p += "Round-4 report: " + r4_path + "\n";
    p += "REQUIREMENTS:\n";
    p += "1) READ-ONLY. Inspect CURRENT working tree. Never edit. Never commit.\n";
    p += "2) Do NOT restate round-5 IDs unless you prove Codex AB-AJ still left them open (id like " + d.key + "-regress-1 and cite the old id).\n";
    p += "3) Do NOT restate rejected false-positives: SIGKILL helper, H05 unlink, get_session skip filter, Gemini chats/ parent, indexing retry_count, linkSessions visibility, parent-detection-2, TS Database constructors, dispatched on every OpenCode parent_id, LIKE whole mixed query, write secrets after proc.run().\n";
    p += "4) Prefer NEW bugs and incomplete AB-AJ patches. At most 5 findings.\n";
    p += "5) Empty findings[] only after inspecting focus files. Swift product is truth.\n";
    p += "6) dimension must equal " + d.key + ". New ids like " + d.key + "-1.\n";
    hunt_jobs.push(#{
        prompt: p,
        label: "hunt:" + d.key,
        capability_mode: "read-only",
        output_schema: findings_schema,
    });
}

log("Launching " + hunt_jobs.len().to_string() + " gap hunters");
let hunt_results = parallel(hunt_jobs);

let new_findings = [];
let hunt_failures = 0;
let hi = 0;
for r in hunt_results {
    if r == () || !r.success || r.output == () || r.output.findings == () {
        hunt_failures += 1;
        log("Hunter failed: " + dims[hi].key);
    } else {
        for f in r.output.findings {
            new_findings.push(#{
                id: f.id,
                severity: f.severity,
                file: f.file,
                issue: f.issue,
                suggestion: f.suggestion,
                confidence: f.confidence,
                dimension: dims[hi].key,
            });
        }
    }
    hi += 1;
}
log("New raw findings: " + new_findings.len().to_string() + "; hunter failures: " + hunt_failures.to_string());

const MAX_VERIFY_NEW = 80;
let ordered = [];
let sevs = ["critical", "high", "med", "low"];
for s in sevs {
    for f in new_findings {
        if f.severity == s { ordered.push(f); }
    }
}
for f in new_findings {
    let known = false;
    for s in sevs {
        if f.severity == s { known = true; }
    }
    if !known { ordered.push(f); }
}

let to_verify = [];
let dropped = 0;
for f in ordered {
    if to_verify.len() < MAX_VERIFY_NEW {
        to_verify.push(f);
    } else {
        dropped += 1;
    }
}
if dropped > 0 {
    log("Dropped " + dropped.to_string() + " new findings from verify cap");
}

phase("VerifyNew");
let new_confirmed = [];
let new_rejected = 0;
let new_vfail = 0;

if to_verify.len() == 0 {
    log("No new findings to verify");
} else {
    log("Verifying " + to_verify.len().to_string() + " new hunt findings");
    let vjobs = [];
    let vi = 0;
    for f in to_verify {
        let encoded = json_encode(f);
        let vp = "";
        vp += "Adversarially VERIFY a ROUND-6 newly hunted Engram defect.\n";
        vp += "Repo: " + root + "\n";
        vp += "Claim JSON: " + encoded + "\n";
        vp += "Working tree is dirty with Codex AB-AJ. CURRENT files are truth.\n";
        vp += "real=true only with file:line evidence it still exists. Fail closed. Empty evidence => false.\n";
        vp += "If this restates a round-5 item Codex already fixed, real=false.\n";
        vjobs.push(#{
            prompt: vp,
            label: "v6new-" + vi.to_string() + "-" + f.id,
            capability_mode: "read-only",
            output_schema: verdict_schema,
        });
        vi += 1;
    }
    let vres = parallel(vjobs);
    let vidx = 0;
    for v in vres {
        let f = to_verify[vidx];
        if v != () && v.success && v.output != () && v.output.real == true && v.output.evidence != () && v.output.evidence != "" {
            let sev = v.output.severity;
            if sev == () || sev == "" || sev == "none" { sev = f.severity; }
            new_confirmed.push(#{
                id: f.id,
                severity: sev,
                file: f.file,
                issue: f.issue,
                suggestion: f.suggestion,
                evidence: v.output.evidence,
                reason: v.output.reason,
                dimension: f.dimension,
                kind: "new-confirmed",
            });
        } else if v == () || !v.success {
            new_vfail += 1;
        } else {
            new_rejected += 1;
        }
        vidx += 1;
    }
}

log("New confirmed " + new_confirmed.len().to_string() + "; rejected " + new_rejected.to_string());

phase("Synthesize");

let still_json = json_encode(still_open);
let new_json = json_encode(new_confirmed);

let sp = "";
sp += "Synthesize Engram ROUND-6 review for a sibling Codex fixer.\n";
sp += "Repo: " + root + " HEAD-map: " + head_blob + "\n";
sp += "Dirty: " + dirty_blob + "\n";
sp += "Codex claimed Wave AB-AJ report-scope complete, not inventory-wide zero-bug. Fix-audit still-open JSON:\n" + still_json + "\n";
sp += "New-confirmed JSON:\n" + new_json + "\n";
sp += "Counts: still_open=" + still_open.len().to_string() + " closed_ok=" + closed_ok.to_string() + " new_confirmed=" + new_confirmed.len().to_string() + "\n";
sp += "audit_failures=" + audit_failures.to_string() + " hunt_failures=" + hunt_failures.to_string() + " dropped_new=" + dropped.to_string() + " new_rejected=" + new_rejected.to_string() + "\n";
sp += "Write markdown: executive summary; still-open table; new-confirmed table; recommended fix order; do-not-fix from prior rounds.\n";
sp += "codex_fix_brief: self-contained TDD Swift-first prompt. Do not invent bugs. Deduplicate overlaps.\n";
sp += "If both arrays empty: tell Codex not to change product code; remaining work is commit/CI/push only.\n";
sp += "Continue on the dirty tree. Do not revert closed AB-AJ patches except incomplete/inverted ones.\n";

let synth_r = agent(sp, #{
    label: "synthesize-round6",
    capability_mode: "read-only",
    output_schema: report_schema,
});

let markdown = "";
let summary = "";
let brief = "";
if synth_r != () && synth_r.success && synth_r.output != () {
    if synth_r.output.markdown != () { markdown = synth_r.output.markdown; }
    if synth_r.output.summary != () { summary = synth_r.output.summary; }
    if synth_r.output.codex_fix_brief != () { brief = synth_r.output.codex_fix_brief; }
}
if markdown == () || markdown == "" {
    summary = "still_open=" + still_open.len().to_string() + " new=" + new_confirmed.len().to_string();
    brief = "Fix only the JSON arrays. Do not reopen prior-round rejected IDs.";
    markdown = "# Engram review round 6\n\n" + summary + "\n\n## still-open\n" + still_json + "\n\n## new\n" + new_json + "\n";
}
if summary == () { summary = ""; }
if brief == () { brief = ""; }

let path = write_scratch_file("engram-review-round6.md", markdown);
complete(#{
    summary: summary,
    path: path,
    still_open: still_open,
    new_confirmed: new_confirmed,
    still_open_count: still_open.len(),
    new_confirmed_count: new_confirmed.len(),
    closed_ok: closed_ok,
    new_rejected: new_rejected,
    audit_failures: audit_failures,
    hunt_failures: hunt_failures,
    dropped_new: dropped,
    codex_fix_brief: brief,
    head: head_blob,
});
