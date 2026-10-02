let meta = #{
    name: "engram-review-round2",
    description: "Round-2 Engram review: audit Codex fixes, verify round-1 leftovers, hunt gaps",
    when_to_use: "After engram-multi-review when Codex has patched confirmed findings and leftover items still need verification",
    phases: [
        #{ title: "Map", detail: "map dirty working tree vs HEAD and Codex closeout claims" },
        #{ title: "FixAudit", detail: "one skeptic per round-1 confirmed ID against the working tree" },
        #{ title: "LeftoverVerify", detail: "adversarial verify of 107 round-1 findings that missed the verify cap" },
        #{ title: "Hunt", detail: "gap hunters on untouched modules and incomplete-fix surfaces" },
        #{ title: "VerifyNew", detail: "fail-closed verify of newly hunted findings" },
        #{ title: "Synthesize", detail: "only still-open and newly confirmed defects" },
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

let leftover_schema = #{
    "type": "object",
    "required": ["id", "real", "severity", "reason", "evidence"],
    "properties": #{
        "id": #{ "type": "string" },
        "real": #{ "type": "boolean" },
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
    "required": ["markdown", "summary", "still_open_count", "leftover_confirmed_count", "new_confirmed_count", "codex_fix_brief"],
    "properties": #{
        "markdown": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "still_open_count": #{ "type": "integer" },
        "leftover_confirmed_count": #{ "type": "integer" },
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
let skip_leftovers = false;
if args != () && args.skip_fix_audit == true { skip_fix_audit = true; }
if args != () && args.skip_leftovers == true { skip_leftovers = true; }

let report_path = root + "/.grok/engram-multi-review-2026-08-21.md";
let leftover_path = root + "/.grok/round1-leftover-findings.json";

let confirmed_ids = [
    "app-lifecycle-2",
    "service-runner-1",
    "service-runner-2",
    "service-runner-3",
    "writer-gate-1",
    "writer-gate-2",
    "service-read-1",
    "service-read-2",
    "mcp-registry-1",
    "mcp-registry-3",
    "mcp-database-1",
    "mcp-database-2",
    "mcp-database-4",
    "adapters-claude-codex-1",
    "adapters-claude-codex-2",
    "adapters-gemini-cursor-vscode-2",
    "adapters-gemini-cursor-vscode-3",
    "adapters-opencode-copilot-1",
    "adapters-opencode-copilot-2",
    "adapters-opencode-copilot-3",
    "adapters-jsonl-rest-1",
    "adapters-jsonl-rest-2",
    "adapters-archived-cache-1",
    "adapters-archived-cache-2",
    "stream-caps-1",
    "stream-caps-2",
    "indexing-core-1",
    "indexing-core-2",
    "startup-backfills-1",
    "startup-backfills-2",
    "startup-backfills-3",
    "startup-backfills-4",
    "session-tier-1",
    "parent-detection-1",
    "project-move-1",
    "project-move-2",
    "project-move-3",
    "core-read-1",
    "embeddings-search-1",
    "archive-v2-1",
    "archive-v2-2",
    "archive-v2-3",
    "remote-sync-1",
    "remote-sync-3",
    "ui-sessions-1",
    "ui-sessions-2",
    "ui-transcript-1",
    "ui-transcript-2",
    "concurrency-1",
    "concurrency-2",
    "concurrency-3",
    "tests-parity-1",
    "tests-parity-2",
    "ts-product-leak-1",
    "ts-product-leak-3",
];

let leftover_ids = [
    "ci-release-1",
    "ci-release-2",
    "cli-resume-1",
    "cli-resume-2",
    "docs-honesty-1",
    "docs-honesty-2",
    "adapters-archived-cache-3",
    "adapters-claude-codex-3",
    "adapters-claude-codex-4",
    "adapters-claude-codex-5",
    "adapters-gemini-cursor-vscode-4",
    "adapters-gemini-cursor-vscode-5",
    "adapters-gemini-cursor-vscode-6",
    "adapters-jsonl-rest-3",
    "adapters-jsonl-rest-4",
    "adapters-jsonl-rest-5",
    "adapters-opencode-copilot-4",
    "adapters-opencode-copilot-5",
    "adapters-opencode-copilot-6",
    "app-lifecycle-3",
    "app-lifecycle-4",
    "app-lifecycle-5",
    "app-lifecycle-6",
    "archive-v2-4",
    "archive-v2-5",
    "archive-v2-6",
    "ci-release-3",
    "ci-release-4",
    "ci-release-5",
    "cli-resume-3",
    "cli-resume-4",
    "cli-resume-5",
    "cli-resume-6",
    "concurrency-4",
    "concurrency-5",
    "concurrency-6",
    "core-read-2",
    "core-read-3",
    "core-read-4",
    "docs-honesty-3",
    "docs-honesty-4",
    "docs-honesty-5",
    "embeddings-search-2",
    "embeddings-search-3",
    "embeddings-search-4",
    "embeddings-search-5",
    "embeddings-search-6",
    "indexing-core-3",
    "indexing-core-5",
    "ipc-security-1",
    "ipc-security-2",
    "ipc-security-3",
    "mcp-database-3",
    "mcp-database-5",
    "mcp-database-6",
    "mcp-registry-4",
    "mcp-registry-5",
    "parent-detection-3",
    "parent-detection-4",
    "parent-detection-5",
    "project-move-4",
    "project-move-5",
    "remote-sync-2",
    "remote-sync-4",
    "remote-sync-5",
    "remote-sync-6",
    "service-commands-2",
    "service-commands-3",
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
    "stream-caps-3",
    "stream-caps-4",
    "stream-caps-5",
    "stream-caps-6",
    "tests-parity-3",
    "tests-parity-4",
    "tests-parity-5",
    "ts-product-leak-4",
    "ts-product-leak-5",
    "ts-product-leak-6",
    "ui-search-settings-1",
    "ui-search-settings-2",
    "ui-search-settings-3",
    "ui-search-settings-4",
    "ui-search-settings-5",
    "ui-search-settings-6",
    "ui-sessions-3",
    "ui-sessions-4",
    "ui-sessions-5",
    "ui-sessions-6",
    "ui-transcript-3",
    "ui-transcript-4",
    "ui-transcript-5",
    "writer-gate-3",
    "adapters-claude-codex-6",
    "ipc-security-4",
    "ipc-security-5",
    "project-move-6",
];

phase("Map");
log("Mapping dirty working tree at " + root);

let map_prompt = "";
map_prompt += "READ-ONLY map of Engram at " + root + "\n";
map_prompt += "Use git status, git diff --stat HEAD, git diff HEAD -- <hot files>, read_file. Never edit.\n";
map_prompt += "HEAD was d97d0257. Round-1 report: " + report_path + "\n";
map_prompt += "Codex claimed it fixed all 55 confirmed findings in the uncommitted working tree (82 files).\n";
map_prompt += "Return:\n";
map_prompt += "- head: git rev-parse HEAD (actual hash)\n";
map_prompt += "- dirty_summary: file count + notable modules still dirty vs HEAD\n";
map_prompt += "- claimed_fixed: one sentence on whether CHANGELOG/MEMO claim the round-1 list is closed\n";
map_prompt += "- hotspots: files most likely to have incomplete fixes or missed bugs (untouched CoreRead, CLI, UITests, ipc, resume, search UI)\n";
map_prompt += "Do not invent hashes.\n";

let map_r = agent(map_prompt, #{
    label: "map-dirty-tree",
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
    log("Map failed — continuing with empty context");
}
if head_blob == () { head_blob = ""; }
if dirty_blob == () { dirty_blob = ""; }
if claimed_blob == () { claimed_blob = ""; }
if hotspots_blob == () { hotspots_blob = "[]"; }

// ── Fix audit of round-1 confirmed IDs ─────────────────────────────────────
phase("FixAudit");
let still_open = [];
let closed_ok = 0;
let audit_failures = 0;

if skip_fix_audit {
    log("Skipping fix-audit (args.skip_fix_audit)");
} else {
    log("Auditing " + confirmed_ids.len().to_string() + " claimed-fixed IDs against working tree");
    let ajobs = [];
    for cid in confirmed_ids {
        let p = "";
        p += "Audit whether a previously CONFIRMED Engram bug is still present AFTER Codex's uncommitted fixes.\n";
        p += "Repo: " + root + "\n";
        p += "Finding id: " + cid + "\n";
        p += "Round-1 report (read the row for this id): " + report_path + "\n";
        p += "Rules:\n";
        p += "1) READ-ONLY. git diff HEAD -- the cited file(s) AND read_file the CURRENT working-tree source.\n";
        p += "2) still_open=true ONLY if the original defect still exists in the WORKING TREE (including uncommitted edits).\n";
        p += "3) If Codex's patch actually fixes it, or the original claim was wrong: still_open=false, severity none.\n";
        p += "4) Incomplete, wrong, or regressing patches count as still_open=true. Quote file:line evidence.\n";
        p += "5) Empty evidence => still_open must be false.\n";
        p += "6) id field must equal " + cid + "\n";
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
        let cid = confirmed_ids[ai];
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
                kind: "still-open-confirmed",
            });
        } else {
            closed_ok += 1;
        }
        ai += 1;
    }
    log("Still open: " + still_open.len().to_string() + "; closed: " + closed_ok.to_string() + "; audit failures: " + audit_failures.to_string());
}

// ── Leftover round-1 findings ──────────────────────────────────────────────
phase("LeftoverVerify");
let leftover_confirmed = [];
let leftover_rejected = 0;
let leftover_failures = 0;

if skip_leftovers {
    log("Skipping leftover verify (args.skip_leftovers)");
} else {
    log("Verifying " + leftover_ids.len().to_string() + " round-1 leftovers that missed the verify cap");
    let ljobs = [];
    for lid in leftover_ids {
        let p = "";
        p += "Adversarially VERIFY a round-1 leftover finding that was NEVER verified (dropped by cap).\n";
        p += "Repo: " + root + "\n";
        p += "Finding id: " + lid + "\n";
        p += "JSON catalog: " + leftover_path + "\n";
        p += "Look up that id in the JSON (id/file/issue/suggestion). Then independently inspect CURRENT working-tree code.\n";
        p += "Rules:\n";
        p += "1) READ-ONLY. read_file/grep the cited file. Working tree (uncommitted Codex edits) is truth.\n";
        p += "2) real=true ONLY with concrete evidence the defect still exists now.\n";
        p += "3) If already fixed by Codex, misunderstood, docs-only, TS-reference-only, or weak: real=false.\n";
        p += "4) Empty evidence => real=false. Prefer disconfirming.\n";
        p += "5) Do NOT re-confirm round-1 IDs that were already in the confirmed-55 list.\n";
        p += "6) id field must equal " + lid + "\n";
        ljobs.push(#{
            prompt: p,
            label: "leftover:" + lid,
            capability_mode: "read-only",
            output_schema: leftover_schema,
        });
    }
    let lres = parallel(ljobs);
    let li = 0;
    for r in lres {
        let lid = leftover_ids[li];
        if r == () || !r.success || r.output == () {
            leftover_failures += 1;
        } else if r.output.real == true && r.output.evidence != () && r.output.evidence != "" {
            let sev = r.output.severity;
            if sev == () || sev == "" || sev == "none" { sev = "med"; }
            leftover_confirmed.push(#{
                id: lid,
                severity: sev,
                issue: r.output.reason,
                evidence: r.output.evidence,
                kind: "leftover-confirmed",
            });
        } else {
            leftover_rejected += 1;
        }
        li += 1;
    }
    log("Leftovers confirmed " + leftover_confirmed.len().to_string() + "; rejected " + leftover_rejected.to_string() + "; failures " + leftover_failures.to_string());
}

// ── New gap hunt ───────────────────────────────────────────────────────────
phase("Hunt");

let dims = [
    #{ key: "ipc-socket", title: "unix socket and capability token", focus: "macos/Shared/Service/UnixSocketEngramServiceTransport.swift, UnixSocketServiceServer.swift, ServiceCapabilityToken.swift — peer UID, 0700/0600, token on mutating commands, leftover ipc-security-*" },
    #{ key: "core-read-gap", title: "CoreRead pool and app Database leftover", focus: "macos/EngramCoreRead/ entirely (untouched by Codex), macos/Engram/Core/Database.swift leftover core-read-2/3/4, nonisolated, busy_timeout, ARCH-001 pool/DTO" },
    #{ key: "cli-export-resume", title: "CLI resume export Warp", focus: "macos/EngramCLI, TranscriptExportService, TerminalLauncher, Warp 0600, cli-resume leftovers, EngramCLIArchiveCommand" },
    #{ key: "service-commands-gap", title: "service command handler leftovers", focus: "EngramServiceCommandHandler.swift not just ProjectMigration — hide, favorite, parent, relations, source enable, leftover service-commands-2..6" },
    #{ key: "search-ui", title: "search page palette sources settings", focus: "SearchPageView, CommandPaletteView, SourcePulseView, SourcesSettingsSection, AISettingsSection — ui-search-settings leftovers, false hybrid, archived sources" },
    #{ key: "popover-live", title: "menu bar popover live sessions", focus: "PopoverView, MenuBarController, LiveSessionCard, live session polling bounds, App.swift lifecycle leftovers app-lifecycle-3..6" },
    #{ key: "observability", title: "logs observability hygiene", focus: "ServiceLogSanitizer, LogStreamView, Observability views, HygieneView, DiagnosticBundleComposer" },
    #{ key: "memory-insights", title: "insights memory MCP", focus: "save_insight dual-write, MemoryView, InsightDetailView, MCP get_memory/get_context remaining, embeddings leftovers embeddings-search-2..6" },
    #{ key: "adapters-unfixed", title: "adapters Codex did not touch", focus: "ClineAdapter, IflowAdapter, CommandCodeAdapter, QoderAdapter, OpenCodeAdapter, MiniMax/Lobster derived, CursorAdapter — leftover adapter-* ids plus NEW cap/empty-session holes" },
    #{ key: "shared-untouched", title: "shared EngramCore not in Codex diff", focus: "macos/Shared/EngramCore except the adapter files already dirty — SessionTier, ParentDetection, ParserLimits, SessionAdapterFactory, AI embedding client" },
    #{ key: "project-move-residual", title: "project move residual after Codex", focus: "Orchestrator.swift, Batch.swift, leftover project-move-4/5/6, encoding, gitdir, Gemini/iFlow/OpenCode SQLite move" },
    #{ key: "archive-remote-residual", title: "archive v2 and remote leftover", focus: "ArchiveReplica, ExactSourceCapture, leftover archive-v2-4/5/6, remote-sync-2/4/5/6, RemoteSyncCoordinator, OffloadRepo, LocalDirectoryBackend" },
    #{ key: "ci-release-gap", title: "CI release verify", focus: ".github/workflows/release.yml test.yml, macos/scripts/release-verify.sh, project.yml vs pbxproj drift after xcodegen, leftover ci-release-1..5 — only if CURRENT files still have the defect" },
    #{ key: "uitests-onboarding", title: "UITests onboarding replay", focus: "macos/EngramUITests (0 files touched), OnboardingView, MCPActivationSupport, Replay/SessionReplayView" },
    #{ key: "today-usage-repos", title: "today workbench usage repos", focus: "TodayWorkbenchSupport, Usage views, ReposView, RepoDiscovery, WorkGraphView, cost notifier" },
    #{ key: "codex-diff-regress", title: "regressions in Codex uncommitted diff", focus: "git diff HEAD across dirty Swift files — look for new bugs introduced by the 55-fix patch: inverted conditions, tests that skip, pbxproj edited directly, fail-open catch, skip-tier upgrades" },
    #{ key: "fts-index-residual", title: "FTS indexer residual", focus: "SwiftIndexer, IndexJobRunner, FTSRebuildPolicy leftovers indexing-core-3/5, SessionSnapshotWriter, skip artifact removal" },
    #{ key: "parent-tier-residual", title: "parent and tier residual", focus: "leftover parent-detection-3/4/5, session-tier-4, startup-backfills-5/6, ExpandableSessionCard, AgentsView — do not re-open rejected H05 unlink or get_session skip filter" },
    #{ key: "mcp-residual", title: "MCP tools residual", focus: "MCPFileTools, MCPTranscriptTools, leftover mcp-registry-4/5 mcp-database-3/5/6 ts-product-leak-4/5, mutating tools besides project_move" },
    #{ key: "ui-pages-untouched", title: "untouched UI pages", focus: "ActivityView already dirty; hunt MemoryView, InsightDetailView, HygieneView, ObservabilityView, ProjectsView leftover ui-sessions-3..6, SessionDetail leftover ui-transcript-3/4/5" },
    #{ key: "concurrency-residual", title: "concurrency leftover", focus: "leftover concurrency-4/5/6, SettingsView, Database.swift, EngramServiceReadProvider races, hashValue cache keys" },
    #{ key: "security-settings", title: "keychain settings file perms", focus: "KeychainHelper, SecureSettingsFileWriter, AISettingsPersister, plaintext fallback only DEBUG, settings.json 0600" },
    #{ key: "human-driven-relations", title: "human-driven filter and session relations", focus: "HumanDrivenFilter, session_relations IPC, RelatedSessionPicker, skip/lite list predicates leftover" },
    #{ key: "docs-vs-code", title: "docs honesty vs current tree", focus: "leftover docs-honesty-*, Agents.md 17-source count, followups ARCH-001/R6/ALIAS-P2, CHANGELOG overclaim of the 55 fixes" },
    #{ key: "tests-skip-gaps", title: "tests that skip or miss production ~/.engram", focus: "leftover tests-parity-3/4/5, UITests, MCP tests env inheritance, XCTSkip of fail-closed repros" },
    #{ key: "opencode-sqlite", title: "OpenCode sqlite session size", focus: "OpenCodeAdapter leftover opencode-copilot-5/6 — per-session size not whole DB, archive paths" },
    #{ key: "gemini-cursor-cwd", title: "Gemini Cursor cwd ownership", focus: "CursorAdapter leftover gemini-cursor-vscode-5, Gemini sidecar leftover -6; do NOT treat chats/ folder as parentSessionId (rejected)" },
    #{ key: "writer-gate-residual", title: "writer gate residual", focus: "leftover writer-gate-3, ServiceWriterGate vs R6 holding FS, CLI writes, MCP save_insight" },
    #{ key: "startup-order", title: "startup backfill order residual", focus: "EngramServiceRunner leftover service-runner-4/5/6, todayParents after backfills, invariant 9 order" },
    #{ key: "messageparser-residual", title: "MessageParser residual after Codex", focus: "git diff MessageParser.swift — leftover stream-caps-3..6, parseLegacy remaining call sites, Load all truncatedAt" },
    #{ key: "remote-server-gap", title: "remote server leftover", focus: "macos/EngramRemoteServer mostly untouched except App.swift — catalog PUT, TLS, private host, 64MiB" },
    #{ key: "scripts-release", title: "macos scripts and deploy", focus: "macos/scripts/build-release.sh deploy-local.sh copy-*-helper.sh package-remote-server.sh — node in bundle, helper copy" },
];

let hunt_jobs = [];
for d in dims {
    let p = "";
    p += "You are a read-only ROUND-2 gap hunter for Engram.\n";
    p += "Repo: " + root + "\n";
    p += "Dimension: " + d.key + " — " + d.title + "\n";
    p += "Focus: " + d.focus + "\n";
    p += "HEAD: " + head_blob + "\n";
    p += "Dirty tree: " + dirty_blob + "\n";
    p += "Codex claim: " + claimed_blob + "\n";
    p += "Hotspots: " + hotspots_blob + "\n";
    p += "Round-1 report: " + report_path + "\n";
    p += "Leftover catalog: " + leftover_path + "\n";
    p += "REQUIREMENTS:\n";
    p += "1) READ-ONLY. Inspect CURRENT working tree (git diff HEAD plus unread files). Never edit.\n";
    p += "2) Do NOT restate the original 55 confirmed IDs unless you prove Codex's patch is incomplete/wrong (then id like " + d.key + "-regress-1 and cite the old id).\n";
    p += "3) Do NOT restate rejected false-positives: app-lifecycle-1 SIGKILL, H05 unlink, get_session skip filter, Gemini chats/ parent, indexing retry_count, linkSessions visibility, parent-detection-2, TS Database constructors.\n";
    p += "4) Prefer NEW bugs and leftover ids that are still true. At most 5 findings.\n";
    p += "5) Swift product is truth. Empty findings[] only after inspecting focus files.\n";
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

const MAX_VERIFY_NEW = 48;
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
        vp += "Adversarially VERIFY a ROUND-2 newly hunted Engram defect.\n";
        vp += "Repo: " + root + "\n";
        vp += "Claim JSON: " + encoded + "\n";
        vp += "Working tree may be dirty with Codex fixes. CURRENT files are truth.\n";
        vp += "real=true only with file:line evidence it still exists. Fail closed. Empty evidence => false.\n";
        vp += "If this merely restates a round-1 confirmed-55 item that Codex already fixed, real=false.\n";
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
let left_json = json_encode(leftover_confirmed);
let new_json = json_encode(new_confirmed);

let sp = "";
sp += "Synthesize Engram ROUND-2 review for a sibling Codex fixer.\n";
sp += "Repo: " + root + " HEAD-map: " + head_blob + "\n";
sp += "Dirty: " + dirty_blob + "\n";
sp += "Fix-audit still-open JSON (round-1 confirmed that Codex did not actually close):\n" + still_json + "\n";
sp += "Leftover-confirmed JSON (round-1 unverified items now proven real):\n" + left_json + "\n";
sp += "New-confirmed JSON (not in round-1 confirmed list):\n" + new_json + "\n";
sp += "Counts to echo: still_open=" + still_open.len().to_string() + " leftover_confirmed=" + leftover_confirmed.len().to_string() + " new_confirmed=" + new_confirmed.len().to_string() + "\n";
sp += "Audit failures=" + audit_failures.to_string() + " leftover_failures=" + leftover_failures.to_string() + " hunt_failures=" + hunt_failures.to_string() + " dropped_new=" + dropped.to_string() + "\n";
sp += "Write markdown: executive summary; three tables (still-open, leftover-confirmed, new); recommended fix order; do-not-fix reminders from round-1 rejected list.\n";
sp += "codex_fix_brief: self-contained TDD Swift-first prompt. Do not invent bugs. Deduplicate overlaps.\n";
sp += "If all three arrays empty: tell Codex not to change code except remaining delivery (commit/CI) if that is all that's left.\n";

let synth_r = agent(sp, #{
    label: "synthesize-round2",
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
    summary = "still_open=" + still_open.len().to_string() + " leftover=" + leftover_confirmed.len().to_string() + " new=" + new_confirmed.len().to_string();
    brief = "Fix only the JSON arrays in this result. Do not reopen round-1 rejected IDs.";
    markdown = "# Engram review round 2\n\n" + summary + "\n\n## still-open\n" + still_json + "\n\n## leftover\n" + left_json + "\n\n## new\n" + new_json + "\n";
}
if summary == () { summary = ""; }
if brief == () { brief = ""; }

let path = write_scratch_file("engram-review-round2.md", markdown);
complete(#{
    summary: summary,
    path: path,
    still_open: still_open,
    leftover_confirmed: leftover_confirmed,
    new_confirmed: new_confirmed,
    still_open_count: still_open.len(),
    leftover_confirmed_count: leftover_confirmed.len(),
    new_confirmed_count: new_confirmed.len(),
    closed_ok: closed_ok,
    leftover_rejected: leftover_rejected,
    new_rejected: new_rejected,
    audit_failures: audit_failures,
    leftover_failures: leftover_failures,
    hunt_failures: hunt_failures,
    dropped_new: dropped,
    codex_fix_brief: brief,
    head: head_blob,
});
