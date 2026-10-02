let meta = #{
    name: "engram-residual-verify-2026-09-01",
    description: "Verify the exact 94 MAX_VERIFY drops from 2026-08-31 engram-multi-review against current source",
    when_to_use: "After recovering .grok/engram-dropped-94-2026-09-01.json; residual-only verify, no new bug hunt",
    phases: [
        #{ title: "Preflight", detail: "confirm HEAD and recovered 94-id catalog" },
        #{ title: "VerifyA", detail: "fail-closed verify of first 47 recovered IDs" },
        #{ title: "VerifyB", detail: "fail-closed verify of remaining 47 recovered IDs" },
        #{ title: "Synthesize", detail: "residual-only report and Codex brief in scratch" },
    ],
};

let preflight_schema = #{
    "type": "object",
    "required": ["head", "json_count", "json_unique", "ok", "reason"],
    "properties": #{
        "head": #{ "type": "string" },
        "json_count": #{ "type": "integer" },
        "json_unique": #{ "type": "integer" },
        "ok": #{ "type": "boolean" },
        "reason": #{ "type": "string" },
    },
};

let verdict_schema = #{
    "type": "object",
    "required": ["id", "disposition", "severity", "reason", "evidence"],
    "properties": #{
        "id": #{ "type": "string" },
        "disposition": #{
            "type": "string",
            "enum": ["confirmed", "rejected", "duplicate", "unverified"],
        },
        "severity": #{
            "type": "string",
            "enum": ["critical", "high", "med", "low", "none"],
        },
        "duplicate_of": #{ "type": "string" },
        "reason": #{ "type": "string" },
        "evidence": #{ "type": "string" },
    },
};

let report_schema = #{
    "type": "object",
    "required": ["markdown", "summary", "codex_fix_brief", "confirmed_count", "rejected_count", "duplicate_count", "unverified_count"],
    "properties": #{
        "markdown": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "codex_fix_brief": #{ "type": "string" },
        "confirmed_count": #{ "type": "integer" },
        "rejected_count": #{ "type": "integer" },
        "duplicate_count": #{ "type": "integer" },
        "unverified_count": #{ "type": "integer" },
    },
};

fn as_str(v) {
    if v == () { return ""; }
    if type_of(v) == "string" { return v; }
    "";
}

fn classify_result(id, v) {
    if v == () || !v.success || v.output == () {
        return #{
            id: id,
            disposition: "unverified",
            severity: "none",
            duplicate_of: "",
            reason: "agent-failed-or-empty",
            evidence: "",
        };
    }
    let out = v.output;
    let d = as_str(out.disposition);
    let ev = as_str(out.evidence);
    let reason = as_str(out.reason);
    let sev = as_str(out.severity);
    if sev == "" { sev = "none"; }
    let dup = as_str(out.duplicate_of);
    if d == "confirmed" {
        if ev == "" {
            return #{
                id: id,
                disposition: "unverified",
                severity: "none",
                duplicate_of: "",
                reason: "confirmed-without-evidence",
                evidence: "",
            };
        }
        return #{
            id: id,
            disposition: "confirmed",
            severity: sev,
            duplicate_of: dup,
            reason: reason,
            evidence: ev,
        };
    }
    if d == "duplicate" {
        if dup == "" {
            return #{
                id: id,
                disposition: "unverified",
                severity: "none",
                duplicate_of: "",
                reason: "duplicate-without-duplicate_of",
                evidence: ev,
            };
        }
        return #{
            id: id,
            disposition: "duplicate",
            severity: sev,
            duplicate_of: dup,
            reason: reason,
            evidence: ev,
        };
    }
    if d == "rejected" {
        return #{
            id: id,
            disposition: "rejected",
            severity: sev,
            duplicate_of: dup,
            reason: reason,
            evidence: ev,
        };
    }
    let unv_reason = reason;
    if unv_reason == "" {
        unv_reason = "unknown-or-missing-disposition";
    }
    #{
        id: id,
        disposition: "unverified",
        severity: "none",
        duplicate_of: dup,
        reason: unv_reason,
        evidence: ev,
    }
}

fn verify_prompt(root, catalog, prior_report, mapped_head, id, idx) {
    let p = "";
    p += "You are a fail-closed adversarial verifier. READ-ONLY.\n";
    p += "Repo root: " + root + "\n";
    p += "Mapped HEAD: " + mapped_head + "\n";
    p += "Candidate id (exact, do not substitute): " + id + "\n";
    p += "Work-list index: " + idx.to_string() + " of 94.\n";
    p += "Catalog JSON: " + catalog + "\n";
    p += "Prior report: " + prior_report + "\n";
    p += "REQUIREMENTS:\n";
    p += "1) Use read_file/grep/list_dir and read-only git. NEVER edit, commit, build, test, SSH, deploy, or use Docker.\n";
    p += "2) Read the catalog JSON and locate dropped_candidates[] whose id equals this candidate id exactly. Use that object's file, issue, suggestion, claimed severity, dimension, confidence. Do not pick another id. Do not re-review the whole catalog.\n";
    p += "3) Independently open the cited file in CURRENT source. Product Swift under macos/ is truth. TypeScript is reference unless a shipped path still depends on it.\n";
    p += "4) Read " + prior_report + " confirmed table and rejected/false-positive table. If this candidate is the same defect as any listed id, disposition=duplicate and duplicate_of=<that existing id>. Semantic match counts even when ids differ.\n";
    p += "5) disposition must be one of: confirmed, rejected, duplicate, unverified.\n";
    p += "6) confirmed ONLY if you personally inspect file:line evidence the defect still exists in CURRENT source. evidence must quote file:line or a short snippet. Empty evidence forbids confirmed.\n";
    p += "7) rejected if already fixed, misunderstanding, test-only, docs-only, TypeScript-reference-only, or weak evidence.\n";
    p += "8) Prefer disconfirming. Do not invent extra bugs. Do not hunt neighboring defects. Do not implement fixes.\n";
    p += "9) Reassess severity (critical/high/med/low/none) from current code. id in the output must equal " + id + ".\n";
    p += "10) If the catalog row is missing, the file is gone, or you cannot get evidence, disposition=unverified.\n";
    p
}

let ids_a = [
    "writer-gate-4",
    "writer-gate-5",
    "service-commands-3",
    "service-read-1",
    "service-read-2",
    "service-read-3",
    "service-read-4",
    "service-read-5",
    "mcp-registry-2",
    "mcp-registry-3",
    "mcp-registry-4",
    "mcp-registry-5",
    "mcp-database-1",
    "mcp-database-3",
    "adapters-claude-codex-3",
    "adapters-claude-codex-4",
    "adapters-gemini-cursor-vscode-3",
    "adapters-gemini-cursor-vscode-4",
    "adapters-gemini-cursor-vscode-5",
    "adapters-opencode-copilot-2",
    "adapters-opencode-copilot-3",
    "adapters-opencode-copilot-4",
    "adapters-opencode-copilot-5",
    "adapters-jsonl-rest-2",
    "adapters-jsonl-rest-3",
    "adapters-jsonl-rest-4",
    "adapters-jsonl-rest-5",
    "adapters-archived-cache-2",
    "adapters-archived-cache-3",
    "adapters-archived-cache-4",
    "adapters-archived-cache-5",
    "stream-caps-6",
    "indexing-core-3",
    "indexing-core-4",
    "indexing-core-5",
    "startup-backfills-3",
    "startup-backfills-4",
    "session-tier-3",
    "session-tier-4",
    "parent-detection-2",
    "parent-detection-3",
    "parent-detection-4",
    "parent-detection-5",
    "project-move-3",
    "project-move-4",
    "project-move-5",
    "core-read-2",
];

let ids_b = [
    "core-read-3",
    "core-read-4",
    "core-read-5",
    "embeddings-search-4",
    "archive-v2-4",
    "archive-v2-5",
    "archive-v2-6",
    "remote-sync-3",
    "remote-sync-4",
    "remote-sync-5",
    "remote-sync-6",
    "ui-sessions-2",
    "ui-sessions-3",
    "ui-sessions-4",
    "ui-sessions-5",
    "ui-sessions-6",
    "ui-transcript-2",
    "ui-transcript-3",
    "ui-transcript-4",
    "ui-search-settings-1",
    "ui-search-settings-2",
    "ui-search-settings-3",
    "ui-search-settings-4",
    "concurrency-3",
    "concurrency-4",
    "concurrency-5",
    "tests-parity-5",
    "tests-parity-6",
    "ts-product-leak-3",
    "ci-release-1",
    "ci-release-2",
    "ci-release-3",
    "ci-release-5",
    "ci-release-6",
    "cli-resume-1",
    "cli-resume-4",
    "cli-resume-5",
    "cli-resume-6",
    "docs-honesty-2",
    "docs-honesty-3",
    "docs-honesty-4",
    "mcp-database-5",
    "adapters-jsonl-rest-6",
    "session-tier-5",
    "project-move-6",
    "ui-transcript-5",
    "ui-search-settings-5",
];

let root = "/Users/bing/-Code-/engram";
if args != () && args.root != () && type_of(args.root) == "string" {
    root = args.root;
    root.trim();
    if root == "" {
        root = "/Users/bing/-Code-/engram";
    }
}

let catalog = root + "/.grok/engram-dropped-94-2026-09-01.json";
let prior_report = root + "/.grok/engram-multi-review-2026-08-31.md";
let mapped_head = "33b6f8c95faaa7b2df25afe3037dd613e2085bde";

if ids_a.len() != 47 || ids_b.len() != 47 {
    complete(#{
        summary: "hardcoded ID batches are not 47+47",
        recovered_count: ids_a.len() + ids_b.len(),
        confirmed_count: 0,
        rejected_count: 0,
        duplicate_count: 0,
        unverified_count: 0,
    });
}

phase("Preflight");
log("Preflight catalog " + catalog + " against HEAD " + mapped_head);

let pre_p = "";
pre_p += "READ-ONLY preflight for Engram residual verify.\n";
pre_p += "Repo: " + root + "\n";
pre_p += "1) Run git rev-parse HEAD. Expected mapped HEAD: " + mapped_head + "\n";
pre_p += "2) Read " + catalog + " . Count dropped_candidates. Count unique id fields.\n";
pre_p += "3) ok=true only if json_count==94 AND json_unique==94 AND the file is the recovered catalog (not a re-review).\n";
pre_p += "4) Do not verify defects. Do not edit files.\n";
pre_p += "head: the hash you actually saw. reason: short status.\n";

let pre = agent(pre_p, #{
    label: "preflight-catalog",
    capability_mode: "read-only",
    output_schema: preflight_schema,
});

let pre_ok = false;
let pre_head = "";
let pre_reason = "preflight-missing";
if pre != () && pre.success && pre.output != () {
    pre_ok = pre.output.ok == true;
    pre_head = as_str(pre.output.head);
    pre_reason = as_str(pre.output.reason);
    let jc = pre.output.json_count;
    let ju = pre.output.json_unique;
    if jc != 94 || ju != 94 {
        pre_ok = false;
        if pre_reason == "" { pre_reason = "catalog-count-not-94"; }
    }
}

if pre_ok == false {
    let fail_md = "";
    fail_md += "# Engram residual verify 2026-09-01 — preflight failed\n\n";
    fail_md += "Catalog: `" + catalog + "`\n\n";
    fail_md += "HEAD seen: `" + pre_head + "`\n\n";
    fail_md += "Reason: " + pre_reason + "\n\n";
    fail_md += "No candidate was verified. Nothing was confirmed.\n";
    let fail_path = write_scratch_file("engram-residual-verify-2026-09-01.md", fail_md);
    complete(#{
        summary: "preflight failed; 0 verified, 0 confirmed",
        path: fail_path,
        recovered_count: 94,
        confirmed_count: 0,
        rejected_count: 0,
        duplicate_count: 0,
        unverified_count: 94,
        head: pre_head,
        reason: pre_reason,
        codex_fix_brief: "Do not change code. Residual verify preflight failed.",
    });
}

log("Preflight ok head=" + pre_head);

phase("VerifyA");
log("VerifyA first 47 IDs");
let jobs_a = [];
let ia_build = 0;
for id in ids_a {
    let idx = ia_build;
    let p = verify_prompt(root, catalog, prior_report, mapped_head, id, idx);
    jobs_a.push(#{
        prompt: p,
        label: "verify-" + idx.to_string() + "-" + id,
        capability_mode: "read-only",
        output_schema: verdict_schema,
    });
    ia_build += 1;
}
let results_a = parallel(jobs_a);

phase("VerifyB");
log("VerifyB remaining 47 IDs");
let jobs_b = [];
let ib_build = 0;
for id in ids_b {
    let idx = 47 + ib_build;
    let p = verify_prompt(root, catalog, prior_report, mapped_head, id, idx);
    jobs_b.push(#{
        prompt: p,
        label: "verify-" + idx.to_string() + "-" + id,
        capability_mode: "read-only",
        output_schema: verdict_schema,
    });
    ib_build += 1;
}
let results_b = parallel(jobs_b);

let classified = [];
let ia = 0;
for v in results_a {
    classified.push(classify_result(ids_a[ia], v));
    ia += 1;
}
let ib = 0;
for v in results_b {
    classified.push(classify_result(ids_b[ib], v));
    ib += 1;
}

let confirmed = [];
let rejected = [];
let duplicates = [];
let unverified = [];
for row in classified {
    if row.disposition == "confirmed" {
        confirmed.push(row);
    } else if row.disposition == "rejected" {
        rejected.push(row);
    } else if row.disposition == "duplicate" {
        duplicates.push(row);
    } else {
        unverified.push(row);
    }
}

let n_conf = confirmed.len();
let n_rej = rejected.len();
let n_dup = duplicates.len();
let n_unv = unverified.len();
let n_all = classified.len();
log("classified " + n_all.to_string() + " confirmed=" + n_conf.to_string() + " rejected=" + n_rej.to_string() + " duplicate=" + n_dup.to_string() + " unverified=" + n_unv.to_string());

phase("Synthesize");

let synth_p = "";
synth_p += "Synthesize a residual-only Engram verify report. READ-ONLY. Do not hunt new bugs. Do not implement.\n";
synth_p += "Repo: " + root + "\n";
synth_p += "Mapped HEAD: " + mapped_head + "\n";
synth_p += "Preflight HEAD: " + pre_head + "\n";
synth_p += "Catalog: " + catalog + "\n";
synth_p += "Prior report (already verified 64; do not re-open those except as duplicate targets): " + prior_report + "\n";
synth_p += "Script-enforced counts (use these; do not invent): confirmed=" + n_conf.to_string() + " rejected=" + n_rej.to_string() + " duplicate=" + n_dup.to_string() + " unverified=" + n_unv.to_string() + " total=" + n_all.to_string() + "\n";
synth_p += "Every recovered id must appear exactly once across the four lists.\n";
synth_p += "Confirmed JSON:\n" + json_encode(confirmed) + "\n";
synth_p += "Rejected JSON:\n" + json_encode(rejected) + "\n";
synth_p += "Duplicate JSON:\n" + json_encode(duplicates) + "\n";
synth_p += "Unverified JSON:\n" + json_encode(unverified) + "\n";
synth_p += "Write markdown with: executive summary; confirmed residual table (id, reassessed severity, file:line evidence, suggestion from catalog if you read it); duplicates with duplicate_of; rejected; unverified (agent failure and missing evidence stay unverified, never confirmed); explicit statement that the 44 confirmed and 20 rejected from 2026-08-31 are out of scope except as duplicate targets.\n";
synth_p += "codex_fix_brief: self-contained prompt for residual CONFIRMED items only. TDD _repro, Swift-first, no xcodeproj edits, no skip-tier upgrades, writes via service only, no Docker. If confirmed is empty, tell Codex not to change code.\n";
synth_p += "confirmed_count/rejected_count/duplicate_count/unverified_count MUST equal the script-enforced counts above.\n";
synth_p += "Do not invent extra bugs.\n";

let synth = agent(synth_p, #{
    label: "synthesize-residual",
    capability_mode: "read-only",
    output_schema: report_schema,
});

let markdown = "";
let summary = n_conf.to_string() + " confirmed / " + n_rej.to_string() + " rejected / " + n_dup.to_string() + " duplicate / " + n_unv.to_string() + " unverified of 94";
let brief = "Fix only residual CONFIRMED IDs from the 2026-09-01 dropped-94 verify. Do not implement rejected, duplicate, or unverified IDs. If confirmed_count is 0, do not change code.";
if synth != () && synth.success && synth.output != () {
    markdown = as_str(synth.output.markdown);
    let s2 = as_str(synth.output.summary);
    if s2 != "" { summary = s2; }
    let b2 = as_str(synth.output.codex_fix_brief);
    if b2 != "" { brief = b2; }
}

if markdown == "" {
    markdown += "# Engram residual verify 2026-09-01\n\n";
    markdown += "Synthesizer missing; script counts are authoritative.\n\n";
    markdown += "- confirmed: " + n_conf.to_string() + "\n";
    markdown += "- rejected: " + n_rej.to_string() + "\n";
    markdown += "- duplicate: " + n_dup.to_string() + "\n";
    markdown += "- unverified: " + n_unv.to_string() + "\n\n";
    markdown += "HEAD mapped: `" + mapped_head + "` preflight: `" + pre_head + "`\n\n";
    markdown += "## Confirmed\n\n" + json_encode(confirmed) + "\n\n";
    markdown += "## Rejected\n\n" + json_encode(rejected) + "\n\n";
    markdown += "## Duplicate\n\n" + json_encode(duplicates) + "\n\n";
    markdown += "## Unverified\n\n" + json_encode(unverified) + "\n";
}

let report_path = write_scratch_file("engram-residual-verify-2026-09-01.md", markdown);
let brief_path = write_scratch_file("codex-fix-from-residual-verify-2026-09-01.md", brief);

complete(#{
    summary: summary,
    path: report_path,
    brief_path: brief_path,
    recovered_count: 94,
    batch_a: 47,
    batch_b: 47,
    confirmed_count: n_conf,
    rejected_count: n_rej,
    duplicate_count: n_dup,
    unverified_count: n_unv,
    classified_count: n_all,
    head: pre_head,
    mapped_head: mapped_head,
    catalog: catalog,
    prior_report: prior_report,
    confirmed: confirmed,
    rejected: rejected,
    duplicates: duplicates,
    unverified: unverified,
    codex_fix_brief: brief,
});
