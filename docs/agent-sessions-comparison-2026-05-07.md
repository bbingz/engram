# Agent Sessions vs Engram Review

Date: 2026-05-07

## Executive summary

Engram should not clone Agent Sessions. The strongest lesson is to absorb Agent Sessions' productization of live work surfaces: Agent Cockpit, menu bar HUD, onboarding, Power Tips, and resume workflows. Engram's durable advantage remains its cross-tool platform layer: broad adapter coverage, MCP tools, hybrid search, local memory, handoff, project timelines, and stronger automation/security foundations.

Recommended priority:

1. Build an Engram Cockpit-lite surface on top of existing live sessions.
2. Fix `/api/live` batch enrichment before expanding live UI usage.
3. Add Power Tips / What's New as a repeatable product education surface.
4. Productize the Resume / Handoff / Replay path in session detail and command palette.
5. Upgrade menu bar meters into a daily operational status panel.

## Review scope

This review combines multiple specialist perspectives:

- Product and UX
- Agent Sessions implementation architecture
- Engram baseline capability review
- Comparative architecture
- Testing, CI, and engineering hygiene
- Security, privacy, and local-first posture
- Performance and operations

The comparison is based on local repositories:

- Engram: `/Users/bing/-Code-/engram`
- Agent Sessions: `/Users/bing/-Code-/agent-sessions`

## Positioning comparison

| Dimension | Engram | Agent Sessions | Assessment |
|---|---|---|---|
| Product position | Cross-tool AI session memory layer, MCP/daemon/Web/macOS platform | Native macOS session browser, resume tool, live cockpit | Engram is deeper infrastructure; Agent Sessions is a more polished desktop workflow |
| Core workflows | Search history, aggregate context, handoff, memory, project timeline, MCP tools | Browse sessions, inspect transcripts, copy resume commands, monitor live agents | Engram is powerful; Agent Sessions is easier to understand |
| Live sessions | `LiveSessionMonitor`, `SourcePulseView`, menu bar active count | Agent Cockpit Beta, iTerm2 live HUD, active/waiting/focus/jump | Agent Sessions is much more productized |
| Search and memory | FTS5 + sqlite-vec + RRF hybrid + insights | Unified search + in-session find | Engram has stronger retrieval and memory foundations |
| UI information architecture | Many pages; capability is somewhat distributed | Main window, pinned sessions, cockpit, Power Tips, Preferences are tightly connected | Agent Sessions has clearer everyday UX |
| Menu bar | Today count, active count, popover usage | Configurable menu bar meters, usage details, live count, HUD entry | Agent Sessions has a more mature status surface |
| Onboarding | Welcome -> Sources -> Ready | Multi-slide tour covering Cockpit, Power Tips, Analytics, Feedback | Agent Sessions is much stronger for feature discovery |
| Engineering quality | Strong TypeScript CI/lint/coverage/knip/fixture checks | Good Swift/Xcode tests, weaker CI enforcement | Engram automation is stronger |
| Security/privacy | Localhost/CIDR/bearer/path confinement/Keychain controls | Clear local-only/no-telemetry messaging | Engram has stronger technical controls; Agent Sessions has clearer user messaging |
| Performance/ops | Better observability, health endpoints, metrics, trace IDs | Better live polling discipline and menu bar repaint control | Both have patterns worth borrowing |

## What Engram should learn from Agent Sessions

### 1. Make Live Sessions a clear Agent Cockpit

Engram already has live session infrastructure, but the current surface feels like a source status page. Agent Sessions turns the same category of capability into a named, obvious product surface: Agent Cockpit.

Engram should build a Cockpit-lite:

- Active / waiting / recent agent grouping
- Project grouping
- Source, model, current activity, and last-active display
- One-click session detail
- One-click replay, handoff, and resume
- Menu bar and main-window entry points
- Clear Beta scope and source support limitations

### 2. Add Power Tips / What's New

Agent Sessions uses onboarding as product education, not only first-run setup. Engram has many high-value features that are easy to miss:

- Command palette
- Transcript find
- Handoff
- Replay
- Parent-child agent grouping
- `save_insight` / `get_context`
- Menu bar usage
- Live sessions
- Project timeline
- Memory search

Engram should add a repeatable Power Tips / What's New flow that can be opened from Help and shown after meaningful updates.

### 3. Turn the menu bar into a daily operational panel

Engram's menu bar already shows today count and active count. It should become a more useful at-a-glance surface:

- Today's parent sessions
- Active agents
- Waiting / idle agents
- Quota or usage risk
- Daemon/web/embedding health
- Last indexed time
- Direct entry to Cockpit

Implementation should avoid repainting on every poll. Borrow the Agent Sessions idea of versioned live-state invalidation or membership versions.

### 4. Productize resume workflows

Agent Sessions makes resume a first-class workflow. Engram already has Resume, Handoff, and Replay, but they are distributed across the UI.

Recommended primary path:

1. Find a session.
2. Inspect transcript.
3. Replay or generate handoff.
4. Copy resume command.
5. Open terminal or copy cwd.
6. Optionally focus iTerm2 later.

The first four steps should become obvious in session detail and command palette.

### 5. Explain Beta scope and privacy boundaries in the UI

Agent Sessions is explicit about Cockpit being Beta and about its iTerm2/tool support. Engram supports more sources, but live detection boundaries are less visible.

Engram should clearly explain:

- Which sources support live detection
- Which sources are history-only
- Whether terminal permissions are needed
- What is read-only
- Whether any network calls are involved
- When live state can be stale or approximate

### 6. Add a lightweight feedback loop

Agent Sessions places feedback, GitHub star, and support links in onboarding. Engram can borrow this carefully:

- Help menu: Feedback / Star / Sponsor / Security
- About or Settings footer
- Optional onboarding final slide
- Clear no-telemetry statement so users know feedback is opt-in

## Where Engram is already stronger

### Platform architecture

Engram's adapter/core/db/tools/web/macOS separation is more suitable for a long-lived platform. MCP tools, daemon mode, and Web/API surfaces are strategic advantages. Engram should not reduce itself to a macOS-only session browser.

### Source coverage

Engram supports a broader source matrix across CLI and IDE tools. Agent Sessions is more focused around native macOS browsing and live workflows. Engram should keep broad coverage while improving the high-frequency workflow layer.

### Search and memory

Engram's hybrid retrieval, insights, `get_context`, handoff, and project timeline capabilities are closer to an AI work-memory system than Agent Sessions' browser-style search.

### Security and privacy controls

Engram has stronger technical controls: localhost default, CIDR allowlist, bearer token for writes, path confinement, and Keychain handling. Agent Sessions is clearer in plain-language local-only/no-telemetry messaging. Engram should keep the controls and improve user-facing privacy summaries.

### CI and engineering hygiene

Engram's TypeScript side has stronger CI, lint, coverage, dead-code detection, and fixture checks. The main gap is Swift/macOS-side lint and test enforcement.

## Implementation patterns worth borrowing

| Pattern from Agent Sessions | Why it matters for Engram |
|---|---|
| Multi-level poll intervals and background intervals for live sessions | Prevents live monitoring from becoming CPU-heavy |
| In-flight probe tracking, generation IDs, and queue deduplication | Avoids probe storms and stale state updates |
| Dynamic `NSStatusItem` fitting-size width updates | Makes menu bar meters more stable and polished |
| App/window router for main window, HUD, pinned cockpit | Gives Engram a clean way to add Cockpit without UI sprawl |
| Data-driven onboarding content | Enables versioned Power Tips without hardcoded branches |
| Pinned Cockpit restore | Useful for power users who treat live monitoring as a persistent HUD |

## What not to copy

1. Do not over-bind Engram to iTerm2. Terminal focus can be optional, but Engram's value is cross-tool and cross-surface.
2. Do not expose too many preferences. Agent Sessions has many knobs; Engram should favor strong defaults.
3. Do not lock core workflows into macOS UI. MCP, daemon, CLI, and Web surfaces are Engram's moat.
4. Avoid large all-purpose app/model files. If Cockpit grows, split scanner, classifier, enrichment, presentation, and actions.
5. Do not shift Engram's core identity from memory/context platform to session browser.

## Risks and gaps

### Engram

| Risk | Impact | Recommendation |
|---|---|---|
| `/api/live` enriches sessions with per-row DB lookups | Degrades as active live sessions increase | Batch-enrich live sessions |
| Session detail can load full transcripts | Slow first paint and high memory for large sessions | Add paging or summary-first detail mode |
| Source Pulse is observability-oriented, not action-oriented | Users may not understand why to use it | Reframe as Cockpit-lite |
| Onboarding is too basic | Valuable features remain hidden | Add Power Tips / What's New |
| Localhost CORS is broad | Larger local attack surface | Tighten or document local-dev scope; keep bearer protection |
| Swift-side quality gates lag TS-side gates | macOS regressions are easier to miss | Add SwiftLint/XCTest CI |

### Agent Sessions

| Risk | Impact |
|---|---|
| Strong macOS/iTerm2 dependency | Less portable and less platform-like |
| Dense settings and feature flags | Higher cognitive load |
| Large files with broad responsibility | Long-term maintenance cost |
| CI automation weaker than test assets | Tests are less effective as release gates |
| Browser-first product shape | Less depth as a memory/context platform |

## Recommended roadmap for Engram

### P0

1. **Engram Cockpit-lite**
   - Evolve from `SourcePulseView`
   - Active / waiting / recent grouping
   - Project grouping
   - Session actions: open, replay, handoff, resume
   - Menu bar entry point

2. **Fix `/api/live` N+1 DB enrichment**
   - Batch query session metadata by file path
   - Prepare the endpoint for heavier cockpit use

3. **Power Tips / What's New**
   - Data-driven content
   - Help menu entry
   - Optional first-run/update presentation

4. **Unify Resume / Handoff / Replay as primary actions**
   - Session detail should make these actions obvious
   - Command palette should expose them as first-class actions

### P1

1. **Configurable menu bar meters**
   - Active agents
   - Today sessions
   - Usage/quota
   - Daemon/embedding health
   - Last indexed time

2. **Transcript paging or summary-first session detail**
   - Avoid full transcript loads on first paint
   - Preserve search-result navigation

3. **Split live session monitoring responsibilities**
   - Scanner
   - Classifier
   - Enrichment
   - UI presentation
   - Action router

4. **Beta scope and privacy disclosure**
   - Live detection support matrix
   - Optional provider/network data flow
   - LAN mode warning

5. **Swift quality gates**
   - SwiftLint
   - XCTest CI
   - Native fixture/golden test organization

### P2

1. **Optional iTerm2 focus/reveal**
   - Explicit permission and support scope
   - No hard dependency

2. **Pinned Cockpit**
   - For power users
   - Off by default

3. **Feedback/support links**
   - Help/About/Onboarding
   - Clear opt-in framing

4. **Command palette as action center**
   - Open, replay, handoff, resume, link, archive, search, memory

## Final recommendation

Engram's strategic direction should be:

> Keep building the cross-tool AI work-memory platform, and add an Agent Sessions-style live workbench as the high-frequency UI layer.

The near-term sequence should be:

1. Cockpit-lite
2. `/api/live` performance fix
3. Power Tips
4. Resume/Handoff/Replay primary path
5. Menu bar meters

This keeps Engram's platform depth while closing the biggest product-experience gap exposed by Agent Sessions.
