# Web interface layout and localization

## Scope

The native `EngramRemoteServer` Web UI shares a 1600px maximum shell across
Sessions, Search, Insights, Dashboard, Stats, Health, Machines, Settings and
session detail. `--page-width` and `--page-gutter` also align the top navigation.
Dialog/readable-card widths and independently scrolling tables remain bounded;
1600px is a maximum, not a minimum viewport requirement.

The command palette entry lives in the header tools beside the language selector.
On small screens it becomes an accessible search-icon button; navigation scrolls
within its own row. Cmd/Ctrl+K retains the existing keyboard and IME protections.
The palette searches pages, current-session actions and **loaded** session titles,
not the entire library. Page/action commands match both English and Chinese;
loaded titles are never translated. Use Search for full-library searches.

## Locale contract

- Simplified Chinese (`zh-CN`) is the default, even if the browser uses English.
  English (`en`) is available from the header, including while signed out.
- The browser stores only the selection in `engram.web.locale`. No server setting,
  API payload, credential, session content or draft is stored for localization.
  An invalid or unreadable preference falls back to Simplified Chinese.
- Switching languages explicitly confirms a page reload, warning that unsaved
  inputs will be lost. Cancelling leaves drafts intact. Pending authentication or
  application writes block switching. A failed storage write shows a localized
  error and does not reload or pretend the preference was saved.
- Reload preserves the current URL/bookmark and existing authentication lifecycle.
  Language does not change API route/filter identifiers, server timezone buckets,
  source-admission rules or authorization.
- Dates and numeric display use the selected locale. PIDs, revisions, IDs and
  technical protocol identifiers retain their identifier representation.

## Implementation and maintenance

`macos/EngramRemoteServer/Core/WebUILocalization.swift` contains the bundled
Chinese catalog and small `t(key, values)` helper. English message keys provide
fallback text. Whole-message templates accept numbered or named placeholders;
values are substituted once and are never recursively translated or parsed as HTML.
`WebUIRoutes.mount` serves this script before the application in the **same**
external `/web/app.js` asset. There are no runtime packages, translation requests,
inline scripts, CSP relaxations or new public routes.

Static markup ships Chinese text and `lang="zh-CN"`. Explicit `data-i18n`,
`data-i18n-title`, `data-i18n-placeholder` and `data-i18n-aria-label` bindings support
the saved English preference before application startup. Mixed labels use child
spans so localization does not replace inputs, icons or event targets.
Dynamic interface copy opts into `t`; `setText` deliberately stays a raw text sink.
Never add global text replacement or send conversation bodies, titles, project
paths, insights, tool input/output, or arbitrary server diagnostics through translation.
Known typed status enums can be localized at their display boundary; unknown
technical values remain verbatim. Keep command dispatch IDs and focus keys stable.

When adding copy:

1. Add its English key and Simplified Chinese translation; preserve placeholder
   multisets and metric semantics (files, generations, replica tasks and sessions
   are distinct; unknown or stale is not healthy zero).
2. Mark only the interface node/attribute or explicitly call `t` at its producer.
   Keep user-provided values as interpolation arguments or raw DOM text.
3. Run `npx vitest run tests/scripts/collector-web-ui.test.ts`,
   `npm run typecheck:test`, and native `WebUIRoutesTests`. The tests check catalog
   completeness/slots, default/fallback/storage behavior, write guards, bilingual
   command matching, privacy fences and raw user text.
4. Check rendered Chinese and English desktop/mobile layouts, both themes,
   keyboard navigation, language reload/cancellation and contained scrolling.

The JS payload gate is 400,000 UTF-8 bytes including the catalog (catalog alone
must stay below 100,000); CSS remains bounded at 80,000. New Swift files are picked
up from the existing `project.yml` source directory; regenerate with the project's
pinned XcodeGen, never hand-edit the generated project.

This document describes the implementation, not proof of deployment. The dated
`CHANGELOG.md` entry records validation and rollout status. HQ deployment must still
respect the compatible-line rule while the migration prerequisite is unresolved.

## HQ rollout — 2026-11-11

- PR #515 merged as `d8b7b17f` after 15 successful CI checks and two conditional
  skips (the first CodeQL run flagged double unescaping in a test helper; fixed
  with a single-pass decoder and regression). HQ uses compatible deploy commit
  `909aef7b` (descendant of `081426da`), not a main build. It also localizes the
  deployed AI endpoint-conflict (409) guard that exists only on that line.
- Compatible gates: RemoteServerCore 551/551, UI/exporter 407/407, typecheck,
  project drift, Release arm64 packaging and strict/deep signatures. Package
  `remote-server-web-i18n-909aef7b-20261111`, SHA-256
  `3e3c0c7c0722bfa9cfe34c64b50529225910b11333cfb1aa6efce5fe6cee674d`.
- Receiver-only cutover: PID 58762 → 66658, health `ok`, served JS equals the
  compatible source. Only the receiver executable argument changed. Sampler job and
  config fingerprints unchanged; its next automatic publication reported five
  reachable hosts and the new receiver PID/revision. Seven other sampled
  collector/index/archive processes kept their PIDs and revisions.
- Live checks: editor/anonymous/origin/query/method/no-store/privacy gates, assets,
  sessions/filter/search/default Overview/Insights. Four real browser cases
  (Chinese dark, English light; 1440 and 390 wide) passed shared shell width,
  locale, Machines tables/keyboard/contained scrolling, bilingual Cmd+K, refresh,
  drilldown, reload, navigation privacy clearing and identity-mode logout.
- Health/Overview remains unavailable at the paginated Overview read: a read-only
  probe returned 503 at page 19 (`limit=2`) in three of three runs, matching the
  pre-existing failure first recorded at the initial fleet rollout. This rollout
  changed no read route, index or service; root cause remains unverified.
- **Rollback (UI only):** restore the private
  `hq/state/web-fleet/web-i18n-909aef7b-20261111/receiver-before.plist` and restart
  only the receiver onto retained `081426da`. Leave the sampler loaded; no database
  rollback is needed. Safari/physical-device testing was not run.
