# Perceived Duration Audit

Date: 2026-07-08

Scope: macOS app user-facing waits. Swift product UI evidence is anchored to
`macos/Engram`. Duration classes are source-timeout-backed when the code has an
explicit timeout; otherwise they are estimated from the operation shape.
`UNVERIFIED` means this audit found no current app UI or timeout evidence for a
user-facing wait.

## Latency Classes

| Class | User perception | Required feedback |
| --- | --- | --- |
| `<100ms` | Instant | No indicator. |
| `100ms-1s` | Brief | Subtle activity cue allowed; no layout shift. |
| `1-10s` | Waiting | Visible indeterminate or determinate progress plus status text. |
| `>10s` | Long-running | Progress plus cancel, or progress plus background continuation. |

## Audit Table

| Operation | Duration class | Current UI feedback and evidence | Verdict |
| --- | --- | --- | --- |
| Keyword search | Estimated `100ms-1s`; the input path debounces for 300 ms before search starts. | `SearchPageView` cancels and delays query changes before calling `performSearch` (`macos/Engram/Views/Pages/SearchPageView.swift:126-131`), flips `isSearching` around the service call (`macos/Engram/Views/Pages/SearchPageView.swift:394-405`), and shows a small spinner with `Searching...` while active (`macos/Engram/Views/Pages/SearchPageView.swift:183-186`). | OK - active search has visible indeterminate progress and status text. |
| Semantic/hybrid search | `UNVERIFIED`; not currently user-facing in the Swift app. | `SearchSupport.availableModes` returns only keyword while semantic search is not shipped end-to-end (`macos/Engram/Views/SearchSupport.swift:6-10`), `SearchPageView` sends `mode: "keyword"` (`macos/Engram/Views/Pages/SearchPageView.swift:401-405`), and AI settings document that embeddings/semantic controls were removed because no Swift embedding path exists (`macos/Engram/Views/Settings/AISettingsSection.swift:13-18`). | OK - unsupported modes are not exposed as waits; re-audit when semantic or hybrid search becomes user-facing. |
| Initial full index / rescan | Estimated `>10s`. | Home treats service `.starting` as indexing (`macos/Engram/Views/Pages/HomeView.swift:417-419`) and replaces empty panels with `Indexing your sessions...` (`macos/Engram/Views/Pages/HomeView.swift:131-136`, `macos/Engram/Views/Pages/HomeView.swift:149-150`, `macos/Engram/Views/Pages/HomeView.swift:187-188`, `macos/Engram/Views/Pages/HomeView.swift:226-227`). Source Pulse states indexing runs in the background (`macos/Engram/Views/Pages/SourcePulseView.swift:76-78`), and System Health exposes index scan status plus job counts (`macos/Engram/Views/Observability/SystemHealthView.swift:54-67`). | OK - the wait is backgrounded and visible through indexing status and health counters. |
| FTS full rebuild | Estimated `>10s`; `UNVERIFIED` current app trigger. | The command palette deliberately excludes `reindex/triggerSync` (`macos/Engram/Models/PaletteItem.swift:41-43`). The visible surfaces are aggregate health and coverage only: System Health lists index job counts (`macos/Engram/Views/Observability/SystemHealthView.swift:58-67`) and Source Pulse shows search coverage plus failed-job pills (`macos/Engram/Views/Pages/SourcePulseView.swift:296-299`). | GAP - there is no rebuild-specific progress, cancel, or background-continuation handoff if a full rebuild becomes visible to users. |
| Project move / batch move | Source-timeout-backed `>10s`: project migration commands use a 10 minute timeout in the service client (`macos/Shared/Service/EngramServiceClient.swift:8`, `macos/Shared/Service/EngramServiceClient.swift:189-202`). | Batch Move shows a small spinner and `Moving N project(s)...` while executing (`macos/Engram/Views/Projects/BatchMoveSheet.swift:139-146`) but disables Cancel and interactive dismissal (`macos/Engram/Views/Projects/BatchMoveSheet.swift:159-164`, `macos/Engram/Views/Projects/BatchMoveSheet.swift:176-178`). Rename and Archive have similar progress text (`macos/Engram/Views/Projects/RenameSheet.swift:117-138`, `macos/Engram/Views/Projects/ArchiveSheet.swift:102-113`) and also disable cancellation during execution (`macos/Engram/Views/Projects/RenameSheet.swift:178-180`, `macos/Engram/Views/Projects/ArchiveSheet.swift:202-204`). | GAP - progress text exists, but `>10s` operations provide neither cancel nor background continuation after execution starts. |
| Session export | Source-timeout-backed `>10s`: `exportSession` uses the service client's default 30 second timeout (`macos/Shared/Service/EngramServiceClient.swift:17-20`, `macos/Shared/Service/EngramServiceClient.swift:260-262`, `macos/Shared/Service/EngramServiceClient.swift:297-306`). | Session rows expose Markdown/JSON export actions (`macos/Engram/Views/Pages/SessionsPageView.swift:141-142`), and the handler awaits completion before showing only success or failure status (`macos/Engram/Views/SessionActionHandlers.swift:81-92`). The Sessions page renders that status after it is set (`macos/Engram/Views/Pages/SessionsPageView.swift:68-70`); Command Palette export also only sets a completion/failure message after the await (`macos/Engram/Views/CommandPaletteView.swift:282-293`). | GAP - there is no in-flight progress indicator or cancel/background affordance while export is running. |
| Embedding backfill | `UNVERIFIED`; no current user-facing Swift app backfill. Estimated `>10s` if reintroduced. | AI settings explicitly say embedding controls were removed and no Swift embedding path exists (`macos/Engram/Views/Settings/AISettingsSection.swift:13-18`, `macos/Engram/Views/Settings/AISettingsSection.swift:96`), while search mode availability remains keyword-only (`macos/Engram/Views/SearchSupport.swift:6-10`). | OK - there is no current user-facing backfill wait; any future backfill UI must include long-running progress. |
| Service restart | Source-behavior-backed `>10s`: the launcher has a 30 second startup grace window (`macos/Engram/Core/EngramServiceLauncher.swift:52-55`) and keeps status at `.starting` during that grace (`macos/Engram/Core/EngramServiceLauncher.swift:206-210`). | Restart immediately applies `.starting` (`macos/Engram/App.swift:225-226`), and launcher restart surfaces `.starting` before health monitoring resumes (`macos/Engram/Core/EngramServiceLauncher.swift:247-259`). Home shows service status in the header and Service State panel (`macos/Engram/Views/Pages/HomeView.swift:75-79`, `macos/Engram/Views/Pages/HomeView.swift:257-265`), while Settings labels startup as `Starting...` (`macos/Engram/Views/Settings/GeneralSettingsSection.swift:106-112`). | OK - restart is backgrounded, status remains visible, and the app stays usable while the helper comes back. |
| Session list initial load | Estimated `1-10s`. | `SessionsPageView.loadData` sets `isLoading` during the detached DB read (`macos/Engram/Views/Pages/SessionsPageView.swift:222-248`), shows skeleton rows on the initial empty load (`macos/Engram/Views/Pages/SessionsPageView.swift:109-113`), and shows a compact spinner for pagination (`macos/Engram/Views/Pages/SessionsPageView.swift:153-157`). | OK - initial load has skeleton feedback and pagination has visible progress. |

## Gap Summary

- FTS full rebuild lacks a rebuild-specific progress/cancel/background surface if
  the operation becomes user-visible.
- Project move and batch move can run under a 10 minute timeout but disable
  cancellation and cannot be backgrounded once execution starts.
- Session export can wait up to the default 30 second service timeout without
  in-flight progress or cancellation.
