# GitHub README Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the public GitHub presentation without touching runtime code.

**Architecture:** Documentation-only change. `README.md` becomes the English public entry point, `README.zh-CN.md` mirrors it in Chinese, and GitHub metadata files provide license and issue intake polish.

**Tech Stack:** Markdown, GitHub Mermaid rendering, GitHub issue form YAML.

---

### Task 1: Public README

**Files:**
- Modify: `README.md`

- [ ] Replace the long Chinese-first README with an English landing page.
- [ ] Include badges for release, CI, license, Node version, and macOS target.
- [ ] Include Mermaid diagrams for ingest flow and runtime architecture.
- [ ] Keep quick start commands for release users and source users.
- [ ] Link to `README.zh-CN.md`, `docs/PRIVACY.md`, `docs/SECURITY.md`, `CONTRIBUTING.md`, and `docs/mcp-tools.md`.

### Task 2: Chinese README

**Files:**
- Create: `README.zh-CN.md`

- [ ] Add a Chinese mirror with the same sections as the English README.
- [ ] Keep phrasing native and concise.
- [ ] Mention privacy, supported sources, install paths, and development commands.

### Task 3: GitHub polish files

**Files:**
- Create: `LICENSE`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Modify: `CHANGELOG.md`

- [ ] Add MIT license text with `bbingz` as copyright holder.
- [ ] Add concise issue forms for bug reports and feature requests.
- [ ] Add an Unreleased changelog entry for the docs refresh.

### Task 4: Verification and publish

**Files:**
- No file edits.

- [ ] Run `npm run lint`.
- [ ] Confirm `.memory/` is ignored and not staged.
- [ ] Commit and push the documentation refresh.
