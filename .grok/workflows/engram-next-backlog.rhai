let meta = #{
    name: "engram-next-backlog",
    description: "Two-round Engram next-work recovery: history then a dispatchable development plan",
    when_to_use: "When the user wants the next Engram development backlog recovered from current files and then handed to another agent",
    phases: [
        #{ title: "History", detail: "four read-only historians: collector web, backlog files, git topology, HQ residuals" },
        #{ title: "Plan", detail: "one planner turns verified history into ordered tasks plus a Cursor dispatch prompt" },
    ],
};

let history_schema = #{
    "type": "object",
    "required": ["area", "facts", "open_items"],
    "properties": #{
        "area": #{ "type": "string" },
        "facts": #{
            "type": "array",
            "maxItems": 12,
            "items": #{
                "type": "object",
                "required": ["claim", "evidence"],
                "properties": #{
                    "claim": #{ "type": "string" },
                    "evidence": #{ "type": "string" },
                },
            },
        },
        "open_items": #{
            "type": "array",
            "maxItems": 10,
            "items": #{
                "type": "object",
                "required": ["id", "why", "evidence"],
                "properties": #{
                    "id": #{ "type": "string" },
                    "why": #{ "type": "string" },
                    "evidence": #{ "type": "string" },
                },
            },
        },
    },
};

let plan_schema = #{
    "type": "object",
    "required": ["summary", "workdir", "branch", "do_not", "tasks", "dispatch_prompt", "markdown"],
    "properties": #{
        "summary": #{ "type": "string" },
        "workdir": #{ "type": "string" },
        "branch": #{ "type": "string" },
        "do_not": #{
            "type": "array",
            "maxItems": 12,
            "items": #{ "type": "string" },
        },
        "tasks": #{
            "type": "array",
            "maxItems": 8,
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

phase("History");

let collector_prompt = "";
collector_prompt += "You are a read-only historian for Engram collector/native-web work. ";
collector_prompt += "Repo: " + repo + ". ";
collector_prompt += "Use read_file, grep, and git commands only. Do not edit files. ";
collector_prompt += "Read these if they exist: ";
collector_prompt += repo + "/.worktrees/collector-server-web-20260905/CHANGELOG.md; ";
collector_prompt += repo + "/.worktrees/collector-server-web-20260905/MEMO.md; ";
collector_prompt += repo + "/docs/superpowers/plans/2026-09-13-web-native-parity.md; ";
collector_prompt += "git -C " + repo + "/.worktrees/collector-server-web-20260905 log --oneline -15; ";
collector_prompt += "git -C " + repo + "/.worktrees/collector-server-web-20260905 status -sb. ";
collector_prompt += "Return area='collector-web'. Facts must cite file paths or SHAs. ";
collector_prompt += "open_items are remaining HQ-scale web defects, unmerged state, and deploy markers. ";
collector_prompt += "Empty open_items is valid only after those files were actually read.";

let backlog_prompt = "";
backlog_prompt += "You are a read-only historian for Engram canonical backlog files. ";
backlog_prompt += "Repo: " + repo + ". Use read_file and grep only. Do not edit. ";
backlog_prompt += "Read " + repo + "/docs/TODO.md, " + repo + "/docs/roadmap.md, " + repo + "/docs/followups.md. ";
backlog_prompt += "Distinguish: empty engineering TODO vs parked follow-ups vs owner-decision roadmap rows. ";
backlog_prompt += "Return area='backlog'. Facts and open_items must cite heading or row IDs such as live-ingest-sla-1. ";
backlog_prompt += "Do not invent tasks that those files mark DONE or closed.";

let git_prompt = "";
git_prompt += "You are a read-only historian for Engram git topology on this HQ checkout. ";
git_prompt += "Repo: " + repo + ". Use git commands and read_file. Do not edit. ";
git_prompt += "Collect: git -C " + repo + " rev-parse --short HEAD origin/main; git status -sb; git worktree list; ";
git_prompt += "git log --oneline -8; whether main is dirty (CHANGELOG/MEMO/.gitignore hygiene only is expected). ";
git_prompt += "Return area='git-topology'. open_items should cover: do not merge collector into main unless asked; ";
git_prompt += "local dirty hygiene docs; remaining worktrees with unique uncommitted source.";

let residual_prompt = "";
residual_prompt += "You are a read-only historian for HQ-scale residuals named in Engram MEMO/CHANGELOG. ";
residual_prompt += "Repo: " + repo + ". Read " + repo + "/MEMO.md (2026-09-14 and 2026-09-13) and CHANGELOG Unreleased. ";
residual_prompt += "Also grep collector worktree MEMO for 503, CJK, overview, session_files, INDEXED BY. ";
residual_prompt += "Return area='hq-residuals'. Capture claimed-fixed vs still-open HQ web issues with evidence. ";
residual_prompt += "Known leads to confirm or refute from files: overview default limit=50 503; two-char CJK search 5-6s; ";
residual_prompt += "Health Parsed skip-tier count; live-ingest 16-minute SLA unproven. Do not treat MEMO as truth without the file citation.";

let history_jobs = [
    #{ prompt: collector_prompt, label: "history:collector-web", capability_mode: "read-only", output_schema: history_schema },
    #{ prompt: backlog_prompt, label: "history:backlog", capability_mode: "read-only", output_schema: history_schema },
    #{ prompt: git_prompt, label: "history:git-topology", capability_mode: "read-only", output_schema: history_schema },
    #{ prompt: residual_prompt, label: "history:hq-residuals", capability_mode: "read-only", output_schema: history_schema },
];
let history_results = parallel(history_jobs);

let histories = [];
let i = 0;
for r in history_results {
    if r != () && r.success && r.output != () {
        histories.push(r.output);
    } else {
        log("history slot " + i.to_string() + " failed or empty; planner must treat that area as unknown");
    }
    i += 1;
}
if histories.len() == 0 {
    complete(#{ summary: "History round produced no usable output.", tasks: [] });
}

phase("Plan");

let packed = json_encode(histories);
let plan_prompt = "";
plan_prompt += "You are the Engram next-work planner. Read-only. Do not edit the repo. ";
plan_prompt += "Repo: " + repo + ". You received four historian JSON blobs. Re-open the cited files if a claim is load-bearing. ";
plan_prompt += "Historian JSON:\n" + packed + "\n";
plan_prompt += "Produce an ordered development plan for a sibling Cursor agent. ";
plan_prompt += "Default workdir to " + repo + "/.worktrees/collector-server-web-20260905 if collector web residuals remain; ";
plan_prompt += "otherwise " + repo + " on current main. ";
plan_prompt += "Do not schedule merging collector into main, public v1.0.6, Docker, or production ~/.engram writes. ";
plan_prompt += "Do not turn owner-decision roadmap rows into engineering tasks. ";
plan_prompt += "Prefer HQ web residuals that files still mark open. Cap at 8 tasks, p0 first. ";
plan_prompt += "dispatch_prompt must be a complete English prompt Cursor can execute without this chat: include workdir, branch, constraints, tasks, verifiers. ";
plan_prompt += "markdown is a human digest in GitHub markdown with tasks as a table. ";
plan_prompt += "workdir and branch must be real paths/refs from git, not invented.";

let plan_res = agent(plan_prompt, #{
    label: "plan:dispatch",
    capability_mode: "read-only",
    output_schema: plan_schema,
});

if plan_res == () || !plan_res.success || plan_res.output == () {
    complete(#{ summary: "Planner failed after history round.", history_areas: histories.len() });
}

let md = "No markdown from planner.";
if plan_res.output.markdown != () && type_of(plan_res.output.markdown) == "string" {
    md = plan_res.output.markdown;
} else if plan_res.output.summary != () && type_of(plan_res.output.summary) == "string" {
    md = plan_res.output.summary;
}
if md == "" {
    md = "No markdown from planner.";
}
let report_path = write_scratch_file("next-backlog.md", md);

let summary = "";
if plan_res.output.summary != () && type_of(plan_res.output.summary) == "string" {
    summary = plan_res.output.summary;
}
let workdir = repo;
if plan_res.output.workdir != () && type_of(plan_res.output.workdir) == "string" {
    workdir = plan_res.output.workdir;
}
let branch = "";
if plan_res.output.branch != () && type_of(plan_res.output.branch) == "string" {
    branch = plan_res.output.branch;
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
    workdir: workdir,
    branch: branch,
    tasks: tasks,
    do_not: do_not,
    dispatch_prompt: dispatch_prompt,
});
