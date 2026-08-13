# Documentation archive

This directory preserves superseded plans, reviews, scripts, and implementation
notes that still provide useful project history. It is an evidence store, not a
current work queue.

## Index

- [plans/](plans/): superseded implementation and migration plans.
- [reviews/](reviews/): older review reports and remediation evidence.
- [scripts/](scripts/): retired operational and verification scripts.
- [superpowers/](superpowers/): historical plans, reports, and specifications
  produced by structured engineering workflows.
- Top-level Markdown files: legacy project notes that predate the current
  directory layout.

Use `rg '<term>' docs/archive` when looking for a specific historical decision;
the archive is intentionally indexed by directory rather than by an exhaustive
file list.

## Authority

Archived claims describe the repository at a point in time and must be checked
against current source and tests before reuse. Current work is routed only
through `docs/roadmap.md`, `docs/TODO.md`, and `docs/followups.md`, as defined in
[the contribution guide](../CONTRIBUTING.md#backlog-规范).

## Retention

- **No automatic age-based deletion.** Preserve unique evidence and decision
  history by default, regardless of age.
- Move material here when its work is closed or a newer authority supersedes it.
  Record or link the successor when one exists.
- Prefer moving a historical artifact intact over rewriting it to appear current.
- Remove an artifact only through a reviewed change after checking live
  references. Appropriate reasons include an exact/generated duplicate,
  sensitive content, corruption, or confirmation that it contains no unique
  evidence.
