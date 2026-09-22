let meta = #{
    name: "engram-followup-plan",
    description: "Review the uncommitted Engram source-catalog wave, then design the task queue after the in-flight Cursor assignment",
    when_to_use: "When the lead wants a read-only review of the dirty 19-source wave plus a dispatchable follow-up plan that does not collide with Cursor",
    phases: [
        #{ title: "Review", detail: "five read-only reviewers on the dirty wave and parked residuals" },
        #{ title: "Verify", detail: "adversarial skeptics on high and medium findings" },
        #{ title: "Plan", detail: "ordered follow-up tasks after the in-flight assignment" },
    ],
};

let finding_schema = #{
    "type": "object",
    "required": ["dimension", "findings"],
    "properties": #{
        "dimension": #{ "type": "string" },
        "findings": #{
            "type": "array",
            "maxItems": 5,
            "items": #{
                "type": "object",
                "required": ["id", "severity", "file", "issue", "evidence", "suggestion"],
                "properties": #{
                    "id": #{ "type": "string" },
                    "severity": #{ "type": "string", "enum": ["high", "med", "low"] },
                    "file": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                    "evidence": #{ "type": "string" },
                    "suggestion": #{ "type": "string" },
                },
            },
        },
    },
};

let verdict_schema = #{
    "type": "object",
    "required": ["id", "real", "severity", "reason", "evidence"],
    "properties": #{
        "id": #{ "type": "string" },
        "real": #{ "type": "boolean" },
        "severity": #{ "type": "string", "enum": ["high", "med", "low", "none"] },
        "reason": #{ "type": "string" },
        "evidence": #{ "type": "string" },
    },
};

let plan_schema = #{
    "type": "object",
    "required": ["summary", "do_not", "tasks", "dispatch_prompt", "markdown"],
    "properties": #{
        "summary": #{ "type": "string" },
        "do_not": #{
            "type": "array",
            "maxItems": 12,
            "items": #{ "type": "string" },
        },
        "tasks": #{
            "type": "array",
            "maxItems": 6,
            "items": #{
                "type": "object",
                "required": ["id", "priority", "title", "why", "files", "verifier", "done_when"],
                "properties": #{
                    "id": #{ "type": "string" },
                    "priority": #{ "type": "string", "enum": ["p0", "p1", "p2"] },
                    "title": #{ "type": "string" },
                    "why": #{ "type": "string" },
                    "files": #{ "type": "string" },
                    "verifier": #{ "type": "string" },
                    "done_when": #{ "type": "string" },
                },
            },
        },
        "dispatch_prompt": #{ "type": "string" },
        "markdown": #{ "type": "string" },
    },
};

let repo = "/Users/bing/-Code-/engram";
if args != () && args.repo != () {
    repo = args.repo;
}

let rules = "";
rules += "Repo: " + repo + ". Read-only. Do not edit, commit, or run xcodebuild. ";
rules += "Use git diff, git status, read_file, and grep. Cite path:line. ";
rules += "The working tree is dirty and Cursor may be mid-edit on parent-unlink. Re-read a file before citing it. ";
rules += "Already landed in the dirty tree, do not re-file as new work: UNLOCK-19 (SourceCatalog/SourceColors/Onboarding/SOURCE_NAMES/docs for pi and grok), GROK-SUMMARY (GrokAdapter primaryTranscriptURL is JSONL-only), MOVE-19 (Swift SourceId/roots pi flat and grok percent-encoding), FRESHNESS-ISO (SourceIndexFreshness uses EngramTimestampParser). ";
rules += "In flight, do not schedule as new tasks: PARENT-UNLINK (applyClearParentSession must clear suggestion fields, keep subagent/dispatched at skip, setParentSession must not change tier), TS-MOVE-19 (src/core/project-move/sources.ts add pi and grok), TS-BOOTSTRAP-15 (do not invent full pi.ts or grok.ts parsers). ";
rules += "Swift product behavior is authoritative. TypeScript under src/ is reference tooling. No Docker. Empty findings is valid only after you opened the named files.";

phase("Review");

let catalog_prompt = rules;
catalog_prompt += " Dimension: UNLOCK-19 consistency. Compare SessionAdapterFactory.defaultAdapters() (expect 19, including PiAdapter and GrokAdapter) with SourceCatalog.all, SourceColors, OnboardingView.scanSources, src/adapters/types.ts SOURCE_NAMES, README, CLAUDE.md, docs/mcp-tools.md, docs/PRIVACY.md, docs/session-formats/support-matrix.yml, and docs/session-formats/pi.md plus grok.md. ";
catalog_prompt += "Report only real mismatches: missing catalog row, wrong path, color falling through to gray, docs still saying 17, tests locking 17. Return dimension='unlock-19'.";

let grok_prompt = rules;
grok_prompt += " Dimension: GROK-SUMMARY. Read macos/Shared/EngramCore/Adapters/Sources/GrokAdapter.swift primaryTranscriptURL, preferredLocator, scanSession, and GrokAdapterTests summary-only repro. ";
grok_prompt += "Confirm summary.json is metadata, not parsed as JSONL, and that a missing declared compaction segment is still malformedJSON. Report regressions only. Return dimension='grok-summary'.";

let move_prompt = rules;
move_prompt += " Dimension: MOVE-19 and FRESHNESS-ISO. Read macos/EngramCoreWrite/ProjectMove/Sources.swift SourceId and SessionSources.roots/encodeGrok, SessionSourcesTests, macos/Engram/Components/SourceIndexFreshness.swift, and EngramTimestampParser.date. ";
move_prompt += "Check pi is flat, grok encodes slash as %2F, and ISO8601 plus SQLite timestamps both classify. Report real bugs only. Return dimension='move-freshness'.";

let parent_prompt = rules;
parent_prompt += " Dimension: parent unlink as currently written. Read applyClearParentSession, applySetParentSession, and applyDismissSuggestion in macos/EngramService/Core/EngramServiceCommandHandler.swift, plus any new repro in EngramServiceIPCTests. ";
parent_prompt += "Flag only if the current diff still leaves suggested_parent_id set, upgrades skip tier, or lets setParentSession change tier. If the edit is incomplete, say so as med and do not design a second unlink task. Return dimension='parent-unlink'.";

let parked_prompt = rules;
parked_prompt += " Dimension: parked residuals that are still true in current source, not names from memory. Check at most these leads and drop any that the code already fixed: LOGIN-13 LaunchAgent.setLegacy behind macOS 14 deployment; TOPBAR-DEAD TopBarView with zero callers; DATE-PARSE-DUP extra ISO parsers on the write side; docs/full-review-report.md describing Node MCP/Daemon as current; package.json description still saying MCP Server. ";
parked_prompt += "Return dimension='parked'. A lead that is already fixed must not appear.";

let review_jobs = [
    #{ prompt: catalog_prompt, label: "review:unlock-19", capability_mode: "read-only", output_schema: finding_schema },
    #{ prompt: grok_prompt, label: "review:grok-summary", capability_mode: "read-only", output_schema: finding_schema },
    #{ prompt: move_prompt, label: "review:move-freshness", capability_mode: "read-only", output_schema: finding_schema },
    #{ prompt: parent_prompt, label: "review:parent-unlink", capability_mode: "read-only", output_schema: finding_schema },
    #{ prompt: parked_prompt, label: "review:parked", capability_mode: "read-only", output_schema: finding_schema },
];
let review_results = parallel(review_jobs);

let candidates = [];
let low_notes = [];
let slot = 0;
for r in review_results {
    if r != () && r.success && r.output != () && r.output.findings != () {
        for f in r.output.findings {
            if f.severity == "high" || f.severity == "med" {
                if candidates.len() < 6 {
                    candidates.push(f);
                } else {
                    log("dropped over verify cap: " + f.id);
                }
            } else {
                low_notes.push(f.id);
            }
        }
    } else {
        log("review slot " + slot.to_string() + " missing or failed");
    }
    slot += 1;
}
log("verify candidates " + candidates.len().to_string() + "; low notes " + low_notes.len().to_string());

phase("Verify");

let confirmed = [];
let rejected = 0;
if candidates.len() > 0 {
    let vjobs = [];
    for f in candidates {
        let vp = "";
        vp += "Adversarially verify this Engram finding. Read-only. Repo: " + repo + ". ";
        vp += "Open the cited file and the surrounding function. Set real=true only if you personally see the defect. ";
        vp += "Default real=false when the code already matches the suggestion, the file is mid-edit toward the fix, or evidence is only a comment. ";
        vp += "Return id exactly as given. Finding JSON:\n" + json_encode(f);
        vjobs.push(#{
            prompt: vp,
            label: "verify:" + f.id,
            capability_mode: "read-only",
            output_schema: verdict_schema,
        });
    }
    let verdicts = parallel(vjobs);
    let vi = 0;
    for v in verdicts {
        if v != () && v.success && v.output != () && v.output.real == true && v.output.evidence != () && v.output.evidence != "" {
            let kept = candidates[vi];
            confirmed.push(#{
                id: kept.id,
                severity: v.output.severity,
                file: kept.file,
                issue: kept.issue,
                evidence: v.output.evidence,
                suggestion: kept.suggestion,
            });
        } else {
            rejected += 1;
        }
        vi += 1;
    }
}
log("confirmed " + confirmed.len().to_string() + " rejected " + rejected.to_string());

phase("Plan");

let plan_prompt = "";
plan_prompt += "You are the Engram follow-up planner. Read-only. Do not edit. Repo: " + repo + ". ";
plan_prompt += "Re-open any file a confirmed finding cites before you schedule it. ";
plan_prompt += "Cursor is already implementing, in order: PARENT-UNLINK, then TS-MOVE-19, then TS-BOOTSTRAP-15. ";
plan_prompt += "Do not put those three, or UNLOCK-19, GROK-SUMMARY, MOVE-19, FRESHNESS-ISO, into tasks. ";
plan_prompt += "Do not schedule LOGIN-13 or TOPBAR-DEAD unless a confirmed finding still shows the bug. ";
plan_prompt += "Do not schedule commit, push, PR, Docker, HQ deploy, or a full-repo inventory. ";
plan_prompt += "Cap 6 tasks, p0 first. Each task must name files and a concrete verifier command or test name. ";
plan_prompt += "dispatch_prompt is one English prompt a later Cursor turn can run after the in-flight wave, without this chat. ";
plan_prompt += "markdown is a GitHub-markdown digest: confirmed findings, rejected count, then a task table. ";
plan_prompt += "If nothing confirmed is worth a task, return tasks=[] and say the queue waits on the in-flight wave. ";
plan_prompt += "Confirmed findings JSON:\n" + json_encode(confirmed) + "\n";
plan_prompt += "Low-severity ids not verified: " + json_encode(low_notes) + "\n";
plan_prompt += "Rejected-or-unverified count: " + rejected.to_string() + ".";

let plan_res = agent(plan_prompt, #{
    label: "plan:followups",
    capability_mode: "read-only",
    output_schema: plan_schema,
});

if plan_res == () || !plan_res.success || plan_res.output == () {
    complete(#{
        summary: "Planner failed. Confirmed findings were kept for a manual pass.",
        confirmed: confirmed,
        rejected: rejected,
    });
}

let md = "No markdown from planner.";
if plan_res.output.markdown != () && type_of(plan_res.output.markdown) == "string" && plan_res.output.markdown != "" {
    md = plan_res.output.markdown;
}
let report_path = write_scratch_file("followup-plan.md", md);

let summary = "";
if plan_res.output.summary != () && type_of(plan_res.output.summary) == "string" {
    summary = plan_res.output.summary;
}
let tasks = [];
if plan_res.output.tasks != () {
    tasks = plan_res.output.tasks;
}
let do_not = [];
if plan_res.output.do_not != () {
    do_not = plan_res.output.do_not;
}
let dispatch_prompt = "";
if plan_res.output.dispatch_prompt != () && type_of(plan_res.output.dispatch_prompt) == "string" {
    dispatch_prompt = plan_res.output.dispatch_prompt;
}

complete(#{
    path: report_path,
    summary: summary,
    tasks: tasks,
    do_not: do_not,
    dispatch_prompt: dispatch_prompt,
    confirmed_count: confirmed.len(),
    rejected_count: rejected,
});
