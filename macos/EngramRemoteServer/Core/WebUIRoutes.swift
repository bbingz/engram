import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Same-origin static viewer. HTML/JS/CSS are constant strings; no inline script or style.
enum WebUIRoutes {
    static func mount<Context: RequestContext>(on router: Router<Context>) {
        router.get("/web") { _, _ in asset("text/html; charset=utf-8", html) }
        router.get("/web/app.js") { _, _ in asset("text/javascript; charset=utf-8", javascript) }
        router.get("/web/app.css") { _, _ in asset("text/css; charset=utf-8", css) }
    }

    private static func asset(_ type: String, _ body: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = type
        headers[.contentLength] = "\(body.utf8.count)"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: body)))
    }

    static let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Engram</title>
        <link rel="stylesheet" href="/web/app.css">
        </head>
        <body>
        <header class="top-nav">
        <h1>Engram</h1>
        <p id="lede" class="lede">Browse your session library.</p>
        <form id="login">
        <label>Credential <input id="credential" name="credential" type="password" autocomplete="current-password"></label>
        <button type="submit">Log in</button>
        </form>
        <button id="logout" type="button" hidden>Log out</button>
        <p id="status" role="status"></p>
        </header>
        <p id="signed-out" class="empty">Sign in to browse your session library.</p>
        <main id="workspace" hidden>
        <nav class="page-nav" aria-label="Main navigation">
        <a id="nav-sessions" href="#sessions" aria-current="page">Sessions</a>
        <a id="nav-search" href="#search">Search</a>
        <a id="nav-stats" href="#stats">Stats</a>
        <a id="nav-health" href="#health">Health</a>
        <a id="nav-settings" href="#settings">Settings</a>
        </nav>
        <section id="library-page">
        <aside class="list-pane">
        <section id="overview"></section>
        <section id="search-options" hidden>
        <div class="search-mode-controls">
        <label>Search mode <select id="search-mode"><option id="mode-keyword" value="keyword">Keyword</option><option id="mode-semantic" value="semantic" disabled>Semantic</option><option id="mode-hybrid" value="hybrid" disabled>Hybrid</option></select></label>
        <label>Results <select id="search-limit"><option value="10">10</option><option value="25">25</option><option value="50">50</option></select></label>
        </div>
        <p id="search-capabilities" role="status"></p>
        <p id="search-result-status" role="status"></p>
        <details id="insight-compose" class="advanced-filters">
        <summary>Save an insight</summary>
        <p id="insight-write-status" role="status"></p>
        <form id="insight-save-form" hidden>
        <label>Insight <textarea id="insight-content-input" rows="6" maxlength="50000" placeholder="A lesson or note to find again…" required></textarea></label>
        <div class="search-mode-controls">
        <label>Category <input id="insight-wing-input" maxlength="200" placeholder="Optional"></label>
        <label>Topic <input id="insight-room-input" maxlength="200" placeholder="Optional"></label>
        <label>Importance <select id="insight-importance-input"><option value="5">5 — High</option><option value="4">4</option><option value="3">3</option><option value="2">2</option><option value="1">1</option><option value="0">0 — Low</option></select></label>
        </div>
        <label>Source session ID <input id="insight-source-input" maxlength="4096" placeholder="Optional; leave blank for a library note"></label>
        <button id="insight-save-button" type="submit">Save insight</button>
        </form>
        <button id="insight-saved-read" type="button" hidden>Read saved insight</button>
        </details>
        </section>
        <form id="search">
        <label id="search-query"><span class="visually-hidden">Search</span> <input id="query" name="query" type="search" placeholder="Keywords"></label>
        <details id="source-picker" class="facet-picker">
        <summary id="source-summary">All sources</summary>
        <div class="facet-menu">
        <p id="source-status" role="status"></p>
        <div id="source-options" class="facet-options"></div>
        <button id="source-more" type="button" hidden>More sources</button>
        <button id="source-clear" type="button">Clear sources</button>
        </div>
        </details>
        <details id="project-picker" class="facet-picker">
        <summary id="project-summary">All projects</summary>
        <div class="facet-menu">
        <div class="facet-search">
        <label for="project-query" class="visually-hidden">Search projects</label>
        <input id="project-query" type="search" placeholder="Search projects…" maxlength="1024">
        <button id="project-find" type="button">Find</button>
        </div>
        <p id="project-status" role="status"></p>
        <div id="project-options" class="facet-options"></div>
        <button id="project-more" type="button" hidden>More projects</button>
        <button id="project-clear" type="button">Clear projects</button>
        </div>
        </details>
        <details class="advanced-filters">
        <summary>Advanced filters</summary>
        <label>Since <input id="since" name="since" type="date"></label>
        <label>Until <input id="until" name="until" type="date"></label>
        <label class="tool-filter"><input id="hide-tools" type="checkbox"> Hide tool-only sessions</label>
        <label>Machine ID <input id="machineId" name="machineId" placeholder="Machine ID"></label>
        </details>
        <button type="submit">Search</button>
        </form>
        <div class="agent-filters" role="group" aria-label="Agent sessions">
        <button id="agents-hide" type="button" aria-pressed="true">Hide Agents</button>
        <button id="agents-all" type="button" aria-pressed="false">All</button>
        <button id="agents-only" type="button" aria-pressed="false">Agents Only</button>
        </div>
        <form id="session-jump" class="session-jump">
        <label for="session-id" class="visually-hidden">Session ID</label>
        <input id="session-id" name="sessionId" placeholder="Session ID…" maxlength="4096" autocomplete="off">
        <button type="submit">Go to session</button>
        </form>
        <section id="insight-results" hidden><h2>Insights across your library</h2><div id="insight-rows"></div></section>
        <section id="sessions"></section>
        <div class="session-pagination" aria-label="Session pages">
        <button id="session-previous" type="button" hidden>Previous</button>
        <span id="session-page-status" role="status"></span>
        <button id="more" type="button" hidden>Next</button>
        </div>
        </aside>
        <section class="detail-pane">
        <button id="back" type="button" hidden>Sessions</button>
        <section id="detail"></section>
        <section id="session-summary" class="settings-section" hidden><h3>Summary</h3><div id="session-summary-text"></div></section>
        <details id="session-actions" class="advanced-filters" hidden>
        <summary>Generate summary or title</summary>
        <p id="session-action-status" role="status"></p>
        <div class="search-mode-controls"><button id="session-generate-summary" type="button" disabled>Generate summary</button><button id="session-generate-title" type="button" disabled>Generate title</button></div>
        </details>
        <nav id="detail-view-nav" class="agent-filters" aria-label="Session views" hidden>
        <button id="detail-view-transcript" type="button" aria-pressed="true">Transcript</button>
        <button id="detail-view-timeline" type="button" aria-pressed="false">Timeline</button>
        <button id="detail-view-children" type="button" aria-pressed="false">Child sessions</button>
        </nav>
        <section id="transcript-panel">
        <section id="messages"></section>
        <button id="more-messages" type="button" hidden>Load more messages</button>
        </section>
        <section id="timeline-panel" hidden>
        <div class="page-heading"><h3>Timeline</h3><button id="timeline-refresh" type="button">Refresh</button></div>
        <p id="timeline-status" role="status"></p><div id="timeline-rows"></div>
        <button id="timeline-more" type="button" hidden>Load more events</button>
        </section>
        <section id="detail-children-panel" hidden>
        <div class="page-heading"><h3>Child sessions</h3><button id="detail-children-refresh" type="button">Refresh</button></div>
        <button id="relationship-edit" type="button">Edit relationships</button>
        <p id="relationship-access" role="status"></p>
        <form id="relationship-form" class="stats-filters" hidden>
        <label>Child session ID <input id="relationship-child-id" required maxlength="4096" autocomplete="off" placeholder="Session to link to this parent"></label>
        <button id="relationship-add" type="submit">Link child</button>
        </form>
        <p id="relationship-status" role="status"></p>
        <p id="detail-children-status" role="status"></p><div id="detail-children-rows"></div>
        <button id="detail-children-more" type="button" hidden>Load more child sessions</button>
        </section>
        </section>
        </section>
        <section id="health-page" hidden>
        <div class="page-heading"><h2>Health</h2><button id="health-refresh" type="button">Refresh</button></div>
        <p>Capture and indexing observations from the service.</p>
        <p id="health-status" role="status"></p>
        <div id="health-content" class="health-grid"></div>
        </section>
        <section id="settings-page" hidden>
        <div class="page-heading"><h2>Settings</h2><button id="settings-refresh" type="button">Refresh</button></div>
        <p id="settings-status" role="status"></p>
        <div id="settings-content"></div>
        <button id="settings-more" type="button" hidden>More project aliases</button>
        <p id="settings-access" role="status"></p>
        <details id="ai-config" class="settings-section">
        <summary>AI settings</summary>
        <p>Configure summaries, titles, semantic search and call history. API keys are managed on the server.</p>
        <p>Environment overrides can take precedence. Changing the embedding model or dimensions does not rebuild stored vectors.</p>
        <form id="ai-config-form">
        <fieldset class="ai-config-group"><legend>Summaries</legend>
        <label>Protocol<select id="ai-config-aiProtocol"><option value="openai">openai</option><option value="disabled">disabled</option></select></label>
        <label>API base URL<input id="ai-config-aiBaseURL" maxlength="2048"></label>
        <label>Model<input id="ai-config-aiModel" maxlength="256"></label>
        <label>Language<input id="ai-config-summaryLanguage" maxlength="64"></label>
        <label>Maximum sentences<input id="ai-config-summaryMaxSentences" type="number" required min="1" max="20" step="1"></label>
        <label>Style<input id="ai-config-summaryStyle" maxlength="512"></label>
        <label>Custom prompt<textarea id="ai-config-summaryPrompt" rows="3" maxlength="8000"></textarea></label>
        <label>Maximum output tokens<input id="ai-config-summaryMaxTokens" type="number" required min="1" max="32768" step="1"></label>
        <label>Temperature<input id="ai-config-summaryTemperature" type="number" required min="0" max="2" step="0.1"></label>
        <label>First messages<input id="ai-config-summarySampleFirst" type="number" required min="0" max="200" step="1"></label>
        <label>Last messages<input id="ai-config-summarySampleLast" type="number" required min="0" max="200" step="1"></label>
        <label>Characters per message<input id="ai-config-summaryTruncateChars" type="number" required min="1" max="10000" step="1"></label>
        </fieldset>
        <fieldset class="ai-config-group"><legend>Titles</legend>
        <label>Provider<select id="ai-config-titleProvider"><option value="ollama">ollama</option><option value="custom">custom</option><option value="openai">openai</option></select></label>
        <label>API base URL<input id="ai-config-titleBaseUrl" maxlength="2048"></label>
        <label>Model<input id="ai-config-titleModel" maxlength="256"></label>
        </fieldset>
        <fieldset class="ai-config-group"><legend>Semantic search</legend>
        <label>API base URL<input id="ai-config-embeddingBaseURL" maxlength="2048"></label>
        <label>Model<input id="ai-config-embeddingModel" maxlength="256"></label>
        <label>Dimensions<input id="ai-config-embeddingDimension" type="number" required min="1" max="65536" step="1"></label>
        <label>Send dimensions to provider<input id="ai-config-embeddingIncludeDimensions" type="checkbox"></label>
        </fieldset>
        <fieldset class="ai-config-group"><legend>AI call history</legend>
        <label>Record calls<input id="ai-config-aiAudit.enabled" type="checkbox"></label>
        <label>Store redacted request and response bodies<input id="ai-config-aiAudit.logBodies" type="checkbox"></label>
        <label>Maximum stored body size<input id="ai-config-aiAudit.maxBodySize" type="number" required min="1" max="1000000" step="1"></label>
        </fieldset>
        <div class="ai-config-actions"><button id="ai-config-save" type="submit" disabled>Save changes</button><button id="ai-config-reload" type="button">Reload saved settings</button></div>
        </form><p id="ai-config-status" role="status"></p>
        </details>
        <section id="batch-title-actions" class="settings-section" hidden>
        <h3>Session titles</h3><p>Generate titles for sessions that do not yet have one, using the configured AI provider.</p>
        <button id="batch-title-button" type="button">Generate missing titles</button><p id="batch-title-status" role="status"></p>
        </section>
        <section id="source-settings" class="settings-section" hidden>
        <h3>Source settings</h3>
        <p>These controls change importing and session visibility on this server.</p>
        <table aria-label="Source configuration"><thead><tr><th>Source</th><th>Status</th><th>Action</th></tr></thead><tbody id="source-settings-rows"></tbody></table>
        </section>
        <p id="source-settings-status" role="status"></p>
        <p id="source-write-status" role="status"></p>
        <section id="alias-editor" class="settings-section" hidden>
        <h3>Add project alias</h3>
        <form id="alias-project-form" class="stats-filters">
        <label>Find destination project <input id="alias-project-query" type="search" maxlength="1000"></label>
        <button id="alias-project-search" type="submit">Find</button>
        </form>
        <p id="alias-project-status" role="status"></p>
        <form id="alias-form" class="stats-filters">
        <label>Old name or path <input id="alias-text" required maxlength="1000" placeholder="/old/project"></label>
        <label>Destination project <select id="alias-canonical" required></select></label>
        <button id="alias-add" type="submit">Add alias</button>
        </form>
        <button id="alias-project-more" type="button" hidden>More destination projects</button>
        </section>
        <p id="alias-status" role="status"></p>
        </section>
        <section id="stats-page" hidden>
        <div class="page-heading"><h2>Stats</h2></div>
        <div class="agent-filters" role="group" aria-label="Statistics view"><button id="stats-view-sessions" type="button" aria-pressed="true">Sessions</button><button id="stats-view-costs" type="button" aria-pressed="false">Costs</button><button id="stats-view-tools" type="button" aria-pressed="false">Tools</button><button id="stats-view-files" type="button" aria-pressed="false">Files</button><button id="stats-view-usage" type="button" aria-pressed="false">Usage</button><button id="stats-view-repos" type="button" aria-pressed="false">Repositories</button><button id="stats-view-ai" type="button" aria-pressed="false">AI calls</button></div>
        <div id="stats-content">
        <form id="stats-form" class="stats-filters">
        <label>Group by <select id="stats-group"><option value="source">Source</option><option value="project">Project</option><option value="day">Day</option><option value="week">Week</option></select></label>
        <label>Since <input id="stats-since" type="date"></label>
        <label>Until <input id="stats-until" type="date"></label>
        <label>Agents <select id="stats-agents"><option value="hide">Hide agents</option><option value="all">All</option><option value="only">Agents only</option></select></label>
        <label><input id="stats-noise" type="checkbox"> Exclude lightweight sessions</label>
        <button type="submit">Apply</button>
        </form>
        <p id="stats-status" role="status"></p>
        <dl id="stats-totals" class="stats-totals"></dl>
        <div class="stats-table"><table aria-label="Session statistics"><thead><tr><th>Group</th><th>Sessions</th><th>Messages</th><th>User</th><th>Assistant</th><th>Tool</th></tr></thead><tbody id="stats-rows"></tbody></table></div>
        <button id="stats-more" type="button" hidden>More groups</button>
        </div>
        <div id="costs-content" hidden>
        <form id="costs-form" class="stats-filters">
        <label>Group by <select id="costs-group"><option value="model">Model</option><option value="source">Source</option><option value="project">Project</option><option value="day">Day</option></select></label>
        <label>Since <input id="costs-since" type="date"></label>
        <label>Until <input id="costs-until" type="date"></label>
        <label>Agents <select id="costs-agents"><option value="hide">Hide agents</option><option value="all">All</option><option value="only">Agents only</option></select></label>
        <label>Top sessions <select id="costs-limit"><option value="20">20</option><option value="50">50</option><option value="100">100</option></select></label>
        <button type="submit">Apply</button>
        </form>
        <p id="costs-status" role="status"></p>
        <dl id="costs-totals" class="stats-totals"></dl>
        <p id="costs-unpriced"></p>
        <div class="stats-table"><table aria-label="Cost breakdown"><thead><tr><th>Group</th><th>USD</th><th>Sessions</th><th>Input tokens</th><th>Output tokens</th><th>Cache read</th><th>Cache write</th></tr></thead><tbody id="costs-rows"></tbody></table></div>
        <button id="costs-more" type="button" hidden>More groups</button>
        <h3>Highest-cost sessions</h3>
        <p id="costs-sessions-status" role="status"></p>
        <div class="stats-table"><table aria-label="Session costs"><thead><tr><th>Session</th><th>Model</th><th>USD</th><th>Input tokens</th><th>Output tokens</th><th>Cache read</th><th>Cache write</th></tr></thead><tbody id="costs-sessions"></tbody></table></div>
        </div>
        <div id="tools-content" hidden>
        <form id="tools-form" class="stats-filters">
        <label>Group by <select id="tools-group"><option value="tool">Tool</option><option value="session">Session</option><option value="project">Project</option></select></label>
        <label>Project contains <input id="tools-project" type="search" placeholder="Filter projects"></label>
        <label>Since <input id="tools-since" type="date"></label>
        <label>Until <input id="tools-until" type="date"></label>
        <label>Agents <select id="tools-agents"><option value="hide">Hide agents</option><option value="all">All</option><option value="only">Agents only</option></select></label>
        <button type="submit">Apply</button>
        </form>
        <p id="tools-status" role="status"></p>
        <p id="tools-totals"></p>
        <div class="stats-table"><table aria-label="Tool activity"><thead><tr><th>Group</th><th>Calls</th><th>Sessions</th><th>Tools</th></tr></thead><tbody id="tools-rows"></tbody></table></div>
        <button id="tools-more" type="button" hidden>More groups</button>
        </div>
        <div id="files-content" hidden>
        <form id="files-form" class="stats-filters">
        <label>Project contains <input id="files-project" type="search" placeholder="Filter projects"></label>
        <label>Since <input id="files-since" type="date"></label>
        <label>Until <input id="files-until" type="date"></label>
        <label>Agents <select id="files-agents"><option value="hide">Hide agents</option><option value="all">All</option><option value="only">Agents only</option></select></label>
        <button type="submit">Apply</button>
        </form>
        <p id="files-status" role="status"></p>
        <p id="files-totals"></p>
        <div class="stats-table"><table aria-label="File activity"><thead><tr><th>File</th><th>Reads</th><th>Edits</th><th>Writes</th><th>Sessions</th></tr></thead><tbody id="files-rows"></tbody></table></div>
        <button id="files-more" type="button" hidden>More files</button>
        </div>
        <div id="usage-content" hidden>
        <button id="usage-refresh" type="button">Reload observations</button>
        <p id="usage-status" role="status"></p>
        <div class="stats-table"><table aria-label="Recorded usage"><thead><tr><th>Source</th><th>Metric</th><th>Value / limit</th><th>Basis</th><th>Status</th><th>Resets</th><th>Collected</th></tr></thead><tbody id="usage-rows"></tbody></table></div>
        </div>
        <div id="ai-content" hidden>
        <form id="ai-form" class="stats-filters">
        <label>Caller <input id="ai-caller" maxlength="128" placeholder="e.g. summary"></label>
        <label>Model <input id="ai-model" maxlength="128" placeholder="Exact model name"></label>
        <label>Session ID <input id="ai-session" maxlength="4096"></label>
        <label>From <input id="ai-from" type="date"></label>
        <label>To <input id="ai-to" type="date"></label>
        <label>Outcome <select id="ai-errors"><option value="">All</option><option value="true">Errors</option><option value="false">Successful</option></select></label>
        <button type="submit">Find calls</button>
        <button id="ai-stats-refresh" type="button">View statistics</button>
        </form>
        <p class="meta">Statistics use the date range only; without dates they cover the last 24 hours. Call history uses all filters.</p>
        <p id="ai-stats-status" role="status"></p><div id="ai-stats"></div>
        <p id="ai-status" role="status"></p><div id="ai-rows" class="health-grid"></div>
        <button id="ai-more" type="button" hidden>More calls</button>
        <section id="ai-detail" class="settings-section" hidden aria-label="AI call details"></section>
        </div>
        <div id="repos-content" hidden>
        <button id="repos-refresh" type="button">Reload observations</button>
        <p id="repos-status" role="status"></p>
        <div id="repos-rows" class="health-grid"></div>
        <button id="repos-more" type="button" hidden>More repositories</button>
        </div>
        </section>
        </main>
        <dialog id="insight-dialog" hidden aria-labelledby="insight-heading">
        <div class="insight-heading"><h2 id="insight-heading">Insight</h2><button id="insight-close" type="button">Close</button></div>
        <p id="insight-detail-status" role="status"></p>
        <div id="insight-body"></div><button id="insight-more" type="button" hidden>Read more</button>
        </dialog>
        <script src="/web/app.js"></script>
        </body>
        </html>
        """

    static let css = """
        [hidden] { display: none !important; }
        /* Preserve the legacy Web palette from 5013bab7:src/web/views.ts. */
        :root { color-scheme: dark; --bg:#0f172a; --panel:#1e293b; --text:#f8fafc; --muted:#94a3b8; --line:#334155; --accent:#22c55e; --code:#0d1117; }
        * { box-sizing: border-box; }
        html { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; overflow-wrap: anywhere; }
        a { color: inherit; text-decoration: none; }
        .visually-hidden { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
        .top-nav { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 16px; min-height: 48px; padding: 10px 20px; margin-bottom: 16px; border-bottom: 1px solid var(--line); position: sticky; top: 0; z-index: 20; background: rgba(15,23,42,0.85); backdrop-filter: blur(12px); }
        h1 { margin: 0; font-size: 18px; line-height: 1.25; letter-spacing: -0.02em; }
        .lede, #status { margin: 0; color: var(--muted); font-size: 12px; }
        .lede { flex: 1; }
        #status:empty { display: none; }
        #logout { margin-left: auto; }
        .top-nav #login { margin: 0; }
        #login { display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: end; margin: 12px 0; }
        #login label { display: flex; flex-direction: column; gap: 4px; color: var(--muted); font-size: 12px; font-weight: 700; }
        #search { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 8px 0; }
        #search-query { flex: 1 1 100%; min-width: 0; }
        #search-query input { width: 100%; min-width: 0; }
        #search > .advanced-filters { flex: 1 1 100%; min-width: 0; order: 3; }
        .advanced-filters label { display: flex; flex-direction: column; gap: 4px; color: var(--muted); font-size: 12px; font-weight: 700; }
        .facet-picker { position: relative; flex: 1 1 10rem; min-width: 0; margin: 0; }
        .facet-picker > summary { cursor: pointer; color: var(--text); border: 1px solid var(--line); border-radius: 6px; background: var(--panel); padding: 6px 10px; }
        .facet-menu { position: absolute; left: 0; top: calc(100% + 4px); width: min(320px, calc(100vw - 32px)); min-width: 100%; z-index: 10; padding: 10px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); box-shadow: 0 8px 24px #0002; }
        #project-picker .facet-menu { left: auto; right: 0; }
        .facet-options { max-height: 240px; overflow-y: auto; margin: 8px 0; }
        .facet-options label { display: flex; align-items: baseline; gap: 8px; padding: 5px 0; color: var(--text); cursor: pointer; }
        .facet-options input { flex: 0 0 auto; accent-color: var(--accent); }
        .facet-options .facet-count { margin-left: auto; color: var(--muted); }
        .facet-menu p { margin: 4px 0; }
        .facet-menu p:empty { display: none; }
        .facet-search { display: flex; gap: 6px; }
        .facet-search input { width: 100%; min-width: 0; }
        .facet-search button { flex-shrink: 0; white-space: nowrap; }
        #search > button { flex: 0 0 auto; order: 2; }
        .session-jump { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0; }
        .session-jump input { flex: 1 1 16rem; min-width: 0; }
        .agent-filters { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0; }
        .agent-filters button { border-radius: 16px; font-size: 12px; }
        .agent-filters button[aria-pressed="true"] { color: var(--accent); border-color: var(--accent); background: color-mix(in srgb, var(--accent) 10%, var(--panel)); }
        .agent-label { color: light-dark(#7e22ce, #c084fc); font-weight: 600; }
        input, select { margin: 0; padding: 6px 8px; border: 1px solid var(--line); border-radius: 6px; background: var(--panel); color: var(--text); }
        button { margin: 0; padding: 6px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--panel); color: var(--text); }
        button:hover { border-color: var(--accent); color: var(--accent); }
        #workspace { width: 100%; max-width: 960px; margin: 0 auto; padding: 0 20px 40px; }
        .page-nav { display: flex; gap: 4px; padding-bottom: 12px; margin-bottom: 16px; border-bottom: 1px solid var(--line); overflow-x: auto; }
        .page-nav a { padding: 5px 10px; border-radius: 6px; color: var(--muted); font-weight: 500; white-space: nowrap; }
        .page-nav a:hover { color: var(--text); background: var(--panel); }
        .page-nav a[aria-current="page"] { color: var(--accent); background: rgba(34,197,94,0.12); }
        .advanced-filters label.tool-filter { display: flex; flex-direction: row; align-items: center; gap: 6px; padding: 8px 0; }
        .advanced-filters .tool-filter input { width: auto; margin: 0; }
        .search-mode-controls { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; margin: 12px 0; }
        .search-mode-controls label { display: flex; align-items: center; gap: 6px; color: var(--muted); font-size: 12px; }
        #search-capabilities, #search-result-status { color: var(--muted); font-size: 12px; }
        #search-result-status:empty { display: none; }
        #insight-results h2 { font-size: 14px; }
        #insight-compose { margin-bottom: 14px; }
        #insight-save-form { display: grid; gap: 12px; margin: 12px 0; }
        #insight-save-form label { display: grid; gap: 5px; }
        #insight-save-form textarea { width: 100%; resize: vertical; padding: 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--text); font: inherit; }
        .insight-card { padding: 12px; margin: 10px 0; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
        .insight-card p { white-space: pre-wrap; }
        #insight-dialog { width: min(760px, calc(100vw - 32px)); max-height: 85vh; padding: 20px; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); color: var(--text); overflow-wrap: anywhere; }
        #insight-dialog::backdrop { background: rgba(0,0,0,.65); }
        .insight-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
        .insight-heading h2 { margin: 0; }
        #insight-body { white-space: pre-wrap; margin-bottom: 16px; }
        #insight-detail-status { color: var(--muted); }
        #session-summary-text p { color: var(--text); font-size: 14px; }
        .search-snippet { color: var(--muted); font-weight: 400; margin: 8px 0 0; line-height: 1.5; max-height: 4.5em; overflow: hidden; white-space: pre-wrap; }
        .search-snippet mark { background: var(--accent); color: var(--bg); padding: 0 2px; border-radius: 2px; }
        .session-pagination { display: flex; align-items: center; justify-content: center; flex-wrap: wrap; gap: 12px; padding: 12px 0; }
        #session-page-status { color: var(--muted); font-size: 12px; }
        .page-heading { display: flex; gap: 12px; align-items: center; justify-content: space-between; }
        .page-heading h2 { margin: 0; font-size: 20px; }
        #health-page > p { color: var(--muted); }
        .health-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr)); gap: 12px; }
        .health-card { padding: 16px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); min-width: 0; }
        #usage-content table { font-size: 12px; }
        #usage-rows td:first-child, #usage-rows td:nth-child(5) { white-space: nowrap; }
        #repos-rows p, #repos-rows h3 { overflow-wrap: anywhere; }
        .health-card h3 { margin: 0 0 6px; }
        .health-card dl { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 6px 12px; margin: 12px 0; font-size: 12px; }
        .health-card dt { color: var(--muted); }
        .health-card dd { margin: 0; text-align: right; }
        .health-card .attention { color: light-dark(#9a3412, #fdba74); }
        .stats-filters { display: flex; flex-wrap: wrap; align-items: end; gap: 10px; margin: 16px 0; }
        .stats-filters label { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; color: var(--muted); font-size: 12px; }
        .stats-filters input { max-width: 100%; }
        #repos-status, #usage-status, #files-status, #tools-status, #stats-status, #costs-status, #costs-unpriced, #costs-sessions-status { color: var(--muted); }
        #costs-more { margin-top: 12px; }
        #tools-rows button, #costs-sessions button { max-width: 280px; text-align: left; white-space: normal; overflow-wrap: anywhere; }
        #costs-content .stats-table th, #costs-content .stats-table td { white-space: nowrap; }
        #costs-sessions td:first-child { min-width: 220px; }
        #ai-detail { scroll-margin-top: 64px; }
        #ai-stats .health-card { color: var(--text); }
        .ai-counts { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 6px 12px; margin: 12px 0; font-size: 12px; }
        .ai-counts dt { color: var(--muted); }
        .ai-counts dd { margin: 0; text-align: right; }
        .stats-totals { display: flex; flex-wrap: wrap; gap: 12px; margin: 16px 0; }
        .stats-totals > div { flex: 1 1 120px; padding: 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
        .stats-totals dt { font-size: 12px; color: var(--muted); }
        .stats-totals dd { margin: 4px 0 0; font-size: 24px; font-weight: 650; }
        .stats-table { max-width: 100%; overflow-x: auto; }
        .stats-table table { width: 100%; min-width: 580px; border-collapse: collapse; }
        .stats-table th, .stats-table td { padding: 10px; text-align: right; border-bottom: 1px solid var(--line); }
        .stats-table th:first-child, .stats-table td:first-child { text-align: left; }
        #stats-more, #settings-more { margin-top: 12px; }
        #settings-status { color: var(--muted); }
        .settings-section { padding: 16px; margin-top: 16px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
        #ai-config > summary { color: var(--text); font-size: 16px; font-weight: 600; cursor: pointer; }
        .ai-config-group { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr)); gap: 14px; border: 1px solid var(--line); border-radius: 8px; padding: 16px; margin: 16px 0; min-width: 0; }
        .ai-config-group legend { color: var(--text); font-size: 14px; padding: 0 6px; }
        .ai-config-group label { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
        .ai-config-group input, .ai-config-group select, .ai-config-group textarea { width: 100%; box-sizing: border-box; min-width: 0; }
        .ai-config-group input[type="checkbox"] { width: auto; align-self: flex-start; }
        .ai-config-group textarea { resize: vertical; font: inherit; color: var(--text); background: var(--bg); border: 1px solid var(--line); border-radius: 6px; padding: 8px; }
        .ai-config-actions { display: flex; gap: 10px; flex-wrap: wrap; }
        .settings-section h3 { margin: 0 0 12px; font-size: 16px; }
        .settings-section dl { margin: 0; }
        .settings-section dl > div { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 6px 16px; padding: 6px 0; }
        .settings-section dt { color: var(--muted); }
        .settings-section dd { margin: 0; overflow-wrap: anywhere; }
        .settings-section p { color: var(--muted); font-size: 12px; }
        .settings-sources { display: flex; flex-wrap: wrap; gap: 6px; }
        .settings-section table { width: 100%; table-layout: fixed; border-collapse: collapse; }
        .settings-section th, .settings-section td { text-align: left; padding: 8px 4px; border-bottom: 1px solid var(--line); overflow-wrap: anywhere; }
        #workspace:not(.showing-detail) .detail-pane, #workspace.showing-detail .list-pane { display: none; }
        #back { margin: 0 0 10px; }
        .sticky h2 { margin: 0 0 8px; font-size: 18px; line-height: 1.3; font-weight: 600; }
        .sticky .meta { margin: 0; }

        @media (min-width: 880px) {
          .top-nav { padding-left: max(20px, calc((100% - 920px) / 2)); padding-right: max(20px, calc((100% - 920px) / 2)); }
          #search-query { flex: 1 1 20rem; }
          .facet-picker { flex: 0 1 10rem; }
        }
        @media (max-width: 879px) {
          .top-nav { padding: 10px 16px; gap: 8px; }
          .top-nav .lede { display: none; }
          #workspace { padding: 0 16px 24px; }
          #search input, #search select { max-width: 100%; }
          #detail h2 {
            margin: 0 0 4px;
            font-size: 18px;
            line-height: 1.3;
            display: -webkit-box;
            -webkit-box-orient: vertical;
            -webkit-line-clamp: 3;
            overflow: hidden;
          }
        }
        .list-pane, .detail-pane { min-width: 0; }
        .session { display: block; width: 100%; text-align: left; border: 1px solid color-mix(in srgb, var(--line) 45%, transparent); border-radius: 8px; padding: 10px 12px; margin: 4px 0; background: transparent; cursor: pointer; }
        .session:hover, .session:focus-visible { border-color: var(--accent); background: var(--panel); color: var(--text); }
        .title { color: var(--text); font-weight: 600; line-height: 1.4; margin-bottom: 4px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
        .meta { color: var(--muted); display: flex; gap: 8px; flex-wrap: wrap; font-size: 12px; align-items: center; }
        .meta .sep { color: color-mix(in srgb, var(--muted) 70%, transparent); }
        .badge { display: inline-block; color: white; background: var(--source-color, #64748b); border-radius: 4px; padding: 1px 6px; font-size: 11px; font-weight: 600; }
        .source-codex { --source-color: #237a43; }
        .source-claude-code { --source-color: #a65b20; }
        .source-copilot, .source-vscode { --source-color: #64748b; }
        .source-gemini-cli, .source-antigravity { --source-color: #087e8b; }
        .source-kimi { --source-color: #b52273; }
        .source-qwen { --source-color: #087c70; }
        .source-qoder { --source-color: #2563eb; }
        .source-minimax { --source-color: #b93832; }
        .source-lobsterai { --source-color: #856400; }
        .source-commandcode { --source-color: #218343; }
        .source-cline { --source-color: #007f74; }
        .source-cursor { --source-color: #2476ac; }
        .source-windsurf { --source-color: #795548; }
        .source-opencode { --source-color: #535fa6; }
        .source-iflow { --source-color: #8547a0; }
        .source-pi { --source-color: #4a6d8c; }
        .source-grok { --source-color: #7a5c2e; }
        .sticky { position: sticky; top: 0; background: var(--bg); border-bottom: 1px solid var(--line); z-index: 2; padding: 12px 0 16px; }
        #messages { padding: 8px 0 24px; display: flex; flex-direction: column; gap: 14px; }
        .message { max-width: 86%; min-width: 0; }
        .message.user { align-self: flex-end; }
        .message.assistant { align-self: flex-start; }
        .message.tool, .message.system { align-self: stretch; max-width: 100%; }
        .role { color: var(--muted); font-size: 11px; font-weight: 700; margin: 0 8px 3px; }
        .user .role { text-align: right; }
        .message.assistant .role { color: var(--source-color, var(--muted)); }
        .message .body { min-width: 0; overflow-wrap: anywhere; margin: 0; padding: 12px 14px; border: 1px solid var(--line); border-radius: 14px; background: var(--panel); font: inherit; line-height: 1.6; }
        .message .body > * { margin: 0; }
        .message .body > * + * { margin-top: 0.55em; }
        .message .body p { overflow-wrap: anywhere; }
        .message .body h1, .message .body h2, .message .body h3, .message .body h4, .message .body h5, .message .body h6 { line-height: 1.3; font-weight: 650; }
        .message .body h1 { font-size: 1.25em; } .message .body h2 { font-size: 1.12em; } .message .body h3 { font-size: 1.05em; }
        .message .body ul, .message .body ol { padding-left: 1.4em; }
        .message .body li { margin: 0.12em 0; }
        .message .body hr { border: none; border-top: 1px solid var(--line); }
        .message .body .table-wrap { max-width: 100%; overflow-x: auto; }
        .message .body table { width: auto; max-width: none; border-collapse: collapse; font-size: 0.92em; overflow-wrap: normal; }
        .message .body th, .message .body td { border: 1px solid var(--line); padding: 0.25em 0.5em; }
        .message .body a { color: var(--accent); text-decoration: underline; }
        .message .body code { font: 0.88em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; padding: 0.1em 0.35em; border-radius: 4px; background: var(--code); }
        .message .body .code-block { margin: 0.15em 0; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; background: var(--code); }
        .message .body .code-header { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 0.35em 0.75em; font-size: 11px; color: var(--muted); border-bottom: 1px solid var(--line); }
        .message .body .copy-btn { margin: 0; padding: 2px 8px; }
        .message .body .code-block pre { margin: 0; padding: 0.75em; border: 0; border-radius: 0; background: transparent; white-space: pre; overflow-x: auto; }
        .message .body .code-block code { padding: 0; background: transparent; font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
        .user .body { border-color: color-mix(in srgb, var(--accent) 45%, var(--line)); background: color-mix(in srgb, var(--accent) 10%, var(--panel)); border-bottom-right-radius: 4px; }
        .message.assistant .body { border-bottom-left-radius: 4px; }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
        .user pre { border-color: color-mix(in srgb, var(--accent) 45%, var(--line)); background: color-mix(in srgb, var(--accent) 10%, var(--panel)); }
        details { margin-top: 6px; color: var(--muted); font-size: 12px; }
        details pre { margin-top: 6px; }
        .message details { padding: 0.5em 0.75em; border: 1px dashed color-mix(in srgb, var(--muted) 45%, transparent); border-radius: 8px; background: transparent; }
        .message.system > details { border-color: color-mix(in srgb, #f59e0b 35%, var(--line)); }
        .message.tool > details, .message details.tool-call { border-color: color-mix(in srgb, #a855f7 35%, var(--line)); }
        .message details summary { cursor: pointer; display: flex; gap: 0.5em; align-items: baseline; min-width: 0; }
        .message details .preview { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 400; }
        #more, #more-messages { display: block; margin: 0.35rem 0; }
        .empty { max-width: 960px; margin: 24px 20px; color: var(--muted); }
        .overview-summary { margin: 0 0 8px; color: var(--muted); }
        @media (max-width: 600px) {
          #files-content table, #usage-content table { min-width: 0; }
          #files-content thead, #usage-content thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
          #files-rows, #usage-rows { display: grid; gap: 12px; font-size: 14px; }
          #files-rows tr, #usage-rows tr { display: grid; gap: 12px; padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
          #files-rows tr { grid-template-columns: repeat(4, minmax(0, 1fr)); }
          #usage-rows tr { grid-template-columns: repeat(2, minmax(0, 1fr)); }
          #files-rows td, #usage-rows td { padding: 0; border: 0; text-align: left; min-width: 0; overflow-wrap: anywhere; }
          #files-rows td:first-child, #usage-rows td:nth-child(3) { grid-column: 1 / -1; }
          #files-rows td[data-label]::before, #usage-rows td[data-label]::before { content: attr(data-label); display: block; margin-bottom: 4px; color: var(--muted); font-size: 11px; }
        }
        """

    static let javascript = """
        const statusNode = document.getElementById("status");
        const overviewNode = document.getElementById("overview");
        const sessionsNode = document.getElementById("sessions");
        const detailNode = document.getElementById("detail");
        const messagesNode = document.getElementById("messages");
        const moreNode = document.getElementById("more");
        const moreMessagesNode = document.getElementById("more-messages");
        const backNode = document.getElementById("back");
        const signedOutNode = document.getElementById("signed-out");
        const workspaceNode = document.getElementById("workspace");
        const healthContent = document.getElementById("health-content");
        const healthStatus = document.getElementById("health-status");
        const statsFields = [["sessionCount", "Sessions"], ["messageCount", "Messages"], ["userMessageCount", "User"], ["assistantMessageCount", "Assistant"], ["toolMessageCount", "Tool"]];
        let statsSnapshot = "";
        let statsCursor = "";
        let statsFilters = "";
        let statsTotals = null;
        const costFields = [["costUsd", "Cost (USD)"], ["sessionCount", "Sessions"], ["inputTokens", "Input tokens"], ["outputTokens", "Output tokens"], ["cacheReadTokens", "Cache read"], ["cacheCreationTokens", "Cache write"]];
        let statsView = "sessions";
        let aiSnapshot = "", aiCursor = "", aiFilters = "", aiTotal = null;
        let aiDetailVersion = 0, aiStatsVersion = 0;
        let reposSnapshot = "", reposCursor = "", reposTotal = null;
        let filesSnapshot = "", filesCursor = "", filesFilters = "";
        let filesTotals = null;
        let toolsSnapshot = "", toolsCursor = "", toolsFilters = "";
        let toolsTotals = null;
        let costsSnapshot = "";
        let costsCursor = "";
        let costsFilters = "";
        let costsTotals = null;
        let detailReturnPage = null;
        const encoder = new TextEncoder();
        const decoder = new TextDecoder("utf-8", { fatal: true });
        let sessionSnapshotId = "";
        let sessionCursor = "";
        let sessionFilters = "";
        let agentFilter = "hide";
        const facets = {
          source: { selected: new Map(), items: new Map(), version: 0 },
          project: { selected: new Map(), items: new Map(), version: 0 }
        };
        let facetEpoch = 0;
        let messageSessionId = "";
        let messageGeneration = "";
        let sessionListScrollTop = 0;
        let messageCursor = "";
        let messageBuf = null;
        let messageRequest = null;
        let detailSource = "";
        let detailContextSession = "";
        let detailContextGeneration = "";
        let detailExtrasVersion = 0;
        let detailChildren = { loaded: false, busy: false, snapshot: "", cursor: "", seen: new Set(), items: [] };
        let sessionActionCanWrite = false, sessionActionPending = false, batchTitlePending = false;
        let detailRelationship = { canWrite: false, checking: false };
        let relationshipWritePending = false;
        let relationshipButtons = [];
        let detailTimeline = { loaded: false, busy: false, next: null, total: null, count: 0, lastIndex: -1 };
        let authWriteTail = null;
        let insightWriteVersion = 0, insightCanWrite = false, insightSavePending = false, savedInsightId = "";
        let insightVersion = 0, insightPage = null, insightBusy = false;
        let requestEpoch = 0;
        let activePage = "sessions";
        let searchStatusVersion = 0;
        let sessionPageSizes = [];
        let sessionPage = 0;
        let sessionTotal = null;
        let sessionPagingBusy = false;
        let settingsSnapshot = "";
        let settingsCursor = "";
        let settingsAliasRows = null;
        let settingsAccessVersion = 0;
        let settingsCanWrite = false;
        let settingsWriteBusy = false;
        let settingsDeleteButtons = [];
        let aiConfigVersion = 0, aiConfigSaved = null, aiConfigBusy = false, aiConfigUncertain = false;
        const aiConfigFields = [{"key": "aiProtocol", "label": "Protocol", "type": "choice", "choices": ["openai", "disabled"]}, {"key": "aiBaseURL", "label": "API base URL", "type": "text", "max": 2048}, {"key": "aiModel", "label": "Model", "type": "text", "max": 256}, {"key": "summaryLanguage", "label": "Language", "type": "text", "max": 64}, {"key": "summaryMaxSentences", "label": "Maximum sentences", "type": "number", "min": 1, "max": 20, "integer": true}, {"key": "summaryStyle", "label": "Style", "type": "text", "max": 512}, {"key": "summaryPrompt", "label": "Custom prompt", "type": "text", "max": 8000}, {"key": "summaryMaxTokens", "label": "Maximum output tokens", "type": "number", "min": 1, "max": 32768, "integer": true}, {"key": "summaryTemperature", "label": "Temperature", "type": "number", "min": 0, "max": 2, "integer": false}, {"key": "summarySampleFirst", "label": "First messages", "type": "number", "min": 0, "max": 200, "integer": true}, {"key": "summarySampleLast", "label": "Last messages", "type": "number", "min": 0, "max": 200, "integer": true}, {"key": "summaryTruncateChars", "label": "Characters per message", "type": "number", "min": 1, "max": 10000, "integer": true}, {"key": "titleProvider", "label": "Provider", "type": "choice", "choices": ["ollama", "custom", "openai"]}, {"key": "titleBaseUrl", "label": "API base URL", "type": "text", "max": 2048}, {"key": "titleModel", "label": "Model", "type": "text", "max": 256}, {"key": "embeddingBaseURL", "label": "API base URL", "type": "text", "max": 2048}, {"key": "embeddingModel", "label": "Model", "type": "text", "max": 256}, {"key": "embeddingDimension", "label": "Dimensions", "type": "number", "min": 1, "max": 65536, "integer": true}, {"key": "embeddingIncludeDimensions", "label": "Send dimensions to provider", "type": "boolean"}, {"key": "aiAudit.enabled", "label": "Record calls", "type": "boolean"}, {"key": "aiAudit.logBodies", "label": "Store redacted request and response bodies", "type": "boolean"}, {"key": "aiAudit.maxBodySize", "label": "Maximum stored body size", "type": "number", "min": 1, "max": 1000000, "integer": true}];
        let sourceSettingsVersion = 0;
        let sourceSettingsRows = new Map();
        let aliasProjectVersion = 0;
        let aliasProjects = new Map();
        let aliasProjectSnapshot = "";
        let aliasProjectCursor = "";
        let aliasProjectQuery = "";
        function bumpEpoch() {
          requestEpoch += 1;
          return requestEpoch;
        }
        function setText(node, value) {
          node.textContent = value == null ? "" : String(value);
        }
        // Search snippets carry only <mark>…</mark> highlight markers from the
        // service. Render those as real mark elements and everything else as
        // text nodes; never parse the snippet as HTML.
        function setHighlightedText(node, value) {
          setText(node, "");
          const text = value == null ? "" : String(value);
          const open = "<mark>";
          const close = "</mark>";
          let rest = text;
          while (rest.length) {
            const start = rest.indexOf(open);
            const end = start < 0 ? -1 : rest.indexOf(close, start + open.length);
            if (start < 0 || end < 0) {
              node.appendChild(textSpan(rest));
              break;
            }
            if (start > 0) node.appendChild(textSpan(rest.slice(0, start)));
            const mark = document.createElement("mark");
            setText(mark, rest.slice(start + open.length, end));
            node.appendChild(mark);
            rest = rest.slice(end + close.length);
          }
        }
        function setSignedIn(signedIn) {
          if (!signedIn) {
            clearFacets();
            setText(healthContent, "");
            setText(healthStatus, "");
            clearStats();
            clearCosts();
            clearTools();
            clearFiles();
            clearUsage();
            clearRepos();
            clearAi();
            detailReturnPage = null;
            clearSettings();
            clearSearchData();
          }
          signedOutNode.hidden = signedIn;
          workspaceNode.hidden = !signedIn;
          document.getElementById("login").hidden = signedIn;
          document.getElementById("logout").hidden = !signedIn;
          document.getElementById("lede").hidden = signedIn;
        }
        function expireSession() {
          setSignedIn(false);
          showSessionList();
          setText(overviewNode, "");
          setText(sessionsNode, "");
          setText(detailNode, "");
          clearSessionPaging();
          clearMessages();
          setText(statusNode, "Session expired");
          bumpEpoch();
        }
        function showSessionList() {
          activatePage(detailReturnPage || (activePage === "search" ? "search" : "sessions"));
          detailReturnPage = null;
          const wasDetail = workspaceNode.className === "showing-detail";
          workspaceNode.className = "";
          backNode.hidden = true;
          if (wasDetail) window.scrollTo({ top: sessionListScrollTop, behavior: "instant" });
        }
        function showSessionDetailPane() {
          activatePage(activePage === "search" ? "search" : "sessions");
          setText(backNode, detailReturnPage === "stats" ? (statsView === "tools" ? "Tools" : "Costs") : activePage === "search" ? "Search results" : "Sessions");
          if (workspaceNode.className !== "showing-detail") sessionListScrollTop = window.scrollY;
          workspaceNode.className = "showing-detail";
          backNode.hidden = false;
          window.scrollTo({ top: 0, behavior: "instant" });
        }
        function showDetailEmpty() {
          setText(detailNode, "");
          const empty = document.createElement("p");
          empty.className = "empty";
          setText(empty, "Select a session to read it.");
          detailNode.appendChild(empty);
        }
        function activatePage(page) {
          if (page !== "search") { clearInsights(); clearInsightComposer(); }
          activePage = ["sessions", "search", "stats", "health", "settings"].includes(page) ? page : "sessions";
          document.getElementById("library-page").hidden = !["sessions", "search"].includes(activePage);
          document.getElementById("health-page").hidden = activePage !== "health";
          document.getElementById("stats-page").hidden = activePage !== "stats";
          document.getElementById("settings-page").hidden = activePage !== "settings";
          document.getElementById("search-options").hidden = activePage !== "search";
          ["sessions", "search", "stats", "health", "settings"].forEach(function (name) {
            document.getElementById("nav-" + name).setAttribute("aria-current", name === activePage ? "page" : "false");
          });
        }
        async function navigate(page) {
          detailReturnPage = null;
          bumpEpoch();
          clearMessages();
          activatePage(page);
          if (activePage === "health") {
            setText(healthContent, "");
            setText(healthStatus, "Loading…");
            await loadOverview();
          } else if (activePage === "search") {
            await refreshLibrary();
          } else if (activePage === "settings") {
            await loadSettings(false);
          } else if (activePage === "stats") {
            await showStatsView("sessions");
          } else {
            await loadSessions(false);
          }
        }
        function restoreRequestedPage() {
          if (workspaceNode.hidden || !window.location.hash) return;
          const page = window.location.hash.slice(1);
          if (page === "stats" || page === "settings") return navigate(page);
          activatePage(page);
          if (page === "search") return loadSearchStatus();
        }
        function clearSearchData() {
          clearInsights();
          clearInsightComposer();
          searchStatusVersion += 1;
          setText(document.getElementById("search-capabilities"), "");
          setText(document.getElementById("search-result-status"), "");
          document.getElementById("mode-keyword").disabled = false;
          document.getElementById("mode-semantic").disabled = true;
          document.getElementById("mode-hybrid").disabled = true;
        }
        async function loadSearchStatus() {
          const version = ++searchStatusVersion;
          const status = document.getElementById("search-capabilities");
          const params = new URLSearchParams(sessionQuery(false).slice(1));
          ["query", "mode", "limit", "snapshotId", "cursor"].forEach(function (key) { params.delete(key); });
          setText(status, "Checking search availability…");
          try {
            const suffix = params.toString().replaceAll("+", "%20");
            const page = await api("GET", "/web/api/search/status" + (suffix ? "?" + suffix : ""));
            if (version !== searchStatusVersion) return;
            const modes = ["keyword", "semantic", "hybrid"];
            if (!page || modes.some(function (mode) { return !["available", "unavailable"].includes(page[mode]); })) throw new Error("invalid search status");
            modes.forEach(function (mode) { document.getElementById("mode-" + mode).disabled = page[mode] !== "available"; });
            const notes = [page.semantic === "available" ? "Semantic search ready" : "Semantic search unavailable"];
            if (Number.isSafeInteger(page.embeddedSessionCount) && Number.isSafeInteger(page.eligibleSessionCount)) {
              notes.push("Semantic index: " + page.embeddedSessionCount.toLocaleString("en-US") + " / " + page.eligibleSessionCount.toLocaleString("en-US") + " sessions" + (Number.isFinite(page.progressPercent) ? " (" + page.progressPercent + "%)" : ""));
            }
            if (page.model) notes.push(page.model);
            if (page.warning) notes.push(page.warning);
            setText(status, notes.join(" · "));
          } catch (error) {
            if (version === searchStatusVersion) {
              document.getElementById("mode-semantic").disabled = true;
              document.getElementById("mode-hybrid").disabled = true;
              setText(status, "Search status unavailable. Submit a search to retry.");
            }
          }
        }
        function refreshLibrary() {
          if (activePage !== "search") return loadSessions(false);
          setText(document.getElementById("search-result-status"), "");
          if (!document.getElementById("query").value.trim()) clearInsights();
          const results = document.getElementById("query").value.trim() ? loadRankedSearch() : loadSessions(false);
          return Promise.all([results, loadSearchStatus()]);
        }
        async function loadRankedSearch() {
          clearInsights();
          const token = bumpEpoch();
          clearSessionPaging();
          setText(sessionsNode, "");
          showSessionList();
          showDetailEmpty();
          clearMessages();
          const status = document.getElementById("search-result-status");
          const params = new URLSearchParams(sessionQuery(false).slice(1));
          const mode = document.getElementById("search-mode").value || "keyword";
          if (mode !== "keyword") params.set("mode", mode);
          params.set("limit", document.getElementById("search-limit").value || "10");
          setText(status, "Searching…");
          try {
            const page = await api("GET", "/web/api/search?" + params.toString().replaceAll("+", "%20"));
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || page.query !== params.get("query")) throw new Error("changed search");
            const items = page.items.map(function (hit) {
              if (!hit.session || typeof hit.session.sessionId !== "string") throw new Error("invalid search hit");
              return Object.assign({}, hit.session, { snippet: hit.snippet, matchType: hit.matchType });
            });
            acceptSessionsPage(false, { items: items });
            const modes = Array.isArray(page.searchModes) ? page.searchModes.join(" + ") : mode;
            const insightCount = renderInsights(page.insightResults || []);
            const counts = page.items.length + " sessions" + (insightCount ? " · " + insightCount + " insight" + (insightCount === 1 ? "" : "s") : "");
            setText(status, counts + " · " + (page.warning || modes));
          } catch (error) {
            if (token === requestEpoch) setText(status, "Search unavailable. Submit again to retry.");
          }
        }
        function updateInsightWriteControls() {
          document.getElementById("insight-save-form").hidden = !insightCanWrite;
          ["insight-content-input", "insight-wing-input", "insight-room-input", "insight-importance-input", "insight-source-input", "insight-save-button"].forEach(function (id) {
            document.getElementById(id).disabled = !insightCanWrite || insightSavePending;
          });
        }
        function clearInsightComposer() {
          insightWriteVersion += 1;
          insightCanWrite = false;
          savedInsightId = "";
          ["insight-content-input", "insight-wing-input", "insight-room-input", "insight-source-input"].forEach(function (id) { document.getElementById(id).value = ""; });
          document.getElementById("insight-importance-input").value = "5";
          document.getElementById("insight-compose").open = false;
          document.getElementById("insight-saved-read").hidden = true;
          setText(document.getElementById("insight-write-status"), "");
          updateInsightWriteControls();
        }
        async function loadInsightWriteAccess() {
          const version = ++insightWriteVersion;
          insightCanWrite = false;
          updateInsightWriteControls();
          const status = document.getElementById("insight-write-status");
          setText(status, "Checking edit access…");
          try {
            const access = await api("GET", "/web/api/auth");
            if (version !== insightWriteVersion || activePage !== "search") return;
            insightCanWrite = access && access.canWrite === true;
            setText(status, insightCanWrite ? "Save a note to your library. Keyword search is available immediately." : "Read only. Sign in with an editor key to save insights.");
          } catch (error) {
            if (version !== insightWriteVersion || activePage !== "search") return;
            setText(status, "Edit access unavailable. Close and reopen this section to retry.");
          }
          updateInsightWriteControls();
        }
        async function saveInsight() {
          if (!insightCanWrite || insightSavePending || activePage !== "search") return;
          const status = document.getElementById("insight-write-status");
          const content = document.getElementById("insight-content-input").value.trim();
          if (content.length < 10 || content.length > 50000) {
            setText(status, "Enter an insight between 10 and 50,000 characters."); return;
          }
          const importance = Number(document.getElementById("insight-importance-input").value);
          if (!Number.isInteger(importance) || importance < 0 || importance > 5) {
            setText(status, "Importance must be between 0 and 5."); return;
          }
          const body = { content: content, importance: importance };
          [["wing", "insight-wing-input"], ["room", "insight-room-input"], ["sourceSessionId", "insight-source-input"]].forEach(function (field) {
            const value = document.getElementById(field[1]).value.trim();
            if (value) body[field[0]] = value;
          });
          const version = insightWriteVersion;
          insightSavePending = true;
          updateInsightWriteControls();
          savedInsightId = "";
          document.getElementById("insight-saved-read").hidden = true;
          setText(status, "Saving…");
          try {
            const result = await api("POST", "/web/api/insights", JSON.stringify(body));
            if (version !== insightWriteVersion || activePage !== "search") return;
            if (!result || typeof result.id !== "string" || !result.id) throw new Error("invalid save result");
            savedInsightId = result.id;
            document.getElementById("insight-content-input").value = "";
            document.getElementById("insight-saved-read").hidden = false;
            setText(status, "Saved. " + (result.warning || "Find it with keyword search."));
          } catch (error) {
            if (version !== insightWriteVersion || activePage !== "search") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              insightCanWrite = false;
              setText(status, "Editor access required. Sign in again to save.");
            } else if (error.status === 400 || error.status === 404) {
              setText(status, "Could not save. Check the note and source session ID before retrying.");
            } else {
              setText(status, "Could not confirm the save. Search before retrying; your draft is preserved.");
            }
          } finally {
            insightSavePending = false;
            updateInsightWriteControls();
          }
        }
        document.getElementById("insight-compose").addEventListener("toggle", function () {
          if (this.open) loadInsightWriteAccess();
        });
        document.getElementById("insight-save-form").addEventListener("submit", function (event) {
          event.preventDefault(); saveInsight();
        });
        document.getElementById("insight-saved-read").addEventListener("click", function () {
          if (savedInsightId) loadInsight(savedInsightId, false);
        });
        function closeInsight() {
          insightVersion += 1;
          insightPage = null;
          insightBusy = false;
          const dialog = document.getElementById("insight-dialog");
          if (typeof dialog.close === "function") dialog.close();
          dialog.hidden = true;
          setText(document.getElementById("insight-body"), "");
          setText(document.getElementById("insight-detail-status"), "");
          document.getElementById("insight-more").hidden = true;
        }
        function clearInsights() {
          closeInsight();
          document.getElementById("insight-results").hidden = true;
          setText(document.getElementById("insight-rows"), "");
        }
        function renderInsights(items) {
          if (!Array.isArray(items) || items.length > 5) throw new Error("invalid insights");
          const rows = document.getElementById("insight-rows");
          setText(rows, "");
          items.forEach(function (item) {
            if (!item || typeof item.id !== "string" || !item.id || typeof item.content !== "string") throw new Error("invalid insight");
            const card = document.createElement("article");
            card.className = "insight-card";
            const label = document.createElement("span");
            label.className = "meta";
            setText(label, item.matchType === "semantic" ? "Semantic match" : "Keyword match");
            const preview = document.createElement("p");
            setText(preview, item.content);
            const read = document.createElement("button");
            read.type = "button";
            setText(read, "Read insight");
            read.addEventListener("click", function () { loadInsight(item.id, false); });
            card.appendChild(label); card.appendChild(preview); card.appendChild(read);
            rows.appendChild(card);
          });
          document.getElementById("insight-results").hidden = !items.length;
          return items.length;
        }
        async function loadInsight(id, more) {
          if (more && (insightBusy || !insightPage || insightPage.id !== id || insightPage.nextOffset == null)) return;
          if (!more) closeInsight();
          const version = ++insightVersion;
          const previous = more ? insightPage : null;
          const offset = previous ? previous.nextOffset : 0;
          const dialog = document.getElementById("insight-dialog");
          const body = document.getElementById("insight-body");
          const status = document.getElementById("insight-detail-status");
          const button = document.getElementById("insight-more");
          dialog.hidden = false;
          if (typeof dialog.showModal === "function" && !dialog.open) dialog.showModal();
          insightBusy = true;
          button.disabled = true;
          setText(status, "Loading insight…");
          const params = new URLSearchParams({ offset: String(offset), limit: "8000" });
          if (previous) params.set("revision", previous.revision);
          try {
            const page = await api("GET", "/web/api/insights/" + encodeURIComponent(id) + "?" + params.toString());
            if (version !== insightVersion) return;
            if (!page || page.id !== id || typeof page.revision !== "string" || !page.revision || page.offset !== offset || typeof page.content !== "string" || !Number.isSafeInteger(page.totalLength) || page.totalLength < 0) throw new Error("invalid insight");
            const end = offset + Array.from(page.content).length;
            if (end > page.totalLength || (previous && (page.revision !== previous.revision || page.totalLength !== previous.totalLength)) || (page.nextOffset != null ? page.nextOffset !== end || end <= offset || end >= page.totalLength : end !== page.totalLength)) throw new Error("changed insight");
            setText(body, (more ? body.textContent : "") + page.content);
            insightPage = page;
            button.hidden = page.nextOffset == null;
            setText(status, page.nextOffset == null ? "Complete · " + page.totalLength.toLocaleString("en-US") + " characters" : end.toLocaleString("en-US") + " of " + page.totalLength.toLocaleString("en-US") + " characters");
          } catch (error) {
            if (version !== insightVersion) return;
            insightPage = null;
            setText(body, "");
            button.hidden = true;
            setText(status, "Insight changed or is unavailable. Close and reopen it to retry.");
          } finally {
            if (version === insightVersion) { insightBusy = false; button.disabled = false; }
          }
        }
        document.getElementById("insight-close").addEventListener("click", closeInsight);
        document.getElementById("insight-dialog").addEventListener("cancel", closeInsight);
        document.getElementById("insight-more").addEventListener("click", function () {
          if (insightPage) loadInsight(insightPage.id, true);
        });
        function clearSettings() {
          aiConfigVersion += 1;
          aiConfigSaved = null;
          aiConfigUncertain = false;
          document.getElementById("ai-config").open = false;
          aiConfigFields.forEach(function (field) {
            const node = document.getElementById("ai-config-" + field.key);
            node.value = "";
            node.checked = false;
          });
          setText(document.getElementById("ai-config-status"), "");
          setText(document.getElementById("batch-title-status"), "");
          settingsAccessVersion += 1;
          sourceSettingsVersion += 1;
          sourceSettingsRows.clear();
          document.getElementById("source-settings").hidden = true;
          ["source-settings-rows", "source-settings-status", "source-write-status"].forEach(function (id) { setText(document.getElementById(id), ""); });
          aliasProjectVersion += 1;
          settingsCanWrite = false;
          settingsDeleteButtons = [];
          aliasProjects.clear();
          aliasProjectSnapshot = "";
          aliasProjectCursor = "";
          ["settings-access", "alias-status", "alias-project-status", "alias-canonical"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("alias-text").value = "";
          document.getElementById("alias-project-query").value = "";
          document.getElementById("alias-project-more").hidden = true;
          updateAliasControls();
          settingsSnapshot = "";
          settingsCursor = "";
          settingsAliasRows = null;
          setText(document.getElementById("settings-content"), "");
          setText(document.getElementById("settings-status"), "");
          document.getElementById("settings-more").hidden = true;
        }
        function renderSettings(summary) {
          const content = document.getElementById("settings-content");
          function section(title) {
            const element = document.createElement("section");
            element.className = "settings-section";
            const heading = document.createElement("h3");
            setText(heading, title);
            element.appendChild(heading);
            content.appendChild(element);
            return element;
          }
          function fields(element, values) {
            const list = document.createElement("dl");
            values.forEach(function (pair) {
              const row = document.createElement("div");
              const label = document.createElement("dt");
              const value = document.createElement("dd");
              setText(label, pair[0]);
              setText(value, pair[1]);
              row.appendChild(label);
              row.appendChild(value);
              list.appendChild(row);
            });
            element.appendChild(list);
          }
          fields(section("Database"), [["Visible sessions", summary.totalSessions.toLocaleString("en-US")], ["Web server", window.location.origin]]);
          const sources = section("Active Sources");
          const badges = document.createElement("div");
          badges.className = "settings-sources";
          summary.sources.forEach(function (source) {
            const badge = document.createElement("span");
            badge.className = "badge " + sourceClass(source.key);
            setText(badge, sourceLabel(source.key));
            badges.appendChild(badge);
          });
          if (!summary.sources.length) setText(badges, "No sources enabled.");
          sources.appendChild(badges);
          const sync = section("Sync");
          fields(sync, [["Node name", "Unavailable"], ["Peers", "Unavailable"]]);
          const retired = document.createElement("p");
          setText(retired, "Legacy peer-sync settings are retired in this runtime. Collectors publish captures to this server and its replicas; per-source heartbeats, last captures and replica acknowledgements are shown on the Health page.");
          sync.appendChild(retired);
          const healthLink = document.createElement("a");
          healthLink.href = "#health";
          setText(healthLink, "Open Health");
          sync.appendChild(healthLink);
          const unavailable = section("Not available in this deployment");
          const unavailableNote = document.createElement("p");
          setText(unavailableNote, "This Web runs on the central server and reads captured sessions only. The following legacy Web features read or acted on the machine that hosted the old Web and are intentionally not offered here:");
          unavailable.appendChild(unavailableNote);
          const unavailableList = document.createElement("ul");
          [
            "Skills, hooks, memory files and hygiene checks of a local machine — use the Engram app on that Mac.",
            "Live session events and monitor alerts — Health shows per-source capture, ingest and replica observations instead.",
            "Resume launch and link-sessions filesystem actions — run them on the machine that owns the session.",
            "Developer mock, lint and log utilities — development-only endpoints, not part of the Web."
          ].forEach(function (text) {
            const item = document.createElement("li");
            setText(item, text);
            unavailableList.appendChild(item);
          });
          unavailable.appendChild(unavailableList);
          const aliases = section("Project Aliases");
          const explanation = document.createElement("p");
          setText(explanation, "Project names linked across moved or renamed directories.");
          aliases.appendChild(explanation);
          const table = document.createElement("table");
          table.setAttribute("aria-label", "Project aliases");
          const head = document.createElement("thead");
          const row = document.createElement("tr");
          ["Old Project", "New Project", "Action"].forEach(function (text) {
            const cell = document.createElement("th");
            setText(cell, text);
            row.appendChild(cell);
          });
          head.appendChild(row);
          table.appendChild(head);
          settingsAliasRows = document.createElement("tbody");
          table.appendChild(settingsAliasRows);
          aliases.appendChild(table);
          if (!summary.aliases.length && !summary.nextCursor) {
            const empty = document.createElement("p");
            setText(empty, "No visible project aliases.");
            aliases.appendChild(empty);
          }
        }
        async function loadSettings(more) {
          if (more && (!settingsCursor || settingsWriteBusy)) return;
          const token = bumpEpoch();
          const status = document.getElementById("settings-status");
          const moreButton = document.getElementById("settings-more");
          const query = more ? "?" + new URLSearchParams({ snapshotId: settingsSnapshot, cursor: settingsCursor }).toString() : "";
          if (!more) clearSettings();
          setText(status, "Loading…");
          moreButton.disabled = true;
          try {
            const pendingPage = api("GET", "/web/api/settings" + query);
            if (!more) loadSettingsAccess();
            const page = await pendingPage;
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.sources) || !Array.isArray(page.aliases)
                || (more && page.snapshotId !== settingsSnapshot)) throw new Error("changed settings");
            if (!more) renderSettings(page);
            setText(statusNode, "signed in");
            page.aliases.forEach(function (alias) {
              const row = document.createElement("tr");
              [alias.aliasLabel || alias.alias, alias.canonicalLabel || alias.canonical].forEach(function (text) {
                const cell = document.createElement("td");
                setText(cell, text);
                row.appendChild(cell);
              });
              const action = document.createElement("td");
              const remove = document.createElement("button");
              remove.type = "button";
              setText(remove, "Delete");
              remove.setAttribute("aria-label", "Delete alias " + (alias.aliasLabel || alias.alias));
              remove.addEventListener("click", function () { mutateAlias("remove", { alias: alias.alias, canonical: alias.canonical }); });
              settingsDeleteButtons.push(remove);
              action.appendChild(remove);
              row.appendChild(action);
              settingsAliasRows.appendChild(row);
            });
            settingsSnapshot = page.snapshotId;
            settingsCursor = page.nextCursor || "";
            moreButton.hidden = !settingsCursor;
            setText(status, "Observed: " + healthTime(page.observedAt));
            updateAliasControls();
          } catch (error) {
            if (token === requestEpoch) setText(status, "Settings unavailable. Refresh to retry.");
          } finally {
            if (token === requestEpoch) moreButton.disabled = false;
          }
        }
        function updateAliasControls() {
          updateAISettingsControls();
          document.getElementById("batch-title-actions").hidden = !settingsCanWrite;
          document.getElementById("batch-title-button").disabled = !settingsCanWrite || batchTitlePending;
          document.getElementById("alias-editor").hidden = !settingsCanWrite;
          ["alias-add", "alias-text", "alias-canonical", "alias-project-search", "alias-project-query", "alias-project-more"].forEach(function (id) {
            document.getElementById(id).disabled = !settingsCanWrite || settingsWriteBusy;
          });
          document.getElementById("settings-refresh").disabled = settingsWriteBusy;
          sourceSettingsRows.forEach(function (entry) { entry.button.disabled = !settingsCanWrite || settingsWriteBusy; });
          settingsDeleteButtons.forEach(function (button) {
            button.hidden = !settingsCanWrite;
            button.disabled = !settingsCanWrite || settingsWriteBusy;
          });
        }
        async function loadSettingsAccess() {
          const version = settingsAccessVersion;
          const status = document.getElementById("settings-access");
          setText(status, "Checking edit access…");
          try {
            const access = await api("GET", "/web/api/auth");
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            settingsCanWrite = access && access.canWrite === true;
            setText(status, settingsCanWrite ? "Editor access" : "Read only. Sign in with an editor key to make changes.");
            updateAliasControls();
            loadSourceSettings();
            if (settingsCanWrite) loadAliasProjects(false);
          } catch (error) {
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            settingsCanWrite = false;
            setText(status, "Edit access unavailable. Refresh to retry.");
            updateAliasControls();
          }
        }
        function updateAISettingsControls() {
          const editable = settingsCanWrite && aiConfigSaved && !aiConfigBusy && !aiConfigUncertain;
          aiConfigFields.forEach(function (field) { document.getElementById("ai-config-" + field.key).disabled = !editable; });
          document.getElementById("ai-config-save").disabled = !editable;
          document.getElementById("ai-config-reload").disabled = aiConfigBusy;
        }
        function aiConfigValue(settings, key) {
          return key.startsWith("aiAudit.") ? settings.aiAudit && settings.aiAudit[key.slice(8)] : settings[key];
        }
        function validAIConfigValue(field, value) {
          if (field.type === "boolean") return typeof value === "boolean";
          if (field.type === "choice") return field.choices.includes(value);
          if (field.type === "text") return typeof value === "string" && value.length <= field.max;
          return typeof value === "number" && Number.isFinite(value) && value >= field.min && value <= field.max && (!field.integer || Number.isSafeInteger(value));
        }
        function renderAISettings(result) {
          if (!result || !result.settings || !aiConfigFields.every(function (field) { return validAIConfigValue(field, aiConfigValue(result.settings, field.key)); })) throw new Error("invalid AI settings");
          aiConfigSaved = result.settings;
          aiConfigFields.forEach(function (field) {
            const node = document.getElementById("ai-config-" + field.key);
            const value = aiConfigValue(aiConfigSaved, field.key);
            if (field.type === "boolean") node.checked = value;
            else node.value = String(value);
          });
          aiConfigUncertain = false;
        }
        async function loadAISettings() {
          if (activePage !== "settings" || aiConfigBusy) return;
          const version = ++aiConfigVersion;
          const status = document.getElementById("ai-config-status");
          aiConfigBusy = true;
          updateAISettingsControls();
          setText(status, "Loading saved settings…");
          try {
            const result = await api("GET", "/web/api/settings/ai");
            if (version !== aiConfigVersion || activePage !== "settings") return;
            renderAISettings(result);
            setText(status, settingsCanWrite ? "Edit values and save your changes." : "Read only. Sign in with an editor key to change settings.");
          } catch (error) {
            if (version !== aiConfigVersion || activePage !== "settings") return;
            aiConfigSaved = null;
            setText(status, "Settings unavailable. Reload to retry.");
          } finally {
            aiConfigBusy = false;
            updateAISettingsControls();
          }
        }
        async function saveAISettings() {
          if (activePage !== "settings" || !settingsCanWrite || !aiConfigSaved || aiConfigBusy || aiConfigUncertain) return;
          const patch = {}, values = {};
          const status = document.getElementById("ai-config-status");
          for (const field of aiConfigFields) {
            const node = document.getElementById("ai-config-" + field.key);
            const value = field.type === "boolean" ? node.checked : field.type === "number" ? (node.value.trim() ? Number(node.value) : NaN) : node.value;
            if (!validAIConfigValue(field, value)) { setText(status, "Check " + field.label + " before saving."); return; }
            if (field.key.startsWith("aiAudit.")) {
              if (!values.aiAudit) values.aiAudit = {};
              values.aiAudit[field.key.slice(8)] = value;
            } else values[field.key] = value;
            if (value !== aiConfigValue(aiConfigSaved, field.key)) {
              if (field.key.startsWith("aiAudit.")) patch.aiAudit = true;
              else patch[field.key] = value;
            }
          }
          if (patch.aiAudit) patch.aiAudit = values.aiAudit;
          if (!Object.keys(patch).length) { setText(status, "No changes to save."); return; }
          const version = aiConfigVersion;
          aiConfigBusy = true;
          updateAISettingsControls();
          setText(status, "Saving…");
          try {
            const result = await api("POST", "/web/api/settings/ai", JSON.stringify(patch));
            if (version !== aiConfigVersion || activePage !== "settings") return;
            renderAISettings(result);
            setText(status, "Saved. Environment overrides still take precedence; existing vectors are unchanged.");
          } catch (error) {
            if (version !== aiConfigVersion || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) settingsCanWrite = false;
            aiConfigUncertain = true;
            setText(status, "Could not confirm saving. Your draft is retained. Reload saved settings before retrying.");
          } finally {
            aiConfigBusy = false;
            updateAliasControls();
          }
        }
        document.getElementById("ai-config").addEventListener("toggle", function () {
          if (this.open && !aiConfigSaved) loadAISettings();
        });
        document.getElementById("ai-config-form").addEventListener("submit", function (event) { event.preventDefault(); saveAISettings(); });
        document.getElementById("ai-config-reload").addEventListener("click", loadAISettings);
        async function loadSourceSettings() {
          const version = ++sourceSettingsVersion;
          const accessVersion = settingsAccessVersion;
          const status = document.getElementById("source-settings-status");
          setText(status, "Loading source settings…");
          try {
            const result = await api("GET", "/web/api/settings/sources");
            if (version !== sourceSettingsVersion || accessVersion !== settingsAccessVersion || activePage !== "settings") return;
            if (!result || !Array.isArray(result.sources) || result.sources.some(function (item) {
              return !item || typeof item.key !== "string" || typeof item.enabled !== "boolean";
            })) throw new Error("invalid source settings");
            sourceSettingsRows.clear();
            const rows = document.getElementById("source-settings-rows");
            setText(rows, "");
            result.sources.forEach(function (item) {
              const row = document.createElement("tr");
              [sourceLabel(item.key), item.enabled ? "Enabled" : "Disabled"].forEach(function (text) {
                const cell = document.createElement("td");
                setText(cell, text);
                row.appendChild(cell);
              });
              const action = document.createElement("td");
              const button = document.createElement("button");
              button.type = "button";
              setText(button, item.enabled ? "Disable" : "Enable");
              button.setAttribute("aria-label", (item.enabled ? "Disable " : "Enable ") + sourceLabel(item.key));
              button.addEventListener("click", function () { setWebSourceEnabled(item.key, !item.enabled); });
              action.appendChild(button);
              row.appendChild(action);
              rows.appendChild(row);
              sourceSettingsRows.set(item.key, { item: item, button: button });
            });
            document.getElementById("source-settings").hidden = false;
            setText(status, result.sources.length ? "" : "No sources reported.");
            if (!settingsSnapshot && result.sources.length && result.sources.every(function (item) { return !item.enabled; })) {
              setText(document.getElementById("settings-status"), "All sources are disabled. Enable a source below to show sessions.");
              setText(statusNode, "signed in");
            }
            updateAliasControls();
          } catch (error) {
            if (version === sourceSettingsVersion && accessVersion === settingsAccessVersion && activePage === "settings") {
              setText(status, "Source settings unavailable. Refresh to retry.");
            }
          }
        }
        async function setWebSourceEnabled(source, enabled) {
          if (!settingsCanWrite || settingsWriteBusy || activePage !== "settings" || !sourceSettingsRows.has(source) || typeof enabled !== "boolean") return;
          const token = requestEpoch;
          settingsWriteBusy = true;
          updateAliasControls();
          const status = document.getElementById("source-write-status");
          setText(status, "Saving source setting…");
          try {
            const result = await api("POST", "/web/api/settings/sources", JSON.stringify({ source: source, enabled: enabled }));
            if (token !== requestEpoch || activePage !== "settings") return;
            if (!result || result.source !== source || result.enabled !== enabled) throw new Error("unconfirmed source setting");
            const refreshed = loadSettings(false);
            const refreshEpoch = requestEpoch;
            await refreshed;
            if (refreshEpoch === requestEpoch && activePage === "settings") setText(status, sourceLabel(source) + (enabled ? " enabled." : " disabled."));
          } catch (error) {
            if (token !== requestEpoch || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              settingsCanWrite = false;
              setText(status, "Editor access required. Sign in again to edit.");
            } else setText(status, "Could not confirm the change. Refresh settings before retrying.");
          } finally {
            settingsWriteBusy = false;
            updateAliasControls();
          }
        }
        async function loadAliasProjects(more) {
          if (!settingsCanWrite || (more && !aliasProjectCursor)) return;
          const version = ++aliasProjectVersion;
          const accessVersion = settingsAccessVersion;
          const status = document.getElementById("alias-project-status");
          const select = document.getElementById("alias-canonical");
          if (!more) {
            aliasProjects.clear();
            aliasProjectSnapshot = "";
            aliasProjectCursor = "";
            aliasProjectQuery = document.getElementById("alias-project-query").value.trim();
            setText(select, "");
            select.value = "";
          }
          const params = new URLSearchParams({ kind: "project" });
          if (aliasProjectQuery) params.set("query", aliasProjectQuery);
          if (more) { params.set("snapshotId", aliasProjectSnapshot); params.set("cursor", aliasProjectCursor); }
          setText(status, "Loading projects…");
          document.getElementById("alias-project-more").disabled = true;
          try {
            const page = await api("GET", "/web/api/facets?" + params.toString().replaceAll("+", "%20"));
            if (version !== aliasProjectVersion || accessVersion !== settingsAccessVersion || activePage !== "settings") return;
            if (!page || !Array.isArray(page.items) || !page.snapshotId || (more && page.snapshotId !== aliasProjectSnapshot)) throw new Error("changed projects");
            aliasProjectSnapshot = page.snapshotId;
            aliasProjectCursor = page.nextCursor || "";
            page.items.forEach(function (item) {
              if (aliasProjects.has(item.key)) return;
              aliasProjects.set(item.key, item);
              const option = document.createElement("option");
              option.value = item.key;
              setText(option, item.label || item.key);
              select.appendChild(option);
            });
            if (!select.value && aliasProjects.size) select.value = aliasProjects.keys().next().value;
            setText(status, aliasProjects.size ? "" : "No matching projects.");
          } catch (error) {
            if (version === aliasProjectVersion && accessVersion === settingsAccessVersion && activePage === "settings") setText(status, "Projects unavailable. Find again to retry.");
          } finally {
            if (version === aliasProjectVersion && accessVersion === settingsAccessVersion) {
              document.getElementById("alias-project-more").hidden = !aliasProjectCursor;
              updateAliasControls();
            }
          }
        }
        async function addAlias() {
          const alias = document.getElementById("alias-text").value.trim();
          const canonical = document.getElementById("alias-canonical").value;
          if (!alias || !aliasProjects.has(canonical)) {
            setText(document.getElementById("alias-status"), "Enter an old name or path and select a destination project.");
            return;
          }
          await mutateAlias("add", { alias: alias, canonical: canonical });
        }
        async function mutateAlias(action, pair) {
          if (!settingsCanWrite || settingsWriteBusy || activePage !== "settings") return;
          const token = requestEpoch;
          settingsWriteBusy = true;
          updateAliasControls();
          const status = document.getElementById("alias-status");
          setText(status, "Saving…");
          try {
            const result = await api(action === "add" ? "POST" : "DELETE", "/web/api/settings/aliases", JSON.stringify(pair));
            if (token !== requestEpoch || activePage !== "settings") return;
            if (!result || result.action !== action || (result.changed !== 0 && result.changed !== 1)) throw new Error("invalid write result");
            const refreshed = loadSettings(false);
            const refreshEpoch = requestEpoch;
            await refreshed;
            if (refreshEpoch === requestEpoch && activePage === "settings") setText(status, result.changed ? (action === "add" ? "Alias added." : "Alias removed.") : "No change was needed.");
          } catch (error) {
            if (token !== requestEpoch || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              settingsCanWrite = false;
              setText(status, "Editor access required. Sign in again to edit.");
            } else setText(status, "Could not confirm the change. Refresh settings before retrying.");
          } finally {
            settingsWriteBusy = false;
            updateAliasControls();
          }
        }
        function clearStats() {
          statsSnapshot = "";
          statsCursor = "";
          statsFilters = "";
          statsTotals = null;
          ["stats-rows", "stats-totals", "stats-status"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("stats-more").hidden = true;
        }
        async function loadStats(more) {
          if (more && !statsCursor) return;
          const token = bumpEpoch();
          const status = document.getElementById("stats-status");
          const moreButton = document.getElementById("stats-more");
          if (!more) clearStats();
          const params = new URLSearchParams(more ? statsFilters : { groupBy: document.getElementById("stats-group").value || "source" });
          if (more) {
            params.set("snapshotId", statsSnapshot);
            params.set("cursor", statsCursor);
          } else {
            const since = document.getElementById("stats-since").value;
            const until = document.getElementById("stats-until").value;
            const agents = document.getElementById("stats-agents").value || "hide";
            if (since) params.set("since", since);
            if (until) params.set("until", until);
            if (agents !== "hide") params.set("agents", agents);
            if (document.getElementById("stats-noise").checked) params.set("excludeNoise", "true");
            statsFilters = params.toString();
          }
          setText(status, "Loading…");
          moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/stats?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || !page.totals || page.groupBy !== params.get("groupBy")
                || (more && page.snapshotId !== statsSnapshot)
                || (statsTotals && statsFields.some(function (field) { return statsTotals[field[0]] !== page.totals[field[0]]; }))) throw new Error("changed statistics");
            statsSnapshot = page.snapshotId;
            statsCursor = page.nextCursor || "";
            statsTotals = page.totals;
            const totals = document.getElementById("stats-totals");
            setText(totals, "");
            statsFields.forEach(function (field) {
              const group = document.createElement("div");
              const label = document.createElement("dt");
              const value = document.createElement("dd");
              setText(label, field[1]);
              setText(value, page.totals[field[0]].toLocaleString("en-US"));
              group.appendChild(label);
              group.appendChild(value);
              totals.appendChild(group);
            });
            page.items.forEach(function (item) {
              const row = document.createElement("tr");
              const label = document.createElement("td");
              setText(label, page.groupBy === "source" ? sourceLabel(item.key) : item.label);
              row.appendChild(label);
              statsFields.forEach(function (field) {
                const value = document.createElement("td");
                setText(value, item[field[0]].toLocaleString("en-US"));
                row.appendChild(value);
              });
              document.getElementById("stats-rows").appendChild(row);
            });
            setText(status, "Grouped by " + page.groupBy + " · " + page.timeZone + " · Observed: " + healthTime(page.observedAt));
            moreButton.hidden = !statsCursor;
          } catch (error) {
            if (token === requestEpoch) setText(status, "Statistics unavailable. Apply filters to retry.");
          } finally {
            if (token === requestEpoch) moreButton.disabled = false;
          }
        }
        async function showStatsView(view) {
          statsView = view;
          ["sessions", "costs", "tools", "files", "usage", "repos", "ai"].forEach(function (name) {
            document.getElementById(name === "sessions" ? "stats-content" : name + "-content").hidden = view !== name;
            document.getElementById("stats-view-" + name).setAttribute("aria-pressed", view === name ? "true" : "false");
          });
          if (view === "ai") await loadAiAudit(false);
          else if (view === "repos") await loadRepos(false);
          else if (view === "usage") await loadUsage();
          else if (view === "files") await loadFiles(false);
          else if (view === "tools") await loadTools(false);
          else if (view === "costs") await loadCosts(false);
          else await loadStats(false);
        }
        function clearAi() {
          aiSnapshot = ""; aiCursor = ""; aiFilters = ""; aiTotal = null;
          ["ai-status", "ai-rows", "ai-detail", "ai-stats", "ai-stats-status"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("ai-more").hidden = true;
          document.getElementById("ai-detail").hidden = true;
        }
        function aiCounts(parent, pairs, large) {
          const counts = document.createElement("dl"); counts.className = large ? "stats-totals" : "ai-counts";
          pairs.forEach(function (pair) {
            const label = document.createElement("dt"), value = document.createElement("dd");
            setText(label, pair[0]); setText(value, typeof pair[1] === "number" ? costValue(pair[1], "value") : pair[1] == null ? "Not reported" : pair[1]);
            const pairNode = large ? document.createElement("div") : counts;
            pairNode.appendChild(label); pairNode.appendChild(value); if (large) counts.appendChild(pairNode);
          }); parent.appendChild(counts);
        }
        function aiCard(item, detail) {
          const card = document.createElement("article"); card.className = "health-card";
          const title = document.createElement("h3"); setText(title, item.caller + " · " + item.operation); card.appendChild(title);
          const when = document.createElement("p"); when.className = "meta"; setText(when, healthTime(item.at) + " · " + (item.hasError ? "Error" : "Success") + (item.statusCode == null ? "" : " · HTTP " + item.statusCode)); card.appendChild(when);
          const model = document.createElement("p"); setText(model, item.model || "Model not reported"); card.appendChild(model);
          aiCounts(card, [["Duration (ms)", item.durationMs], ["Input tokens", item.promptTokens], ["Output tokens", item.completionTokens], ["Total tokens", item.totalTokens]]);
          if (item.error) { const error = document.createElement("p"); setText(error, item.error); card.appendChild(error); }
          if (detail) {
            aiCounts(card, [["Call ID", item.id], ["Provider", item.provider], ["Method", item.method], ["Endpoint", item.url], ["Session ID", item.sessionId]]);
          } else {
            const button = document.createElement("button"); button.type = "button"; setText(button, "View call");
            button.addEventListener("click", function () { loadAiDetail(item.id); }); card.appendChild(button);
          }
          return card;
        }
        async function loadAiAudit(more) {
          if (more && !aiCursor) return;
          const token = bumpEpoch(); if (!more) clearAi();
          const status = document.getElementById("ai-status"), button = document.getElementById("ai-more");
          const params = new URLSearchParams(more ? aiFilters : "");
          if (more) { params.set("snapshotId", aiSnapshot); params.set("cursor", aiCursor); }
          else {
            [["caller", "ai-caller"], ["model", "ai-model"], ["sessionId", "ai-session"], ["from", "ai-from"], ["to", "ai-to"], ["hasError", "ai-errors"]].forEach(function (pair) {
              const value = document.getElementById(pair[1]).value.trim(); if (value) params.set(pair[0], value);
            }); aiFilters = params.toString();
          }
          setText(status, "Loading…"); button.disabled = true;
          try {
            const page = await api("GET", "/web/api/ai/audit?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || !Number.isSafeInteger(page.total)
                || (more && (page.snapshotId !== aiSnapshot || page.nextCursor === aiCursor))
                || (aiTotal !== null && page.total !== aiTotal)) throw new Error("changed AI observations");
            aiSnapshot = page.snapshotId; aiCursor = page.nextCursor || ""; aiTotal = page.total;
            page.items.forEach(function (item) { document.getElementById("ai-rows").appendChild(aiCard(item, false)); });
            setText(status, page.total ? page.total.toLocaleString("en-US") + " calls · Observed: " + healthTime(page.observedAt) : "No recorded AI calls for these filters.");
            button.hidden = !aiCursor;
          } catch (error) { if (token === requestEpoch) setText(status, "AI call history unavailable. Find calls to retry."); }
          finally { if (token === requestEpoch) button.disabled = false; }
        }
        async function loadAiDetail(id) {
          const token = requestEpoch, version = ++aiDetailVersion, detail = document.getElementById("ai-detail");
          detail.hidden = false; setText(detail, "Loading call…");
          try {
            const page = await api("GET", "/web/api/ai/audit/" + encodeURIComponent(id));
            if (token !== requestEpoch || version !== aiDetailVersion) return;
            if (!page || !page.item || page.item.id !== id) throw new Error("invalid call");
            setText(detail, ""); detail.appendChild(aiCard(page.item, true));
            aiCounts(detail, [["Request body", page.hasRequestBody ? "Stored" : "Not stored"], ["Response body", page.hasResponseBody ? "Stored" : "Not stored"]]);
            const note = document.createElement("p"); note.className = "meta"; setText(note, "Message bodies are not included in this view."); detail.appendChild(note);
            if (typeof detail.scrollIntoView === "function") detail.scrollIntoView({ block: "start" });
          } catch (error) { if (token === requestEpoch && version === aiDetailVersion) setText(detail, "Call unavailable or no longer visible."); }
        }
        async function loadAiStats() {
          const token = requestEpoch, version = ++aiStatsVersion, status = document.getElementById("ai-stats-status"), content = document.getElementById("ai-stats");
          setText(content, ""); setText(status, "Loading statistics…");
          const params = new URLSearchParams();
          ["from", "to"].forEach(function (key) { const value = document.getElementById("ai-" + key).value; if (value) params.set(key, value); });
          try {
            const page = await api("GET", "/web/api/ai/stats?" + params.toString());
            if (token !== requestEpoch || version !== aiStatsVersion) return;
            if (!page || !page.totals || !page.timeRange || !Array.isArray(page.byCaller) || !Array.isArray(page.byModel) || !Array.isArray(page.hourly)) throw new Error("invalid AI statistics");
            aiCounts(content, [["Requests", page.totals.requests], ["Errors", page.totals.errors], ["Input tokens", page.totals.promptTokens], ["Output tokens", page.totals.completionTokens], ["Average duration (ms)", page.totals.avgDurationMs]], true);
            [["By caller", page.byCaller], ["By model", page.byModel], ["Hourly (UTC)", page.hourly]].forEach(function (group) {
              const section = document.createElement("details"); section.open = true;
              const heading = document.createElement("summary"); setText(heading, group[0]); section.appendChild(heading);
              const rows = document.createElement("div"); rows.className = "health-grid";
              group[1].forEach(function (item) {
                const card = document.createElement("article"); card.className = "health-card";
                const title = document.createElement("h3"); setText(title, item.hour ? item.hour + " UTC" : item.key); card.appendChild(title);
                const pairs = [["Requests", item.requests]];
                if (item.hour) pairs.push(["Tokens", item.tokens]);
                else { if (item.errors != null) pairs.push(["Errors", item.errors]); pairs.push(["Input tokens", item.promptTokens], ["Output tokens", item.completionTokens]); }
                aiCounts(card, pairs); rows.appendChild(card);
              }); section.appendChild(rows); content.appendChild(section);
            });
            setText(status, page.timeRange.from + " → " + page.timeRange.to + " · Date range only");
          } catch (error) { if (token === requestEpoch && version === aiStatsVersion) setText(status, "AI statistics unavailable. View statistics to retry."); }
        }
        function clearRepos() {
          reposSnapshot = ""; reposCursor = ""; reposTotal = null;
          setText(document.getElementById("repos-rows"), ""); setText(document.getElementById("repos-status"), "");
          document.getElementById("repos-more").hidden = true;
        }
        async function loadRepos(more) {
          if (more && !reposCursor) return;
          const token = bumpEpoch(); if (!more) clearRepos();
          const status = document.getElementById("repos-status"), moreButton = document.getElementById("repos-more");
          const params = new URLSearchParams();
          if (more) { params.set("snapshotId", reposSnapshot); params.set("cursor", reposCursor); }
          setText(status, "Loading…"); moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/repos?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || page.scope !== "serverFilesystem" || !Array.isArray(page.items) || !Number.isSafeInteger(page.totalRepos)
                || (more && (page.snapshotId !== reposSnapshot || page.nextCursor === reposCursor))
                || (reposTotal !== null && reposTotal !== page.totalRepos)) throw new Error("changed repository observations");
            reposSnapshot = page.snapshotId; reposCursor = page.nextCursor || ""; reposTotal = page.totalRepos;
            page.items.forEach(function (item) {
              const card = document.createElement("article"); card.className = "health-card";
              const title = document.createElement("h3"); setText(title, item.name); card.appendChild(title);
              const branch = document.createElement("p"); branch.className = "meta"; setText(branch, item.branch || "Branch not reported"); card.appendChild(branch);
              const counts = document.createElement("dl");
              [["Dirty", item.dirtyCount], ["Untracked", item.untrackedCount], ["Unpushed", item.unpushedCount], ["Sessions", item.sessionCount]].forEach(function (pair) {
                const label = document.createElement("dt"), value = document.createElement("dd"); setText(label, pair[0]); setText(value, costValue(pair[1], "count")); counts.appendChild(label); counts.appendChild(value);
              }); card.appendChild(counts);
              const commit = document.createElement("p"); setText(commit, item.lastCommitMessage || "Commit not reported"); card.appendChild(commit);
              const last = document.createElement("p"); last.className = "meta";
              setText(last, (item.lastCommitHash ? item.lastCommitHash.slice(0, 12) + " · " : "") + healthTime(item.lastCommitAt)); card.appendChild(last);
              const observed = document.createElement("p"); observed.className = "meta"; setText(observed, "Probed: " + healthTime(item.probedAt)); card.appendChild(observed);
              document.getElementById("repos-rows").appendChild(card);
            });
            setText(status, page.totalRepos.toLocaleString("en-US") + " repositories · Observations from this server’s filesystem.");
            moreButton.hidden = !reposCursor;
          } catch (error) {
            if (token === requestEpoch) setText(status, "Repository observations unavailable. Reload observations to retry.");
          } finally { if (token === requestEpoch) moreButton.disabled = false; }
        }
        function clearUsage() {
          setText(document.getElementById("usage-rows"), "");
          setText(document.getElementById("usage-status"), "");
        }
        function recordedTime(value) {
          return healthTime(typeof value === "string" ? Math.floor(Date.parse(value) / 1000) : value);
        }
        async function loadUsage() {
          const token = bumpEpoch(); clearUsage();
          const status = document.getElementById("usage-status"), refresh = document.getElementById("usage-refresh");
          setText(status, "Loading…"); refresh.disabled = true;
          try {
            const page = await api("GET", "/web/api/usage");
            if (token !== requestEpoch) return;
            if (!page || page.scope !== "server" || !Array.isArray(page.items)) throw new Error("invalid usage");
            page.items.forEach(function (item) {
              const row = document.createElement("tr");
              const unit = item.unit ? " " + item.unit : "";
              const amount = costValue(item.value, "value") + unit + (item.limit == null ? "" : " / " + costValue(item.limit, "value") + unit);
              [sourceLabel(item.source), item.metric, amount, item.basis === "indexedSessions" ? "Indexed sessions" : "Reported",
               item.status || "Not reported", recordedTime(item.resetAt), recordedTime(item.collectedAt)].forEach(function (value, index) {
                const cell = document.createElement("td"); cell.setAttribute("data-label", ["Source", "Metric", "Value / limit", "Basis", "Status", "Resets", "Collected"][index]); setText(cell, value); row.appendChild(cell);
              });
              document.getElementById("usage-rows").appendChild(row);
            });
            setText(status, page.items.length ? "Recorded by this server. Indexed-session metrics are estimates from recorded sessions." : "No recorded usage on this server.");
          } catch (error) {
            if (token === requestEpoch) setText(status, "Usage unavailable. Reload observations to retry.");
          } finally { if (token === requestEpoch) refresh.disabled = false; }
        }
        function clearFiles() {
          filesSnapshot = ""; filesCursor = ""; filesFilters = ""; filesTotals = null;
          ["files-status", "files-totals", "files-rows"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("files-more").hidden = true;
        }
        async function loadFiles(more) {
          if (more && !filesCursor) return;
          const token = bumpEpoch();
          const status = document.getElementById("files-status"), moreButton = document.getElementById("files-more");
          if (!more) clearFiles();
          const params = new URLSearchParams(more ? filesFilters : "");
          if (more) {
            params.set("snapshotId", filesSnapshot); params.set("cursor", filesCursor);
          } else {
            ["project", "since", "until", "agents"].forEach(function (name) {
              const value = document.getElementById("files-" + name).value.trim();
              if (value && !(name === "agents" && value === "hide")) params.set(name, value);
            });
            filesFilters = params.toString();
          }
          setText(status, "Loading…"); moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/file-activity?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || !Number.isSafeInteger(page.totalFiles) || !Number.isSafeInteger(page.totalOperations)
                || (more && (page.snapshotId !== filesSnapshot || page.nextCursor === filesCursor))
                || (filesTotals && (filesTotals.files !== page.totalFiles || filesTotals.operations !== page.totalOperations))) throw new Error("changed file activity");
            filesSnapshot = page.snapshotId; filesCursor = page.nextCursor || "";
            filesTotals = {files: page.totalFiles, operations: page.totalOperations};
            setText(document.getElementById("files-totals"), page.totalFiles.toLocaleString("en-US") + " files · " + page.totalOperations.toLocaleString("en-US") + " operations");
            page.items.forEach(function (item) {
              const row = document.createElement("tr"), label = document.createElement("td"); setText(label, item.label); row.appendChild(label);
              ["readCount", "editCount", "writeCount", "sessionCount"].forEach(function (field, index) {
                const cell = document.createElement("td"); cell.setAttribute("data-label", ["Reads", "Edits", "Writes", "Sessions"][index]); setText(cell, costValue(item[field], field)); row.appendChild(cell);
              });
              document.getElementById("files-rows").appendChild(row);
            });
            setText(status, page.totalFiles ? "Most active files · Observed: " + healthTime(page.observedAt) : "No file activity in this range");
            moreButton.hidden = !filesCursor;
          } catch (error) {
            if (token === requestEpoch) setText(status, "File activity unavailable. Apply filters to retry.");
          } finally { if (token === requestEpoch) moreButton.disabled = false; }
        }
        function clearTools() {
          toolsSnapshot = ""; toolsCursor = ""; toolsFilters = ""; toolsTotals = null;
          ["tools-status", "tools-totals", "tools-rows"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("tools-more").hidden = true;
        }
        async function loadTools(more) {
          if (more && !toolsCursor) return;
          const token = bumpEpoch();
          const status = document.getElementById("tools-status"), moreButton = document.getElementById("tools-more");
          if (!more) clearTools();
          const params = new URLSearchParams(more ? toolsFilters : { groupBy: document.getElementById("tools-group").value || "tool" });
          if (more) {
            params.set("snapshotId", toolsSnapshot); params.set("cursor", toolsCursor);
          } else {
            ["project", "since", "until", "agents"].forEach(function (name) {
              const value = document.getElementById("tools-" + name).value.trim();
              if (value && !(name === "agents" && value === "hide")) params.set(name, value);
            });
            toolsFilters = params.toString();
          }
          setText(status, "Loading…"); moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/tool-analytics?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || page.groupBy !== params.get("groupBy")
                || !Number.isSafeInteger(page.totalCalls) || !Number.isSafeInteger(page.groupCount)
                || (more && (page.snapshotId !== toolsSnapshot || page.nextCursor === toolsCursor))
                || (toolsTotals && (toolsTotals.calls !== page.totalCalls || toolsTotals.groups !== page.groupCount))) throw new Error("changed tool activity");
            toolsSnapshot = page.snapshotId; toolsCursor = page.nextCursor || "";
            toolsTotals = {calls: page.totalCalls, groups: page.groupCount};
            setText(document.getElementById("tools-totals"), page.totalCalls.toLocaleString("en-US") + " calls · " + page.groupCount.toLocaleString("en-US") + " groups");
            page.items.forEach(function (item) {
              const row = document.createElement("tr"), label = document.createElement("td");
              if (page.groupBy === "session" && item.sessionId) {
                const button = document.createElement("button"); button.type = "button"; setText(button, item.label);
                button.addEventListener("click", function () { openDetail(item.sessionId, "stats").catch(function () {}); });
                label.appendChild(button);
              } else setText(label, item.label);
              row.appendChild(label);
              ["callCount", "sessionCount", "toolCount"].forEach(function (field) {
                const cell = document.createElement("td"); setText(cell, costValue(item[field], field)); row.appendChild(cell);
              });
              document.getElementById("tools-rows").appendChild(row);
            });
            setText(status, page.groupCount ? "Grouped by " + page.groupBy + " · Observed: " + healthTime(page.observedAt) : "No tool activity in this range");
            moreButton.hidden = !toolsCursor;
          } catch (error) {
            if (token === requestEpoch) setText(status, "Tool activity unavailable. Apply filters to retry.");
          } finally { if (token === requestEpoch) moreButton.disabled = false; }
        }
        function clearCosts() {
          costsSnapshot = "";
          costsCursor = "";
          costsFilters = "";
          costsTotals = null;
          ["costs-totals", "costs-rows", "costs-sessions", "costs-status", "costs-sessions-status", "costs-unpriced"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("costs-more").hidden = true;
        }
        function costValue(value, field) {
          return typeof value === "number" && Number.isFinite(value)
            ? field === "costUsd" ? "$" + value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : value.toLocaleString("en-US")
            : "Not reported";
        }
        async function loadCosts(more) {
          if (more && !costsCursor) return;
          const token = bumpEpoch();
          const status = document.getElementById("costs-status");
          const moreButton = document.getElementById("costs-more");
          if (!more) clearCosts();
          const params = new URLSearchParams(more ? costsFilters : { groupBy: document.getElementById("costs-group").value || "model" });
          if (more) {
            params.set("snapshotId", costsSnapshot);
            params.set("cursor", costsCursor);
          } else {
            ["since", "until", "agents"].forEach(function (name) {
              const value = document.getElementById("costs-" + name).value;
              if (value && !(name === "agents" && value === "hide")) params.set(name, value);
            });
            costsFilters = params.toString();
          }
          setText(status, "Loading…");
          moreButton.disabled = true;
          const groups = (async function () {
            try {
              const page = await api("GET", "/web/api/costs?" + params.toString());
              if (token !== requestEpoch) return;
              if (!page || !Array.isArray(page.items) || !page.totals || page.groupBy !== params.get("groupBy")
                  || (more && page.snapshotId !== costsSnapshot)
                  || (costsTotals && costFields.some(function (field) { return costsTotals[field[0]] !== page.totals[field[0]]; }))) throw new Error("changed costs");
              costsSnapshot = page.snapshotId;
              costsCursor = page.nextCursor || "";
              costsTotals = page.totals;
              const totals = document.getElementById("costs-totals");
              setText(totals, "");
              costFields.forEach(function (field) {
                const group = document.createElement("div");
                const label = document.createElement("dt");
                const value = document.createElement("dd");
                setText(label, field[1]);
                setText(value, costValue(page.totals[field[0]], field[0]));
                group.appendChild(label); group.appendChild(value); totals.appendChild(group);
              });
              page.items.forEach(function (item) {
                const row = document.createElement("tr");
                const label = document.createElement("td");
                setText(label, page.groupBy === "source" ? sourceLabel(item.key) : item.label);
                row.appendChild(label);
                costFields.forEach(function (field) {
                  const cell = document.createElement("td");
                  setText(cell, costValue(item[field[0]], field[0])); row.appendChild(cell);
                });
                document.getElementById("costs-rows").appendChild(row);
              });
              const unpriced = [];
              if (Number.isSafeInteger(page.unpricedUnattributedSessions)) unpriced.push(page.unpricedUnattributedSessions.toLocaleString("en-US") + " sessions have no model attribution");
              if (Number.isSafeInteger(page.unpricedNoPriceSessions)) unpriced.push(page.unpricedNoPriceSessions.toLocaleString("en-US") + " sessions have no matching price");
              setText(document.getElementById("costs-unpriced"), unpriced.length ? "Unpriced usage: " + unpriced.join("; ") + "." : "Unpriced usage: not reported.");
              setText(status, "Grouped by " + page.groupBy + " · " + page.timeZone + (page.totals.sessionCount === 0 ? " · No cost records in this range" : ""));
              moreButton.hidden = !costsCursor;
            } catch (error) {
              if (token === requestEpoch) setText(status, "Costs unavailable. Apply filters to retry.");
            }
          })();
          const sessions = more ? Promise.resolve() : loadCostSessions(params, token);
          await Promise.all([groups, sessions]);
          if (token === requestEpoch) moreButton.disabled = false;
        }
        async function loadCostSessions(filters, token) {
          const params = new URLSearchParams(filters.toString());
          params.delete("groupBy");
          params.set("limit", document.getElementById("costs-limit").value || "20");
          const status = document.getElementById("costs-sessions-status");
          setText(status, "Loading…");
          try {
            const page = await api("GET", "/web/api/costs/sessions?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items)) throw new Error("invalid session costs");
            page.items.forEach(function (item) {
              if (!item.session || typeof item.session.sessionId !== "string") throw new Error("invalid cost session");
              const row = document.createElement("tr");
              const cell = document.createElement("td");
              const button = document.createElement("button");
              button.type = "button";
              setText(button, sessionTitle(item.session));
              button.addEventListener("click", function () { openDetail(item.session.sessionId, "stats").catch(function () {}); });
              cell.appendChild(button); row.appendChild(cell);
              const model = document.createElement("td");
              setText(model, item.model || "Not reported"); row.appendChild(model);
              costFields.filter(function (field) { return field[0] !== "sessionCount"; }).forEach(function (field) {
                const value = document.createElement("td");
                setText(value, costValue(item[field[0]], field[0])); row.appendChild(value);
              });
              document.getElementById("costs-sessions").appendChild(row);
            });
            setText(status, page.items.length ? "Showing " + page.items.length + " highest-cost sessions" : "No cost records in this range");
          } catch (error) {
            if (token === requestEpoch) setText(status, "Session costs unavailable. Apply filters to retry.");
          }
        }
        function updateSessionMore() {
          moreNode.hidden = !(sessionPage + 1 < sessionPageSizes.length || (sessionCursor && sessionSnapshotId));
          moreNode.disabled = sessionPagingBusy;
          const previous = document.getElementById("session-previous");
          previous.hidden = sessionPage === 0;
          previous.disabled = sessionPagingBusy;
          const start = sessionPageSizes.slice(0, sessionPage).reduce(function (sum, count) { return sum + count; }, 0);
          const size = sessionPageSizes[sessionPage] || 0;
          Array.from(sessionsNode.children).forEach(function (row, index) { row.hidden = index < start || index >= start + size; });
          const range = size ? (start + 1) + "–" + (start + size) : "";
          const total = sessionTotal !== null ? sessionTotal.toLocaleString("en-US") : null;
          setText(document.getElementById("session-page-status"), range ? range + (total !== null ? " of " + total : "") + " sessions" : total === "0" ? "0 sessions" : "");
        }
        async function changeSessionPage(direction) {
          if (sessionPagingBusy) return;
          const next = sessionPage + direction;
          if (next < 0) return;
          if (next < sessionPageSizes.length) {
            bumpEpoch();
            sessionPage = next;
            updateSessionMore();
            window.scrollTo({ top: 0, behavior: "instant" });
            return;
          }
          if (!sessionCursor || !sessionSnapshotId) return;
          sessionPagingBusy = true;
          updateSessionMore();
          const token = requestEpoch + 1;
          try {
            await loadSessions(true);
            if (token === requestEpoch) window.scrollTo({ top: 0, behavior: "instant" });
          } finally {
            if (token === requestEpoch) {
              sessionPagingBusy = false;
              updateSessionMore();
            }
          }
        }
        function updateMessageMore() {
          moreMessagesNode.hidden = !(messageCursor && messageSessionId && messageGeneration);
        }
        const sourceLabels = {
          "codex": "Codex", "claude-code": "Claude Code", "copilot": "Copilot", "gemini-cli": "Gemini CLI",
          "opencode": "OpenCode", "iflow": "iFlow", "qwen": "Qwen", "qoder": "Qoder", "kimi": "Kimi",
          "minimax": "MiniMax", "lobsterai": "LobsterAI", "commandcode": "Command Code", "cline": "Cline",
          "cursor": "Cursor", "vscode": "VS Code", "antigravity": "Antigravity", "windsurf": "Windsurf", "pi": "Pi", "grok": "Grok"
        };
        function sourceLabel(value) {
          return sourceLabels[value] || value || "Unknown source";
        }
        function sourceClass(value) {
          return value && /^[a-z0-9-]+$/.test(value) ? "source-" + value : "";
        }
        function clipPreview(value) {
          const raw = String(value == null ? "" : value).split(String.fromCharCode(10)).join(" ").split(String.fromCharCode(13)).join(" ").split(String.fromCharCode(9)).join(" ");
          let text = "";
          let space = false;
          for (let i = 0; i < raw.length; i += 1) {
            if (raw[i] === " ") {
              if (text && !space) text += " ";
              space = true;
            } else {
              text += raw[i];
              space = false;
            }
          }
          if (!text) return "";
          return text.length > 100 ? text.slice(0, 100) : text;
        }
        function fillDisclosure(summary, label, preview) {
          const name = document.createElement("strong");
          setText(name, label);
          summary.appendChild(name);
          const clipped = clipPreview(preview);
          if (!clipped) return;
          const hint = document.createElement("span");
          hint.className = "preview";
          setText(hint, clipped);
          summary.appendChild(hint);
        }
        setSignedIn(false);
        showSessionList();
        updateSessionMore();
        updateMessageMore();
        function headers(json) {
          const fields = { "X-Engram-Web": "1" };
          if (json) fields["Content-Type"] = "application/json";
          return fields;
        }
        function clearSessionPaging() {
          sessionSnapshotId = "";
          sessionCursor = "";
          sessionFilters = "";
          sessionPageSizes = [];
          sessionPage = 0;
          sessionTotal = null;
          sessionPagingBusy = false;
          updateSessionMore();
        }
        function clearDetailExtras() {
          sessionActionCanWrite = false;
          document.getElementById("session-actions").hidden = true;
          document.getElementById("session-actions").open = false;
          setText(document.getElementById("session-action-status"), "");
          renderSessionSummary("");
          updateSessionActionControls();
          detailExtrasVersion += 1;
          detailContextSession = "";
          detailContextGeneration = "";
          detailRelationship = { canWrite: false, checking: false };
          relationshipButtons = [];
          ["relationship-access", "relationship-status"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("relationship-child-id").value = "";
          updateRelationshipControls();
          detailChildren = { loaded: false, busy: false, snapshot: "", cursor: "", seen: new Set(), items: [] };
          detailTimeline = { loaded: false, busy: false, next: null, total: null, count: 0, lastIndex: -1 };
          document.getElementById("detail-view-nav").hidden = true;
          ["timeline", "detail-children"].forEach(function (prefix) {
            setText(document.getElementById(prefix + "-rows"), "");
            setText(document.getElementById(prefix + "-status"), "");
            document.getElementById(prefix + "-more").hidden = true;
            document.getElementById(prefix + "-panel").hidden = true;
          });
          document.getElementById("transcript-panel").hidden = false;
        }
        function renderSessionSummary(summary) {
          const node = document.getElementById("session-summary-text");
          setText(node, "");
          document.getElementById("session-summary").hidden = typeof summary !== "string" || !summary.trim();
          if (typeof summary === "string" && summary.trim()) renderRichText(node, summary);
        }
        function updateSessionActionControls() {
          ["session-generate-summary", "session-generate-title"].forEach(function (id) {
            document.getElementById(id).disabled = !sessionActionCanWrite || sessionActionPending || !detailContextGeneration;
          });
        }
        async function loadSessionActionAccess() {
          if (!detailContextSession || !detailContextGeneration) return;
          const version = detailExtrasVersion;
          const status = document.getElementById("session-action-status");
          sessionActionCanWrite = false;
          updateSessionActionControls();
          setText(status, "Checking edit access…");
          try {
            const access = await api("GET", "/web/api/auth");
            if (version !== detailExtrasVersion) return;
            sessionActionCanWrite = access && access.canWrite === true;
            setText(status, sessionActionCanWrite ? "Uses the configured AI provider and saves the result to this session." : "Read only. Sign in with an editor key to generate content.");
          } catch (error) {
            if (version !== detailExtrasVersion) return;
            setText(status, "Edit access unavailable. Reopen this section to retry.");
          }
          updateSessionActionControls();
        }
        async function generateSessionText(action) {
          if (!sessionActionCanWrite || sessionActionPending || !detailContextSession || !detailContextGeneration || !["summary", "title"].includes(action)) return;
          const version = detailExtrasVersion, id = detailContextSession, generation = detailContextGeneration;
          const status = document.getElementById("session-action-status");
          sessionActionPending = true;
          updateSessionActionControls();
          setText(status, "Generating " + action + "…");
          try {
            const result = await api("POST", "/web/api/sessions/" + encodeURIComponent(id) + "/" + action, JSON.stringify({generation: generation}));
            if (version !== detailExtrasVersion) return;
            if (!result || result.sessionId !== id || result.generation !== generation || typeof result[action] !== "string" || !result[action].trim()) throw new Error("changed generation");
            if (action === "summary") renderSessionSummary(result.summary);
            else {
              const title = detailNode.querySelector("h2");
              if (title) { setText(title, result.displayTitle || result.title); title.title = result.displayTitle || result.title; }
            }
            setText(status, action === "summary" ? "Summary saved." : "Title saved.");
          } catch (error) {
            if (version !== detailExtrasVersion) return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              sessionActionCanWrite = false;
              setText(status, "Editor access required. Sign in again to generate content.");
            } else if (error.status === 503) {
              setText(status, "Generation unavailable. Check the server's AI provider settings and try again.");
            } else setText(status, "Could not confirm generation. Reopen the session before retrying.");
          } finally {
            sessionActionPending = false;
            updateSessionActionControls();
          }
        }
        async function generateMissingTitles() {
          if (!settingsCanWrite || batchTitlePending || activePage !== "settings") return;
          const version = settingsAccessVersion;
          const status = document.getElementById("batch-title-status");
          batchTitlePending = true;
          updateAliasControls();
          setText(status, "Starting generation…");
          try {
            const result = await api("POST", "/web/api/titles/regenerate", JSON.stringify({}));
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            if (!result || !["started", "running"].includes(result.status)) throw new Error("invalid generation status");
            const count = Number.isSafeInteger(result.total) && result.total >= 0 ? " (" + result.total + " sessions)" : "";
            setText(status, (result.status === "started" ? "Generation started" : "Generation is already running") + count + ". Reload Sessions to see updated titles.");
          } catch (error) {
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) settingsCanWrite = false;
            setText(status, error.status === 503 ? "Generation unavailable. Check the server's AI provider settings." : "Could not confirm generation. Reload Sessions before retrying.");
          } finally {
            batchTitlePending = false;
            updateAliasControls();
          }
        }
        document.getElementById("session-actions").addEventListener("toggle", function () {
          if (this.open) loadSessionActionAccess();
        });
        document.getElementById("session-generate-summary").addEventListener("click", function () { generateSessionText("summary"); });
        document.getElementById("session-generate-title").addEventListener("click", function () { generateSessionText("title"); });
        document.getElementById("batch-title-button").addEventListener("click", generateMissingTitles);
        async function showDetailView(view) {
          if (!detailContextSession || !["transcript", "timeline", "children"].includes(view)) return;
          if (view === "timeline" && !detailContextGeneration) return;
          ["transcript", "timeline", "children"].forEach(function (name) {
            document.getElementById("detail-view-" + name).setAttribute("aria-pressed", String(name === view));
            document.getElementById((name === "children" ? "detail-children" : name) + "-panel").hidden = name !== view;
          });
          if (view === "children" && !detailChildren.loaded) await loadDetailChildren(false);
          if (view === "timeline" && !detailTimeline.loaded) await loadDetailTimeline(false);
        }
        async function loadDetailChildren(more) {
          const state = detailChildren;
          if (!detailContextSession || state.busy || (more && !state.cursor)) return;
          const sessionId = detailContextSession, version = detailExtrasVersion, token = requestEpoch;
          const rows = document.getElementById("detail-children-rows"), status = document.getElementById("detail-children-status");
          const params = new URLSearchParams({ limit: "20" });
          if (more) { params.set("snapshotId", state.snapshot); params.set("cursor", state.cursor); }
          state.busy = true;
          setText(status, "Loading child sessions…");
          try {
            const page = await api("GET", "/web/api/sessions/" + encodeURIComponent(sessionId) + "/children?" + params);
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            if (page.sessionId !== sessionId || !page.snapshotId || !Array.isArray(page.items) ||
                (more && page.snapshotId !== state.snapshot) ||
                (more && page.nextCursor && (page.nextCursor === state.cursor || state.seen.has(page.nextCursor))) ||
                page.items.some(function (item) { return !item.session || !item.session.sessionId || !["confirmed", "suggested"].includes(item.relationship); })) throw new Error("Invalid children page");
            if (!more) { state.items = []; state.seen.clear(); }
            state.items = state.items.concat(page.items);
            renderDetailChildren();
            if (more) state.seen.add(state.cursor);
            state.snapshot = page.snapshotId; state.cursor = page.nextCursor || ""; state.loaded = true;
            setText(status, rows.children.length ? rows.children.length + " child sessions loaded" : "No child sessions");
          } catch (error) {
            if (version === detailExtrasVersion && token === requestEpoch) setText(status, "Child sessions unavailable. Refresh to retry.");
          } finally {
            if (version === detailExtrasVersion && token === requestEpoch) {
              state.busy = false;
              document.getElementById("detail-children-more").hidden = !state.cursor;
            }
          }
        }
        function updateRelationshipControls() {
          document.getElementById("relationship-form").hidden = !detailRelationship.canWrite;
          document.getElementById("relationship-edit").disabled = detailRelationship.checking || relationshipWritePending;
          ["relationship-add", "relationship-child-id"].forEach(function (id) {
            document.getElementById(id).disabled = !detailRelationship.canWrite || relationshipWritePending;
          });
          relationshipButtons.forEach(function (button) { button.disabled = !detailRelationship.canWrite || relationshipWritePending; });
          document.getElementById("detail-children-refresh").disabled = relationshipWritePending;
          document.getElementById("detail-children-more").disabled = relationshipWritePending;
        }
        function renderDetailChildren() {
          const rows = document.getElementById("detail-children-rows"), parentId = detailContextSession;
          setText(rows, ""); relationshipButtons = [];
          detailChildren.items.forEach(function (item) {
            const row = document.createElement("article");
            const button = document.createElement("button"); button.type = "button"; button.className = "session";
            const title = document.createElement("strong"); setText(title, sessionTitle(item.session)); button.appendChild(title);
            const meta = document.createElement("p"); meta.className = "meta";
            appendSessionMetadata(meta, item.session);
            appendMetaPart(meta, textSpan(item.relationship === "confirmed" ? "Confirmed" : "Suggested"));
            button.appendChild(meta);
            button.addEventListener("click", function () { openDetail(item.session.sessionId).catch(function () {}); });
            row.appendChild(button);
            if (detailRelationship.canWrite) {
              const actions = document.createElement("div"); actions.className = "agent-filters";
              const choices = item.relationship === "confirmed" ? [["unlink", "Unlink"]] : [["confirmSuggestion", "Confirm"], ["dismissSuggestion", "Dismiss"]];
              choices.forEach(function (choice) {
                const action = document.createElement("button"); action.type = "button";
                setText(action, choice[1]);
                action.addEventListener("click", function () { mutateRelationship(choice[0], item.session.sessionId, parentId); });
                relationshipButtons.push(action); actions.appendChild(action);
              });
              row.appendChild(actions);
            }
            rows.appendChild(row);
          });
          updateRelationshipControls();
        }
        async function loadRelationshipAccess() {
          if (!detailContextSession || detailRelationship.checking || relationshipWritePending) return;
          const state = detailRelationship, version = detailExtrasVersion, token = requestEpoch;
          state.checking = true; updateRelationshipControls();
          const status = document.getElementById("relationship-access");
          setText(status, "Checking edit access…");
          try {
            const access = await api("GET", "/web/api/auth");
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            state.canWrite = access && access.canWrite === true;
            setText(status, state.canWrite ? "Editor access. Changes apply to this parent session." : "Read only. Sign in with an editor key to make changes.");
            renderDetailChildren();
          } catch (error) {
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            state.canWrite = false;
            setText(status, "Edit access unavailable. Retry to check access.");
          } finally {
            if (version === detailExtrasVersion && token === requestEpoch) { state.checking = false; updateRelationshipControls(); }
          }
        }
        async function attachDetailChild() {
          const childId = document.getElementById("relationship-child-id").value.trim();
          if (!childId) { setText(document.getElementById("relationship-status"), "Enter a child session ID."); return; }
          await mutateRelationship("link", childId, detailContextSession);
        }
        async function mutateRelationship(action, childId, parentId) {
          if (!detailContextSession || parentId !== detailContextSession || !detailRelationship.canWrite || relationshipWritePending || detailChildren.busy) return;
          const operation = {
            link: ["POST", "link", { parentId: parentId }],
            unlink: ["DELETE", "link", {}],
            confirmSuggestion: ["POST", "confirm-suggestion", { suggestedParentId: parentId }],
            dismissSuggestion: ["DELETE", "suggestion", { suggestedParentId: parentId }]
          }[action];
          if (!operation || !childId || childId === parentId) { setText(document.getElementById("relationship-status"), "Choose a different child session."); return; }
          if (action !== "link" && !detailChildren.items.some(function (item) {
            return item.session.sessionId === childId && item.relationship === (action === "unlink" ? "confirmed" : "suggested");
          })) return;
          const version = detailExtrasVersion, token = requestEpoch, status = document.getElementById("relationship-status");
          relationshipWritePending = true; updateRelationshipControls(); setText(status, "Saving relationship…");
          try {
            const result = await api(operation[0], "/web/api/sessions/" + encodeURIComponent(childId) + "/" + operation[1], JSON.stringify(operation[2]));
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            if (!result || result.sessionId !== childId || result.action !== action || result.ok !== true) throw new Error("Invalid relationship response");
            await loadDetailChildren(false);
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            const labels = { link: "Child session linked.", unlink: "Child session unlinked.", confirmSuggestion: "Suggestion confirmed.", dismissSuggestion: "Suggestion dismissed." };
            setText(status, labels[action]); setText(statusNode, "signed in");
            if (action === "link") document.getElementById("relationship-child-id").value = "";
          } catch (error) {
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              detailRelationship.canWrite = false; renderDetailChildren();
              setText(status, "Editor access required. Sign in again to edit.");
            } else if (error.status === 409) {
              await loadDetailChildren(false);
              if (version === detailExtrasVersion && token === requestEpoch) setText(status, "Relationship changed. Review the refreshed child sessions before retrying.");
            } else setText(status, "Could not confirm the change. Refresh child sessions before retrying.");
          } finally {
            relationshipWritePending = false;
            updateRelationshipControls();
          }
        }
        async function loadDetailTimeline(more) {
          const state = detailTimeline;
          if (!detailContextSession || !detailContextGeneration || state.busy || (more && state.next == null)) return;
          const sessionId = detailContextSession, generation = detailContextGeneration, version = detailExtrasVersion, token = requestEpoch;
          const rows = document.getElementById("timeline-rows"), status = document.getElementById("timeline-status");
          const offset = more ? state.next : 0;
          const params = new URLSearchParams({ generation: generation, offset: String(offset), limit: "100" });
          state.busy = true; setText(status, "Loading timeline…");
          try {
            const page = await api("GET", "/web/api/sessions/" + encodeURIComponent(sessionId) + "/timeline?" + params);
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            let previous = more ? state.lastIndex : -1;
            if (page.sessionId !== sessionId || page.generation !== generation || !Number.isSafeInteger(page.totalEntries) || page.totalEntries < 0 ||
                !Array.isArray(page.entries) || (more && page.totalEntries !== state.total) ||
                page.entries.some(function (entry) {
                  const invalid = !Number.isSafeInteger(entry.index) || entry.index < offset || entry.index <= previous || entry.index >= page.totalEntries ||
                    !["message", "tool_use", "tool_result"].includes(entry.type) || typeof entry.preview !== "string";
                  previous = entry.index; return invalid;
                }) || (page.nextOffset != null && (!Number.isSafeInteger(page.nextOffset) || page.nextOffset <= offset || page.nextOffset <= previous || page.nextOffset >= page.totalEntries || !page.entries.length))) throw new Error("Invalid timeline page");
            if (!more) { setText(rows, ""); state.count = 0; }
            page.entries.forEach(function (entry) {
              const card = document.createElement("article"); card.className = "message";
              const meta = document.createElement("p"); meta.className = "meta";
              setText(meta, "#" + (entry.index + 1) + " · " + entry.role + " · " + entry.type);
              if (entry.timestamp) appendMetaPart(meta, textSpan(entry.timestamp));
              if (entry.toolName) appendMetaPart(meta, textSpan(entry.toolName));
              if (entry.tokens) appendMetaPart(meta, textSpan("Tokens: " + entry.tokens.input + " in / " + entry.tokens.output + " out"));
              if (Number.isFinite(entry.durationToNextMs)) appendMetaPart(meta, textSpan((entry.durationToNextMs / 1000).toLocaleString("en-US") + " s to next"));
              card.appendChild(meta);
              const preview = document.createElement("p"); setText(preview, entry.preview); card.appendChild(preview); rows.appendChild(card);
            });
            state.count += page.entries.length; state.lastIndex = previous; state.total = page.totalEntries;
            state.next = page.nextOffset == null ? null : page.nextOffset; state.loaded = true;
            setText(status, state.count + " / " + state.total + " messages");
          } catch (error) {
            if (version === detailExtrasVersion && token === requestEpoch) setText(status, "Timeline unavailable. Refresh the session if its transcript changed.");
          } finally {
            if (version === detailExtrasVersion && token === requestEpoch) {
              state.busy = false; document.getElementById("timeline-more").hidden = state.next == null;
            }
          }
        }
        function clearMessages() {
          clearDetailExtras();
          messageSessionId = "";
          messageGeneration = "";
          messageCursor = "";
          messageBuf = null;
          messageRequest = null;
          detailSource = "";
          setText(messagesNode, "");
          updateMessageMore();
        }
        async function api(method, path, body) {
          const token = requestEpoch;
          let response;
          try {
            response = await fetch(path, {
              method: method,
              credentials: "same-origin",
              headers: headers(body !== undefined),
              body: body
            });
          } catch (error) {
            if (token === requestEpoch) setText(statusNode, "Network unavailable");
            throw error;
          }
          if (!response.ok) {
            if (token === requestEpoch) {
              if (response.status === 401 && method === "GET") expireSession();
              else setText(statusNode, String(response.status));
            }
            const error = new Error("request failed");
            error.status = response.status;
            throw error;
          }
          const type = response.headers.get("content-type") || "";
          if (type.indexOf("application/json") >= 0) return response.json();
          return null;
        }
        async function authWrite(method, body) {
          const predecessor = authWriteTail;
          let release;
          const completion = new Promise(resolve => { release = resolve; });
          // Register before waiting; the first write still dispatches synchronously.
          authWriteTail = completion;
          try {
            if (predecessor) await predecessor;
            return await api(method, "/web/api/auth", body);
          } finally {
            if (authWriteTail === completion) authWriteTail = null;
            release();
          }
        }
        async function login(event) {
          event.preventDefault();
          clearFacets();
          const token = bumpEpoch();
          const credential = document.getElementById("credential").value;
          await authWrite("POST", JSON.stringify({ credential: credential }));
          if (token !== requestEpoch) return;
          document.getElementById("credential").value = "";
          setText(statusNode, "signed in");
          setSignedIn(true);
          clearSessionPaging();
          clearMessages();
          const listEpoch = await loadSessions(false);
          if (listEpoch !== requestEpoch) return;
          await loadOverview();
          await restoreRequestedPage();
        }
        async function logout() {
          const token = bumpEpoch();
          setSignedIn(false);
          showSessionList();
          setText(overviewNode, "");
          setText(sessionsNode, "");
          setText(detailNode, "");
          clearSessionPaging();
          clearMessages();
          try {
            await authWrite("DELETE", "{}");
            if (token === requestEpoch) setText(statusNode, "signed out");
          } catch (error) {
            if (token === requestEpoch) setText(statusNode, "Sign-out failed; local view cleared. Retry to revoke the server session.");
            throw error;
          }
        }
        function sessionQuery(more) {
          const params = new URLSearchParams(more ? sessionFilters : "");
          if (!more) {
            const query = document.getElementById("query").value;
            const machineId = document.getElementById("machineId").value;
            if (query) params.set("query", query);
            if (facets.source.selected.size) params.set("sources", Array.from(facets.source.selected.keys()).sort().join(","));
            if (machineId) params.set("machineId", machineId);
            if (facets.project.selected.size) params.set("projectKeys", Array.from(facets.project.selected.keys()).sort().join(","));
            if (agentFilter !== "hide") params.set("agents", agentFilter);
            const since = document.getElementById("since").value;
            const until = document.getElementById("until").value;
            if (since) params.set("since", since);
            if (until) params.set("until", until);
            if (document.getElementById("hide-tools").checked) params.set("tools", "hide");
            sessionFilters = params.toString();
          }
          if (more && sessionSnapshotId && sessionCursor) {
            params.set("snapshotId", sessionSnapshotId);
            params.set("cursor", sessionCursor);
          }
          const encoded = params.toString().replaceAll("+", "%20");
          return encoded ? ("?" + encoded) : "";
        }
        function updateFacetSummary(kind) {
          const selected = facets[kind].selected;
          const label = !selected.size ? "All " + kind + "s" : selected.size === 1 ? Array.from(selected.values())[0] : selected.size + " " + kind + "s";
          setText(document.getElementById(kind + "-summary"), label);
          document.getElementById(kind + "-summary").title = label;
        }
        function clearFacets() {
          facetEpoch += 1;
          ["source", "project"].forEach(function (kind) {
            const state = facets[kind];
            state.version += 1;
            state.selected.clear();
            state.items.clear();
            state.loaded = false;
            state.snapshot = "";
            state.cursor = "";
            document.getElementById(kind + "-picker").open = false;
            document.getElementById(kind + "-more").hidden = true;
            setText(document.getElementById(kind + "-options"), "");
            setText(document.getElementById(kind + "-status"), "");
            updateFacetSummary(kind);
          });
          document.getElementById("project-query").value = "";
        }
        function renderFacets(kind) {
          const state = facets[kind];
          const options = document.getElementById(kind + "-options");
          setText(options, "");
          state.items.forEach(function (item) {
            const itemLabel = kind === "source" ? sourceLabel(item.key) : item.label;
            const label = document.createElement("label");
            const input = document.createElement("input");
            input.type = "checkbox";
            input.value = item.key;
            input.checked = state.selected.has(item.key);
            input.addEventListener("change", function () {
              if (input.checked && state.selected.size >= 32) {
                input.checked = false;
                setText(document.getElementById(kind + "-status"), "Select up to 32 " + kind + "s.");
                return;
              }
              if (input.checked) state.selected.set(item.key, itemLabel);
              else state.selected.delete(item.key);
              updateFacetSummary(kind);
              refreshLibrary().catch(function () {});
            });
            label.appendChild(input);
            const name = document.createElement("span");
            setText(name, itemLabel);
            label.appendChild(name);
            const count = document.createElement("span");
            count.className = "facet-count";
            setText(count, item.sessionCount.toLocaleString("en-US"));
            label.appendChild(count);
            options.appendChild(label);
          });
          document.getElementById(kind + "-more").hidden = !state.cursor;
        }
        async function loadFacets(kind, more) {
          const state = facets[kind];
          if (more && !state.cursor) return;
          const epoch = facetEpoch;
          const version = ++state.version;
          const status = document.getElementById(kind + "-status");
          const params = new URLSearchParams(more ? state.filters : { kind: kind });
          if (more) {
            params.set("snapshotId", state.snapshot);
            params.set("cursor", state.cursor);
          } else {
            const query = kind === "project" ? document.getElementById("project-query").value.trim() : "";
            if (query) params.set("query", query);
            if (agentFilter !== "hide") params.set("agents", agentFilter);
            state.filters = params.toString();
            state.items.clear();
            state.snapshot = "";
            state.cursor = "";
            state.seenCursors = new Set();
            renderFacets(kind);
          }
          setText(status, "Loading…");
          document.getElementById(kind + "-more").disabled = true;
          try {
            const response = await fetch("/web/api/facets?" + params.toString().replaceAll("+", "%20"), { credentials: "same-origin", headers: headers() });
            if (epoch !== facetEpoch || version !== state.version) return;
            if (response.status === 401) { expireSession(); return; }
            if (!response.ok) throw new Error("unavailable");
            const page = await response.json();
            if (epoch !== facetEpoch || version !== state.version) return;
            if (!Array.isArray(page.items) || !page.snapshotId || (more && page.snapshotId !== state.snapshot)
                || (page.nextCursor && state.seenCursors.has(page.nextCursor))) throw new Error("invalid page");
            state.snapshot = page.snapshotId;
            state.cursor = page.nextCursor || "";
            if (state.cursor) state.seenCursors.add(state.cursor);
            page.items.forEach(function (item) { state.items.set(item.key, item); });
            state.loaded = true;
            renderFacets(kind);
            setText(status, state.items.size ? "" : "No matching " + kind + "s.");
          } catch (error) {
            if (epoch === facetEpoch && version === state.version) {
              state.loaded = false;
              setText(status, "Options unavailable. Reopen to retry.");
            }
          } finally {
            if (epoch === facetEpoch && version === state.version) document.getElementById(kind + "-more").disabled = false;
          }
        }
        async function jumpToSession(event) {
          event.preventDefault();
          const id = document.getElementById("session-id").value.trim();
          if (!id) {
            setText(statusNode, "Enter a session ID.");
            return;
          }
          const token = bumpEpoch();
          showSessionList();
          showDetailEmpty();
          clearMessages();
          clearSessionPaging();
          setText(sessionsNode, "");
          setText(statusNode, "Finding session…");
          sessionFilters = new URLSearchParams({ sessionId: id }).toString().replaceAll("+", "%20");
          const page = await api("GET", "/web/api/sessions?" + sessionFilters);
          if (token !== requestEpoch) return;
          acceptSessionsPage(false, page);
          const items = page.items || [];
          if (items.length === 1 && !page.nextCursor) {
            setText(statusNode, "");
            await openDetail(items[0].sessionId);
          } else {
            setText(statusNode, items.length ? "Several sessions share this ID. Select the matching session." : "Session not found.");
          }
        }
        function countValue(value) {
          const number = Number(value);
          return number > 0 ? number : 0;
        }
        function showOverviewUnavailable() {
          setText(healthContent, "");
          setText(healthStatus, "Health is temporarily unavailable.");
          setText(overviewNode, "");
          const note = document.createElement("p");
          note.className = "empty";
          setText(note, "Overview is temporarily unavailable.");
          overviewNode.appendChild(note);
        }
        async function loadOverview() {
          const token = requestEpoch;
          const streams = [];
          let observedAt = null;
          const params = new URLSearchParams({ limit: "2" });
          const seenCursors = new Set();
          do {
            let response;
            let page;
            try {
              response = await fetch("/web/api/overview?" + params.toString(), {
                method: "GET",
                credentials: "same-origin",
                headers: headers()
              });
              if (token !== requestEpoch) return token;
              if (response.status === 401) {
                expireSession();
                return token;
              }
              if (!response.ok) {
                showOverviewUnavailable();
                return token;
              }
              page = await response.json();
            } catch (error) {
              if (token === requestEpoch) showOverviewUnavailable();
              return token;
            }
            if (token !== requestEpoch) return token;
            if (!Array.isArray(page.streams)
                || (params.has("snapshotId") && page.snapshotId !== params.get("snapshotId"))) {
              showOverviewUnavailable();
              return token;
            }
            streams.push(...page.streams);
            if (observedAt === null) observedAt = page.observedAt;
            if (!page.nextCursor) break;
            if (typeof page.snapshotId !== "string" || !page.snapshotId
                || typeof page.nextCursor !== "string" || seenCursors.has(page.nextCursor)) {
              showOverviewUnavailable();
              return token;
            }
            seenCursors.add(page.nextCursor);
            params.set("snapshotId", page.snapshotId);
            params.set("cursor", page.nextCursor);
          } while (true);
          renderHealth(streams, observedAt);
          setText(overviewNode, "");
          let publications = 0;
          let ready = 0;
          const sources = {};
          streams.forEach(function (stream) {
            const source = stream.registry && stream.registry.source ? stream.registry.source : "unassigned";
            sources[source] = (sources[source] || 0) + 1;
            publications += countValue(stream.ingest && stream.ingest.publicationCount);
            ready += countValue(stream.fts && stream.fts.readyLogicalSessions);
          });
          const names = Object.keys(sources).map(sourceLabel);
          const summary = document.createElement("p");
          summary.className = "overview-summary";
          const sourceText = names.length ? names.length + " sources" : "No sources yet";
          setText(summary, "Session library · " + sourceText + " · " + ready.toLocaleString("en-US") + " ready sessions");
          overviewNode.appendChild(summary);
          if (streams.length) {
            const identities = document.createElement("details");
            const caption = document.createElement("summary");
            setText(caption, "Technical details");
            identities.appendChild(caption);
            const counts = document.createElement("p");
            setText(counts, publications + " captured files");
            identities.appendChild(counts);
            streams.forEach(function (stream) {
              const line = document.createElement("p");
              const source = stream.registry && stream.registry.source ? stream.registry.source : "stream";
              setText(line, sourceLabel(source) + " " + (stream.machineId || "") + " " + (stream.sourceInstanceId || ""));
              identities.appendChild(line);
            });
            overviewNode.appendChild(identities);
          }
          return token;
        }
        function healthTime(value) {
          return Number.isSafeInteger(value) && value >= 0 && value <= 253402300799
            ? new Date(value * 1000).toLocaleString() : "Not reported";
        }
        function renderHealth(streams, observedAt) {
          setText(healthContent, "");
          setText(healthStatus, streams.length ? "Observed: " + healthTime(observedAt) : "No registered sources reported.");
          streams.forEach(function (stream) {
            const card = document.createElement("section");
            card.className = "health-card";
            const heading = document.createElement("h3");
            setText(heading, sourceLabel(stream.registry && stream.registry.source));
            card.appendChild(heading);
            const tasks = stream.ingest && stream.ingest.taskCounts;
            if (tasks && (tasks.retryableFailure > 0 || tasks.quarantined > 0)) {
              const note = document.createElement("p");
              note.className = "attention";
              setText(note, "Some captures need attention.");
              card.appendChild(note);
            }
            const metrics = document.createElement("dl");
            function row(label, value) {
              const name = document.createElement("dt");
              const detail = document.createElement("dd");
              setText(name, label);
              setText(detail, value);
              metrics.appendChild(name);
              metrics.appendChild(detail);
            }
            function count(label, value) {
              row(label, Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString("en-US") : "Not reported");
            }
            count("Captured files", stream.ingest && stream.ingest.publicationCount);
            [["Pending", "pending"], ["Processing", "processing"], ["Parsed", "parsed"], ["Index ready", "indexReady"],
              ["Retryable failures", "retryableFailure"], ["Quarantined", "quarantined"]].forEach(function (metric) {
              count(metric[0], tasks && tasks[metric[1]]);
            });
            count("Parse failures", stream.ingest && stream.ingest.parseFailureTasks);
            count("Search-ready sessions", stream.fts && stream.fts.readyLogicalSessions);
            row("Heartbeat", healthTime(stream.heartbeatAt));
            row("Last capture", healthTime(stream.lastCapture && stream.lastCapture.observedAt));
            row("Oldest pending", healthTime(stream.ingest && stream.ingest.oldestPendingAt));
            row("AI state", stream.ai ? stream.ai.state : "Not reported");
            row("Replica acknowledgements", Array.isArray(stream.replicaACKs)
              ? stream.replicaACKs.map(function (ack) { return ack.serverId + ": " + healthTime(ack.observedAt); }).join("; ") || "None reported"
              : "Not reported");
            card.appendChild(metrics);
            const identity = document.createElement("details");
            const caption = document.createElement("summary");
            setText(caption, "Source identity");
            identity.appendChild(caption);
            const value = document.createElement("p");
            setText(value, "Machine: " + (stream.machineId || "Not reported") + " · Instance: " + (stream.sourceInstanceId || "Not reported"));
            identity.appendChild(value);
            card.appendChild(identity);
            healthContent.appendChild(card);
          });
        }
        function projectText(item) {
          return item.projectLabel || item.projectKey || "";
        }
        function sessionTitle(item) {
          return item.title && item.title !== item.sessionId ? item.title : "Untitled session";
        }
        function appendMetaPart(meta, node) {
          if (meta.children.length) {
            const sep = document.createElement("span");
            sep.className = "sep";
            setText(sep, "·");
            meta.appendChild(sep);
          }
          meta.appendChild(node);
        }
        function appendSessionMetadata(meta, item, showCounts) {
          if (item.source) {
            const badge = document.createElement("span");
            const tint = sourceClass(item.source);
            badge.className = tint ? "badge " + tint : "badge";
            setText(badge, sourceLabel(item.source));
            appendMetaPart(meta, badge);
          }
          if (item.isAgent === true) {
            const label = document.createElement("span");
            label.className = "agent-label";
            setText(label, "agent");
            appendMetaPart(meta, label);
          }
          const project = projectText(item);
          if (project) {
            const label = document.createElement("span");
            setText(label, project);
            appendMetaPart(meta, label);
          }
          if (Number.isSafeInteger(item.startedAt) && item.startedAt >= 0 && item.startedAt <= 253402300799) {
            const date = new Date(item.startedAt * 1000);
            const time = document.createElement("time");
            time.dateTime = date.toISOString();
            time.title = date.toLocaleString();
            const seconds = Math.floor((Date.now() - date.getTime()) / 1000);
            const relative = seconds < 0 ? null : seconds < 60 ? "just now"
              : seconds < 3600 ? Math.floor(seconds / 60) + "m ago"
              : seconds < 86400 ? Math.floor(seconds / 3600) + "h ago"
              : seconds < 604800 ? Math.floor(seconds / 86400) + "d ago" : null;
            setText(time, relative || date.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" }));
            appendMetaPart(meta, time);
          }
          if (showCounts) {
            const counts = [["user", item.userMessageCount], ["assistant", item.assistantMessageCount], ["system", item.systemMessageCount]]
              .filter(function (entry) { return Number.isSafeInteger(entry[1]) && entry[1] >= 0; })
              .map(function (entry) { return entry[1].toLocaleString("en-US") + " " + entry[0]; });
            if (counts.length) {
              const label = document.createElement("span");
              label.className = "message-counts";
              setText(label, counts.join(" · "));
              appendMetaPart(meta, label);
            }
          }
        }
        function acceptSessionsPage(more, page) {
          sessionSnapshotId = page.snapshotId || "";
          sessionCursor = page.nextCursor || "";
          if (!more) {
            sessionPageSizes = [];
            sessionPage = 0;
            sessionTotal = null;
          }
          if (Number.isSafeInteger(page.totalCount) && page.totalCount >= 0) sessionTotal = page.totalCount;
          const size = (page.items || []).length;
          if (size) {
            sessionPageSizes.push(size);
            sessionPage = sessionPageSizes.length - 1;
          }
          if (!more && !(page.items || []).length) setText(sessionsNode, "No sessions found");
          (page.items || []).forEach(function (item) {
            const button = document.createElement("button");
            button.type = "button";
            button.className = "session";
            const title = document.createElement("div");
            title.className = "title";
            setText(title, sessionTitle(item));
            title.title = title.textContent;
            button.appendChild(title);
            const meta = document.createElement("div");
            meta.className = "meta";
            appendSessionMetadata(meta, item, true);
            if (item.matchType) {
              const match = document.createElement("span");
              setText(match, item.matchType === "semantic" ? "Semantic match" : "Keyword match");
              appendMetaPart(meta, match);
            }
            button.appendChild(meta);
            if (item.snippet) {
              const snippet = document.createElement("p");
              snippet.className = "search-snippet";
              setHighlightedText(snippet, item.snippet);
              button.appendChild(snippet);
            }
            button.addEventListener("click", function () {
              openDetail(item.sessionId).catch(function () {});
            });
            sessionsNode.appendChild(button);
          });
          updateSessionMore();
        }
        async function loadSessions(more) {
          const token = bumpEpoch();
          if (!more) {
            clearSessionPaging();
            setText(sessionsNode, "");
            showSessionList();
            showDetailEmpty();
            clearMessages();
          }
          const page = await api("GET", "/web/api/sessions" + sessionQuery(more));
          if (token !== requestEpoch) return;
          acceptSessionsPage(more, page);
          return token;
        }
        async function restoreSession() {
          const token = requestEpoch;
          async function probe() {
            return fetch("/web/api/sessions" + sessionQuery(false), {
              method: "GET",
              credentials: "same-origin",
              headers: headers()
            });
          }
          let response;
          try {
            response = await probe();
          } catch (error) {
            if (token === requestEpoch) setText(statusNode, "Network unavailable");
            return;
          }
          if (token !== requestEpoch) return;
          if (response.status === 401) return;
          if (response.status === 503) {
            try {
              response = await probe();
            } catch (error) {
              if (token === requestEpoch) setText(statusNode, "Network unavailable");
              return;
            }
            if (token !== requestEpoch) return;
            if (response.status === 401) return;
          }
          if (!response.ok) {
            if (token === requestEpoch) setText(statusNode, "Temporarily unavailable");
            return;
          }
          let page;
          try {
            const type = response.headers.get("content-type") || "";
            page = type.indexOf("application/json") >= 0 ? await response.json() : { items: [] };
          } catch (error) {
            if (token === requestEpoch) setText(statusNode, "Temporarily unavailable");
            return;
          }
          if (token !== requestEpoch) return;
          setText(statusNode, "signed in");
          setSignedIn(true);
          setText(sessionsNode, "");
          showSessionList();
          showDetailEmpty();
          clearMessages();
          acceptSessionsPage(false, page);
          if (token !== requestEpoch) return;
          await loadOverview();
        }
        async function openDetail(sessionId, returnPage) {
          detailReturnPage = returnPage || null;
          const token = bumpEpoch();
          sessionPagingBusy = false;
          updateSessionMore();
          showSessionDetailPane();
          setText(detailNode, "");
          clearMessages();
          try {
            const page = await api("GET", "/web/api/sessions/" + encodeURIComponent(sessionId));
            if (token !== requestEpoch) return;
            const detail = page.detail;
            if (!detail || !detail.session) {
              setText(detailNode, "unavailable");
              return;
            }
            const session = detail.session;
            const heading = document.createElement("header");
            heading.className = "sticky";
            const title = document.createElement("h2");
            const label = sessionTitle(session);
            setText(title, label);
            title.title = label;
            heading.appendChild(title);
            const meta = document.createElement("p");
            meta.className = "meta";
            appendSessionMetadata(meta, session);
            const shownGeneration = [detail.lastReady, detail.lastParsed].find(function (value) {
              return value && value.generationId === detail.transcriptGeneration;
            });
            if (shownGeneration && Number.isSafeInteger(shownGeneration.normalizedMessageCount) && shownGeneration.normalizedMessageCount >= 0) {
              const count = document.createElement("span");
              setText(count, shownGeneration.normalizedMessageCount.toLocaleString("en-US") + " messages");
              appendMetaPart(meta, count);
            }
            heading.appendChild(meta);
            detailNode.appendChild(heading);
            detailSource = session.source ? String(session.source) : "";
            const generation = detail.transcriptGeneration;
            detailContextSession = session.sessionId;
            detailContextGeneration = generation || "";
            renderSessionSummary(detail.summary);
            document.getElementById("session-actions").hidden = !generation;
            updateSessionActionControls();
            document.getElementById("detail-view-nav").hidden = false;
            document.getElementById("detail-view-timeline").disabled = !generation;
            showDetailView("transcript");
            if (!generation) {
              const note = document.createElement("p");
              setText(note, "transcript unavailable");
              messagesNode.appendChild(note);
              return;
            }
            await loadMessages(token, session.sessionId, generation, "");
          } catch (error) {
            if (token !== requestEpoch) return;
            throw error;
          }
        }
        function toolJSON(value) {
          if (value == null) return "";
          if (typeof value === "string") return value;
          try { return JSON.stringify(value, null, 2); } catch (error) { return String(value); }
        }
        function textSpan(value) {
          const node = document.createElement("span");
          setText(node, value);
          return node;
        }
        function appendInline(parent, text) {
          const source = text == null ? "" : String(text);
          let i = 0;
          function starts(token) {
            return source.slice(i, i + token.length) === token;
          }
          function takeUntil(token) {
            const at = source.indexOf(token, i);
            if (at < 0) return null;
            const inner = source.slice(i, at);
            i = at + token.length;
            return inner;
          }
          function isHttp(url) {
            const lower = url.toLowerCase();
            return lower.indexOf("https://") === 0 || lower.indexOf("http://") === 0;
          }
          function wrap(tag, value, extra) {
            const node = document.createElement(tag);
            if (extra) extra(node);
            else setText(node, value);
            parent.appendChild(node);
          }
          while (i < source.length) {
            if (starts("`")) {
              i += 1;
              const inner = takeUntil("`");
              if (inner == null) { parent.appendChild(textSpan("`")); continue; }
              wrap("code", inner);
              continue;
            }
            if (starts("***")) {
              i += 3;
              const inner = takeUntil("***");
              if (inner == null) { parent.appendChild(textSpan("***")); continue; }
              wrap("strong", inner, function (node) {
                const em = document.createElement("em");
                setText(em, inner);
                node.appendChild(em);
              });
              continue;
            }
            if (starts("**") || starts("__")) {
              const token = starts("**") ? "**" : "__";
              i += token.length;
              const inner = takeUntil(token);
              if (inner == null) { parent.appendChild(textSpan(token)); continue; }
              wrap("strong", inner);
              continue;
            }
            if (starts("~~")) {
              i += 2;
              const inner = takeUntil("~~");
              if (inner == null) { parent.appendChild(textSpan("~~")); continue; }
              wrap("del", inner);
              continue;
            }
            if (starts("*") || starts("_")) {
              const token = starts("*") ? "*" : "_";
              i += 1;
              const inner = takeUntil(token);
              if (inner == null) { parent.appendChild(textSpan(token)); continue; }
              wrap("em", inner);
              continue;
            }
            if (starts("[")) {
              const close = source.indexOf("]", i + 1);
              if (close > i && source.charAt(close + 1) === "(") {
                const end = source.indexOf(")", close + 2);
                if (end > close) {
                  const literal = source.slice(i, end + 1);
                  const label = source.slice(i + 1, close);
                  const url = source.slice(close + 2, end);
                  i = end + 1;
                  if (isHttp(url)) {
                    wrap("a", label, function (node) {
                      node.setAttribute("href", url);
                      node.setAttribute("target", "_blank");
                      node.setAttribute("rel", "noopener noreferrer");
                      setText(node, label);
                    });
                  } else {
                    parent.appendChild(textSpan(literal));
                  }
                  continue;
                }
              }
            }
            let j = i + 1;
            while (j < source.length && "`*_~[".indexOf(source.charAt(j)) < 0) j += 1;
            parent.appendChild(textSpan(source.slice(i, j)));
            i = j;
          }
        }
        function copyCode(button) {
          const block = button.closest(".code-block");
          const pre = block && block.querySelector("pre");
          const text = pre ? pre.textContent : "";
          if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text);
        }
        function renderRichText(root, raw) {
          const lines = String(raw == null ? "" : raw).split(String.fromCharCode(10));
          let i = 0;
          let paragraph = [];
          function flushParagraph() {
            if (!paragraph.length) return;
            const p = document.createElement("p");
            for (let n = 0; n < paragraph.length; n += 1) {
              if (n) p.appendChild(document.createElement("br"));
              appendInline(p, paragraph[n]);
            }
            root.appendChild(p);
            paragraph = [];
          }
          function isRule(text) {
            if (text.length < 3) return false;
            const mark = text.charAt(0);
            if (mark !== "-" && mark !== "*" && mark !== "_") return false;
            for (let n = 0; n < text.length; n += 1) if (text.charAt(n) !== mark) return false;
            return true;
          }
          function isTableSep(text) {
            if (text.charAt(0) !== "|" || text.charAt(text.length - 1) !== "|") return false;
            for (let n = 0; n < text.length; n += 1) {
              if ("|:- ".indexOf(text.charAt(n)) < 0) return false;
            }
            return true;
          }
          function headingLevel(text) {
            let n = 0;
            while (n < 6 && text.charAt(n) === "#") n += 1;
            return n > 0 && text.charAt(n) === " " ? n : 0;
          }
          function listMarker(text) {
            if ((text.charAt(0) === "-" || text.charAt(0) === "*") && text.charAt(1) === " ") {
              const rest = text.slice(2);
              if (rest.charAt(0) === "[" && " xX".indexOf(rest.charAt(1)) >= 0 && rest.slice(2, 4) === "] ") {
                return { kind: "task", done: rest.charAt(1) !== " ", text: rest.slice(4) };
              }
              return { kind: "ul", text: rest };
            }
            let n = 0;
            while (n < text.length && text.charAt(n) >= "0" && text.charAt(n) <= "9") n += 1;
            if (n && text.charAt(n) === "." && text.charAt(n + 1) === " ") {
              return { kind: "ol", text: text.slice(n + 2) };
            }
            return null;
          }
          while (i < lines.length) {
            const line = lines[i];
            const trimmed = line.trimStart();
            if (trimmed.indexOf("```") === 0) {
              flushParagraph();
              const language = trimmed.slice(3).trim();
              i += 1;
              const codeLines = [];
              while (i < lines.length && lines[i].trimStart().indexOf("```") !== 0) {
                codeLines.push(lines[i]);
                i += 1;
              }
              if (i < lines.length) i += 1;
              const block = document.createElement("div");
              block.className = "code-block";
              const header = document.createElement("div");
              header.className = "code-header";
              const label = document.createElement("span");
              setText(label, language);
              const button = document.createElement("button");
              button.type = "button";
              button.className = "copy-btn";
              setText(button, "Copy");
              button.addEventListener("click", function () { copyCode(button); });
              header.appendChild(label);
              header.appendChild(button);
              const pre = document.createElement("pre");
              const code = document.createElement("code");
              setText(code, codeLines.join(String.fromCharCode(10)));
              pre.appendChild(code);
              block.appendChild(header);
              block.appendChild(pre);
              root.appendChild(block);
              continue;
            }
            const stripped = trimmed.replace(/ /g, "");
            if (isRule(stripped)) {
              flushParagraph();
              root.appendChild(document.createElement("hr"));
              i += 1;
              continue;
            }
            const heading = headingLevel(trimmed);
            if (heading) {
              flushParagraph();
              const node = document.createElement("h" + heading);
              appendInline(node, trimmed.slice(heading + 1));
              root.appendChild(node);
              i += 1;
              continue;
            }
            if (trimmed.charAt(0) === "|" && trimmed.charAt(trimmed.length - 1) === "|" && i + 1 < lines.length) {
              const next = lines[i + 1].trim();
              if (isTableSep(next)) {
                flushParagraph();
                const table = document.createElement("table");
                const thead = document.createElement("thead");
                const headerRow = document.createElement("tr");
                trimmed.slice(1, -1).split("|").forEach(function (cell) {
                  const th = document.createElement("th");
                  appendInline(th, cell.trim());
                  headerRow.appendChild(th);
                });
                thead.appendChild(headerRow);
                table.appendChild(thead);
                const tbody = document.createElement("tbody");
                i += 2;
                while (i < lines.length) {
                  const rowText = lines[i].trim();
                  if (rowText.charAt(0) !== "|" || rowText.charAt(rowText.length - 1) !== "|") break;
                  const tr = document.createElement("tr");
                  rowText.slice(1, -1).split("|").forEach(function (cell) {
                    const td = document.createElement("td");
                    appendInline(td, cell.trim());
                    tr.appendChild(td);
                  });
                  tbody.appendChild(tr);
                  i += 1;
                }
                table.appendChild(tbody);
                const wrap = document.createElement("div");
                wrap.className = "table-wrap";
                wrap.appendChild(table);
                root.appendChild(wrap);
                continue;
              }
            }
            const firstMark = listMarker(trimmed);
            if (firstMark && firstMark.kind === "task") {
              flushParagraph();
              const list = document.createElement("ul");
              while (i < lines.length) {
                const item = listMarker(lines[i].trimStart());
                if (!item || item.kind !== "task") break;
                const li = document.createElement("li");
                setText(li, item.done ? "☑ " : "☐ ");
                appendInline(li, item.text);
                list.appendChild(li);
                i += 1;
              }
              root.appendChild(list);
              continue;
            }
            if (firstMark && firstMark.kind === "ul") {
              flushParagraph();
              const list = document.createElement("ul");
              while (i < lines.length) {
                const item = listMarker(lines[i].trimStart());
                if (!item || item.kind !== "ul") break;
                const li = document.createElement("li");
                appendInline(li, item.text);
                list.appendChild(li);
                i += 1;
              }
              root.appendChild(list);
              continue;
            }
            if (firstMark && firstMark.kind === "ol") {
              flushParagraph();
              const list = document.createElement("ol");
              while (i < lines.length) {
                const item = listMarker(lines[i].trimStart());
                if (!item || item.kind !== "ol") break;
                const li = document.createElement("li");
                appendInline(li, item.text);
                list.appendChild(li);
                i += 1;
              }
              root.appendChild(list);
              continue;
            }
            if (trimmed === "") {
              flushParagraph();
              i += 1;
              continue;
            }
            paragraph.push(trimmed);
            i += 1;
          }
          flushParagraph();
        }
        function renderMessage(role, payload) {
          const kind = role === "user" ? "user" : (role === "tool" || role === "system" ? role : "assistant");
          const article = document.createElement("article");
          const tint = kind === "assistant" ? sourceClass(detailSource) : "";
          article.className = tint ? "message " + kind + " " + tint : "message " + kind;
          if (kind === "user" || kind === "assistant") {
            const roleNode = document.createElement("div");
            roleNode.className = "role";
            setText(roleNode, kind === "user" ? "You" : (detailSource ? sourceLabel(detailSource) : (role || "assistant")));
            article.appendChild(roleNode);
          }
          const content = payload && payload.content ? payload.content : "";
          const calls = payload && payload.toolCalls ? payload.toolCalls : [];
          if (kind === "tool" || kind === "system") {
            const dump = document.createElement("details");
            const summary = document.createElement("summary");
            fillDisclosure(summary, kind === "tool" ? "Tool" : "System", content);
            dump.appendChild(summary);
            const body = document.createElement("pre");
            setText(body, content);
            dump.appendChild(body);
            article.appendChild(dump);
          } else if (String(content).trim() || calls.length === 0) {
            const body = document.createElement("div");
            body.className = "body";
            renderRichText(body, content);
            article.appendChild(body);
          }
          calls.forEach(function (call) {
            const tools = document.createElement("details");
            tools.className = "tool-call";
            const summary = document.createElement("summary");
            const dumpText = [toolJSON(call.input), toolJSON(call.output)].filter(Boolean).join("\\n");
            fillDisclosure(summary, call.name || "Tool", dumpText);
            tools.appendChild(summary);
            const dump = document.createElement("pre");
            setText(dump, dumpText);
            tools.appendChild(dump);
            article.appendChild(tools);
          });
          messagesNode.appendChild(article);
        }
        function acceptFragment(fragment) {
          const piece = encoder.encode(fragment.payloadFragment || "");
          const ordinal = fragment.messageOrdinal;
          const hash = fragment.payloadSHA256;
          if (!messageBuf || messageBuf.ordinal !== ordinal || messageBuf.hash !== hash) {
            if (messageBuf) {
              setText(statusNode, "incomplete message");
              return;
            }
            if (fragment.utf8Offset !== 0) {
              setText(statusNode, "invalid fragment offset");
              return;
            }
            messageBuf = { ordinal: ordinal, hash: hash, chunks: [piece], bytes: piece.length, role: fragment.role };
          } else {
            if (fragment.utf8Offset !== messageBuf.bytes) {
              setText(statusNode, "invalid fragment offset");
              return;
            }
            messageBuf.chunks.push(piece);
            messageBuf.bytes += piece.length;
          }
          if (fragment.isLastFragment) {
            const assembled = new Uint8Array(messageBuf.bytes);
            let offset = 0;
            for (let i = 0; i < messageBuf.chunks.length; i += 1) {
              assembled.set(messageBuf.chunks[i], offset);
              offset += messageBuf.chunks[i].length;
            }
            const text = decoder.decode(assembled);
            renderMessage(messageBuf.role, JSON.parse(text));
            messageBuf = null;
          }
        }
        async function loadMessages(token, sessionId, generation, cursor) {
          if (messageRequest && messageRequest.token === token && messageRequest.sessionId === sessionId
              && messageRequest.generation === generation && messageRequest.cursor === cursor) return;
          const pending = { token: token, sessionId: sessionId, generation: generation, cursor: cursor };
          messageRequest = pending;
          messageSessionId = sessionId;
          messageGeneration = generation;
          let path = "/web/api/sessions/" + encodeURIComponent(sessionId) + "/messages?generation=" + encodeURIComponent(generation);
          if (cursor) path += "&cursor=" + encodeURIComponent(cursor);
          try {
            const page = await api("GET", path);
            if (token !== requestEpoch) return;
            (page.fragments || []).forEach(acceptFragment);
            messageCursor = page.nextCursor || "";
            updateMessageMore();
            if (messageBuf && !messageCursor) setText(statusNode, "incomplete message");
            if (messageBuf && messageCursor) {
              if (messageRequest === pending) messageRequest = null;
              await loadMessages(token, sessionId, generation, messageCursor);
            }
          } finally {
            if (messageRequest === pending) messageRequest = null;
          }
        }
        document.getElementById("login").addEventListener("submit", function (event) {
          login(event).catch(function () {});
        });
        document.getElementById("logout").addEventListener("click", function () {
          logout().catch(function () {});
        });
        document.getElementById("session-jump").addEventListener("submit", function (event) {
          jumpToSession(event).catch(function () {});
        });
        document.getElementById("search").addEventListener("submit", function (event) {
          event.preventDefault();
          bumpEpoch();
          refreshLibrary().catch(function () {});
        });
        ["hide", "all", "only"].forEach(function (choice) {
          document.getElementById("agents-" + choice).addEventListener("click", function () {
            agentFilter = choice;
            ["hide", "all", "only"].forEach(function (value) {
              document.getElementById("agents-" + value).setAttribute("aria-pressed", String(value === choice));
            });
            ["source", "project"].forEach(function (kind) {
              facets[kind].version += 1;
              facets[kind].loaded = false;
              if (document.getElementById(kind + "-picker").open) loadFacets(kind, false);
            });
            refreshLibrary().catch(function () {});
          });
        });
        ["source", "project"].forEach(function (kind) {
          document.getElementById(kind + "-picker").addEventListener("toggle", function () {
            if (this.open && !facets[kind].loaded) loadFacets(kind, false);
          });
          document.getElementById(kind + "-more").addEventListener("click", function () { loadFacets(kind, true); });
          document.getElementById(kind + "-clear").addEventListener("click", function () {
            facets[kind].selected.clear();
            updateFacetSummary(kind);
            renderFacets(kind);
            refreshLibrary().catch(function () {});
          });
        });
        document.getElementById("project-find").addEventListener("click", function () { loadFacets("project", false); });
        document.getElementById("project-query").addEventListener("keydown", function (event) {
          if (event.key === "Enter") { event.preventDefault(); loadFacets("project", false); }
        });
        backNode.addEventListener("click", function () {
          showSessionList();
        });
        document.getElementById("session-previous").addEventListener("click", function () { changeSessionPage(-1).catch(function () {}); });
        moreNode.addEventListener("click", function () { changeSessionPage(1).catch(function () {}); });
        moreMessagesNode.addEventListener("click", function () {
          if (!messageCursor || !messageSessionId || !messageGeneration) return;
          loadMessages(requestEpoch, messageSessionId, messageGeneration, messageCursor).catch(function () {});
        });
        document.addEventListener("DOMContentLoaded", function () {
          restoreSession().then(function () {
            return restoreRequestedPage();
          }).catch(function () {});
        });
        window.addEventListener("hashchange", function () {
          if (!workspaceNode.hidden) navigate(window.location.hash.slice(1)).catch(function () {});
        });
        ["search-mode", "search-limit"].forEach(function (id) {
          document.getElementById(id).addEventListener("change", function () { if (activePage === "search") refreshLibrary().catch(function () {}); });
        });
        ["transcript", "timeline", "children"].forEach(function (view) {
          document.getElementById("detail-view-" + view).addEventListener("click", function () { showDetailView(view); });
        });
        document.getElementById("timeline-more").addEventListener("click", function () { loadDetailTimeline(true); });
        document.getElementById("timeline-refresh").addEventListener("click", function () { loadDetailTimeline(false); });
        document.getElementById("detail-children-more").addEventListener("click", function () { if (!relationshipWritePending) loadDetailChildren(true); });
        document.getElementById("detail-children-refresh").addEventListener("click", function () { if (!relationshipWritePending) loadDetailChildren(false); });
        document.getElementById("relationship-edit").addEventListener("click", function () { loadRelationshipAccess(); });
        document.getElementById("relationship-form").addEventListener("submit", function (event) { event.preventDefault(); attachDetailChild(); });
        document.getElementById("health-refresh").addEventListener("click", function () { navigate("health").catch(function () {}); });
        document.getElementById("alias-form").addEventListener("submit", function (event) { event.preventDefault(); addAlias(); });
        document.getElementById("alias-project-form").addEventListener("submit", function (event) { event.preventDefault(); loadAliasProjects(false); });
        document.getElementById("alias-project-more").addEventListener("click", function () { loadAliasProjects(true); });
        document.getElementById("settings-refresh").addEventListener("click", function () { loadSettings(false); });
        document.getElementById("settings-more").addEventListener("click", function () { loadSettings(true); });
        document.getElementById("stats-form").addEventListener("submit", function (event) { event.preventDefault(); loadStats(false); });
        document.getElementById("stats-more").addEventListener("click", function () { loadStats(true); });
        document.getElementById("stats-view-sessions").addEventListener("click", function () { showStatsView("sessions"); });
        document.getElementById("stats-view-costs").addEventListener("click", function () { showStatsView("costs"); });
        document.getElementById("stats-view-tools").addEventListener("click", function () { showStatsView("tools"); });
        document.getElementById("stats-view-files").addEventListener("click", function () { showStatsView("files"); });
        document.getElementById("stats-view-usage").addEventListener("click", function () { showStatsView("usage"); });
        document.getElementById("stats-view-ai").addEventListener("click", function () { showStatsView("ai"); });
        document.getElementById("ai-form").addEventListener("submit", function (event) { event.preventDefault(); loadAiAudit(false); });
        document.getElementById("ai-more").addEventListener("click", function () { loadAiAudit(true); });
        document.getElementById("ai-stats-refresh").addEventListener("click", function () { loadAiStats(); });
        document.getElementById("stats-view-repos").addEventListener("click", function () { showStatsView("repos"); });
        document.getElementById("repos-refresh").addEventListener("click", function () { loadRepos(false); });
        document.getElementById("repos-more").addEventListener("click", function () { loadRepos(true); });
        document.getElementById("usage-refresh").addEventListener("click", function () { loadUsage(); });
        document.getElementById("files-form").addEventListener("submit", function (event) { event.preventDefault(); loadFiles(false); });
        document.getElementById("files-more").addEventListener("click", function () { loadFiles(true); });
        document.getElementById("tools-form").addEventListener("submit", function (event) { event.preventDefault(); loadTools(false); });
        document.getElementById("tools-more").addEventListener("click", function () { loadTools(true); });
        document.getElementById("costs-form").addEventListener("submit", function (event) { event.preventDefault(); loadCosts(false); });
        document.getElementById("costs-more").addEventListener("click", function () { loadCosts(true); });
        """
}
