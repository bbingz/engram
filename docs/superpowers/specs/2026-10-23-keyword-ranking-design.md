# Human keyword ranking consistency

Status: implemented and verified locally, 2026-10-23; not pushed/deployed.

## Baseline and scope

Lifecycle 3.4's blanket missing-BM25/CJK/facet description is stale. Service
keyword search already uses FTS5 rank, best row per session/token, session-level
AND matching and windowed highlights. SearchPage has source/project/time/origin
filters and calls Service with keyword mode; on failure it uses DatabaseManager
searchWithSnippets. Both readers rank only by the first token. The App also routes
all CJK terms through zero-rank LIKE, unlike Service's scalar-count trigram path.

This batch corrects these two ranking inconsistencies. No schema, index rebuild,
embedding dependency, scoring preference, UI layout or new facet is introduced.
Value/lifecycle facets and title/quality/recency weighting need separate contracts.
The native MCP's separate ranking policy is outside this human-search change.

## Acceptance contract

- Every searchable term must still occur somewhere within a session; matching
  terms in separate messages remains valid. Existing tier/visibility/scope and
  source/project/date/origin filters apply before the result limit.
- Rank sessions by the sum of each term's existing best-row FTS5 rank. Short
  terms keep zero-rank LIKE matching; placing a short term first must not discard
  the relevance contribution of later long terms. Sum in canonical token order
  so input permutation cannot change floating-point addition order. Preserve
  query order for snippets. Repeated terms retain their existing query semantics.
- Ties sort by start_time descending, then session ID ascending. Apply the same
  order before LIMIT and in Service's final snippet projection.
- App search and searchWithSnippets use the same scalar-count MATCH/LIKE routing
  as Service: three or more Unicode scalars use trigram MATCH, shorter searchable
  terms use LIKE. Verify Chinese, Japanese and Korean matching/highlighting.
- Keep Service's bounded short-token candidates and optimized identity-indexed
  FTS plan. This does not promise exhaustive recall beyond the existing cap or
  full App/Service parity when that cap excludes old short-token matches.
- Compare real Service and both App queries over one temporary database. Capture
  RED for Latin multi-term relevance, short-first mixed queries and CJK fallback;
  then verify rank-before-limit, permutations, cross-message conjunction, ties,
  filters, snippets, both Service FTS layouts and existing syntax/semantic tests.

## Failure handling and residuals

Failed tests leave the batch open. Use isolated temporary databases/fixed homes;
no production index, service restart or host mutation. Local tests do not prove
HQ-corpus latency or subjective relevance quality. Record actual acceptance in
the roadmap/reconciliation and CHANGELOG/MEMO; larger lifecycle 3.4 remains open.

## Local verification receipt

The first test build caught a missing await in the new fixture setup; corrected
before behavioral RED. Three new App/Service shared-fixture tests then produced
72 expected ordering failures. After the minimal two-reader fix, 163 App data/search
tests and 63 Service search/semantic/insight/Web admission tests passed, zero failures.
They cover six permutations of three terms, relevance before LIMIT, cross-message
AND, ties, mixed short/long Latin/Chinese/Japanese/Korean queries, highlights,
identity-indexed/fallback layouts, visibility/origin/date/tool filters and busy/
semantic fallback. The query-plan regression retains FTS-driven execution.
Lint (one pre-existing warning, 40 infos) and invariant/module/convention gates passed.
Logs, xcresults and exact Service selectors: `/tmp/engram-leader-keyword-ranking-20261023/`.
No full all-target, rendered UI, hosted CI, production-corpus latency or host rollout
acceptance. No new Swift source files or project generation were needed.
