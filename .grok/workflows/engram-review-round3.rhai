let meta = #{
    name: "engram-review-round3",
    description: "Round-3 Engram review: audit Codex Wave G-K closeout and hunt remaining gaps",
    when_to_use: "After Codex claims round-2 Wave G-K findings are fixed on the dirty working tree",
    phases: [
        #{ title: "Map", detail: "map dirty working tree vs HEAD and Codex G-K closeout claims" },
        #{ title: "FixAudit", detail: "one skeptic per unique round-2 confirmed ID" },
        #{ title: "Hunt", detail: "gap hunters for regressions and still-untouched surfaces" },
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

let r2_path = root + "/.grok/engram-review-round2-2026-08-21.md";
let r1_path = root + "/.grok/engram-multi-review-2026-08-21.md";

let audit_ids = [
    "adapters-opencode-copilot-2",
    "concurrency-2",
    "ci-release-2",
    "cli-resume-1",
    "cli-resume-2",
    "ci-release-1",
    "adapters-archived-cache-3",
    "adapters-claude-codex-3",
    "adapters-claude-codex-4",
    "adapters-claude-codex-5",
    "adapters-gemini-cursor-vscode-5",
    "adapters-gemini-cursor-vscode-6",
    "adapters-jsonl-rest-4",
    "app-lifecycle-3",
    "app-lifecycle-4",
    "app-lifecycle-5",
    "archive-v2-4",
    "archive-v2-5",
    "archive-v2-6",
    "ci-release-3",
    "cli-resume-4",
    "concurrency-5",
    "core-read-2",
    "core-read-3",
    "embeddings-search-2",
    "embeddings-search-3",
    "embeddings-search-4",
    "indexing-core-3",
    "ipc-security-1",
    "ipc-security-3",
    "mcp-database-3",
    "mcp-database-5",
    "mcp-database-6",
    "mcp-registry-4",
    "project-move-4",
    "project-move-5",
    "remote-sync-4",
    "remote-sync-5",
    "remote-sync-6",
    "service-commands-2",
    "service-commands-4",
    "service-commands-5",
    "service-commands-6",
    "service-read-3",
    "service-read-4",
    "service-runner-4",
    "service-runner-5",
    "service-runner-6",
    "session-tier-4",
    "startup-backfills-5",
    "startup-backfills-6",
    "ui-search-settings-2",
    "ui-search-settings-3",
    "ui-search-settings-4",
    "ui-search-settings-5",
    "ui-search-settings-6",
    "ui-sessions-4",
    "ui-sessions-5",
    "ui-transcript-3",
    "ui-transcript-4",
    "ui-transcript-5",
    "ipc-security-5",
    "ipc-socket-1",
    "core-read-gap-1",
    "search-ui-5",
    "popover-live-1",
    "observability-1",
    "observability-2",
    "memory-insights-1",
    "adapters-unfixed-1",
    "adapters-unfixed-2",
    "shared-untouched-1",
    "project-move-residual-1",
    "project-move-residual-2",
    "ci-release-gap-1",
    "ci-release-gap-2",
    "uitests-onboarding-1",
    "today-usage-repos-1",
    "today-usage-repos-2",
    "today-usage-repos-3",
    "codex-diff-regress-1",
    "codex-diff-regress-2",
    "codex-diff-regress-3",
    "codex-diff-regress-5",
    "fts-index-residual-regress-1",
    "fts-index-residual-2",
    "security-settings-2",
    "docs-vs-code-1",
    "docs-vs-code-2",
    "tests-skip-gaps-regress-1",
    "opencode-sqlite-2",
    "writer-gate-3",
    "messageparser-residual-regress-1",
    "messageparser-residual-regress-2",
    "remote-server-gap-1",
    "remote-server-gap-2",
    "scripts-release-1",
    "scripts-release-2",
    "scripts-release-3",
    "ipc-security-2",
    "core-read-gap-2",
    "core-read-4",
];

phase("Map");
log("Mapping Codex G-K dirty tree at " + root);

let map_prompt = "";
map_prompt += "READ-ONLY map of Engram at " + root + "\n";
map_prompt += "Use git status, git diff --stat HEAD, git rev-parse HEAD, read_file. Never edit.\n";
map_prompt += "HEAD should still be d97d0257. Round-2 report: " + r2_path + "\n";
map_prompt += "Codex claimed Wave G-K closed on the uncommitted tree (~199 files) with Core/App/Service/MCP/Remote tests green.\n";
map_prompt += "Return head (actual hash), dirty_summary (file count + notable modules), claimed_fixed (whether CHANGELOG/MEMO claim G-K closed), hotspots (files most likely still incomplete).\n";
map_prompt += "Do not invent hashes. Ignore /tmp/*.xcresult.\n";

let map_r = agent(map_prompt, #{
    label: "map-gk-tree",
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
    log("Auditing " + audit_ids.len().to_string() + " round-2 IDs against current working tree");
    let ajobs = [];
    for cid in audit_ids {
        let p = "";
        p += "Audit whether a ROUND-2 confirmed Engram bug is still present AFTER Codex Wave G-K uncommitted fixes.\n";
        p += "Repo: " + root + "\n";
        p += "Finding id: " + cid + "\n";
        p += "Round-2 report (read the row for this id, including leftover and new-confirmed tables): " + r2_path + "\n";
        p += "Rules:\n";
        p += "1) READ-ONLY. git diff HEAD -- cited file(s) AND read_file CURRENT working-tree source.\n";
        p += "2) still_open=true ONLY if the original defect still exists in the WORKING TREE.\n";
        p += "3) If Codex actually fixed it, or original claim is now wrong: still_open=false, severity none.\n";
        p += "4) Incomplete, inverted, tests-only (repro does not hit production path), or regressing patches => still_open=true. Quote file:line.\n";
        p += "5) Empty evidence => still_open must be false. Prefer disconfirming.\n";
        p += "6) id field must equal " + cid + "\n";
        p += "7) Do not reopen round-1 rejected false positives (no SIGKILL, no get_session skip filter, no H05 unlink rewrite, no Gemini chats/ parent).\n";
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
    #{ key: "copilot-index-path", title: "Copilot scanForIndexing cap", focus: "CopilotAdapter scanForIndexing vs wholeDocumentMessagesWithMetadata countsTowardMessageLimit; adapters-opencode-copilot-2 production path" },
    #{ key: "session-detail-race", title: "SessionDetail reuse race", focus: "SessionDetailView loadParentInfo/loadRelated Task.detached, live @State token vs captured lets, MainWindowView .id(session.id), concurrency-2" },
    #{ key: "fts-hol", title: "FTS HOL and not_applicable", focus: "IndexJobRunner recoverableFtsJobCount, archived/disabled jobs, capture fail captured([:]), locatorNotAllowed, missing adapter retryable" },
    #{ key: "mixed-token-search", title: "App MCP mixed-token search", focus: "DatabaseManager and MCPDatabase keywordSearch vs service per-token CTE; AI usage MATCH AI; CHANGELOG honesty" },
    #{ key: "messageparser-loadall", title: "MessageParser empty-complete and Load all", focus: "MessageParser catch [], truncatedJSONL unsafe, windowedMessagesWithMetadata maxMessages, SessionDetail Load all" },
    #{ key: "cli-resume-export", title: "claude resume and live export", focus: "resumeCommand parent_session_id, claude --resume subagents, TranscriptExportService fallback complete, Warp openApplication" },
    #{ key: "hygiene-frameworks", title: "release-verify helper Frameworks", focus: "release-verify.sh hygiene-only EngramServiceCore EngramCoreRead EngramCoreWrite GRDB-dynamic; helper-only stub must FAIL; deploy-local.sh kill service" },
    #{ key: "secrets-follow", title: "ai-secrets token lock follow-prone", focus: "writeRuntimeAISecrets, ServiceCapabilityToken, acquireProcessLock O_NOFOLLOW, connect getpeereid, removeRuntimeAISecrets on run() catch" },
    #{ key: "apikey-empty-delete", title: "AI settings empty-delete", focus: "applyAPIKey empty after load debounce, isLoadingSettings, Keychain caption vs plaintext DEBUG" },
    #{ key: "popover-live-id", title: "live metadata id vs sessionId", focus: "parseLiveMetadata prefers id over sessionId; Popover click; Claude with-tools.jsonl Gemini session-sample" },
    #{ key: "observability-tee", title: "service log ring vs OSLog KPI", focus: "ErrorDashboard SystemHealth OSLogReader only; CoreWrite raw os.Logger vs ServiceLogger tee" },
    #{ key: "insights-supersede", title: "deleteInsight superseded_by", focus: "deleteInsight does not NULL superseded_by; MemoryView vs MCP list" },
    #{ key: "opencode-parent", title: "OpenCode parent_id grouping", focus: "OpenCodeAdapter SELECT parent_id; dispatched only true subagent/task children not every fork" },
    #{ key: "cursor-summary", title: "Cursor nested summary", focus: "latestConversationSummary nested object as? String" },
    #{ key: "embed-http-isolate", title: "embedding 400 isolate", focus: "400/413/422 inputRejected vs http; param dimensions stays http; isolate aborting whole backfill" },
    #{ key: "project-move-encoding", title: "project move encoding and ~", focus: "Claude/Qoder/Qwen foo_bar steal; Orchestrator expandHome ~/dst" },
    #{ key: "usage-repos", title: "git_repos costs usageAggregates", focus: "session_count 32-cwd overwrite, MTD localtime, skip tokens in usageAggregates" },
    #{ key: "mcp-busy-search", title: "MCP busy_timeout hybrid 3-char", focus: "MCPDatabase readerConfiguration, hybrid query.count<3 throw, get_memory dim mismatch swallow, redact-then-cap" },
    #{ key: "uitest-mock", title: "UITests mock-daemon onboarding", focus: "--mock-daemon consumed, MockEngramServiceClient, SearchTests vacuous, --show-onboarding" },
    #{ key: "docs-agents-search", title: "Agents.md search honesty", focus: "AGENTS.md keyword-only vs shipped hybrid; CHANGELOG Unreleased overclaim" },
    #{ key: "mcp-test-home", title: "MCP tests inherit ~/.engram", focus: "EngramMCPExecutableTests spawn helpers ENGRAM_MCP_DB_PATH HOME SERVICE_SOCKET invariant 6" },
    #{ key: "writer-checkpoint", title: "WAL checkpoint actor", focus: "checkpointWal Truncate semaphore timeout nil writeInProgress 30s liveness" },
    #{ key: "remote-catalog", title: "remote catalog fail-open", focus: "GET /v1/catalog empty 200, TLS env fail-open, LocalDirectoryBackend" },
    #{ key: "ci-deriveddata", title: "CI DerivedData restore-keys", focus: "release.yml test.yml xcode-select derivedDataPath home DerivedData" },
    #{ key: "adapters-residual", title: "remaining adapter holes", focus: "Cline untimestamped say, Claude listSessionLocators fail-close, subagents path contains, Gemini cwd fail-open, Kimi paged reportFailures false, Qoder CommandCode Iflow Cline" },
    #{ key: "ui-search-palette", title: "search UI leftover", focus: "palette literal mark tags, 1-char no results, lite counts vs search, Gemini trust true snippet" },
    #{ key: "ui-sessions-pages", title: "Home Agents Timeline paging", focus: "follow-ups post-filter tiny FTS page, AgentsView 200 then filter, child favorite skip" },
    #{ key: "transcript-find", title: "transcript find and children", focus: "Text mode ChatMessages vs displayIndexed, children preview 20 ASC, tool/system highlight" },
    #{ key: "archive-reclaim", title: "archive v2 leftover", focus: "processClaims cancel uploadingObjects, ExactSourceCapturer CAS before recordCapture, planAndReclaim no re-gate" },
    #{ key: "service-handoff-list", title: "handoff listing visibility", focus: "omitted-id handoff no listVisibleSQL, hygiene hideEmpty skip, generateSummary skip, skip FTS rebuild delete" },
    #{ key: "startup-periodic", title: "periodic maintenance leftovers", focus: "Defer lastSuccessAt, usageParserBackfillNeeded markComplete, post-merge throw index_error, suggested-parent LIMIT, Codex model UTF-8 256KiB" },
    #{ key: "core-read-time", title: "timeline timezone leftover", focus: "sessionTimeline UTC DATE now, implementationTimeline UTC formatter, fileActivity start_time vs COALESCE end start" },
    #{ key: "xcodeproj-drift", title: "xcodeproj vs project.yml", focus: "macos/Engram.xcodeproj dirty vs project.yml; agents must not treat xcodeproj as source of truth but flag if Codex edited pbxproj without xcodegen" },
    #{ key: "test-skip-xctskip", title: "repro tests that skip", focus: "XCTSkip on fail-closed repros, tests that go green if parseSessionInfo starts succeeding, UITests skip" },
    #{ key: "diff-regression", title: "new regressions in 199-file diff", focus: "git diff HEAD — inverted conditions, catch-all, skip-tier upgrades, fail-open, tests locking wrong path, Node product path reintroduced" },
    #{ key: "pbxproj-signing", title: "test target signing and schemes", focus: "project.yml CODE_SIGNING, untracked schemes, helper copy scripts node in bundle" },
    #{ key: "onboarding-window", title: "onboarding window leak", focus: "showOnboarding always new window, MenuBar accessory vs onboardingWindow" },
    #{ key: "gemini-trust-snippet", title: "Gemini MCP trust snippet", focus: "SourcesSettingsSection trust true mutating tools" },
    #{ key: "human-driven", title: "human-driven and relations", focus: "HumanDrivenFilter include_all, session_relations, skip/lite list predicates" },
    #{ key: "r2-dropped", title: "round-2 dropped_new 101", focus: "Round-2 dropped 101 new findings from verify cap. Hunt OTHER remaining bugs in untouched files: EngramCLI, EngramUITests remaining, Shared not in diff, RemoteServer leftover routes" },
];

let hunt_jobs = [];
for d in dims {
    let p = "";
    p += "You are a read-only ROUND-3 gap hunter for Engram.\n";
    p += "Repo: " + root + "\n";
    p += "Dimension: " + d.key + " — " + d.title + "\n";
    p += "Focus: " + d.focus + "\n";
    p += "HEAD: " + head_blob + "\n";
    p += "Dirty tree: " + dirty_blob + "\n";
    p += "Codex claim: " + claimed_blob + "\n";
    p += "Hotspots: " + hotspots_blob + "\n";
    p += "Round-2 report: " + r2_path + "\n";
    p += "Round-1 report: " + r1_path + "\n";
    p += "REQUIREMENTS:\n";
    p += "1) READ-ONLY. Inspect CURRENT working tree. Never edit. Never commit.\n";
    p += "2) Do NOT restate round-2 IDs unless you prove Codex G-K still left them open (id like " + d.key + "-regress-1 and cite the old id).\n";
    p += "3) Do NOT restate rejected false-positives: SIGKILL helper, H05 unlink, get_session skip filter, Gemini chats/ parent, indexing retry_count, linkSessions visibility, parent-detection-2, TS Database constructors, dispatched on every OpenCode parent_id, LIKE whole mixed query, write secrets after proc.run().\n";
    p += "4) Prefer NEW bugs and incomplete G-K patches. At most 5 findings.\n";
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
        vp += "Adversarially VERIFY a ROUND-3 newly hunted Engram defect.\n";
        vp += "Repo: " + root + "\n";
        vp += "Claim JSON: " + encoded + "\n";
        vp += "Working tree is dirty with Codex G-K. CURRENT files are truth.\n";
        vp += "real=true only with file:line evidence it still exists. Fail closed. Empty evidence => false.\n";
        vp += "If this restates a round-2 item Codex already fixed, real=false.\n";
        vjobs.push(#{
            prompt: vp,
            label: "vnew-" + vi.to_string() + "-" + f.id,
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
sp += "Synthesize Engram ROUND-3 review for a sibling Codex fixer.\n";
sp += "Repo: " + root + " HEAD-map: " + head_blob + "\n";
sp += "Dirty: " + dirty_blob + "\n";
sp += "Codex claimed Wave G-K closed. Fix-audit still-open JSON:\n" + still_json + "\n";
sp += "New-confirmed JSON:\n" + new_json + "\n";
sp += "Counts: still_open=" + still_open.len().to_string() + " closed_ok=" + closed_ok.to_string() + " new_confirmed=" + new_confirmed.len().to_string() + "\n";
sp += "audit_failures=" + audit_failures.to_string() + " hunt_failures=" + hunt_failures.to_string() + " dropped_new=" + dropped.to_string() + " new_rejected=" + new_rejected.to_string() + "\n";
sp += "Write markdown: executive summary; still-open table; new-confirmed table; recommended fix order; do-not-fix from round-1/2.\n";
sp += "codex_fix_brief: self-contained TDD Swift-first prompt. Do not invent bugs. Deduplicate overlaps.\n";
sp += "If both arrays empty: tell Codex not to change product code; remaining work is commit/CI/UI only.\n";
sp += "Continue on the dirty tree. Do not revert closed G-K patches except incomplete/inverted ones.\n";

let synth_r = agent(sp, #{
    label: "synthesize-round3",
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
    brief = "Fix only the JSON arrays. Do not reopen round-1/2 rejected IDs.";
    markdown = "# Engram review round 3\n\n" + summary + "\n\n## still-open\n" + still_json + "\n\n## new\n" + new_json + "\n";
}
if summary == () { summary = ""; }
if brief == () { brief = ""; }

let path = write_scratch_file("engram-review-round3.md", markdown);
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
