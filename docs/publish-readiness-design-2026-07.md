# Design Doc: Publish Readiness — Public Copy, Release Notes, and the 1.0.5 Runbook

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog rows 0, 6, 18; composes
  with the accepted baseline specs `docs/source-health-predicate-design-2026-07.md`
  (shares `docs/invariants.md`) and `docs/adapter-format-drift-design-2026-07.md`
  (shares source-count truth); `docs/roadmap.md` "public macOS release baseline";
  `docs/TODO.md` "Public macOS release baseline".

> **Citation baseline.** The brief names HEAD `23dca547` (branch
> `docs/mirror-followup-specs`, clean). The actual working tree this spec was
> authored against is HEAD `382693db` on branch `feat/adapter-format-drift`,
> dirty (`package.json`, `macos/Engram.xcodeproj/project.pbxproj` modified; several
> untracked design docs). Every `path:line` below was personally opened at
> `382693db`. Concurrent implementation of the four accepted specs will drift these
> anchors; that is expected. An implementer on any other commit must re-anchor.

## Problem

Engram's public face is measurably false, and its release channel is stalled one
owner-decision short of shipping. Three coupled facts, all verified:

1. **The public description names an architecture that was deleted.**
   `gh repo view --json description,repositoryTopics,homepageUrl` returns
   description `"Cross-tool AI session aggregator: TypeScript MCP server and macOS
   menu bar app"`, topics `[ai-coding, local-first, macos, mcp, raspberry-pi,
   sqlite, typescript, web-ui]`, `homepageUrl ""`. The shipped runtime is native
   Swift (`EngramService` + `EngramMCP`); TypeScript is reference/dev tooling only
   (`CLAUDE.md:1-8`). `raspberry-pi` and `web-ui` name a Node/HTTP surface that no
   longer exists in the product path. `README.md:117` promises
   `之后通过文件监听增量更新` (incremental updates via file watching) — a file
   watcher that a test asserts must NOT exist on disk
   (`macos/EngramTests/AppSearchServiceCutoverScanTests.swift:1062-1075`,
   `testUnusedSwiftWatcherPathIsRemovedFromProductAndTests`). The real cadence is
   an adaptive periodic scan of 15/30/60 min
   (`macos/EngramService/Core/IndexingSchedulePolicy.swift:32-35`). A stranger
   reading the repo today is lied to on the first screen.

2. **There is no user-readable release notes artifact anywhere.** `CHANGELOG.md`
   is agent narrative by mandate (`CLAUDE.md` "Memory & cross-AI handoff"); its
   `[Unreleased]` span (`CHANGELOG.md:8-793`) is ~60 headings of audit/fix log,
   dense with the exact internal wording a user-facing note must not contain.
   `ls docs/release-notes/` → does not exist. When 1.0.5 publishes, its GitHub
   Release body has no honest source.

3. **1.0.5 is built, signed, and installed locally — but unpublished — and the
   authorization to publish is explicitly withheld.** `gh release list` shows
   `v1.0.3` as Latest (2026-05-07). A `v1.0.4` git tag exists (never released);
   no `v1.0.5` tag exists. `package.json:3` is `1.0.5`; `macos/project.yml`
   MARKETING_VERSION is `1.0.5`. A Developer-ID-signed `1.0.5 (1340)` is installed
   locally but not notarized/stapled/tagged (`CHANGELOG.md:11-15`). `docs/TODO.md:31-33`
   and `docs/roadmap.md:82-85` explicitly do NOT authorize pushing a tag or
   publishing. So publish is an owner decision, and every honesty fix that waits on
   it reaches only re-downloaders.

This spec fixes what is false today, stages the note artifact and its gate, and
stages the publish runbook — performing no state change itself.

## Goals / Non-goals

**Goals**

- Correct the public description and topics to describe the Swift product, and
  delete the false file-watching sentence — the fixes that are lies independent of
  any release.
- Add `scripts/check-public-copy.sh`, a fail-closed gate that catches the false
  claims regressing, deriving counts from source-of-truth files (not hardcoded).
- Establish `docs/release-notes/<version>.md` as a new artifact class, gated at
  tag time, and author `docs/release-notes/1.0.5.md` itself.
- Produce a "publish 1.0.5" runbook: exact ordered commands, each publish/notarize/
  tag step marked `[needs owner authorization]`, plus a go/no-go decision memo.

**Non-goals**

- Editing repo metadata (`gh repo edit`), pushing a tag, `gh release create`, or
  any DB write. This spec stages text and scripts only.
- The README Download CTA to `/releases/latest` — it may not land until 1.0.5
  publishes, because `/releases/latest` resolves to `v1.0.3` today (see Row 6).
- Homebrew, Sparkle, notarization automation, or CI signing capability (out of
  scope per `docs/roadmap.md:87`).
- Porting the Agent Sessions release-notes skill or its Python linter wholesale —
  adapt the rules, do not copy the files.

## Current state

**Repo metadata (verified via `gh repo view`, 2026-07-24).** description =
`"Cross-tool AI session aggregator: TypeScript MCP server and macOS menu bar app"`;
topics = `ai-coding, local-first, macos, mcp, raspberry-pi, sqlite, typescript,
web-ui`; homepageUrl = `""`.

**README.** `README.md:1` title; `:3` positioning line (bilingual, mentions
`14 个默认启用来源 + 3 个归档默认关闭来源`); `:5` the Codex→Claude continuity hook;
`:7-20` an internal "Current product state (2026-07-15)" status memo — the second
block a reader sees, referencing `docs/TODO.md`, `docs/followups.md`, `docs/roadmap.md`
and archive-v2 backlog counts. `:97-117` 快速上手 opens with `git clone` +
`build-release.sh --local-only`; `:117` the false file-watching sentence. There is
NO Download CTA (grep for `releases/latest|releases/download|下载|Download` in
`README.md` → nothing). `:212` `当前暴露 27 个工具`; `:3,:11,:93` source counts.

**Ingestion cadence (the truthful replacement for :117).**
`IndexingSchedulePolicy.swift:32-35`: `minInterval=15*60`, `midInterval=30*60`,
`maxInterval=60*60`, `fallbackInterval=60*60`; backoff in `recordScan` at `:56-77`
(min after activity, backing off to max when idle). No FSEvents watcher is wired
(`AppSearchServiceCutoverScanTests.swift:1062-1085` asserts the four watcher files
absent and that indexer comments describe the periodic scan).

**Source-of-truth counts.** `macos/Engram/Models/SourceCatalog.swift:26-44` —
`SourceCatalog.all` has exactly 17 leading-dot `.init(source:` rows. The
`init(source:` DEFINITION at `SourceCatalog.swift:50` has NO leading dot and must
be excluded from any count (an unanchored `grep -c 'init(source:'` counts 18).
Archived-by-default is derived from `ArchivedDefaultOffSources.contains`
(`SourceCatalog.swift:54`), whose canonical 3-member list is
`ArchivedDefaultOffSources.orderedIDs` (`macos/Shared/Service/ArchivedDefaultOffSources.swift:6`
= `["cline", "iflow", "lobsterai"]`), which `README.md:3` names as the archived set.
Tool count:
`docs/mcp-tools.md:5` `**Total tools: 27**`, echoed at `README.md:212`.

**Invariant gate registry.** `scripts/invariant-gates.json` — `gates{}` maps a gate
id to `{type:argv, argv:["bash","scripts/<name>.sh"]}` (existing example
`app-mcp-cli-direct-writes` at the `gates` block) or `{type:"ledger-paths"}`;
`invariants{}` maps ids 1-13 to gate-id lists. `scripts/check-invariants-ledger.sh`
enforces the argv schema strictly: `SCRIPT_REL_RE = ^scripts/[A-Za-z0-9][A-Za-z0-9._/-]*\.sh$`,
`len(argv)==2 and argv[0]=="bash"`, rejects flags/`..`/symlink-escape (`:117-205`),
and **fails closed only if the GLOBAL `referenced` set is empty** (`:198-200`) — i.e.
if NO invariant references ANY gate. An individual unreferenced gate does NOT error:
every gate in `gates{}` is planned and executed regardless of whether an invariant
references it (`:128` iterates all gates → `planned`; `:202` executes all of
`planned`). The exemplar gate script shape is
`scripts/check-app-mcp-cli-direct-writes.sh:1-8` (`set -euo pipefail`, `ROOT_DIR`
from `BASH_SOURCE`, `cd`, `rg`-on-PATH guard). `docs/invariants.md` currently holds
13 numbered invariants (`:5-95`) plus an "Unverified Anchors" section (`:96`);
each entry carries **Statement / Enforced by / Verified by / Gate** fields
(pattern at `docs/invariants.md:47-52`).

**CI release gate.** `.github/workflows/release.yml:13-16` triggers on `push` of
`v*` tags. `validate-release-tag` (`:26-35`) runs ONLY the SemVer regex on
`$GITHUB_REF_NAME` — **it does not assert any release-notes file** (correction of
the brief, which called the presence "asserted in the existing job"; it is the
target, not the current state). The build jobs at `:38` and `:94` declare `needs: validate-release-tag`, and
`release-bundle-gate` (`:121`) depends on it transitively via `release-tests`
(`needs: [release-tests, release-remote-server-tests]`), so `validate-release-tag`
fires before all build work and holds the tag name.
`release-bundle-gate` (`:149-190`) archives ad-hoc (`CODE_SIGN_IDENTITY="-"`),
exports by `ditto`, runs `release-verify.sh --adhoc`, and records that this "is not
a signed or notarized distribution approval" (`:183-190`). CI cannot produce a
notarized asset.

**Build/verify scripts.** `macos/scripts/build-release.sh:41-49` rejects a
placeholder `teamID` (`ExportOptions.plist` carries `J25GS8J4XM`, method
`developer-id` — the guard passes). `:52-88` single-sources MARKETING_VERSION from
`project.yml` and auto-derives the build number (`git rev-list --count` on a clean
tree, else UTC timestamp; rejects `0`/`1`). `:136-171` a Developer-ID export;
`--local-only` produces an explicitly non-distributable `Engram-local-only.app`.
`:194-227` PRINTS (does not run) the manual notarize/staple/`release-verify
--require-notarization`/deploy/create-dmg steps. `macos/scripts/release-verify.sh`:
hygiene (`:76-93`), structure (`:95-102`), version/expected-build/expected-short
(`:109-126`), Developer ID + Hardened Runtime + secure Timestamp (`:138-155`),
`--require-notarization` → `stapler validate` + `spctl --assess` (`:157-164`).

**TODO / roadmap drift (verified corrections).** `docs/TODO.md:9-10` and
`docs/roadmap.md:63` both say "current source/installed Engram `1.0.4`" — STALE:
`package.json:3` = `1.0.5` and `CHANGELOG.md:11-15` = installed `1.0.5 (1340)`.
`docs/roadmap.md:64-66` "no configured Actions secrets for Developer ID
signing/notarization" is TRUE for CI only; the local machine has a configured
Developer ID export (`ExportOptions.plist` teamID `J25GS8J4XM`). `docs/roadmap.md:87`
lists "a Claude Code plugin" as out of scope — STALE: it shipped in PR #240
(`CHANGELOG.md:35-67`; `integrations/claude-code/engram/` exists).

**Prior art (read-only, `as-main/`).** The Agent Sessions release-notes SKILL
states the Iron Rule verbatim ("A change earns a line only if it is observable as a
difference between the previous shipped release and this one") and "ship the
destination, not the journey"
(`as-main/.claude/skills/release-notes/SKILL.md`). Its Sparkle linter bans
internal wording and Bug-Fixes-before-headline ordering
(`as-main/tools/release/sparkle_release_notes.py:444-476`; banned set: `internal`,
`implementation`, `pre-release`, `validation fix(es)`, `cleanup`, `hardened`,
`hardening`).

## Proposed design

Three independently-landable parts. A reader implementing only one may ignore the
others; ordering between parts is only the Row-6-CTA / Row-0-publish sequencing
noted in each.

---

### Part A — Row 6 (UX-3): fix the public claim, then freeze it

The minimum that makes the public copy true, split by dependency.

**A1. Repo metadata (lands NOW — lies independent of any release).** This spec
STATES the exact strings; it does not run `gh repo edit`. The runbook (Part C)
carries the command, marked `[needs owner authorization]`.

- New description (≤ the GitHub 350-char limit, one sentence):
  `Native macOS app that unifies your AI coding sessions — Claude Code, Codex, Gemini, Cursor and more — into one local, searchable history, with a bundled MCP server so any assistant can pull past context.`
- Topics — remove `typescript`, `web-ui`, `raspberry-pi`; keep `ai-coding`,
  `local-first`, `macos`, `mcp`, `sqlite`; add `swift`, `developer-tools`,
  `claude-code`. Final set: `ai-coding, claude-code, developer-tools, local-first,
  macos, mcp, sqlite, swift`.
- `homepageUrl`: leave empty (no site exists; do not point at a placeholder).

**A2. README restructure (lands NOW except the CTA link target).** Replace the
`README.md:7-20` status memo with public-facing copy. The status-memo content
belongs in `docs/TODO.md`, not the README head. Exact new copy for `:7-20`:

```markdown
Engram reads the session logs your AI coding tools already write and turns them
into one local history you can search, revisit, and hand to the next assistant —
no cloud account, nothing leaves your Mac by default.

- **Download** — [Build from source](#从源码构建-build-from-source)  <!-- pre-publish state; Part C step 8 adds the `releases/latest` link when 1.0.5 is Latest -->
- **Register the MCP server** — [Claude Code](#claude-code) · [Codex](#codex) · [other MCP clients](#其他支持-mcp-的客户端)

### Why Engram is different

- **Cross-tool by default.** One index over Claude Code, Codex, Gemini, Cursor,
  Copilot and 12 more — not one vendor's history.
- **Local-first.** Everything lives in `~/.engram/index.sqlite`; remote AI
  summaries, embeddings, and archive offload are all opt-in.
- **Built for the next assistant.** A bundled Swift MCP server exposes
  `get_context`, `search`, and project-migration tools so any MCP client picks up
  where the last one stopped.
```

- The **`releases/latest` Download link is the only piece gated on publish.** Until
  1.0.5 is the Latest release, `releases/latest` resolves to `v1.0.3` (pre-plugin), so
  the block above is authored in its PRE-PUBLISH state — the Download line points only at
  `#从源码构建-build-from-source`. Paste it verbatim; do NOT add the `releases/latest`
  link now. Part C step 8 adds that link when 1.0.5 publishes. The "Why Engram is
  different" block and the status-memo deletion land NOW.
- Demote `README.md:97-117` 快速上手 heading to "从源码构建 (Build from source)"; no content
  change beyond the heading and the deleted sentence (A3). **GitHub regenerates the anchor
  from the new heading text as `#从源码构建-build-from-source`, so this same change MUST also
  repoint every `#快速上手` reference to it — the TOC entry at `README.md:45`
  (`- [快速上手](#快速上手)` → `- [从源码构建](#从源码构建-build-from-source)`) and the A2
  Download link above. Leaving any `#快速上手` reference ships a dead link — the exact
  Row-6 failure this Part exists to fix.**

**A3. Delete the false sentence (lands NOW).** Remove `README.md:117` entirely
(`首次启动 … 之后通过文件监听增量更新，无需手动维护。`). If any replacement is
kept, it must be honest: `首次启动 Engram.app 时，EngramService 会自动扫描所有会话
文件并建立索引（~/.engram/index.sqlite），之后每隔 15–60 分钟自动增量扫描更新。`

**A4. `scripts/check-public-copy.sh` (lands NOW) + registry.** A fail-closed gate
in the `check-app-mcp-cli-direct-writes.sh` shape (`set -euo pipefail`, `rg`-on-PATH
guard, prints an OK line, exits 1 with the offending line on any hit) — but its scan
root MUST be OVERRIDABLE so the Vitest fixtures can inject a temp tree:
`ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"; cd "$ROOT_DIR"`.
The exemplar's UNCONDITIONAL `ROOT_DIR="$(…)"; cd "$ROOT_DIR"`
(`check-app-mcp-cli-direct-writes.sh:4-5`) cannot be overridden by an env var — do not
copy it verbatim or the Test-plan fixtures (which point `ROOT_DIR` at a temp dir) are
unrunnable. Three checks:

1. **Bilingual denylist over `README.md`** (seed, extendable): forbid `文件监听`
   and `file[ -]?watch` (matches `file watch`, `file-watch`, `file watching`,
   `file-watching`). Any match → exit 1 printing the line. The README is bilingual
   so both forms are required.
2. **Tool-count consistency (derived, never hardcoded).** Read `N` from
   `docs/mcp-tools.md` (`grep -oE 'Total tools: [0-9]+'`), then assert `README.md`
   contains `暴露 N 个工具`. Mismatch → exit 1. This fails closed when the
   concurrent adapter/tool work moves the count.
3. **Source-count consistency (derived).** Count leading-dot rows with
   `grep -cE '^[[:space:]]*\.init\(source:' SourceCatalog.swift` (→ 17). The leading
   dot is load-bearing: it excludes the `init(source:` DEFINITION at
   `SourceCatalog.swift:50`, which an unanchored `grep -c 'init(source:'` wrongly
   counts (yielding 18 → active 15 → the gate self-fails on a CORRECT tree). Count
   archived members from `ArchivedDefaultOffSources.orderedIDs` in
   `macos/Shared/Service/ArchivedDefaultOffSources.swift:6` (→ 3, NOT from the
   `.contains` call site in `SourceCatalog.swift`). Compute active = total − archived
   (→ 14) and assert `README.md:3` still reads
   `14 个默认启用来源 + 3 个归档默认关闭来源`. Mismatch → exit 1.

Register as an argv gate in `scripts/invariant-gates.json`:
`"public-copy": {"type":"argv","argv":["bash","scripts/check-public-copy.sh"]}`.
Reference `public-copy` from an invariant to keep the registry coherent and document
intent — NOT because an unreferenced gate errors (it does not; the checker fails closed
only when the ENTIRE `referenced` set is empty, `check-invariants-ledger.sh:198-200`, and
still runs every registered gate). The gate is referenced by invariant `15` below.
Add a new invariant **15** to `docs/invariants.md` (append-only, lowest collision
with the concurrent `docs/invariants.md` edits) and reference `public-copy` from
invariant `15` in the `invariants{}` map. **Number 15 is assigned by the
integration pass, 2026-07-24 (authoritative):** three follow-up specs each append
a ledger entry — **14** = `docs/insight-supersede-filter-design-2026-07.md`
(row 1, accepted, sequenced first), **15** = this spec, **16** =
`docs/build-provenance-perf-design-2026-07.md` (Release Bundle Provenance). The
numbers are sequential, not semantic; if the landing order changes, keep 14 on
row 1 and re-sequence 15/16 so the appended entries stay contiguous. New ledger
entry:

```markdown
## 15. Public Copy Matches Shipped Reality

- **Statement** - Public-facing copy (README, repo description) never claims a
  deleted architecture (file watching, TypeScript/Web/Pi runtime) and its tool and
  source counts agree with `docs/mcp-tools.md` and `SourceCatalog.swift`.
- **Enforced by** - `scripts/check-public-copy.sh`.
- **Verified by** - `tests/scripts/check-public-copy.test.ts`.
- **Gate** - `public-copy` (`scripts/invariant-gates.json`).
```

**Acceptance criteria (A)**
- `gh repo view --json description,repositoryTopics` shows the A1 strings and no
  `typescript`/`web-ui`/`raspberry-pi` topic — *after the owner runs the runbook
  command*; the spec's own acceptance is only that the strings are stated verbatim.
- `README.md` contains no `文件监听` and no `file watch` variant; `rg '文件监听|file[
  -]?watch' README.md` returns nothing.
- `README.md:7-20` no longer contains "Current product state"; it contains the
  positioning sentence and "Why Engram is different".
- `bash scripts/check-public-copy.sh` exits 0 on the fixed tree; flipping
  `docs/mcp-tools.md` to `Total tools: 28` (without touching README) makes it exit 1.
- `bash scripts/check-invariants-ledger.sh` passes with invariant 15 present and
  the `public-copy` gate referenced.

---

### Part B — Row 18 (UX-10): release notes as a human artifact

**B1. New artifact class.** Create `docs/release-notes/` and author
`docs/release-notes/1.0.5.md` (drafted below). Format: 10-30 lines, second person,
Highlights before Bug Fixes. It becomes the GitHub Release body (Part C step 8).
It is authored to the delta over `v1.0.3` — the last PUBLIC release, NOT `v1.0.4`
(tagged, never released) — so per the Iron Rule it curates everything user-visible
across `[Unreleased]` (`CHANGELOG.md:8-793`) and `[1.0.4]` (`CHANGELOG.md:794-5109`; the next heading `[1.0.3]` begins at
`:5110`),
and drops every intra-cycle fix a `v1.0.3` user never received.

**B2. CI presence gate (correction of the brief — this must be ADDED).** Add a step
to `validate-release-tag` in `.github/workflows/release.yml` (it already holds
`$GITHUB_REF_NAME` and runs before build via `needs`):

```yaml
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7
      - name: Require a user-facing release note for this tag
        run: |
          note="docs/release-notes/${GITHUB_REF_NAME#v}.md"
          test -s "$note" || {
            echo "Missing/empty release note $note for tag $GITHUB_REF_NAME" >&2
            exit 1
          }
```

This is NOT the invariants ledger: the ledger gate is path-existence-only and
tag-unaware (`check-invariants-ledger.sh` ledger-paths pass), so a per-version note
that only needs to exist at tag time cannot be a ledger anchor. It lives in the
tag-aware CI job.

**B3. Adapted style rules (not a ported skill).** House the Agent Sessions Iron
Rule and banned-word lint in a sibling `docs/release-notes/README.md` (chosen over an
in-note comment block so each per-version note stays prose-only and the rules live in one
place). **Done-when: `docs/release-notes/README.md` exists and states** that
the note curates the *delta from the last shipped release*, drops intra-cycle fixes,
and must not contain `internal`, `implementation`, `pre-release`, `validation fix`,
`cleanup`, `hardened`, `hardening`, nor place Bug Fixes before Highlights. Optional
enforcement: a lint step in `validate-release-tag` grepping the banned set over the
note (adapt, do not port `sparkle_release_notes.py`). Minimum viable is the presence
gate B2; the lint is a stated follow-up so the first note is authored clean rather
than mechanically checked.

**The 1.0.5 release note (authored artifact, `docs/release-notes/1.0.5.md`):**

```markdown
# Engram 1.0.5

The last public build was 1.0.3. Here is what is new when you update.

## Highlights

- **Claude Code plugin.** Register Engram as a Claude Code plugin and every new
  session starts with your recent project context already injected — plus
  catch-up, remember, and handoff skills you can invoke by name.
- **Semantic and hybrid search over your history.** When you configure an
  embedding provider, `search` and `get_memory` add meaning-based and blended
  ranking on top of keyword search; without one, keyword search works exactly as
  before.
- **Move a project without losing its history.** A full project-migration
  toolset — move, archive, undo, and batch — rewrites session paths when a folder
  moves on disk, with a dry-run preview before anything changes.
- **Filter memory by type.** `get_memory` now takes a type filter so you can pull
  back just decisions, lessons, or facts.
- **Cleaner desktop app.** A simplified Today workbench and menu-bar popover, plus
  reduced-motion support that honors your system setting.

## Also new

- Three rarely-used sources (Cline, iflow, Lobster AI) are now off by default and
  can be turned on under Sources › Archived.
- Engram keeps periodic backups of your own data (insights, favorites, aliases,
  hidden and renamed sessions) under `~/.engram/backups/`.
- Export a diagnostic bundle from the app when you need to report an issue.

## Bug fixes

- Search from an MCP client now returns the same results the app does, including
  exact project scoping and Chinese-language queries.
- Project moves preview accurately before they run and no longer mishandle folder
  basenames.
```

*(All draft lines describe a user-visible delta over 1.0.3 and avoid the banned
internal wording. The dozens of `CHANGELOG.md` audit/security/perf-integration
"Fixed:" entries — e.g. `:308,:315,:325,:335,:359` — are intentionally dropped:
none shipped to a 1.0.3 user as a regression.)*

**Acceptance criteria (B)**
- `docs/release-notes/1.0.5.md` exists, is non-empty, second person, Highlights
  precede Bug Fixes.
- `grep -Eiw 'internal|implementation|pre-release|cleanup|hardened|hardening'
  docs/release-notes/1.0.5.md` and `grep -i 'validation fix'` both return nothing.
- Simulating `validate-release-tag` with `GITHUB_REF_NAME=v1.0.5` passes the B2
  step; with `GITHUB_REF_NAME=v9.9.9` (no note) it exits 1.

---

### Part C — Row 0: stage the publish decision, do not make it

The spec performs NO state change. This part is the runbook text and the decision
memo. Each remote/repo-mutating step is marked `[needs owner authorization]`.

**Prerequisites already satisfied (verify, do not perform).**
- Version metadata aligned at 1.0.5 (`package.json:3`, `project.yml` MARKETING_VERSION).
- `ExportOptions.plist` has a real team (`J25GS8J4XM`, `developer-id`) — the
  `build-release.sh:41-49` guard passes; no edit needed.
- A Developer-ID-signed `1.0.5 (1340)` is installed locally (`CHANGELOG.md:11-15`).

**Publish 1.0.5 runbook (ordered).**

1. Confirm a green `main` at the intended release commit and a clean tree
   (`/usr/bin/git status`). No auth needed.
2. `bash scripts/check-public-copy.sh` and `bash scripts/check-invariants-ledger.sh`
   pass; `docs/release-notes/1.0.5.md` exists. No auth needed.
3. Build a distributable artifact: `macos/scripts/build-release.sh` **with NO
   flag** (a Developer-ID export; `--local-only` is verification-only and must NOT
   be the publish artifact). Uses `ExportOptions.plist`. **Local, no remote state.**
4. Notarize + staple (the steps `build-release.sh:194-227` prints, run manually):
   `ditto -c -k --keepParent … Engram.zip`; `xcrun notarytool submit Engram.zip
   --keychain-profile engram-notary --wait`; `xcrun stapler staple …Engram.app`.
   **[needs owner authorization]** (Apple account submission).
5. Final verify: `macos/scripts/release-verify.sh <app> --require-notarization
   --expected-build 1340 --expected-short-version 1.0.5` — asserts the exact
   1.0.5/1340 identity plus stapled ticket and Gatekeeper assess (`release-verify.sh:109-164`).
   Local. (Note the build-number question in Risks — a fresh clean-tree build
   would number differently from 1340.)
6. Package the asset (owner format choice: notarized `Engram.zip` or a
   `create-dmg` `.dmg`; `build-release.sh:202-226` prints both). Local.
7. `/usr/bin/git tag v1.0.5 <commit> && /usr/bin/git push origin v1.0.5`.
   **[needs owner authorization]** — pushing a `v*` tag itself triggers the Release
   Gate CI (`release.yml:13-16`); a green tag-gated run is packaging hygiene only,
   NOT a signed/notarized distribution approval (`release.yml:183-190`).
8. `gh release create v1.0.5 --notes-file docs/release-notes/1.0.5.md <asset>`;
   then land the README Download-CTA un-gate (Part A2) — swap the A2 Download line to
   `- **Download** — [latest release](https://github.com/bbingz/engram/releases/latest) · [Build from source](#从源码构建-build-from-source)`
   (the build-from-source anchor stays post-rename). **[needs owner authorization]**.
9. Repo metadata (may run any time; independent of the release):
   `gh repo edit --description "<A1 string>"` and topic add/remove per A1.
   **[needs owner authorization]** — the spec states the strings; it does not run this.

**Decision memo.**

- **Saying YES unblocks:** the honest public build reaches new visitors (not just
  re-downloaders); the README Download CTA becomes truthful; mirror rows 33/34/35
  and the UX-5 value flip that presume a current public baseline become actionable.
- **Saying NO costs:** every Part A/B honesty fix still lands (they do not depend
  on publish), but a stranger who clicks Download still gets pre-plugin `v1.0.3`;
  the CTA line stays gated; the 1.0.5 build stays installed-only.
- **Smallest reversible first step:** land Parts A (metadata + README + gate) and B
  (note + CI gate) now — all reversible, none touching the release channel — which
  makes the eventual publish a single owner-run pass of steps 3-9. Publishing is the
  only irreversible act and stays entirely owner-gated.
- **Loose end:** `v1.0.4` is a tag on origin with no Release; the runbook goes
  straight to `v1.0.5` and does not reuse or re-push `v1.0.4`.

**Acceptance criteria (C)**
- The runbook exists with every notarize/tag/release/metadata step marked
  `[needs owner authorization]`; no step in the spec's own execution changed remote
  or repo state.
- The decision memo states YES-unblocks, NO-costs, and the smallest reversible step.

## Invariants affected

- **New invariant 15 (Public Copy Matches Shipped Reality)** — introduced by Part A,
  added to `docs/invariants.md` and `scripts/invariant-gates.json` in the same
  change (per the ledger's same-PR rule). Number 15 is the integration pass's
  authoritative assignment (14 = row 1 insight-supersede, 15 = this spec, 16 =
  build-provenance — see Part A4). It composes with the concurrent
  `docs/invariants.md` edits by appending a new numbered section rather than
  editing existing ones; the `invariants{}` map gains a `"15": ["public-copy"]`
  entry.
- **Invariant 7 (Bundle Hygiene)** — untouched; Part C only *references*
  `release-verify.sh`'s existing hygiene checks, adds no bundle behavior.
- No other ledger invariant is touched. Parts B and C add no invariant (the
  release-note presence is a tag-aware CI gate, deliberately not a ledger anchor).

## Alternatives considered

- **Hardcode 27/17/14/3 in `check-public-copy.sh`.** Rejected: the concurrent
  adapter/tool work moves these numbers; a hardcoded gate passes while README
  drifts — the exact rot it exists to prevent. Counts are derived at check time.
- **Put the release-note presence check in the invariants ledger.** Rejected: the
  ledger gate is path-existence-only and tag-unaware; a per-version note that must
  exist only at tag time has no stable ledger anchor. It belongs in
  `validate-release-tag`.
- **Attach `public-copy` to an existing invariant (e.g. 7 Bundle Hygiene) instead
  of a new 15.** Rejected: public-copy honesty is thematically distinct from bundle
  artifacts; overloading 7 muddies both. A new appended entry is also lower-collision
  with the concurrent `docs/invariants.md` edits.
- **Point the README CTA at a pinned `/releases/tag/v1.0.5`.** Rejected in favor of
  `/releases/latest` un-gated at publish time — pinning rots if a later patch ships,
  and the CTA is meaningless before any 1.0.5 release exists anyway.
- **Let the spec run `gh repo edit` / push the tag.** Rejected: `docs/TODO.md:31-33`
  and `docs/roadmap.md:82-85` withhold this authorization; the spec stages text only.
- **Port the Agent Sessions release-notes skill and Sparkle linter.** Rejected:
  Engram has no Sparkle/Homebrew channel (`roadmap.md:87`); only the GitHub Release
  body is in play. Adapt the Iron Rule and banned-word set into one Engram doc.

## Test plan

- **`tests/scripts/check-public-copy.test.ts`** (new, Vitest — `scripts/` dev
  tooling is TypeScript per `CLAUDE.md`). Cases:
  - `passes on the fixed README (repro)` — a fixture README with honest copy and
    matching counts exits 0. Names the PR/row in a comment.
  - `fails on a file-watch claim (repro)` — inject `文件监听` → exit 1; inject
    `file-watching` → exit 1.
  - `fails on tool-count drift (repro)` — fixture `mcp-tools.md` says `Total tools:
    28` while README says 27 → exit 1.
  - `fails on source-count drift (repro)` — fixture `SourceCatalog.swift` with 18
    rows while README says 14+3 → exit 1.
  - Use a temp-dir seed helper that writes minimal `README.md`, `docs/mcp-tools.md`,
    and `SourceCatalog.swift` and runs the script with `ROOT_DIR` pointed at it
    (mirror the existing `tests/scripts/build-release-script.test.ts` harness style).
- **`.github/workflows` — B2 step** is validated by a shell repro in the same test
  file: `release-note presence gate fails without a note (repro)` runs the B2
  `test -s` snippet with `GITHUB_REF_NAME=v9.9.9` (fail) and `=v1.0.5` (pass).
- **`tests/scripts/ci-workflow.test.ts`** must still pass (or be updated) after the B2
  edit mutates `validate-release-tag`: that suite slices `release.yml` job blocks by
  marker and would otherwise flag the added checkout/step as a structural regression
  only at CI time.
- **`check-invariants-ledger.sh`** — existing gate run proves invariant 15 + the
  `public-copy` gate registration are schema-valid and referenced (no new test; the
  existing checker is the guard).
- **Not tested:** the actual `gh repo edit` / `gh release create` / tag push
  (state-changing, owner-gated, out of the spec's scope); the release-note prose
  content (reviewed by the Iron Rule, not machine-asserted beyond the banned-word
  grep in Acceptance B).

## Rollout

- **Parts A2/A3/A4 and B** land NOW on a normal PR; no version bump, no migration,
  no release dependency. The `check-public-copy` gate begins enforcing on that PR.
- **Part A1 (metadata) and A2's Download CTA** are owner actions: A1 any time
  (independent of release), the CTA only at publish.
- **Part C** is text; it takes effect only when the owner runs the runbook.
- **Revert story:** Parts A/B are pure doc/script/CI additions — revert the PR to
  restore prior copy; the new gate and ledger entry disappear with it. No runtime,
  schema, or bundle behavior changes, so there is nothing to migrate back.

## Risks and open questions

- **Citation baseline mismatch (medium).** The brief named `23dca547`/clean; this
  tree is `382693db`/dirty on `feat/adapter-format-drift`. Every anchor above is
  at `382693db`. An implementer on a different commit must re-anchor, especially
  `docs/invariants.md` and `README.md` line numbers.
- **Concurrent `docs/invariants.md` edits (medium).** The source-health-predicate
  spec (row 2) amends entry 3, codex-native (row 22) amends 2/3/9/10, and two other
  follow-up specs also *append* new entries — row 1 appends 14 and build-provenance
  appends 16. Adding invariant 15 as an appended section minimizes but does not
  eliminate a merge conflict in the `invariants{}` map and the numbered-section
  tail. The integration pass fixed the append numbers (14/15/16); land row 1's 14
  before this 15 before build-provenance's 16 so they stay contiguous, or
  re-sequence per the Part A4 note.
- **Count derivation vs. concurrent adapter work (medium).** If the adapter-format-
  drift branch changes the tool or source count, `check-public-copy.sh` will fail
  closed until README is updated to match — intended, but the two PRs must land the
  README bump together or CI blocks.
- **Build-number identity (open question).** The installed build is `1340`, but
  `build-release.sh` derives the number from `git rev-list --count` on a clean tree,
  which will differ. **Open:** does the owner tag the existing `1340` bundle, or cut
  a fresh CI-numbered build and re-verify? The runbook's `--expected-build 1340`
  assumes the former.
- **Asset format (open question).** `gh release create` uploads a notarized
  `Engram.zip` or a `create-dmg` `.dmg` — an owner/format choice not fixed in code.
- **Green tag-CI mistaken for distribution approval (low, but sharp).** Pushing
  `v1.0.5` triggers CI that ad-hoc-verifies packaging only; the notarized asset is
  built and uploaded manually. The runbook states this explicitly at step 7.
- **homepageUrl (open question).** Left empty here; if the owner wants it populated,
  the target (repo README vs. a future landing page) is undecided.
- **Release-note lint mechanism (open question).** B3 offers a CI grep as a
  follow-up; whether the owner wants it as a CI step, a pre-commit hook, or nothing
  beyond the authored-clean first note is unresolved. Minimum viable ships without it.
```
