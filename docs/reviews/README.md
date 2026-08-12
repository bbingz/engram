# Review evidence index

This directory contains dated audits, review reports, adjudications, and
closeouts. Each artifact is evidence for the revision it examined; its findings
are not automatically current backlog items.

## Index

Current routing and disposition entry points:

- [stewardship queue](2026-08-12-stewardship-queue.md): ranked routing for the
  current remediation stream.
- [follow-ups](../followups.md): canonical observations and deferred work.
- [TODO](../TODO.md): canonical confirmed engineering tasks.
- [roadmap](../roadmap.md): canonical product and cross-module direction.
- [archive discovery design scope](2026-08-12-archive-discovery-001-design-scope.md):
  bounded design record for the deferred archive discovery redesign.
- [July finding disposition](2026-07-17-finding-disposition.md) and
  [accepted residuals](2026-07-17-accepted-residuals.md): point-in-time
  dispositions for the July audit set.

Review filenames normally begin with their review date. Use
`rg '<finding-id-or-symbol>' docs/reviews docs/archive/reviews` to locate a
finding and its older evidence without relying on a static, exhaustive file
list.

## Authority

A review finding becomes active work only when it is promoted to
`docs/roadmap.md`, `docs/TODO.md`, or `docs/followups.md`. Before citing a review
as current fact, verify its file-and-line evidence against the current revision.

## Retention

- **No automatic age-based deletion.** Retain source reports together with
  related adjudication and closeout evidence by default.
- Keep a review here while it is referenced by current routing or design work.
  Move inactive historical reviews intact to [the review archive](../archive/reviews/)
  instead of deleting them solely because they are old.
- Remove an exact/generated duplicate, sensitive artifact, or corrupt file only
  through a reviewed change after checking live references and preserving any
  unique evidence in its successor.
