# Today Workbench + Advanced Noise Reduction

Date: 2026-06-01
Status: approved direction, ready for implementation planning

## Goal

Engram should open into a calm workbench for resuming real work, not an
engineering console of every indexed session. The first screen should answer:

- What was I doing today?
- What is safe to resume?
- Which sessions need follow-up?
- Where did important work land?

Advanced and diagnostic controls should remain available, but they should not
dominate the default experience.

## Product Principles

- Default to decision support. The main view should surface the few sessions,
  repos, and follow-ups most likely to matter today.
- Keep power. Existing search, filters, raw transcript views, and maintenance
  tools stay reachable under Advanced or diagnostics surfaces.
- Preserve trust. Do not hide security-critical or integrity-critical state;
  show service health, indexing gaps, and failed writes where they affect resume
  confidence.
- Reduce vocabulary drift. Use one visible predicate for "human transcript":
  non-empty user/assistant content by default, with diagnostics available
  explicitly.

## Required Hardening Before UI Expansion

These are prerequisites because Today Workbench will increase reliance on Resume
and project/session write surfaces:

- Resume command construction must shell-quote `cwd`, command, and args before
  AppleScript interpolation.
- `project_move`, `project_archive`, `project_undo`, and `project_move_batch`
  must require the Swift service single-writer pipeline and fail closed when the
  service is unavailable.
- The Copilot hardening review is tracked in
  `docs/reviews/2026-06-01-copilot-product-hardening-review.md`.

## Default Experience

### Today

Primary screen sections:

- Continue: resumable sessions ranked by recency, repo activity, and clean
  command availability.
- Follow-ups: sessions with unresolved follow-up markers, deferred items, or
  review outputs that need human action.
- Changed Repos: repositories touched recently, with last activity, open
  transcript count, and migration/alias warnings.
- Service State: compact status for service running, index freshness, and write
  pipeline availability.

Each row should support:

- Open transcript.
- Resume when command metadata is complete and safe.
- Copy command.
- Mark follow-up as handled when a durable marker exists.

### Search

Search remains a first-class tab, but it should feel like retrieval, not the app
home. Advanced filters should collapse behind a single disclosure control.

### Advanced

Move low-level controls into Advanced:

- adapter/source toggles;
- raw role/message-type visibility;
- indexing and maintenance controls;
- MCP/network diagnostics;
- migration history and recovery tools;
- transcript diagnostics including system/tool/agent communication messages.

## Noise Rules

Default transcript and Today surfaces should use the same visible-message rule:

- include non-empty `user` and `assistant` content;
- exclude `tool`, blank, `systemPrompt`, and `agentComm` messages;
- expose excluded content only through Advanced diagnostics or an explicit
  transcript toggle.

Pagination must be based on adapter consumption position, not the count of
visible messages after filtering, so hidden messages cannot cause missing or
duplicated visible pages.

## Acceptance Criteria

- Launching the app lands on Today Workbench.
- A user can resume a recent safe session without seeing raw filters first.
- Advanced settings are reachable but visually quieter than Today/Search.
- Follow-up and deferred items have an obvious home in Today.
- Resume shell command construction has malicious-character tests.
- Project migration mutators cannot direct-write when the Swift service is down.
- The remaining Copilot Important items are represented as follow-up tasks, not
  lost in chat.

## Non-Goals For First Pass

- Redesigning every transcript cell.
- Removing all Advanced functionality.
- Solving cloud sync or multi-device history.
- Changing the database schema solely for layout preferences.
