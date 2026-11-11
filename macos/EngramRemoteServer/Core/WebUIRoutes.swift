import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Same-origin static viewer. HTML/JS/CSS are constant strings; no inline script or style.
enum WebUIRoutes {
    static func mount<Context: RequestContext>(on router: Router<Context>, tailscaleServeIdentity: Bool = false) {
        let page = tailscaleServeIdentity ? identityHTML : html
        router.get("/web") { _, _ in asset("text/html; charset=utf-8", page) }
        router.get("/web/app.js") { _, _ in asset("text/javascript; charset=utf-8", WebUILocalization.javascript + "\n" + javascript) }
        router.get("/web/app.css") { _, _ in asset("text/css; charset=utf-8", css) }
    }

    private static func asset(_ type: String, _ body: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = type
        headers[.contentLength] = "\(body.utf8.count)"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: body)))
    }

    /// Identity mode marks the document so the script signs in from the tailnet
    /// identity, and ships the credential form hidden so it never flashes before
    /// the script runs. The markup is otherwise identical.
    static let identityHTML = html
        .replacingOccurrences(of: "<body>", with: "<body data-auth-mode=\"tailscale-serve\">")
        .replacingOccurrences(of: "<form id=\"login\">", with: "<form id=\"login\" hidden>")

    static let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Engram</title>
        <link rel="stylesheet" href="/web/app.css">
        </head>
        <body>
        <header class="top-nav">
        <div class="header-row">
        <h1>Engram</h1>
        <p id="lede" class="lede" data-i18n="Browse your session library.">浏览你的会话库。</p>
        <nav id="page-nav" class="page-nav" aria-label="主导航" data-i18n-aria-label="Main navigation" hidden>
        <a id="nav-sessions" href="#sessions" aria-current="page" data-i18n="Sessions">会话</a>
        <a id="nav-search" href="#search" data-i18n="Search">搜索</a>
        <a id="nav-insights" href="#/insights" data-i18n="Insights">洞察</a>
        <a id="nav-dashboard" href="#dashboard" data-i18n="Dashboard">仪表盘</a>
        <a id="nav-stats" href="#stats" data-i18n="Stats">统计</a>
        <a id="nav-health" href="#health" data-i18n="Health">健康状况</a>
        <a id="nav-fleet" href="#/fleet" data-i18n="Machines">机器</a>
        <a id="nav-settings" href="#settings" data-i18n="Settings">设置</a>
        </nav>
        <form id="login">
        <label><span data-i18n="Credential">凭据</span> <input id="credential" name="credential" type="password" autocomplete="current-password"></label>
        <button type="submit" data-i18n="Log in">登录</button>
        </form>
        <div class="header-tools">
        <button id="command-trigger" type="button" aria-label="搜索页面和已加载会话" data-i18n-aria-label="Search pages and sessions" aria-haspopup="dialog" aria-controls="command-dialog" title="命令（Cmd/Ctrl+K）" data-i18n-title="Commands (Cmd/Ctrl+K)" hidden><span class="command-trigger-label" data-i18n="Commands">命令</span> <kbd>⌘ K</kbd></button>
        <label class="language-picker"><span class="visually-hidden" data-i18n="Interface language">界面语言</span><select id="ui-language"><option value="zh-CN" lang="zh-CN">简体中文</option><option value="en" lang="en">English</option></select></label>
        <button id="shortcuts-help" type="button" aria-label="键盘快捷键" data-i18n-aria-label="Keyboard shortcuts" title="键盘快捷键（?）" data-i18n-title="Keyboard shortcuts (?)" hidden>?</button>
        <button id="logout" type="button" hidden data-i18n="Log out">退出登录</button>
        </div></div>
        <div class="header-feedback">
        <p id="identity-status" class="meta visually-hidden" role="status"></p>
        <p id="status" role="status"></p>
        <p id="language-status" role="status"></p>
        </div>
        </header>
        <section id="signed-out" class="sign-in-card" aria-labelledby="sign-in-heading">
        <h2 id="sign-in-heading" data-i18n="Your session library, in one place">你的会话库，汇聚一处</h2>
        <p data-i18n="Sign in to browse your session library.">登录以浏览你的会话库。</p><p class="meta" data-i18n="Read captured conversations, search your work and review source activity.">阅读已采集的对话，搜索工作记录，查看来源活动。</p></section>
        <dialog id="shortcuts-dialog" hidden role="dialog" aria-modal="true" aria-labelledby="shortcuts-title" tabindex="-1">
        <h2 id="shortcuts-title" data-i18n="Keyboard shortcuts">键盘快捷键</h2>
        <p data-i18n="Cmd/Ctrl+K — commands (or use the Commands button). Pages and loaded sessions only; no global search.">Cmd/Ctrl+K — 命令（或使用“命令”按钮）。仅限页面和已加载会话；不提供全局搜索。</p>
        <p data-i18n="/ — focus search (find in a transcript) · j/k — select session · Enter — open selected session">/ — 聚焦搜索（在对话记录中查找） · j/k — 选择会话 · Enter — 打开所选会话</p>
        <p data-i18n="Esc — close help, find or filters, then return to list · ? — show this help">Esc — 关闭帮助、查找或筛选，然后返回列表 · ? — 显示此帮助</p>
        <p data-i18n="In transcript find: Enter / Shift+Enter — next / previous. Searches only the loaded message model; Search further loads up to 5 pages.">对话记录内查找：Enter / Shift+Enter — 下一处 / 上一处。仅搜索已加载的消息模型；“继续搜索”最多加载 5 页。</p>
        <button id="shortcuts-close" type="button" data-i18n="Close help">关闭帮助</button></dialog>
        <dialog id="command-dialog" hidden role="dialog" aria-modal="true" aria-labelledby="command-title" tabindex="-1">
        <h2 id="command-title" data-i18n="Commands">命令</h2>
        <label for="command-query" class="visually-hidden" data-i18n="Find a command or loaded session">查找命令或已加载会话</label>
        <input id="command-query" type="text" role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="command-results" aria-describedby="command-scope command-status" autocomplete="off" maxlength="120" placeholder="页面、已加载会话或操作…" data-i18n-placeholder="Page, loaded session or action…">
        <p id="command-scope" class="meta"></p>
        <div id="command-results" role="listbox" aria-label="命令" data-i18n-aria-label="Commands"></div>
        <p id="command-status" class="meta" role="status" aria-live="polite"></p>
        <div class="command-footer"><span class="meta" data-i18n="↑ ↓ select · Enter run · Esc close">↑ ↓ 选择 · Enter 执行 · Esc 关闭</span><button id="command-close" type="button" data-i18n="Close commands">关闭命令面板</button></div>
        </dialog>
        <main id="workspace" hidden>
        <section id="library-page">
        <aside class="list-pane">
        <section id="overview"></section>
        <form id="search">
        <label id="search-query"><span class="visually-hidden" data-i18n="Search">搜索</span> <input id="query" name="query" type="search" placeholder="关键词" data-i18n-placeholder="Keywords"></label>
        <details id="source-picker" class="facet-picker">
        <summary id="source-summary" data-i18n="All sources">所有来源</summary>
        <div class="facet-menu">
        <p id="source-status" role="status"></p>
        <div id="source-options" class="facet-options"></div>
        <button id="source-more" type="button" hidden data-i18n="More sources">更多来源</button>
        <button id="source-clear" type="button" data-i18n="Clear sources">清除来源选择</button>
        </div>
        </details>
        <details id="project-picker" class="facet-picker">
        <summary id="project-summary" data-i18n="All projects">所有项目</summary>
        <div class="facet-menu">
        <div class="facet-search">
        <label for="project-query" class="visually-hidden" data-i18n="Search projects">搜索项目</label>
        <input id="project-query" type="search" placeholder="搜索项目…" data-i18n-placeholder="Search projects…" maxlength="1024">
        <button id="project-find" type="button" data-i18n="Find">查找</button>
        </div>
        <p id="project-status" role="status"></p>
        <div id="project-options" class="facet-options"></div>
        <button id="project-more" type="button" hidden data-i18n="More projects">更多项目</button>
        <button id="project-clear" type="button" data-i18n="Clear projects">清除项目选择</button>
        </div>
        </details>
        <details class="advanced-filters">
        <summary data-i18n="Advanced filters">高级筛选</summary>
        <label><span data-i18n="Session order">会话排序</span> <select id="session-sort"><option value="started" data-i18n="Started (newest first)">开始时间（最新优先）</option><option value="lastActivity" data-i18n="Last activity (newest first)">最近活动（最新优先）</option></select></label>
        <label><span data-i18n="Since">起始时间</span> <input id="since" name="since" type="date"></label>
        <label><span data-i18n="Until">截止时间</span> <input id="until" name="until" type="date"></label>
        <label class="tool-filter"><input id="hide-tools" type="checkbox"> <span data-i18n="Hide tool-only sessions">隐藏仅含工具的会话</span></label>
        <label><span data-i18n="Machine ID">机器 ID</span> <input id="machineId" name="machineId" placeholder="机器 ID" data-i18n-placeholder="Machine ID"></label>
        </details>
        <button type="submit" data-i18n="Search">搜索</button>
        </form>
        <section id="search-options" hidden>
        <div class="search-mode-controls">
        <label><span data-i18n="Search mode">搜索模式</span> <select id="search-mode"><option id="mode-keyword" value="keyword" data-i18n="Keyword">关键词</option><option id="mode-semantic" value="semantic" disabled data-i18n="Semantic">语义</option><option id="mode-hybrid" value="hybrid" disabled data-i18n="Hybrid">混合</option></select></label>
        <label><span data-i18n="Results">结果</span> <select id="search-limit"><option value="10">10</option><option value="25" selected>25</option><option value="50">50</option></select></label>
        </div>
        <details id="search-capability-details" class="search-secondary"><summary id="search-capability-summary" data-i18n="Search availability &amp; index">搜索可用性与索引</summary><p id="search-capabilities" role="status"></p></details>
        <p id="search-result-status" role="status"></p>
        <button id="search-more" type="button" hidden data-i18n="Load more search results">加载更多搜索结果</button>
        <details id="insight-compose" class="search-secondary">
        <summary data-i18n="Save an insight">保存一条洞察</summary>
        <p id="insight-write-status" role="status"></p>
        <form id="insight-save-form" hidden>
        <label><span data-i18n="Insight">洞察</span> <textarea id="insight-content-input" rows="6" maxlength="50000" placeholder="记录一条经验或笔记，以便日后查找…" data-i18n-placeholder="A lesson or note to find again…" required></textarea></label>
        <div class="search-mode-controls">
        <label><span data-i18n="Category">类别</span> <input id="insight-wing-input" maxlength="200" placeholder="可选" data-i18n-placeholder="Optional"></label>
        <label><span data-i18n="Topic">主题</span> <input id="insight-room-input" maxlength="200" placeholder="可选" data-i18n-placeholder="Optional"></label>
        <label><span data-i18n="Importance">重要程度</span> <select id="insight-importance-input"><option value="5" data-i18n="5 — High">5 — 高</option><option value="4">4</option><option value="3">3</option><option value="2">2</option><option value="1">1</option><option value="0" data-i18n="0 — Low">0 — 低</option></select></label>
        </div>
        <label><span data-i18n="Source session ID">来源会话 ID</span> <input id="insight-source-input" maxlength="4096" placeholder="可选；留空则保存为会话库笔记" data-i18n-placeholder="Optional; leave blank for a library note"></label>
        <button id="insight-save-button" type="submit" data-i18n="Save insight">保存洞察</button>
        </form>
        <button id="insight-saved-read" type="button" hidden data-i18n="Read saved insight">阅读已保存的洞察</button>
        </details>
        </section>
        <div id="active-filters" class="active-filters" aria-label="当前筛选条件" data-i18n-aria-label="Active filters" hidden></div>
        <div class="list-toolbar">
        <div class="agent-filters segmented" role="group" aria-label="智能体会话" data-i18n-aria-label="Agent sessions">
        <button id="agents-hide" type="button" aria-pressed="true" data-i18n="Hide Agents">隐藏智能体</button>
        <button id="agents-all" type="button" aria-pressed="false" data-i18n="All">全部</button>
        <button id="agents-only" type="button" aria-pressed="false" data-i18n="Agents Only">仅智能体</button>
        </div>
        <form id="session-jump" class="session-jump">
        <label for="session-id" class="visually-hidden" data-i18n="Session ID">会话 ID</label>
        <input id="session-id" name="sessionId" placeholder="会话 ID…" data-i18n-placeholder="Session ID…" maxlength="4096" autocomplete="off">
        <button type="submit" data-i18n="Go to session">前往会话</button>
        </form>
        </div>
        <section id="insight-results" hidden><h2 data-i18n="Insights across your library">整个会话库的洞察</h2><div id="insight-rows"></div></section>
        <section id="sessions"></section>
        <div class="session-pagination" aria-label="会话页面" data-i18n-aria-label="Session pages">
        <button id="session-previous" type="button" hidden data-i18n="Previous">上一项</button>
        <span id="session-page-status" role="status"></span>
        <button id="more" type="button" hidden data-i18n="Next">下一项</button>
        </div>
        </aside>
        <section class="detail-pane">
        <button id="back" type="button" hidden data-i18n="Sessions">会话</button>
        <div id="detail-header"><section id="detail"></section>
        <nav id="detail-view-nav" class="agent-filters" aria-label="会话视图" data-i18n-aria-label="Session views" hidden>
        <button id="detail-view-transcript" type="button" aria-pressed="true" data-i18n="Transcript">对话记录</button>
        <button id="detail-view-timeline" type="button" aria-pressed="false" data-i18n="Timeline">时间线</button>
        <button id="detail-view-children" type="button" aria-pressed="false" data-i18n="Child sessions">子会话</button>
        <button id="detail-view-info" type="button" aria-pressed="false" data-i18n="Info">信息</button>
        </nav>
        <form id="transcript-find" class="agent-filters" hidden>
        <label><span data-i18n="Find in loaded messages">在已加载消息中查找</span> <input id="transcript-find-query" type="search" maxlength="500" autocomplete="off"></label>
        <button type="submit" data-i18n="Next">下一项</button><button id="transcript-find-prev" type="button" data-i18n="Previous">上一项</button>
        <button id="transcript-find-more" type="button" data-i18n="Search further (up to 5 pages)">继续搜索（最多 5 页）</button>
        <button id="transcript-find-close" type="button" data-i18n="Close find">关闭查找</button>
        <p id="transcript-find-status" role="status" aria-live="polite"></p><p id="transcript-find-preview" class="find-preview"></p>
        </form>
        </div>
        <section id="detail-info-panel" hidden><div id="detail-info-content"></div>
        <section id="session-summary" class="settings-section" hidden><h3 data-i18n="Summary">摘要</h3><div id="session-summary-text"></div></section>
        <details id="session-actions" class="advanced-filters" hidden>
        <summary data-i18n="Generate summary or title">生成摘要或标题</summary>
        <p id="session-action-status" role="status"></p>
        <div class="search-mode-controls"><button id="session-generate-summary" type="button" disabled data-i18n="Generate summary">生成摘要</button><button id="session-generate-title" type="button" disabled data-i18n="Generate title">生成标题</button></div>
        </details>
        </section>
        <section id="transcript-panel">
        <div id="transcript-toolbar">
        <div id="transcript-filters" class="agent-filters" role="group" aria-label="已加载消息的类型" data-i18n-aria-label="Message types in loaded messages"></div>
        <p class="meta" data-i18n="Counts cover loaded messages; Tools counts call/result cards. Categories can overlap.">计数仅覆盖已加载的消息；“工具”统计调用/结果卡片。各类别可能重叠。</p>
        <div class="agent-filters"><span id="transcript-loaded" role="status"></span>
        <button id="transcript-find-toggle" type="button" aria-controls="transcript-find" aria-expanded="false" data-i18n="Find in loaded">在已加载内容中查找</button>
        <button id="transcript-minimap-toggle" type="button" aria-controls="transcript-minimap-box" aria-expanded="false" data-i18n="Minimap">概览图</button>
        <button id="transcript-outline-toggle" type="button" aria-controls="transcript-outline-box" aria-expanded="false" data-i18n="Outline">大纲</button>
        <button id="transcript-load-all" type="button" data-i18n="Load all">加载全部</button>
        <button id="transcript-end" type="button" data-i18n="Jump to end">跳转到末尾</button>
        <button id="transcript-copy-id" type="button" data-i18n="Copy session ID">复制会话 ID</button>
        <button id="transcript-copy" type="button" data-i18n="Copy loaded Markdown">复制已加载的 Markdown</button>
        <button id="transcript-previous" type="button" data-i18n="↑ Previous">↑ 上一处</button><button id="transcript-next" type="button" data-i18n="↓ Next">↓ 下一处</button></div>
        </div>
        <section id="transcript-minimap-box" aria-label="对话记录概览图" data-i18n-aria-label="Transcript minimap" hidden>
        <p id="transcript-minimap-status" role="status"></p>
        <p class="meta" data-i18n="Ordinal coverage: solid = loaded · dashed = partial · hollow = not loaded. Ring = selected jump · underline = viewport. Arrow keys/Home/End move focus; Enter jumps.">序号覆盖范围：实心 = 已加载 · 虚线 = 部分加载 · 空心 = 未加载。圆环 = 已选跳转目标 · 下划线 = 可视区域。方向键/Home/End 移动焦点；Enter 跳转。</p>
        <nav id="transcript-minimap" aria-label="序号范围" data-i18n-aria-label="Ordinal ranges"></nav>
        <p id="transcript-minimap-position" role="status"></p>
        <button id="transcript-minimap-more" type="button" data-i18n="Load map timeline (optional)">加载概览图时间线（可选）</button>
        </section>
        <details id="transcript-outline-box" hidden><summary data-i18n="Prompt outline · loaded coverage">提示词大纲 · 已加载的覆盖范围</summary>
        <p id="transcript-outline-status" role="status"></p><nav id="transcript-outline" aria-label="提示词大纲" data-i18n-aria-label="Prompt outline"></nav>
        <button id="transcript-outline-more" type="button" hidden data-i18n="More outline entries">更多大纲条目</button></details>
        <section id="messages"></section>
        <button id="more-messages" type="button" hidden data-i18n="Load more messages">加载更多消息</button>
        </section>
        <section id="timeline-panel" hidden>
        <div class="page-heading"><h3 data-i18n="Timeline">时间线</h3><button id="timeline-refresh" type="button" data-i18n="Refresh">刷新</button></div>
        <p id="timeline-status" role="status"></p><div id="timeline-rows"></div>
        <button id="timeline-more" type="button" hidden data-i18n="Load more events">加载更多事件</button>
        </section>
        <section id="detail-children-panel" hidden>
        <div class="page-heading"><h3 data-i18n="Child sessions">子会话</h3><button id="detail-children-refresh" type="button" data-i18n="Refresh">刷新</button></div>
        <button id="relationship-edit" type="button" data-i18n="Edit relationships">编辑关联关系</button>
        <p id="relationship-access" role="status"></p>
        <form id="relationship-form" class="stats-filters" hidden>
        <label><span data-i18n="Child session ID">子会话 ID</span> <input id="relationship-child-id" required maxlength="4096" autocomplete="off" placeholder="要关联到此父会话的会话" data-i18n-placeholder="Session to link to this parent"></label>
        <button id="relationship-add" type="submit" data-i18n="Link child">关联子会话</button>
        </form>
        <p id="relationship-status" role="status"></p>
        <p id="detail-children-status" role="status"></p><div id="detail-children-rows"></div>
        <button id="detail-children-more" type="button" hidden data-i18n="Load more child sessions">加载更多子会话</button>
        </section>
        </section>
        </section>
        <section id="insights-page" hidden>
        <div class="page-heading"><h2 data-i18n="Insights">洞察</h2><button id="insights-refresh" type="button" data-i18n="Refresh insights">刷新洞察</button></div>
        <p class="meta" data-i18n="Active library notes: global notes and notes linked to currently admitted sessions. Agent sessions are excluded. Previews are redacted and limited to 600 characters.">会话库中的有效笔记：全局笔记及关联到当前获准纳入的会话的笔记。不含智能体会话。预览已脱敏，最多显示 600 个字符。</p>
        <p id="insights-status" role="status" aria-live="polite"></p>
        <div id="insights-rows"></div>
        <button id="insights-more" type="button" hidden data-i18n="Load more insights">加载更多洞察</button>
        </section>
        <section id="fleet-page" hidden aria-labelledby="fleet-heading">
        <div class="page-heading"><h2 id="fleet-heading" data-i18n="Fleet dashboard">机群仪表盘</h2><button id="fleet-refresh" type="button" data-i18n="Refresh machines">刷新机器</button></div>
        <p class="meta" data-i18n="Sampled telemetry, not a service-health verdict. Refreshes every 30 seconds while open; an empty upload queue does not prove capture completeness.">这是采样遥测数据，并非服务健康状况的判定。页面打开时每 30 秒刷新一次；上传队列为空并不能证明采集完整。</p>
        <p id="fleet-status" role="status" aria-live="polite"></p>
        <dl id="fleet-summary" class="fleet-summary"></dl>
        <div id="fleet-content"></div>
        <p class="health-note" data-i18n="Files, capture generations, ingest tasks, and logical sessions are different units. Cooling files stay dirty until their re-capture window ends. Privacy-withheld files are not upload failures. Tracked-file counts exclude unsupported or untracked files. Session counts are database totals; Web source-admission rules may reduce browse results. Parsed skip-tier sessions and historical quarantine outcomes are not a search backlog.">文件、采集代次、接收处理任务和逻辑会话是不同的计量单位。冷却中的文件在重新采集窗口结束前仍处于待重新采集状态。因隐私而暂不上传的文件不属于上传失败。已跟踪文件计数不含不支持或未跟踪的文件。会话计数是数据库中的总数；Web 的来源准入规则可能减少可浏览的结果。已解析的 skip 层级会话和历史隔离结果不属于搜索待处理积压。</p>
        </section>
        <section id="health-page" hidden>
        <div class="page-heading"><h2 data-i18n="Health">健康状况</h2><button id="health-refresh" type="button" data-i18n="Refresh">刷新</button></div>
        <p data-i18n="Heartbeat shows collector liveness, not capture activity. A live collector may have no new conversations to capture.">心跳显示采集器的存活状态，而非采集活动。存活的采集器也可能没有新对话可采集。</p>
        <p id="health-status" role="status"></p>
        <p id="health-summary" class="health-summary"></p>
        <div id="health-content" class="health-grid"></div>
        </section>
        <section id="settings-page" hidden>
        <div class="page-heading"><h2 data-i18n="Settings">设置</h2><button id="settings-refresh" type="button" data-i18n="Refresh">刷新</button></div>
        <p class="meta" data-i18n="Server configuration and captured-library metadata. Values come from this deployment, not the device running your browser.">服务器配置与已采集会话库的元数据。数值来自此部署，而非运行浏览器的设备。</p>
        <p id="settings-access" role="status"></p>
        <p id="settings-status" role="status"></p>
        <div id="settings-content"></div>
        <button id="settings-more" type="button" hidden data-i18n="More project aliases">更多项目别名</button>
        <h3 class="settings-heading" data-i18n="Configuration &amp; actions">配置与操作</h3>
        <details id="ai-config" class="settings-section">
        <summary data-i18n="AI settings">AI 设置</summary>
        <p data-i18n="Configure summaries, titles, semantic search and call history. API keys are managed on the server.">配置摘要、标题、语义搜索和调用历史。API 密钥由服务器管理。</p>
        <p data-i18n="Environment overrides can take precedence. Changing the embedding model or dimensions does not rebuild stored vectors.">环境覆盖设置可能优先生效。更改嵌入模型或维度不会重建已存储的向量。</p>
        <form id="ai-config-form">
        <fieldset class="ai-config-group"><legend data-i18n="Summaries">摘要</legend>
        <label><span data-i18n="Protocol">协议</span><select id="ai-config-aiProtocol"><option value="openai">openai</option><option value="disabled" data-i18n="disabled">已停用</option></select></label>
        <label><span data-i18n="API base URL">API 基础 URL</span><input id="ai-config-aiBaseURL" maxlength="2048"></label>
        <label><span data-i18n="Model">模型</span><input id="ai-config-aiModel" maxlength="256"></label>
        <label><span data-i18n="Language">语言</span><input id="ai-config-summaryLanguage" maxlength="64"></label>
        <label><span data-i18n="Maximum sentences">最大句子数</span><input id="ai-config-summaryMaxSentences" type="number" required min="1" max="20" step="1"></label>
        <label><span data-i18n="Style">风格</span><input id="ai-config-summaryStyle" maxlength="512"></label>
        <label><span data-i18n="Custom prompt">自定义提示词</span><textarea id="ai-config-summaryPrompt" rows="3" maxlength="8000"></textarea></label>
        <label><span data-i18n="Maximum output tokens">最大输出 token 数</span><input id="ai-config-summaryMaxTokens" type="number" required min="1" max="32768" step="1"></label>
        <label><span data-i18n="Temperature">温度</span><input id="ai-config-summaryTemperature" type="number" required min="0" max="2" step="0.1"></label>
        <label><span data-i18n="First messages">开头消息</span><input id="ai-config-summarySampleFirst" type="number" required min="0" max="200" step="1"></label>
        <label><span data-i18n="Last messages">末尾消息</span><input id="ai-config-summarySampleLast" type="number" required min="0" max="200" step="1"></label>
        <label><span data-i18n="Characters per message">每条消息的字符数</span><input id="ai-config-summaryTruncateChars" type="number" required min="1" max="10000" step="1"></label>
        </fieldset>
        <fieldset class="ai-config-group"><legend data-i18n="Titles">标题</legend>
        <label><span data-i18n="Provider">提供商</span><select id="ai-config-titleProvider"><option value="ollama">ollama</option><option value="custom" data-i18n="custom">自定义</option><option value="openai">openai</option></select></label>
        <label><span data-i18n="API base URL">API 基础 URL</span><input id="ai-config-titleBaseUrl" maxlength="2048"></label>
        <label><span data-i18n="Model">模型</span><input id="ai-config-titleModel" maxlength="256"></label>
        </fieldset>
        <fieldset class="ai-config-group"><legend data-i18n="Semantic search">语义搜索</legend>
        <label><span data-i18n="API base URL">API 基础 URL</span><input id="ai-config-embeddingBaseURL" maxlength="2048"></label>
        <label><span data-i18n="Model">模型</span><input id="ai-config-embeddingModel" maxlength="256"></label>
        <label><span data-i18n="Dimensions">维度</span><input id="ai-config-embeddingDimension" type="number" required min="1" max="65536" step="1"></label>
        <label><span data-i18n="Send dimensions to provider">向提供商发送维度参数</span><input id="ai-config-embeddingIncludeDimensions" type="checkbox"></label>
        </fieldset>
        <fieldset class="ai-config-group"><legend data-i18n="AI call history">AI 调用历史</legend>
        <label><span data-i18n="Record calls">记录调用</span><input id="ai-config-aiAudit.enabled" type="checkbox"></label>
        <label><span data-i18n="Store redacted request and response bodies">存储脱敏后的请求与响应正文</span><input id="ai-config-aiAudit.logBodies" type="checkbox"></label>
        <label><span data-i18n="Maximum stored body size">最大正文存储大小</span><input id="ai-config-aiAudit.maxBodySize" type="number" required min="1" max="1000000" step="1"></label>
        </fieldset>
        <div class="ai-config-actions"><button id="ai-config-save" type="submit" disabled data-i18n="Save changes">保存更改</button><button id="ai-config-reload" type="button" data-i18n="Reload saved settings">重新加载已保存的设置</button></div>
        </form><p id="ai-config-status" role="status"></p>
        </details>
        <section id="batch-title-actions" class="settings-section" hidden>
        <h3 data-i18n="Session titles">会话标题</h3><p data-i18n="Generate titles for sessions that do not yet have one, using the configured AI provider.">使用已配置的 AI 提供商，为尚无标题的会话生成标题。</p>
        <button id="batch-title-button" type="button" data-i18n="Generate missing titles">生成缺失的标题</button><p id="batch-title-status" role="status"></p>
        </section>
        <section id="source-settings" class="settings-section" hidden>
        <h3 data-i18n="Source settings">来源设置</h3>
        <p data-i18n="These controls change importing and session visibility on this server.">这些控件会更改此服务器上的导入行为和会话可见性。</p>
        <table aria-label="来源配置" data-i18n-aria-label="Source configuration"><thead><tr><th data-i18n="Source">来源</th><th data-i18n="Status">状态</th><th data-i18n="Action">操作</th></tr></thead><tbody id="source-settings-rows"></tbody></table>
        </section>
        <p id="source-settings-status" role="status"></p>
        <p id="source-write-status" role="status"></p>
        <section id="alias-editor" class="settings-section" hidden>
        <h3 data-i18n="Add project alias">添加项目别名</h3>
        <form id="alias-project-form" class="stats-filters">
        <label><span data-i18n="Find destination project">查找目标项目</span> <input id="alias-project-query" type="search" maxlength="1000"></label>
        <button id="alias-project-search" type="submit" data-i18n="Find">查找</button>
        </form>
        <p id="alias-project-status" role="status"></p>
        <form id="alias-form" class="stats-filters">
        <label><span data-i18n="Old name or path">旧名称或路径</span> <input id="alias-text" required maxlength="1000" placeholder="/old/project"></label>
        <label><span data-i18n="Destination project">目标项目</span> <select id="alias-canonical" required></select></label>
        <button id="alias-add" type="submit" data-i18n="Add alias">添加别名</button>
        </form>
        <button id="alias-project-more" type="button" hidden data-i18n="More destination projects">更多目标项目</button>
        </section>
        <p id="alias-status" role="status"></p>
        </section>
        <section id="dashboard-page" hidden aria-labelledby="dashboard-heading">
        <div class="page-heading"><h2 id="dashboard-heading" data-i18n="Dashboard">仪表盘</h2><button id="dashboard-refresh" type="button" data-i18n="Refresh dashboard">刷新仪表盘</button></div>
        <p class="meta" data-i18n="Last 30 calendar dates · agents hidden · server-local day buckets. Costs include priced usage only, not a billing statement.">最近 30 个日历日 · 已隐藏智能体 · 按服务器本地日期分桶。费用仅包含已计价用量，不代表账单。</p>
        <div id="dashboard-kpis" class="dashboard-kpis"></div>
        <div id="dashboard-activity"></div>
        <button id="dashboard-hours-load" type="button" data-i18n="Load session-start heatmap">加载会话开始热力图</button><div id="dashboard-hours"></div>
        <div class="dashboard-grid"><div id="dashboard-cost"></div><div id="dashboard-sources"></div><div id="dashboard-projects"></div></div>
        <p id="dashboard-health" class="meta"></p>
        <p id="dashboard-dependencies" class="meta" data-i18n="Heatmap counts session starts, not work duration. Per-source health history is unavailable. No activity is inferred from heartbeats.">热力图统计会话开始次数，而非工作时长。各来源的健康历史不可用。不会根据心跳推断活动。</p>
        </section>
        <section id="stats-page" hidden>
        <div class="page-heading"><h2 data-i18n="Stats">统计</h2></div>
        <div class="agent-filters" role="group" aria-label="统计视图" data-i18n-aria-label="Statistics view"><button id="stats-view-sessions" type="button" aria-pressed="true" data-i18n="Sessions">会话</button><button id="stats-view-costs" type="button" aria-pressed="false" data-i18n="Costs">费用</button><button id="stats-view-tools" type="button" aria-pressed="false" data-i18n="Tools">工具</button><button id="stats-view-files" type="button" aria-pressed="false" data-i18n="Files">文件</button><button id="stats-view-usage" type="button" aria-pressed="false" data-i18n="Usage">用量</button><button id="stats-view-repos" type="button" aria-pressed="false" data-i18n="Repositories">仓库</button><button id="stats-view-ai" type="button" aria-pressed="false" data-i18n="AI calls">AI 调用</button></div>
        <div id="stats-content">
        <form id="stats-form" class="stats-filters">
        <label><span data-i18n="Group by">分组依据</span> <select id="stats-group"><option value="source" data-i18n="Source">来源</option><option value="project" data-i18n="Project">项目</option><option value="day" data-i18n="Day">日期</option><option value="week" data-i18n="Week">周</option><option value="hourOfWeek" data-i18n="Weekday / hour (session starts)">星期 / 小时（会话开始次数）</option></select></label>
        <label><span data-i18n="Source">来源</span> <select id="stats-source"><option value="" data-i18n="All sources">所有来源</option></select></label>
        <label><span data-i18n="Project">项目</span> <select id="stats-project"><option value="" data-i18n="All projects">所有项目</option></select></label>
        <button id="stats-choices" type="button" data-i18n="Load filter choices">加载筛选选项</button><span id="stats-choices-status" class="meta" role="status"></span>
        <label><span data-i18n="Since">起始时间</span> <input id="stats-since" type="date"></label>
        <label><span data-i18n="Until">截止时间</span> <input id="stats-until" type="date"></label>
        <label><span data-i18n="Agents">智能体</span> <select id="stats-agents"><option value="hide" data-i18n="Hide agents">隐藏智能体</option><option value="all" data-i18n="All">全部</option><option value="only" data-i18n="Agents only">仅智能体</option></select></label>
        <label><input id="stats-noise" type="checkbox"> <span data-i18n="Exclude lightweight sessions">排除轻量会话</span></label>
        <button type="submit" data-i18n="Apply">应用</button>
        </form>
        <p id="stats-status" role="status"></p>
        <dl id="stats-totals" class="stats-totals"></dl>
        <div id="stats-chart"></div>
        <div class="stats-table"><table aria-label="会话统计" data-i18n-aria-label="Session statistics"><thead><tr><th data-i18n="Group">分组</th><th data-i18n="Sessions">会话</th><th data-i18n="Messages">消息</th><th data-i18n="User">用户</th><th data-i18n="Assistant">助手</th><th data-i18n="Tool">工具</th></tr></thead><tbody id="stats-rows"></tbody></table></div>
        <button id="stats-more" type="button" hidden data-i18n="More groups">更多分组</button>
        </div>
        <div id="costs-content" hidden>
        <form id="costs-form" class="stats-filters">
        <label><span data-i18n="Group by">分组依据</span> <select id="costs-group"><option value="model" data-i18n="Model">模型</option><option value="source" data-i18n="Source">来源</option><option value="project" data-i18n="Project">项目</option><option value="day" data-i18n="Day">日期</option></select></label>
        <label><span data-i18n="Since">起始时间</span> <input id="costs-since" type="date"></label>
        <label><span data-i18n="Until">截止时间</span> <input id="costs-until" type="date"></label>
        <label><span data-i18n="Agents">智能体</span> <select id="costs-agents"><option value="hide" data-i18n="Hide agents">隐藏智能体</option><option value="all" data-i18n="All">全部</option><option value="only" data-i18n="Agents only">仅智能体</option></select></label>
        <label><span data-i18n="Top sessions">排名靠前的会话</span> <select id="costs-limit"><option value="20">20</option><option value="50">50</option><option value="100">100</option></select></label>
        <button type="submit" data-i18n="Apply">应用</button>
        </form>
        <p id="costs-status" role="status"></p>
        <dl id="costs-totals" class="stats-totals"></dl>
        <p id="costs-unpriced"></p>
        <div id="costs-chart"></div>
        <div class="stats-table"><table aria-label="费用明细" data-i18n-aria-label="Cost breakdown"><thead><tr><th data-i18n="Group">分组</th><th>USD</th><th data-i18n="Sessions">会话</th><th data-i18n="Input tokens">输入 token</th><th data-i18n="Output tokens">输出 token</th><th data-i18n="Cache read">缓存读取</th><th data-i18n="Cache write">缓存写入</th></tr></thead><tbody id="costs-rows"></tbody></table></div>
        <button id="costs-more" type="button" hidden data-i18n="More groups">更多分组</button>
        <h3 data-i18n="Highest-cost sessions">费用最高的会话</h3>
        <p id="costs-sessions-status" role="status"></p>
        <div class="stats-table"><table aria-label="会话费用" data-i18n-aria-label="Session costs"><thead><tr><th data-i18n="Session">会话</th><th data-i18n="Model">模型</th><th>USD</th><th data-i18n="Input tokens">输入 token</th><th data-i18n="Output tokens">输出 token</th><th data-i18n="Cache read">缓存读取</th><th data-i18n="Cache write">缓存写入</th></tr></thead><tbody id="costs-sessions"></tbody></table></div>
        </div>
        <div id="tools-content" hidden>
        <form id="tools-form" class="stats-filters">
        <label><span data-i18n="Group by">分组依据</span> <select id="tools-group"><option value="tool" data-i18n="Tool">工具</option><option value="session" data-i18n="Session">会话</option><option value="project" data-i18n="Project">项目</option></select></label>
        <label><span data-i18n="Project contains">项目包含</span> <input id="tools-project" type="search" placeholder="筛选项目" data-i18n-placeholder="Filter projects"></label>
        <label><span data-i18n="Since">起始时间</span> <input id="tools-since" type="date"></label>
        <label><span data-i18n="Until">截止时间</span> <input id="tools-until" type="date"></label>
        <label><span data-i18n="Agents">智能体</span> <select id="tools-agents"><option value="hide" data-i18n="Hide agents">隐藏智能体</option><option value="all" data-i18n="All">全部</option><option value="only" data-i18n="Agents only">仅智能体</option></select></label>
        <button type="submit" data-i18n="Apply">应用</button>
        </form>
        <p id="tools-status" role="status"></p>
        <p id="tools-totals"></p>
        <div id="tools-chart"></div>
        <div class="stats-table"><table aria-label="工具活动" data-i18n-aria-label="Tool activity"><thead><tr><th data-i18n="Group">分组</th><th data-i18n="Calls">调用</th><th data-i18n="Sessions">会话</th><th id="tools-col-tools" data-i18n="Tools">工具</th></tr></thead><tbody id="tools-rows"></tbody></table></div>
        <button id="tools-more" type="button" hidden data-i18n="More groups">更多分组</button>
        </div>
        <div id="files-content" hidden>
        <form id="files-form" class="stats-filters">
        <label><span data-i18n="Project contains">项目包含</span> <input id="files-project" type="search" placeholder="筛选项目" data-i18n-placeholder="Filter projects"></label>
        <label><span data-i18n="Since">起始时间</span> <input id="files-since" type="date"></label>
        <label><span data-i18n="Until">截止时间</span> <input id="files-until" type="date"></label>
        <label><span data-i18n="Agents">智能体</span> <select id="files-agents"><option value="hide" data-i18n="Hide agents">隐藏智能体</option><option value="all" data-i18n="All">全部</option><option value="only" data-i18n="Agents only">仅智能体</option></select></label>
        <button type="submit" data-i18n="Apply">应用</button>
        </form>
        <p id="files-status" role="status"></p>
        <p id="files-totals"></p>
        <div id="files-chart"></div>
        <div class="stats-table"><table aria-label="文件活动" data-i18n-aria-label="File activity"><thead><tr><th data-i18n="File">文件</th><th data-i18n="Reads">读取</th><th data-i18n="Edits">编辑</th><th data-i18n="Writes">写入</th><th data-i18n="Sessions">会话</th></tr></thead><tbody id="files-rows"></tbody></table></div>
        <button id="files-more" type="button" hidden data-i18n="More files">更多文件</button>
        </div>
        <div id="usage-content" hidden>
        <button id="usage-refresh" type="button" data-i18n="Reload observations">重新加载观测数据</button>
        <p id="usage-status" role="status"></p>
        <div id="usage-chart"></div>
        <div class="stats-table"><table aria-label="已记录用量" data-i18n-aria-label="Recorded usage"><thead><tr><th data-i18n="Source">来源</th><th data-i18n="Metric">指标</th><th data-i18n="Value / limit">值 / 上限</th><th data-i18n="Basis">依据</th><th data-i18n="Status">状态</th><th data-i18n="Resets">重置</th><th data-i18n="Collected">采样时间</th></tr></thead><tbody id="usage-rows"></tbody></table></div>
        </div>
        <div id="ai-content" hidden>
        <form id="ai-form" class="stats-filters">
        <label><span data-i18n="Caller">调用方</span> <input id="ai-caller" maxlength="128" placeholder="例如：summary" data-i18n-placeholder="e.g. summary"></label>
        <label><span data-i18n="Model">模型</span> <input id="ai-model" maxlength="128" placeholder="精确模型名称" data-i18n-placeholder="Exact model name"></label>
        <label><span data-i18n="Session ID">会话 ID</span> <input id="ai-session" maxlength="4096"></label>
        <label><span data-i18n="From">从</span> <input id="ai-from" type="date"></label>
        <label><span data-i18n="To">至</span> <input id="ai-to" type="date"></label>
        <label><span data-i18n="Outcome">结果</span> <select id="ai-errors"><option value="" data-i18n="All">全部</option><option value="true" data-i18n="Errors">错误</option><option value="false" data-i18n="Successful">成功</option></select></label>
        <button type="submit" data-i18n="Find calls">查找调用</button>
        <button id="ai-stats-refresh" type="button" data-i18n="View statistics">查看统计</button>
        </form>
        <p class="meta" data-i18n="Statistics use the date range only; without dates they cover the last 24 hours. Call history uses all filters.">统计仅使用日期范围；未指定日期时覆盖最近 24 小时。调用历史使用所有筛选条件。</p>
        <p id="ai-stats-status" role="status"></p><div id="ai-stats"></div>
        <p id="ai-status" role="status"></p><div id="ai-chart"></div>
        <div class="stats-table"><table aria-label="AI 调用历史" data-i18n-aria-label="AI call history"><thead><tr><th data-i18n="Call">调用</th><th data-i18n="Time / outcome">时间 / 结果</th><th data-i18n="Model">模型</th><th data-i18n="Tokens">token 数</th><th data-i18n="Details">详情</th></tr></thead><tbody id="ai-rows"></tbody></table></div>
        <button id="ai-more" type="button" hidden data-i18n="More calls">更多调用</button>
        <section id="ai-detail" class="settings-section" hidden aria-label="AI 调用详情" data-i18n-aria-label="AI call details"></section>
        </div>
        <div id="repos-content" hidden>
        <button id="repos-refresh" type="button" data-i18n="Reload observations">重新加载观测数据</button>
        <p id="repos-status" role="status"></p>
        <div id="repos-chart"></div>
        <div id="repos-rows" class="health-grid"></div>
        <button id="repos-more" type="button" hidden data-i18n="More repositories">更多仓库</button>
        </div>
        </section>
        </main>
        <dialog id="insight-dialog" hidden role="dialog" aria-modal="true" aria-labelledby="insight-heading" tabindex="-1">
        <div class="insight-heading"><h2 id="insight-heading" data-i18n="Insight">洞察</h2><button id="insight-close" type="button" data-i18n="Close">关闭</button></div>
        <p id="insight-detail-status" role="status"></p>
        <div id="insight-body"></div><button id="insight-more" type="button" hidden data-i18n="Read more">阅读更多</button>
        </dialog>
        <div id="toast-region" class="toast-region" aria-live="polite"></div>
        <script src="/web/app.js"></script>
        </body>
        </html>
        """

    static let css = """
        [hidden] { display: none !important; }
        /* Preserve the legacy Web palette from 5013bab7:src/web/views.ts. */
        :root { color-scheme: dark; --bg:#0f172a; --panel:#1e293b; --text:#f8fafc; --muted:#94a3b8; --line:#334155; --accent:#22c55e; --code:#0d1117; }
        /* Design tokens derived from the palette above; light mode overrides tokens only. */
        :root { color-scheme: light dark; --bg-sunken:#0b1222; --panel-2:#273548; --panel-3:#2d3c55; --line-soft:rgba(148,163,184,0.12); --text-dim:#64748b; --text-faint:#475569; --accent-dim:rgba(34,197,94,0.12); --accent-strong:#4ade80; --accent-ink:#052e16; --ok:#4ade80; --ok-bg:rgba(34,197,94,0.14); --warn:#fbbf24; --warn-bg:rgba(245,158,11,0.15); --danger:#f87171; --danger-bg:rgba(239,68,68,0.15); --info:#60a5fa; --info-bg:rgba(59,130,246,0.15); --agent:#c084fc; --agent-bg:rgba(168,85,247,0.15); --mark-bg:rgba(250,204,21,0.28); --mark-line:#facc15; --topbar-bg:rgba(15,23,42,0.82); --input-bg:color-mix(in srgb, var(--bg) 55%, var(--panel)); --shadow-1:0 1px 2px rgba(0,0,0,0.25); --shadow-2:0 8px 24px rgba(0,0,0,0.45); --shadow-3:0 24px 64px rgba(0,0,0,0.6); --s1:4px; --s2:8px; --s3:12px; --s4:16px; --s5:20px; --s6:24px; --s8:32px; --r-xs:4px; --r-sm:6px; --r-md:8px; --r-lg:12px; --r-xl:14px; --r-pill:999px; --fs-cap:11px; --fs-meta:12px; --fs-ui:13px; --fs-body:14px; --font:-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; --mono:ui-monospace, SFMono-Regular, "JetBrains Mono", Menlo, monospace; --dur-1:120ms; --ease:cubic-bezier(.2,.8,.2,1); }
        /* Legacy light tokens from 76706332:src/web/views.ts. */
        @media (prefers-color-scheme: light) {
          :root { color-scheme: light; --bg:#f8fafc; --panel:#ffffff; --text:#0f172a; --muted:#475569; --line:#e2e8f0; --accent:#15803d; --code:#f1f5f9; --bg-sunken:#f1f5f9; --panel-2:#f1f5f9; --panel-3:#e2e8f0; --line-soft:rgba(15,23,42,0.07); --text-dim:#64748b; --text-faint:#94a3b8; --accent-dim:rgba(22,163,74,0.10); --accent-strong:#15803d; --accent-ink:#ffffff; --ok:#15803d; --ok-bg:#dcfce7; --warn:#b45309; --warn-bg:#fef3c7; --danger:#b91c1c; --danger-bg:#fee2e2; --info:#1d4ed8; --info-bg:#dbeafe; --agent:#7e22ce; --agent-bg:#f3e8ff; --mark-bg:rgba(250,204,21,0.45); --mark-line:#ca8a04; --topbar-bg:rgba(248,250,252,0.86); --input-bg:#ffffff; --shadow-1:0 1px 2px rgba(15,23,42,0.06); --shadow-2:0 8px 24px rgba(15,23,42,0.12); --shadow-3:0 24px 64px rgba(15,23,42,0.18); }
        }
        * { box-sizing: border-box; }
        html { font-family: var(--font); }
        body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.6 var(--font); overflow-wrap: anywhere; letter-spacing: -0.006em; -webkit-font-smoothing: antialiased; }
        :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
        ::selection { background: color-mix(in srgb, var(--accent) 35%, transparent); }
        a { color: inherit; text-decoration: none; }
        .visually-hidden { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
        :root { --page-width:1600px; --page-gutter:24px; }
        .top-nav { padding: 8px 0; margin-bottom: 20px; border-bottom: 1px solid var(--line); position: sticky; top: 0; z-index: 20; background: var(--topbar-bg); backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px); }
        .header-row, .header-feedback { width: 100%; max-width: var(--page-width); margin: 0 auto; padding: 0 var(--page-gutter); }
        .header-row { display: flex; align-items: center; gap: 12px; min-height: 44px; }
        .header-tools { display: flex; align-items: center; gap: 6px; margin-left: auto; flex: none; }
        .header-tools button, .language-picker select { min-height: 44px; }
        .language-picker { display: flex; margin: 0; }
        .language-picker select { font: inherit; font-size: 12px; padding: 6px; }
        .header-feedback > p:empty { display: none; }
        #language-status { margin: 4px 0; color: var(--danger); }
        #status[data-tone="ok"], #status[data-tone="neutral"] { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
        h1 { display: flex; align-items: center; gap: 9px; margin: 0; font-size: 17px; line-height: 1.25; letter-spacing: -0.03em; font-weight: 680; }
        h1::before { content: ""; width: 10px; height: 10px; border-radius: 3px; background: var(--accent); box-shadow: 0 0 0 3px var(--accent-dim); }
        .lede, #status { margin: 0; color: var(--muted); font-size: 12px; }
        .lede { flex: 1; }
        #status { order: 4; display: inline-flex; align-items: center; gap: 6px; padding: 2px 10px; border: 1px solid var(--line); border-radius: var(--r-pill); white-space: nowrap; max-width: 100%; overflow: hidden; text-overflow: ellipsis; }
        #status::before { content: ""; flex: none; width: 7px; height: 7px; border-radius: 50%; background: var(--text-faint); }
        #status[data-tone="ok"]::before { background: var(--ok); box-shadow: 0 0 0 3px var(--ok-bg); }
        #status[data-tone="danger"] { color: var(--danger); border-color: color-mix(in srgb, var(--danger) 40%, var(--line)); background: var(--danger-bg); }
        #status[data-tone="danger"]::before { background: var(--danger); }
        #status:empty { display: none; }
        #logout { order: 5; }
        #shortcuts-help { order: 6; font-size: 12px; padding: 6px 9px; }
        .page-nav { position: relative; padding: 3px; display: flex; flex: 1 1 auto; gap: 2px; min-width: 0; overflow-x: auto; scrollbar-width: none; }
        .page-nav a { display: inline-flex; align-items: center; gap: 7px; padding: 6px 11px; border-radius: var(--r-md); color: var(--muted); font-weight: 550; font-size: 13px; letter-spacing: -0.01em; white-space: nowrap; transition: color var(--dur-1) ease, background var(--dur-1) ease; }
        .page-nav a .icon { flex: none; opacity: 0.85; }
        .page-nav a:hover { color: var(--text); background: var(--panel); }
        .page-nav a[aria-current="page"] { color: var(--accent-strong); background: var(--accent-dim); }
        .top-nav #login { margin: 0; }
        #login { display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: end; margin: 12px 0; }
        #login label { display: flex; flex-direction: column; gap: 4px; color: var(--muted); font-size: 12px; font-weight: 700; }
        #search { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 8px 0; }
        #search-query { position: relative; flex: 1 1 100%; min-width: 0; }
        #search-query input { width: 100%; min-width: 0; padding-left: 34px; }
        #search-query .icon { position: absolute; left: 11px; top: 50%; transform: translateY(-50%); color: var(--text-dim); pointer-events: none; }
        #search > .advanced-filters { flex: 1 1 100%; min-width: 0; order: 3; }
        .advanced-filters label { display: flex; flex-direction: column; gap: 4px; color: var(--muted); font-size: 12px; font-weight: 700; }
        .facet-picker { position: relative; flex: 1 1 10rem; min-width: 0; margin: 0; }
        .facet-picker > summary { display: flex; align-items: center; justify-content: space-between; gap: 8px; list-style: none; cursor: pointer; color: var(--text); border: 1px solid var(--line); border-radius: var(--r-md); background: var(--input-bg); padding: 7px 10px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; transition: border-color var(--dur-1) ease; }
        .facet-picker > summary::-webkit-details-marker { display: none; }
        .facet-picker > summary::after { content: ""; flex: none; width: 6px; height: 6px; margin: -3px 2px 0 0; border-right: 1.5px solid var(--text-dim); border-bottom: 1.5px solid var(--text-dim); transform: rotate(45deg); }
        .facet-picker > summary:hover, .facet-picker[open] > summary { border-color: color-mix(in srgb, var(--accent) 45%, var(--line)); }
        .facet-menu { position: absolute; left: 0; top: calc(100% + 4px); width: min(320px, calc(100vw - 32px)); min-width: 100%; z-index: 30; padding: 10px; border: 1px solid var(--line); border-radius: var(--r-lg); background: var(--panel); box-shadow: var(--shadow-2); }
        #project-picker .facet-menu { left: auto; right: 0; }
        .facet-options { max-height: 240px; overflow-y: auto; margin: 8px 0; }
        .facet-options label { display: flex; align-items: center; gap: 8px; padding: 5px 6px; border-radius: var(--r-sm); color: var(--text); cursor: pointer; }
        .facet-options label:hover { background: var(--panel-2); }
        .facet-options input { flex: 0 0 auto; accent-color: var(--accent); }
        .facet-options .facet-count { margin-left: auto; color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; }
        .source-dot { display: inline-block; flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--source-color, #64748b); }
        .facet-menu p { margin: 4px 0; }
        .facet-menu p:empty { display: none; }
        .facet-search { display: flex; gap: 6px; }
        .facet-search input { width: 100%; min-width: 0; }
        .facet-search button { flex-shrink: 0; white-space: nowrap; }
        #search > button { flex: 0 0 auto; order: 2; }
        .session-jump { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0; }
        .session-jump input { flex: 1 1 16rem; min-width: 0; }
        .agent-filters { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0; }
        .agent-filters button { border-radius: 999px; font-size: 12px; padding: 5px 12px; }
        .agent-filters button[aria-pressed="true"] { color: var(--accent-strong); border-color: var(--accent); background: var(--accent-dim); font-weight: 650; }
        .list-toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 12px; margin: 6px 0 12px; }
        .list-toolbar .agent-filters, .list-toolbar .session-jump { margin: 0; }
        .list-toolbar .session-jump { flex: 0 1 360px; flex-wrap: nowrap; }
        .list-toolbar .session-jump input { flex: 1 1 auto; padding-top: 5px; padding-bottom: 5px; font-size: 13px; }
        .list-toolbar .session-jump button { padding: 5px 10px; font-size: 13px; white-space: nowrap; }
        .segmented { display: inline-flex; flex-wrap: nowrap; gap: 2px; padding: 2px; border: 1px solid var(--line); border-radius: var(--r-md); background: var(--input-bg); }
        .segmented button, .segmented button:active { border: 1px solid transparent; border-radius: var(--r-sm); background: transparent; color: var(--muted); padding: 4px 12px; font-weight: 550; }
        .segmented button:hover { color: var(--text); border-color: transparent; }
        .segmented button[aria-pressed="true"] { color: var(--text); background: var(--panel-2); border-color: var(--line); box-shadow: var(--shadow-1); font-weight: 600; }
        .active-filters { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin: 2px 0 8px; }
        .chip { display: inline-flex; align-items: center; gap: 2px; max-width: 100%; padding: 2px 3px 2px 10px; border: 1px solid color-mix(in srgb, var(--accent) 35%, var(--line)); border-radius: var(--r-pill); background: var(--accent-dim); color: var(--text); font-size: 12px; line-height: 18px; }
        .chip-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .chip-remove, .chip-remove:active { display: inline-flex; padding: 2px; border: 0; border-radius: var(--r-pill); background: transparent; color: var(--muted); }
        .chip-remove:hover { color: var(--text); background: color-mix(in srgb, var(--text) 12%, transparent); }
        .chip-remove .icon { width: 12px; height: 12px; }
        .chip-clear, .chip-clear:active { border: 0; padding: 2px 6px; background: transparent; color: var(--muted); font-size: 12px; font-weight: 500; text-decoration: underline; text-underline-offset: 2px; }
        .agent-label { padding: 0 7px; border-radius: var(--r-pill); background: var(--agent-bg); color: var(--agent); font-size: 11px; font-weight: 650; line-height: 17px; }
        .match-badge { padding: 0 7px; border-radius: var(--r-pill); background: var(--info-bg); color: var(--info); font-size: 11px; font-weight: 600; line-height: 17px; }
        .match-badge[data-match="semantic"] { background: color-mix(in srgb, #14b8a6 16%, transparent); color: light-dark(#0f766e, #5eead4); }
        input, select { margin: 0; padding: 7px 10px; border: 1px solid var(--line); border-radius: 8px; background: var(--input-bg); color: var(--text); transition: border-color 0.12s ease, background 0.12s ease; }
        input:hover, select:hover { border-color: color-mix(in srgb, var(--accent) 45%, var(--line)); }
        input::placeholder, textarea::placeholder { color: var(--muted); opacity: 1; }
        input:focus, select:focus { border-color: var(--accent); background: var(--bg); outline: none; }
        button { margin: 0; padding: 7px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); color: var(--text); font-weight: 550; cursor: pointer; transition: border-color 0.12s ease, color 0.12s ease, background 0.12s ease; }
        button:hover { border-color: var(--accent); color: var(--accent); }
        button:active { background: color-mix(in srgb, var(--accent) 12%, var(--panel)); }
        button:disabled { opacity: 0.45; cursor: default; }
        #search > button[type="submit"], #login button[type="submit"] { background: var(--accent); border-color: var(--accent); color: var(--accent-ink); font-weight: 650; }
        #search > button[type="submit"]:hover, #login button[type="submit"]:hover { color: var(--accent-ink); background: color-mix(in srgb, var(--accent) 85%, var(--text)); }
        .icon { flex: none; vertical-align: middle; }
        #workspace { width: 100%; max-width: var(--page-width); margin: 0 auto; padding: 0 var(--page-gutter) 40px; }
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
        .insight-card { padding: 14px 16px; margin: 10px 0; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); box-shadow: var(--shadow-1); }
        .insight-card p { white-space: pre-wrap; }
        #insight-dialog { width: min(760px, calc(100vw - 32px)); max-height: 85vh; padding: 20px; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); color: var(--text); overflow-wrap: anywhere; }
        #insight-dialog::backdrop { background: rgba(0,0,0,.65); }
        .insight-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
        .insight-heading h2 { margin: 0; }
        #insight-body { white-space: pre-wrap; margin-bottom: 16px; }
        #insight-detail-status { color: var(--muted); }
        #session-summary-text p { color: var(--text); font-size: 14px; }
        .search-snippet { color: var(--muted); font-weight: 400; margin: 8px 0 0; line-height: 1.5; max-height: 4.5em; overflow: hidden; white-space: pre-wrap; }
        .search-snippet mark { background: var(--mark-bg); color: inherit; padding: 0 1px; border-radius: 2px; box-shadow: inset 0 -1px 0 var(--mark-line); }
        .session-pagination { display: flex; align-items: center; justify-content: center; flex-wrap: wrap; gap: 12px; padding: 12px 0; }
        #session-page-status { color: var(--muted); font-size: 12px; }
        .page-heading { display: flex; gap: 12px; align-items: center; justify-content: space-between; }
        .page-heading h2 { margin: 0; font-size: 20px; }
        #health-page > p { color: var(--muted); }
        .fleet-summary { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; padding: 12px 16px; margin: 16px 0; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; }
        .fleet-summary dt { font-size: 11px; color: var(--muted); }
        .fleet-summary dd { margin: 4px 0 0; font-size: 20px; font-weight: 650; font-variant-numeric: tabular-nums; }
        .fleet-table-wrap { min-width: 0; max-width: 100%; overflow-x: auto; }
        .fleet-table { width: 100%; border-collapse: collapse; font-size: 12px; white-space: nowrap; }
        .fleet-table caption { text-align: left; font-size: 13px; font-weight: 600; padding: 12px 0 8px; }
        .fleet-table th, .fleet-table td { text-align: right; padding: 9px 8px; border-bottom: 1px solid var(--line); font-variant-numeric: tabular-nums; vertical-align: top; }
        .fleet-table th:first-child, .fleet-table td:first-child { text-align: left; white-space: normal; }
        .fleet-table thead th { color: var(--muted); font-size: 11px; font-weight: 600; white-space: normal; }
        .fleet-table tbody th { font-weight: 500; }
        .fleet-overview { table-layout: fixed; }
        .fleet-overview > thead > tr > th, .fleet-overview > tbody > tr > th, .fleet-overview > tbody > tr > td { white-space: normal; overflow-wrap: anywhere; }
        .fleet-overview > thead th:first-child { width: 14%; }
        .fleet-overview > thead th:nth-child(2) { width: 19%; text-align: left; }
        .fleet-overview .fleet-state { text-align: left; }
        .fleet-overview .pill { white-space: normal; max-width: 100%; margin: 0 3px 4px 0; }
        .fleet-machine-row:hover > th, .fleet-machine-row:hover > td { background: var(--panel-2); }
        .fleet-toggle { text-align: left; padding: 4px 6px; margin-left: -6px; max-width: 100%; white-space: normal; overflow-wrap: anywhere; }
        .fleet-subline { display: block; margin-top: 4px; font-size: 11px; color: var(--muted); }
        .fleet-detail-row > td { padding: 0; text-align: left; }
        .fleet-details { padding: 4px 16px 16px; background: var(--panel); min-width: 0; overflow-wrap: normal; }
        .fleet-process-table { min-width: 440px; }
        .fleet-replica-table { min-width: 560px; }
        .fleet-source-table { min-width: 760px; }
        .fleet-details .fleet-metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr)); gap: 8px 24px; }
        .fleet-details progress { width: 100%; height: 8px; accent-color: var(--accent); }
        .fleet-details .meta { overflow-wrap: anywhere; }
        .fleet-details .attention { color: var(--warn); }
        @media (max-width: 600px) {
          .fleet-summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
          .fleet-overview .fleet-secondary { display: none; }
          .fleet-overview > thead th:first-child { width: 30%; }
          .fleet-overview > thead th:nth-child(2) { width: 45%; }
          .fleet-overview > thead th:nth-child(7) { width: 25%; }
          .fleet-overview > thead > tr > th, .fleet-overview > tbody > tr > th, .fleet-overview > tbody > tr > td { padding: 8px 5px; }
          .fleet-overview .fleet-detail-row > td { padding: 0; }
          .fleet-details { padding: 4px 10px 14px; }
        }
        .health-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr)); gap: 12px; }
        .health-card { padding: 16px 18px; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); min-width: 0; box-shadow: var(--shadow-1); }
        #usage-content table { font-size: 12px; }
        #usage-rows td:first-child, #usage-rows td:nth-child(5) { white-space: nowrap; }
        #repos-rows p, #repos-rows h3 { overflow-wrap: anywhere; }
        .health-card h3 { margin: 0 0 6px; }
        .health-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 6px 10px; }
        .health-head h3 { display: flex; align-items: center; gap: 8px; margin: 0; font-size: 15px; }
        .health-card dl { display: grid; grid-template-columns: minmax(6.5em, 1fr) auto; gap: 6px 12px; margin: 12px 0; font-size: 12px; }
        .health-card dt { color: var(--muted); overflow-wrap: normal; }
        .health-card dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; }
        .health-card .attention { margin: 8px 0 0; color: var(--warn); font-size: 13px; }
        .health-summary { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 14px; }
        .health-summary:empty { display: none; }
        .health-note { grid-column: 1 / -1; margin: 2px 0 0; color: var(--muted); font-size: 12px; }
        .pills { display: inline-flex; flex-wrap: wrap; gap: 6px; }
        .pill { display: inline-flex; align-items: center; gap: 6px; padding: 1px 9px 1px 8px; border-radius: var(--r-pill); background: var(--panel-2); color: var(--muted); font-size: 11.5px; font-weight: 600; line-height: 18px; white-space: nowrap; }
        .pill::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: currentColor; }
        .pill[data-tone="ok"] { background: var(--ok-bg); color: var(--ok); }
        .pill[data-tone="warn"] { background: var(--warn-bg); color: var(--warn); }
        .pill[data-tone="danger"] { background: var(--danger-bg); color: var(--danger); }
        .pill[data-tone="info"] { background: var(--info-bg); color: var(--info); }
        .stats-filters { display: flex; flex-wrap: wrap; align-items: end; gap: 10px; margin: 16px 0; }
        .stats-filters label { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; min-width: 0; max-width: 100%; color: var(--muted); font-size: 12px; }
        .stats-filters input, .stats-filters select { min-width: 0; max-width: 100%; }
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
        .stats-totals > div { flex: 1 1 auto; min-width: 140px; padding: 14px 16px; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); box-shadow: var(--shadow-1); }
        .stats-totals dt { font-size: 11px; letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted); }
        .stats-totals dd { margin: 6px 0 0; font-size: 26px; font-weight: 650; letter-spacing: -0.03em; font-variant-numeric: tabular-nums; white-space: nowrap; overflow-wrap: normal; }
        .stats-table { max-width: 100%; overflow-x: auto; }
        .stats-table table { width: 100%; min-width: 580px; border-collapse: collapse; }
        .stats-table th, .stats-table td { padding: 10px 12px; text-align: right; border-bottom: 1px solid var(--line); font-variant-numeric: tabular-nums; }
        .stats-table th { font-size: 11px; letter-spacing: 0.04em; text-transform: uppercase; color: var(--muted); font-weight: 600; }
        .stats-table tbody tr:hover td { background: color-mix(in srgb, var(--panel) 60%, transparent); }
        .stats-table th:first-child, .stats-table td:first-child { text-align: left; }
        #stats-more, #settings-more { margin-top: 12px; }
        #settings-status { color: var(--muted); }
        .sign-in-card { max-width: 620px; margin: 48px auto; padding: 28px; border: 1px solid var(--line); border-radius: var(--r-lg); background: var(--panel); box-shadow: var(--shadow-1); }
        .sign-in-card h2 { margin-top: 0; font-size: 24px; line-height: 1.3; }
        #identity-status:empty { display: none; }
        #identity-status { overflow-wrap: anywhere; min-width: 0; }
        .search-secondary { margin: 6px 0; padding: 8px 0; border-bottom: 1px solid var(--line); font-size: 13px; }
        .search-secondary > summary { cursor: pointer; color: var(--muted); }
        .settings-heading { margin: 28px 0 0; font-size: 18px; }
        #settings-content { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
        #settings-content > .settings-section { margin-top: 0; }
        #settings-content > .settings-section:nth-child(n+3) { grid-column: 1 / -1; }
        .settings-section > summary { cursor: pointer; font-weight: 600; }
        .health-timestamp { display: block; color: var(--muted); font-size: 11px; overflow-wrap: anywhere; }
        .health-card dd { min-width: 0; overflow-wrap: anywhere; }
        .health-card details { overflow-wrap: anywhere; }
        .message details.tool-error { border-color: var(--danger); }
        dialog:not(:modal)[open] { position: fixed; inset: 10vh 0 auto; z-index: 50; max-height: 80vh; overflow-y: auto; box-shadow: var(--shadow-1); }
        @media (max-width: 600px) {
          .page-nav { display: flex; flex-wrap: nowrap; overflow-x: auto; margin: 0; gap: 3px; }
          .page-nav a { flex: none; justify-content: center; min-height: 44px; }
          #settings-content { grid-template-columns: minmax(0, 1fr); }
          .sign-in-card { margin: 24px 16px; padding: 20px; }
          .health-card dl { grid-template-columns: minmax(0, 1fr) minmax(0, 1.2fr); }
          .agent-filters > button { min-height: 36px; }
          #transcript-toolbar .agent-filters { gap: 6px; }
          .code-header { flex-wrap: wrap; } .code-header > span { min-width: 0; overflow-wrap: anywhere; }
        }
        .settings-section { padding: 18px; margin-top: 16px; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); box-shadow: var(--shadow-1); }
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
        #back { display: inline-flex; align-items: center; gap: 8px; margin: 0 0 10px; }
        #back::before { content: ""; width: 6px; height: 6px; margin-left: 2px; border-left: 1.5px solid currentColor; border-bottom: 1.5px solid currentColor; transform: rotate(45deg); }
        .sticky h2 { margin: 0 0 8px; font-size: 20px; line-height: 1.3; font-weight: 650; letter-spacing: -0.02em; }
        .sticky .meta { margin: 0; }

        @media (min-width: 880px) {
          .session .title { white-space: nowrap; text-overflow: ellipsis; display: block; }
          #search-query { flex: 1 1 20rem; }
          .facet-picker { flex: 0 1 10rem; }
        }
        @media (max-width: 879px) {
          :root { --page-gutter:16px; }
          .header-row { flex-wrap: wrap; gap: 6px 10px; }
          .top-nav .lede { display: none; }
          .top-nav h1 { flex: 1 1 auto; }
          .page-nav { order: 10; flex: 1 1 100%; margin: 0; }
          .list-toolbar .session-jump { flex: 1 1 100%; }
          #workspace { padding-bottom: 24px; }
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
        #sessions { display: flex; flex-direction: column; gap: 1px; padding-top: 2px; }
        .session { position: relative; display: block; width: 100%; text-align: left; border: 1px solid transparent; border-radius: var(--r-md); padding: 8px 12px 9px 16px; margin: 0; background: transparent; font-weight: 400; cursor: pointer; transition: border-color var(--dur-1) ease, background var(--dur-1) ease; }
        .session::before { content: ""; position: absolute; left: 5px; top: 10px; bottom: 10px; width: 3px; border-radius: 3px; background: var(--source-color, var(--line)); opacity: 0.35; transition: opacity var(--dur-1) ease; }
        .session:hover, .session:focus-visible { border-color: var(--line); background: var(--panel); color: var(--text); }
        .session:hover::before, .session:focus-visible::before { opacity: 1; }
        .session:active { background: var(--panel-2); }
        .session-row { min-width: 0; }
        .session-nesting { margin: 0 12px 8px 16px; }
        .session-nesting > summary { cursor: pointer; color: var(--muted); font-size: 13px; }
        .nested-rows { border-left: 2px solid var(--line); margin-top: 8px; padding-left: 12px; }
        .nested-session { display: block; width: 100%; text-align: left; margin: 4px 0; overflow-wrap: anywhere; }
        .nested-session .meta { display: flex; flex-wrap: wrap; }
        .parent-link { margin: 0 12px 8px 16px; font-size: 13px; }
        .nesting-status { font-size: 13px; color: var(--muted); }
        .session.group-start { margin-top: 30px; }
        .group-head { position: absolute; left: 12px; top: -25px; color: var(--muted); font-size: 11px; font-weight: 650; letter-spacing: 0.07em; line-height: 16px; text-transform: uppercase; white-space: nowrap; pointer-events: none; }
        #sessions > .group-start:first-child { margin-top: 24px; }
        .title { color: var(--text); font-weight: 600; font-size: 14px; letter-spacing: -0.012em; line-height: 1.45; margin-bottom: 3px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
        .meta { color: var(--muted); display: flex; gap: 6px; flex-wrap: wrap; font-size: 12px; line-height: 18px; align-items: center; }
        .meta .sep { color: var(--muted); }
        .meta time, .message-counts { font-variant-numeric: tabular-nums; }
        .badge { display: inline-block; color: white; background: var(--source-color, #64748b); border-radius: 999px; padding: 1px 8px; font-size: 10.5px; font-weight: 650; letter-spacing: 0.02em; }
        .meta .badge { display: inline-flex; align-items: center; gap: 6px; padding: 0; border-radius: 0; background: none; color: var(--text); font-size: 12px; font-weight: 550; letter-spacing: 0; }
        .meta .badge::before { content: ""; flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--source-color, #64748b); }
        .search-snippet { display: block; }
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
        .sticky { position: sticky; top: 0; background: color-mix(in srgb, var(--bg) 88%, transparent); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); border-bottom: 1px solid var(--line); z-index: 2; padding: 14px 0 16px; }
        #messages { padding: 12px 0 32px; display: flex; flex-direction: column; gap: 16px; }
        .message { max-width: 84%; min-width: 0; }
        .message.user { align-self: flex-end; }
        .message.assistant { align-self: flex-start; }
        .message.tool, .message.system { align-self: stretch; max-width: 100%; }
        .role { color: var(--muted); font-size: 11px; font-weight: 650; letter-spacing: 0.01em; margin: 0 10px 4px; }
        .user .role { text-align: right; }
        .message.assistant .role { color: var(--source-color, var(--muted)); }
        .message .body { min-width: 0; overflow-wrap: anywhere; margin: 0; padding: 12px 16px; border: 1px solid var(--line); border-radius: 14px; background: var(--panel); font: inherit; line-height: 1.65; box-shadow: var(--shadow-1); }
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
        .message .body code { font: 0.88em/1.5 var(--mono); padding: 0.1em 0.35em; border-radius: 4px; background: var(--code); }
        .message .body .code-block { margin: 0.15em 0; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; background: var(--code); }
        .message .body .code-header { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 0.35em 0.75em; font-size: 11px; color: var(--muted); border-bottom: 1px solid var(--line); }
        .message .body .copy-btn { margin: 0; padding: 2px 8px; }
        .message .body .copy-btn[data-state="copied"] { color: var(--ok); border-color: color-mix(in srgb, var(--ok) 50%, var(--line)); }
        .message .body .code-block pre { margin: 0; padding: 0.75em; border: 0; border-radius: 0; background: transparent; white-space: pre; overflow-x: auto; }
        .message .body .code-block code { padding: 0; background: transparent; font: 13px/1.55 var(--mono); }
        .user .body { border-color: color-mix(in srgb, var(--accent) 40%, var(--line)); background: color-mix(in srgb, var(--accent) 13%, var(--panel)); border-bottom-right-radius: 4px; }
        .message.assistant .body { border-bottom-left-radius: 4px; border-color: color-mix(in srgb, var(--source-color, var(--line)) 30%, var(--line)); }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); font: 13px/1.55 var(--mono); }
        .user pre { border-color: color-mix(in srgb, var(--accent) 45%, var(--line)); background: color-mix(in srgb, var(--accent) 10%, var(--panel)); }
        details { margin-top: 6px; color: var(--muted); font-size: 12px; }
        details pre { margin-top: 6px; }
        .message details { padding: 0.55em 0.85em; border: 1px dashed color-mix(in srgb, var(--muted) 40%, transparent); border-radius: 10px; background: color-mix(in srgb, var(--code) 55%, transparent); }
        .message.system > details { border-color: color-mix(in srgb, #f59e0b 35%, var(--line)); }
        .message.tool > details, .message details.tool-call { border-color: color-mix(in srgb, #a855f7 35%, var(--line)); }
        .message details summary { cursor: pointer; display: flex; gap: 0.5em; align-items: baseline; min-width: 0; }
        .message details .preview { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 400; }
        #more, #more-messages { display: block; margin: 0.35rem 0; }
        .empty { max-width: 960px; margin: 24px 20px; color: var(--muted); }
        #overview { display: flex; flex-wrap: wrap; align-items: baseline; gap: 2px 14px; margin: 0 0 8px; }
        #overview details { margin: 0; }
        #overview details[open] { flex-basis: 100%; }
        #overview .empty { margin: 0; }
        .empty-state { display: flex; flex-direction: column; align-items: center; gap: 6px; margin: 12px 0; padding: 36px 16px; border: 1px dashed var(--line); border-radius: var(--r-lg); color: var(--muted); text-align: center; }
        .empty-state .icon { width: 26px; height: 26px; margin-bottom: 4px; color: var(--text-dim); }
        .empty-state strong { color: var(--text); font-size: 15px; font-weight: 600; }
        .empty-state p { max-width: 48ch; margin: 0; font-size: 13px; }
        .empty-state button { margin-top: 8px; }
        .skeleton-row { display: flex; flex-direction: column; gap: 9px; padding: 13px 16px 12px; }
        .skeleton-line { display: block; width: 34%; height: 10px; border-radius: var(--r-xs); background: linear-gradient(90deg, var(--panel) 25%, var(--panel-2) 50%, var(--panel) 75%); background-size: 200% 100%; animation: shimmer 1.3s linear infinite; }
        .skeleton-line.wide { width: 68%; height: 12px; }
        @keyframes shimmer { from { background-position: 200% 0; } to { background-position: -200% 0; } }
        .toast-region { position: fixed; right: 16px; bottom: 16px; z-index: 40; display: flex; flex-direction: column; gap: 8px; width: min(380px, calc(100vw - 32px)); pointer-events: none; }
        .toast { display: flex; align-items: center; gap: 10px; padding: 9px 8px 9px 12px; border: 1px solid var(--line); border-left: 3px solid var(--info); border-radius: var(--r-md); background: var(--panel); color: var(--text); box-shadow: var(--shadow-2); font-size: 13px; line-height: 1.45; pointer-events: auto; animation: toast-in 180ms var(--ease); }
        .toast > span { flex: 1; min-width: 0; }
        .toast > .icon { color: var(--info); }
        .toast[data-tone="ok"] { border-left-color: var(--ok); } .toast[data-tone="ok"] > .icon { color: var(--ok); }
        .toast[data-tone="warn"] { border-left-color: var(--warn); } .toast[data-tone="warn"] > .icon { color: var(--warn); }
        .toast[data-tone="danger"] { border-left-color: var(--danger); } .toast[data-tone="danger"] > .icon { color: var(--danger); }
        .toast-close, .toast-close:active { display: inline-flex; padding: 4px; border: 0; background: transparent; color: var(--muted); }
        @keyframes toast-in { from { opacity: 0; transform: translateY(6px); } }

        body:has(#workspace.showing-detail) .top-nav { position: static; }
        #detail-header { position: sticky; top: 0; z-index: 21; background: var(--bg); border-bottom: 1px solid var(--line); padding-top: 8px; }
        #detail-header .sticky { position: static; backdrop-filter: none; background: var(--bg); padding: 8px 0; border: 0; }
        .detail-pane .agent-filters button[aria-pressed="true"] { color: var(--text); }
        #detail-view-nav { margin: 0; padding: 6px 0 10px; }
        #library-page .detail-pane .sep { color: var(--muted); }
        #messages .assistant .role { color: var(--text); border-left: 3px solid var(--source-color, var(--line)); padding-left: 8px; }
        #detail-header h2 { max-height: 2.6em; overflow: hidden; }
        #transcript-toolbar { padding: 12px 0; border-bottom: 1px solid var(--line); }
        #transcript-toolbar .agent-filters { flex-wrap: wrap; gap: 6px; margin: 6px 0; }
        #transcript-toolbar button { font-size: 12px; padding: 5px 8px; }
        #transcript-minimap-box { padding: 12px; border: 1px solid var(--line); border-radius: 8px; margin: 12px 0; }
        #transcript-minimap-box p { margin: 4px 0 8px; font-size: 12px; }
        #transcript-minimap { display: grid; grid-template-columns: repeat(auto-fit, minmax(38px, 1fr)); gap: 4px; max-height: 180px; overflow-y: auto; padding: 4px; }
        #transcript-minimap button { padding: 4px 1px; min-width: 0; min-height: 28px; overflow: hidden; font-size: 10px; color: var(--text); border: 1px solid var(--muted); }
        #transcript-minimap .map-loaded { background: var(--accent-dim); border-color: var(--accent); }
        #transcript-minimap .map-partial { background: var(--accent-dim); border-style: dashed; }
        #transcript-minimap .map-unloaded { background: var(--bg); }
        #transcript-minimap button[aria-current="true"] { outline: 2px solid var(--accent); outline-offset: 0; }
        #transcript-minimap button[data-viewport="true"] { box-shadow: inset 0 -3px var(--info); }
        .syntax-keyword { color: var(--agent); } .syntax-string, .syntax-add { color: var(--ok); }
        .syntax-comment { color: var(--muted); } .syntax-number { color: var(--info); } .syntax-delete { color: var(--danger); }
        #transcript-outline-box { padding: 12px; border: 1px solid var(--line); border-radius: 8px; margin: 12px 0; }
        #transcript-outline { display: grid; max-height: 300px; overflow-y: auto; gap: 4px; }
        #transcript-outline button { text-align: left; overflow-wrap: anywhere; white-space: normal; }
        #messages .message { max-width: 100%; width: 100%; scroll-margin-top: 190px; }
        #messages .message.user { align-self: stretch; border-left: 3px solid var(--accent); padding-left: 12px; margin-top: 14px; }
        #messages .message.assistant .body { background: transparent; box-shadow: none; border: 0; padding: 8px 0; font-size: 15px; line-height: 1.75; }
        #messages .turn-continuation { margin-top: -8px; }
        .message .message-meta { display: flex; flex-wrap: wrap; gap: 6px 12px; color: var(--muted); font-size: 12px; margin-bottom: 6px; }
        .message .message-meta a { color: var(--accent); }
        .message .turn-usage { font-variant-numeric: tabular-nums; }
        .message .tool-call { margin-top: 8px; border-style: solid; }
        .message details.tool-call.tool-error { border-color: var(--danger); }
        .message .error-label { color: var(--danger); font-size: 12px; }
        .message .tool-content { padding-top: 12px; }
        .message .tool-content h4 { margin: 10px 0 6px; font-size: 12px; color: var(--muted); }
        .message .tool-content pre { max-height: 360px; overflow: auto; white-space: pre-wrap; }
        .message .tool-output { max-height: 26em; overflow: hidden; }
        .message .tool-output.expanded, .message .tool-output.expanded pre { max-height: none; }
        #messages .associated-result { width: calc(100% - 16px); margin-left: 16px; }
        .message .code-line::before { content: attr(data-line-number); display: inline-block; min-width: 2.5em; padding-right: 1em; color: var(--muted); user-select: none; }
        .message .body .heading-link { margin-left: 8px; font-size: 12px; }
        #transcript-outline button[aria-current="true"] { border-color: var(--accent); background: var(--accent-dim); }
        .message .code-block { min-width: 0; max-width: 100%; border: 1px solid var(--line); border-radius: 8px; background: var(--code); overflow: hidden; }
        .message .code-header { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 10px; color: var(--muted); font-size: 12px; }
        .message .code-block pre { white-space: pre; overflow: auto; margin: 0; padding: 12px; }
        .message .body .code-block.wrap-code pre { white-space: pre-wrap; overflow-wrap: anywhere; }
        .message .diff-row { display: block; white-space: pre-wrap; overflow-wrap: anywhere; }
        .message .diff-row::before { content: attr(data-line-number); display: inline-block; min-width: 7em; margin-right: 1em; color: var(--muted); user-select: none; }
        .message .diff-add { background: color-mix(in srgb, var(--ok) 12%, var(--code)); color: var(--ok); }
        @media (prefers-color-scheme: light) { .message .diff-add { color: #166534; } }
        .message .diff-del { background: color-mix(in srgb, var(--danger) 12%, var(--code)); color: var(--danger); }
        .message.jump-target { outline: 2px solid var(--accent); }
        .timeline-duration { display: block; max-width: 100%; margin: 8px 0; }
        #detail-info-content dl { display: grid; grid-template-columns: minmax(90px, 1fr) minmax(0, 3fr); gap: 8px 16px; }
        #detail-info-content dd { margin: 0; overflow-wrap: anywhere; }
        #detail-info-content dt { color: var(--muted); }
        @media (max-width: 600px) {
          #detail-header .meta { font-size: 11px; max-height: 3.6em; overflow: hidden; }
          #detail-header h2 { font-size: 17px; }
          #detail-view-nav { gap: 4px; } #detail-view-nav button { padding: 6px 8px; font-size: 12px; }
          .message details summary { flex-wrap: wrap; } .message details summary .preview { flex-basis: 65%; }
        }
        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after { animation-duration: 0.01ms !important; animation-iteration-count: 1 !important; transition-duration: 0.01ms !important; scroll-behavior: auto !important; }
        }
        .overview-summary { margin: 0; color: var(--muted); font-size: 13px; }
        @media (max-width: 600px) {
          .page-nav a .icon { display: none; }
          .page-nav a { padding: 6px 9px; }
          #search-query { flex: 1 1 calc(100% - 90px); }
          #search > button[type="submit"] { order: 0; }
          #search > .facet-picker { order: 1; }
          .session .message-counts, .session .sep:has(+ .message-counts) { display: none; }
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
        @media (prefers-color-scheme: light) { .page-nav a[aria-current="page"] { color: #166534; } }
        #command-trigger { display: inline-flex; align-items: center; gap: 8px; min-height: 44px; min-width: 170px; text-align: left; color: var(--muted); background: var(--input-bg); }
        #command-trigger kbd { margin-left: auto; padding: 1px 4px; border: 1px solid var(--line); border-radius: 4px; font: 11px var(--mono); color: var(--muted); }
        @media (min-width: 880px) and (max-width: 1250px) { .header-row { flex-wrap: wrap; } .page-nav { order: 10; flex-basis: 100%; } }
        @media (max-width: 600px) {
          #command-trigger { min-width: 44px; width: 44px; justify-content: center; padding: 8px; }
          #command-trigger .command-trigger-label, #command-trigger kbd { display: none; }
          #shortcuts-help { min-width: 32px; }
          .header-row h1 { font-size: 15px; }
          .header-tools { gap: 4px; }
          #logout { padding: 6px; font-size: 12px; }
        }
        #command-dialog { width: min(640px, calc(100vw - 32px)); box-sizing: border-box; max-height: 85vh; max-height: 85dvh; overflow-y: auto; padding: 20px; border: 1px solid var(--line); border-radius: var(--r-lg); background: var(--panel); color: var(--text); }
        #command-dialog::backdrop { background: rgba(0,0,0,.65); }
        #command-dialog h2 { margin-top: 0; }
        #command-query { width: 100%; box-sizing: border-box; min-height: 44px; }
        #command-results { max-height: 42vh; overflow-y: auto; margin: 12px 0; }
        .command-option { display: flex; flex-direction: column; gap: 3px; min-height: 44px; box-sizing: border-box; padding: 10px 12px; border: 1px solid transparent; border-radius: var(--r-sm); cursor: pointer; overflow-wrap: anywhere; }
        .command-option[aria-selected="true"] { background: var(--panel-3); border-color: var(--accent); }
        .command-option[aria-selected="true"] .meta { color: var(--text); }
        .command-option:hover { border-color: var(--accent); }
        .command-footer { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; }
        #command-close { min-height: 44px; }
        #shortcuts-dialog { max-width: min(620px, calc(100vw - 32px)); border: 1px solid var(--line); border-radius: var(--r-lg); background: var(--panel); color: var(--text); }
        #shortcuts-dialog::backdrop { background: rgba(0,0,0,.65); }
        #transcript-find { padding: 12px; border: 1px solid var(--line); border-radius: var(--r-md); background: var(--panel); }
        #transcript-find label { min-width: 0; } #transcript-find input { max-width: 100%; }
        .find-preview { flex-basis: 100%; overflow-wrap: anywhere; white-space: pre-wrap; margin: 0; }
        #transcript-find-status { flex-basis: 100%; margin: 0; color: var(--muted); }
        .message.find-target, .session[aria-current="true"] { outline: 2px solid var(--accent); outline-offset: -2px; }
        mark, .search-snippet mark { color: var(--text); background: var(--accent-dim); font-weight: 600; }
        /* Charts scale by viewBox, without observers, runtime CSS injection or animation. */
        /* All library, detail and data pages share the same shell width. */
        #stats-page .agent-filters button[aria-pressed="true"] { color:var(--text); }
        :root { --c1:var(--accent); }
        .dashboard-kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,150px),1fr)); gap:12px; margin:16px 0; }
        .dashboard-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,340px),1fr)); gap:16px; }
        .kpi, .chart { min-width:0; padding:16px; border:1px solid var(--line); border-radius:var(--r-lg); background:var(--panel); margin:0 0 16px; }
        .kpi strong { display:block; font-size:24px; font-variant-numeric:tabular-nums; }
        .kpi svg { display:block; width:100%; height:32px; color:var(--c1); }
        .chart h3 { margin:0; font-size:16px; }
        .chart p { color:var(--muted); margin:6px 0 10px; }
        .chart svg { display:block; width:100%; height:auto; max-height:420px; }
        .chart-bar { fill:var(--c1); }
        .ranked-row { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:2px 12px; margin:10px 0; font-size:13px; }
        .ranked-row svg { grid-column:1 / -1; height:8px; }
        .ranked-row .chart-bar { fill:var(--source-color,var(--c1)); }
        .ranked-row strong { font-variant-numeric:tabular-nums; }
        .chart details, .kpi details { margin-top:8px; }
        .chart table, .kpi table { width:100%; border-collapse:collapse; }
        .chart td, .chart th, .kpi td, .kpi th { text-align:left; padding:4px 8px; border-bottom:1px solid var(--line); }
        .usage-meter { margin:12px 0; }
        .usage-meter svg { height:16px; }
        .usage-track { fill:var(--panel-3); }
        .usage-meter[data-tone="danger"] .chart-bar { fill:var(--danger); }
        .usage-meter[data-tone="warn"] .chart-bar { fill:var(--warn); }
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
        // Identity mode: the server marked the document; sign-in is a `{}` POST that
        // the Tailscale Serve proxy authenticates, so the credential form stays hidden.
        const identityMode = !!(document.body && document.body.dataset && document.body.dataset.authMode === "tailscale-serve");
        let identitySignInPending = false;
        let identitySignInAt = 0;
        // Identity display follows authentication lifetime, not page navigation.
        let identityDisplayVersion = 0;
        if (identityMode) {
          document.getElementById("login").hidden = true;
          document.getElementById("logout").hidden = true;
        }
        const healthContent = document.getElementById("health-content");
        const healthStatus = document.getElementById("health-status");
        const statsFields = [["sessionCount", t("Sessions")], ["messageCount", t("Messages")], ["userMessageCount", t("User")], ["assistantMessageCount", t("Assistant")], ["toolMessageCount", t("Tool")]];
        let statsSnapshot = "";
        let statsCursor = "";
        let statsFilters = "";
        let statsTotals = null, statsTimeZone = "", statsChoicesVersion = 0;
        const costFields = [["costUsd", t("Cost (USD)")], ["sessionCount", t("Sessions")], ["inputTokens", t("Input tokens")], ["outputTokens", t("Output tokens")], ["cacheReadTokens", t("Cache read")], ["cacheCreationTokens", t("Cache write")]];
        let statsView = "sessions";
        const chartRows = { stats: [], costs: [], tools: [], files: [], repos: [], ai: [] };
        let overviewStreams = null;
        let overviewObservedAt = null;
        let dashboardVersion = 0, dashboardHoursVersion = 0;
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
        let transcriptMessages = [], transcriptFilter = "all", transcriptStep = -1, transcriptAllBusy = false;
        let detailInfoDetail = null, detailInfoLoaded = false, detailInfoBusy = false, detailInfoEpoch = -1, detailMessageCoverage = null;
        let outlineEntries = [], outlineOpen = false;
        let minimapOpen = false, minimapSelected = null;
        let turnUsageNode = null, turnUsage = null, promptNumber = 0, messageTotal = null, activeOutlineOrdinal = null;
        let detailSource = "";
        let detailContextSession = "";
        let detailContextGeneration = "";
        let detailExtrasVersion = 0;
        let detailChildren = { loaded: false, busy: false, snapshot: "", cursor: "", seen: new Set(), items: [] };
        let sessionActionCanWrite = false, sessionActionPending = false, batchTitlePending = false;
        let sessionActionAccessRequest = null;
        let detailRelationship = { canWrite: false, checking: false };
        let relationshipWritePending = false;
        let relationshipButtons = [];
        let detailTimeline = { loaded: false, busy: false, next: null, total: null, count: 0, lastIndex: -1 };
        let authWriteTail = null;
        let insightWriteVersion = 0, insightCanWrite = false, insightSavePending = false, savedInsightId = "";
        let insightsList = {items:[],snapshot:"",cursor:"",busy:false};
        let insightVersion = 0, insightPage = null, insightBusy = false;
        let rankedCursor = "", rankedSnapshot = "", rankedFilters = "", rankedBusy = false;
        let requestEpoch = 0;
        let activePage = "sessions";
        let fleetTimer = null, fleetRequest = 0;
        const fleetExpanded = new Set();
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
        const aiConfigFields = [{"key": "aiProtocol", "label": t("Protocol"), "type": "choice", "choices": ["openai", "disabled"]}, {"key": "aiBaseURL", "label": t("API base URL"), "type": "text", "max": 2048}, {"key": "aiModel", "label": t("Model"), "type": "text", "max": 256}, {"key": "summaryLanguage", "label": t("Language"), "type": "text", "max": 64}, {"key": "summaryMaxSentences", "label": t("Maximum sentences"), "type": "number", "min": 1, "max": 20, "integer": true}, {"key": "summaryStyle", "label": t("Style"), "type": "text", "max": 512}, {"key": "summaryPrompt", "label": t("Custom prompt"), "type": "text", "max": 8000}, {"key": "summaryMaxTokens", "label": t("Maximum output tokens"), "type": "number", "min": 1, "max": 32768, "integer": true}, {"key": "summaryTemperature", "label": t("Temperature"), "type": "number", "min": 0, "max": 2, "integer": false}, {"key": "summarySampleFirst", "label": t("First messages"), "type": "number", "min": 0, "max": 200, "integer": true}, {"key": "summarySampleLast", "label": t("Last messages"), "type": "number", "min": 0, "max": 200, "integer": true}, {"key": "summaryTruncateChars", "label": t("Characters per message"), "type": "number", "min": 1, "max": 10000, "integer": true}, {"key": "titleProvider", "label": t("Provider"), "type": "choice", "choices": ["ollama", "custom", "openai"]}, {"key": "titleBaseUrl", "label": t("API base URL"), "type": "text", "max": 2048}, {"key": "titleModel", "label": t("Model"), "type": "text", "max": 256}, {"key": "embeddingBaseURL", "label": t("API base URL"), "type": "text", "max": 2048}, {"key": "embeddingModel", "label": t("Model"), "type": "text", "max": 256}, {"key": "embeddingDimension", "label": t("Dimensions"), "type": "number", "min": 1, "max": 65536, "integer": true}, {"key": "embeddingIncludeDimensions", "label": t("Send dimensions to provider"), "type": "boolean"}, {"key": "aiAudit.enabled", "label": t("Record calls"), "type": "boolean"}, {"key": "aiAudit.logBodies", "label": t("Store redacted request and response bodies"), "type": "boolean"}, {"key": "aiAudit.maxBodySize", "label": t("Maximum stored body size"), "type": "number", "min": 1, "max": 1000000, "integer": true}];
        let sourceSettingsVersion = 0;
        let sourceSettingsRows = new Map();
        let aliasProjectVersion = 0;
        let aliasProjects = new Map();
        let aliasProjectSnapshot = "";
        let aliasProjectCursor = "";
        let aliasProjectQuery = "";
        let searchTimer = null, searchInputVersion = 0, routeVersion = 0, handledRoute = null;
        let listRouteKey = "", cachedListScroll = 0, detailReturnRoute = null, selectedSessionIndex = -1;
        let findMatches = [], findIndex = -1, findVersion = 0;
        const routeFilterKeys = ["q", "sources", "projects", "agents", "since", "until", "tools", "machine", "mode", "limit", "sort", "group", "noise"];
        let commandSessions = [], commandResults = [], commandIndex = -1, commandRevision = 0, commandContext = null;
        const statsTabs = ["sessions", "costs", "tools", "files", "usage", "repos", "ai"];
        function groupLabel(key) {
          return uiLocale === "en" ? key : t(({source:"Source",project:"Project",day:"Day",week:"Week",hourOfWeek:"Hour of week",model:"Model",tool:"Tool",session:"Session"})[key] || key);
        }
        function cancelSearchTimer() {
          searchInputVersion += 1;
          if (searchTimer !== null && typeof clearTimeout === "function") clearTimeout(searchTimer);
          searchTimer = null;
        }
        function bumpEpoch() {
          cancelSearchTimer();
          closeCommandPalette();
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
        // --- UI primitives: SVG icons, plurals, status words, toasts, empty states.
        const svgNS = "http://www.w3.org/2000/svg";
        function svg(tag, attrs) {
          const node = document.createElementNS(svgNS, tag);
          Object.keys(attrs || {}).forEach(function (name) { node.setAttribute(name, String(attrs[name])); });
          return node;
        }
        const iconPaths = {
          sessions: ["M8 6h13", "M8 12h13", "M8 18h13", "M3.5 6h.01", "M3.5 12h.01", "M3.5 18h.01"],
          search: ["M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14z", "M20 20l-4-4"],
          dashboard: ["M3 3h7v7H3z", "M14 3h7v7h-7z", "M3 14h7v7H3z", "M14 14h7v7h-7z"],
          stats: ["M4 4v16h16", "M8 16v-5", "M12.5 16V8", "M17 16v-3"],
          insights: ["M4 3h16v18H4z", "M8 8h8", "M8 12h8", "M8 16h5"],
          health: ["M22 12h-4l-3 8-6-16-3 8H2"],
          fleet: ["M3 3h18v7H3z", "M3 14h18v7H3z", "M7 6h1", "M7 17h1"],
          settings: ["M4 21v-7", "M4 10V3", "M12 21v-9", "M12 8V3", "M20 21v-5", "M20 12V3", "M1.5 14h5", "M9.5 8h5", "M17.5 16h5"],
          x: ["M18 6L6 18", "M6 6l12 12"],
          check: ["M20 6L9 17l-5-5"],
          alert: ["M12 3.5l9.5 16.5h-19z", "M12 10v4", "M12 17h.01"],
          info: ["M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18z", "M12 16v-4", "M12 8h.01"],
          inbox: ["M22 12h-6l-2 3h-4l-2-3H2", "M5.5 5h13l3.5 7v7H2v-7z"],
          filter: ["M3 5h18l-7 8v6l-4 2v-8z"]
        };
        function icon(name) {
          const node = svg("svg", { viewBox: "0 0 24 24", width: 16, height: 16, fill: "none", stroke: "currentColor", "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false", class: "icon" });
          (iconPaths[name] || []).forEach(function (d) { node.appendChild(svg("path", { d: d })); });
          return node;
        }
        function plural(count, singular, pluralForm) {
          const value = Number(count);
          const shown = Number.isFinite(value) ? value.toLocaleString(uiLocale) : String(count);
          return shown + " " + (uiLocale === "zh-CN" ? t(singular) : value === 1 ? singular : pluralForm || singular + "s");
        }
        const httpStatusWords = {
          400: t("Bad request"), 401: t("Not authorized"), 403: t("Access denied"), 404: t("Not found"), 408: t("Request timed out"),
          409: t("Conflict"), 413: t("Request too large"), 422: t("Invalid request"), 429: t("Too many requests"),
          500: t("Server error"), 502: t("Bad gateway"), 503: t("Service unavailable"), 504: t("Gateway timeout")
        };
        function httpStatusText(status) {
          return (httpStatusWords[status] || (status >= 500 ? t("Server error") : t("Request failed"))) + " (" + status + ")";
        }
        function setStatus(value) {
          const text = value == null ? "" : String(value);
          setText(statusNode, text);
          if (!statusNode.dataset) return;
          statusNode.dataset.tone = !text ? "" : text === t("signed in") || text.startsWith(t("Signed in as {name}", {name:""})) ? "ok"
            : text === t("signed out") || text === t("Finding session…") ? "neutral" : "danger";
        }
        function toast(message, tone) {
          const region = document.getElementById("toast-region");
          const item = document.createElement("div");
          item.className = "toast";
          item.dataset.tone = tone || "info";
          item.setAttribute("role", tone === "danger" ? "alert" : "status");
          item.appendChild(icon(tone === "ok" ? "check" : tone === "danger" || tone === "warn" ? "alert" : "info"));
          const text = document.createElement("span");
          setText(text, message);
          item.appendChild(text);
          const close = document.createElement("button");
          close.type = "button";
          close.className = "toast-close";
          close.setAttribute("aria-label", t("Dismiss notification"));
          close.appendChild(icon("x"));
          function dismiss() { if (item.parentNode === region) region.removeChild(item); }
          close.addEventListener("click", dismiss);
          item.appendChild(close);
          while (region.children.length >= 3) region.removeChild(region.children[0]);
          region.appendChild(item);
          if (typeof setTimeout === "function") setTimeout(dismiss, tone === "danger" ? 8000 : 4000);
          return item;
        }
        function emptyState(iconName, title, body, actions) {
          const box = document.createElement("div");
          box.className = "empty-state";
          box.appendChild(icon(iconName));
          const heading = document.createElement("strong");
          setText(heading, title);
          box.appendChild(heading);
          if (body) {
            const text = document.createElement("p");
            setText(text, body);
            box.appendChild(text);
          }
          (actions || []).forEach(function (action) {
            const button = document.createElement("button");
            button.type = "button";
            setText(button, action[0]);
            button.addEventListener("click", action[1]);
            box.appendChild(button);
          });
          return box;
        }
        function showListSkeleton() {
          setText(sessionsNode, "");
          sessionsNode.setAttribute("aria-busy", "true");
          setText(document.getElementById("session-page-status"), t("Loading sessions…"));
          for (let i = 0; i < 6; i += 1) {
            const row = document.createElement("div");
            row.className = "skeleton-row";
            row.setAttribute("aria-hidden", "true");
            ["skeleton-line wide", "skeleton-line"].forEach(function (name) {
              const line = document.createElement("span");
              line.className = name;
              row.appendChild(line);
            });
            sessionsNode.appendChild(row);
          }
        }
        function setSignedIn(signedIn) {
          document.getElementById("shortcuts-help").hidden = !signedIn;
          document.getElementById("command-trigger").hidden = !signedIn;
          if (!signedIn) { closeCommandPalette(); commandSessions = []; }
          if (!signedIn) {
            identityDisplayVersion += 1;
            setText(document.getElementById("identity-status"), "");
            routeVersion += 1; listRouteKey = ""; detailReturnRoute = null; cancelSearchTimer(); closeShortcuts();
            clearFacets();
            setText(healthContent, "");
            setText(healthStatus, "");
            setText(document.getElementById("health-summary"), "");
            clearDashboard(); clearFleet();
            overviewStreams = null; overviewObservedAt = null;
            statsChoicesVersion += 1;
            ["source","project"].forEach(function (kind) {
              const node = document.getElementById("stats-" + kind); setText(node,"");
              const option = document.createElement("option"); option.value = ""; setText(option,kind === "source" ? t("All sources") : t("All projects")); node.appendChild(option); node.value = "";
            });
            setText(document.getElementById("stats-choices-status"),"");
            clearStats();
            clearCosts();
            clearTools();
            clearFiles();
            clearUsage();
            clearRepos();
            clearAi();
            detailReturnPage = null;
            clearSettings();
            clearSearchData(); clearInsightsPage();
          }
          signedOutNode.hidden = signedIn;
          workspaceNode.hidden = !signedIn;
          document.getElementById("login").hidden = signedIn || identityMode;
          document.getElementById("logout").hidden = !signedIn || identityMode;
          document.getElementById("lede").hidden = signedIn;
          document.getElementById("page-nav").hidden = !signedIn;
          if (!signedIn && !identityMode) focusVisible(document.getElementById("credential"));
        }
        function expireSession() {
          setSignedIn(false);
          showSessionList();
          setText(overviewNode, "");
          setText(sessionsNode, "");
          setText(detailNode, "");
          clearSessionPaging();
          clearMessages();
          setStatus(t("Session expired"));
          bumpEpoch();
          // One silent re-mint per expiry; the 5 s floor stops a mint/401 loop.
          if (identityMode && Date.now() - identitySignInAt > 5000) identitySignIn(true).catch(function () {});
        }
        async function identitySignIn(restorePage) {
          if (!identityMode || identitySignInPending) return false;
          identitySignInPending = true;
          identitySignInAt = Date.now();
          const token = bumpEpoch();
          try {
            await authWrite("POST", "{}");
          } catch (error) {
            identitySignInPending = false;
            if (token !== requestEpoch) return false;
            setStatus(error.status === 403 ? t("Your tailnet login is not permitted for this Web origin.") : t("Tailnet sign-in unavailable"));
            return false;
          }
          if (token !== requestEpoch) { identitySignInPending = false; return false; }
          try {
            await restoreSession();
          } finally {
            identitySignInPending = false;
          }
          if (token !== requestEpoch) return false;
          if (restorePage && token === requestEpoch) await restoreRequestedPage();
          return true;
        }
        function showSessionList() {
          const wasDetail = workspaceNode.classList.contains("showing-detail");
          activatePage(detailReturnPage || (activePage === "search" ? "search" : "sessions"));
          detailReturnPage = null;
          workspaceNode.className = ["dashboard", "stats", "fleet"].includes(activePage) ? "data-page" : "";
          backNode.hidden = true;
          if (wasDetail) {
            window.scrollTo({ top: sessionListScrollTop, behavior: "instant" });
            if (!workspaceNode.hidden && !focusVisible(detailReturnFocus)) focusVisible(document.getElementById("nav-" + activePage));
          }
          detailReturnFocus = null;
        }
        function showSessionDetailPane() {
          activatePage(activePage === "search" ? "search" : "sessions");
          setText(backNode, detailReturnPage === "insights" ? t("Insights") : detailReturnPage === "stats" ? (statsView === "tools" ? t("Tools") : t("Costs")) : activePage === "search" ? t("Search results") : t("Sessions"));
          if (workspaceNode.className !== "showing-detail") sessionListScrollTop = window.scrollY;
          workspaceNode.className = "showing-detail";
          backNode.hidden = false;
          window.scrollTo({ top: 0, behavior: "instant" });
        }
        function showDetailEmpty() {
          setText(detailNode, "");
          const empty = document.createElement("p");
          empty.className = "empty";
          setText(empty, t("Select a session to read it."));
          detailNode.appendChild(empty);
        }
        function activatePage(page) {
          if (page !== "fleet") clearFleet();
          if (page !== "search" || activePage === "insights") { clearInsights(); clearInsightComposer(); }
          activePage = ["sessions", "search", "dashboard", "stats", "health", "fleet", "settings", "insights"].includes(page) ? page : "sessions";
          document.getElementById("fleet-page").hidden = activePage !== "fleet";
          document.getElementById("library-page").hidden = !["sessions", "search"].includes(activePage);
          document.getElementById("health-page").hidden = activePage !== "health";
          document.getElementById("insights-page").hidden = activePage !== "insights";
          workspaceNode.classList.toggle("data-page", ["dashboard", "stats", "fleet"].includes(activePage));
          document.getElementById("dashboard-page").hidden = activePage !== "dashboard";
          document.getElementById("stats-page").hidden = activePage !== "stats";
          document.getElementById("settings-page").hidden = activePage !== "settings";
          document.getElementById("search-options").hidden = activePage !== "search";
          ["sessions", "search", "dashboard", "stats", "health", "fleet", "settings", "insights"].forEach(function (name) {
            document.getElementById("nav-" + name).setAttribute("aria-current", name === activePage ? "page" : "false");
          });
          const nav = document.getElementById("page-nav"), link = document.getElementById("nav-" + activePage);
          // Scroll only this viewport; retain the 3px padding for the keyboard focus ring.
          if (nav.clientWidth > 0 && nav.scrollWidth > nav.clientWidth) {
            if (link.offsetLeft - 3 < nav.scrollLeft) nav.scrollLeft = Math.max(0, link.offsetLeft - 3);
            else if (link.offsetLeft + link.offsetWidth + 3 > nav.scrollLeft + nav.clientWidth) nav.scrollLeft = link.offsetLeft + link.offsetWidth + 3 - nav.clientWidth;
          }
        }
        async function navigate(page, routed, tab) {
          routeVersion += routed ? 0 : 1;
          if (!routed) writeRoute(page === "stats" ? statsRoute(tab || "sessions") : ["sessions","search"].includes(page) ? libraryRoute(page) : {page:page});
          workspaceNode.classList.remove("showing-detail"); backNode.hidden = true;
          detailReturnPage = null;
          bumpEpoch();
          clearMessages();
          activatePage(page);
          const targetPage = document.getElementById(["sessions", "search"].includes(activePage) ? "query" : activePage + "-page");
          const pageHeading = targetPage.querySelector("h2") || targetPage;
          if (pageHeading !== document.getElementById("query")) pageHeading.setAttribute("tabindex", "-1");
          focusVisible(pageHeading);
          window.scrollTo({ top: 0, behavior: "instant" });
          if (activePage === "insights") {
            await loadInsightsPage(false);
          } else if (activePage === "dashboard") {
            await loadDashboard();
          } else if (activePage === "fleet") {
            await loadFleet();
          } else if (activePage === "health") {
            setText(healthContent, "");
            setText(document.getElementById("health-summary"), "");
            setText(healthStatus, t("Loading…"));
            await loadOverview();
          } else if (activePage === "search") {
            await refreshLibrary(true);
          } else if (activePage === "settings") {
            await loadSettings(false);
          } else if (activePage === "stats") {
            await showStatsView(tab || "sessions", true);
          } else {
            await loadSessions(false);
          }
        }
        // Routes never serialize auth, snapshots, cursors or arbitrary form fields.
        function parseRoute(hash) {
          const fallback = {page:"sessions", filters:{}};
          try {
            let value = String(hash || "").replace(/^#/, "");
            if (!value.startsWith("/")) value = "/" + (value || "sessions");
            if (/%(?![0-9a-f]{2})/i.test(value)) return fallback;
            decodeURIComponent(value); // Reject invalid UTF-8, including in the query.
            const split = value.split("?"), parts = split[0].split("/").slice(1);
            const params = new URLSearchParams(split[1] || ""), filters = {};
            routeFilterKeys.forEach(function (key) {
              const v = params.get(key);
              if (v && v.length <= 4096) filters[key] = v;
            });
            if (!["all", "only"].includes(filters.agents)) delete filters.agents;
            if (!["keyword", "semantic", "hybrid"].includes(filters.mode)) delete filters.mode;
            if (!["10", "25", "50"].includes(filters.limit)) delete filters.limit;
            if (filters.sort !== "lastActivity") delete filters.sort;
            if (!["source","project","day","week","hourOfWeek"].includes(filters.group)) delete filters.group;
            if (filters.noise !== "true") delete filters.noise;
            if (filters.tools !== "hide") delete filters.tools;
            ["since", "until"].forEach(function (key) { if (filters[key] && !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(filters[key])) delete filters[key]; });
            if (parts[0] === "s" && parts[1]) {
              const id = decodeURIComponent(parts[1]);
              if (id.length > 4096) return fallback;
              const route = {page:"detail", id:id};
              if (parts.length === 4 && parts[2] === "m" && /^[0-9]+$/.test(parts[3]) && Number.isSafeInteger(Number(parts[3]))) route.ordinal = Number(parts[3]);
              else if (parts.length === 3 && ["timeline", "children", "info"].includes(parts[2])) route.view = parts[2];
              else if (parts.length !== 2) return fallback;
              if (params.get("find")) route.find = params.get("find").slice(0,500);
              return route;
            }
            if (parts[0] === "stats" && parts.length <= 2 && (!parts[1] || statsTabs.includes(parts[1]))) return {page:"stats", tab:parts[1] || "sessions", filters:filters};
            if (["sessions", "search", "dashboard", "health", "fleet", "settings", "insights"].includes(parts[0]) && parts.length === 1) return {page:parts[0], filters:filters};
          } catch (error) {}
          return fallback;
        }
        function routeHref(route) {
          if (route.page === "detail") return "#/s/" + encodeURIComponent(route.id) + (route.ordinal != null ? "/m/" + route.ordinal : route.view ? "/" + route.view : "") + (route.find ? "?" + new URLSearchParams({find:route.find}).toString() : "");
          if (route.page === "stats") {
            const params = new URLSearchParams();
            ["group","sources","projects","agents","since","until","noise"].forEach(function (key) { if (route.filters && route.filters[key]) params.set(key,route.filters[key]); });
            return "#/stats/" + (statsTabs.includes(route.tab) ? route.tab : "sessions") + (params.toString() ? "?" + params.toString() : "");
          }
          const page = ["sessions", "search", "dashboard", "health", "fleet", "settings", "insights"].includes(route.page) ? route.page : "sessions";
          const params = new URLSearchParams();
          if (["sessions", "search"].includes(page)) routeFilterKeys.forEach(function (key) { if (route.filters && route.filters[key]) params.set(key, route.filters[key]); });
          return "#/" + page + (params.toString() ? "?" + params.toString().replaceAll("+", "%20") : "");
        }
        function libraryRoute(page) {
          page = page || activePage;
          const savedFilters = sessionFilters;
          const query = new URLSearchParams(sessionQuery(false).slice(1)), filters = {};
          sessionFilters = savedFilters;
          // Navigation builds the target route before activatePage changes the current page.
          query.delete("sort");
          if (page !== "search" && document.getElementById("session-sort").value === "lastActivity") query.set("sort", "lastActivity");
          [["q","query"],["sources","sources"],["projects","projectKeys"],["agents","agents"],["since","since"],["until","until"],["tools","tools"],["machine","machineId"],["sort","sort"]].forEach(function (pair) { if (query.get(pair[1])) filters[pair[0]] = query.get(pair[1]); });
          if (page === "search") { filters.mode = document.getElementById("search-mode").value || "keyword"; filters.limit = document.getElementById("search-limit").value || "25"; }
          return {page:page === "search" ? "search" : "sessions", filters:filters};
        }
        function writeRoute(route, replace) {
          const href = routeHref(route);
          if (!replace && !workspaceNode.classList.contains("showing-detail") && ["sessions", "search"].includes(activePage)) cachedListScroll = window.scrollY;
          handledRoute = href;
          if (window.location.hash === href) return;
          if (window.history && typeof window.history[replace ? "replaceState" : "pushState"] === "function") window.history[replace ? "replaceState" : "pushState"](null, "", href);
          else window.location.hash = href;
        }
        function applyRouteFilters(filters) {
          const f = filters || {};
          [["query","q"],["machineId","machine"],["since","since"],["until","until"]].forEach(function (pair) { document.getElementById(pair[0]).value = f[pair[1]] || ""; });
          document.getElementById("hide-tools").checked = f.tools === "hide";
          document.getElementById("session-sort").value = f.sort || "started";
          setAgentFilter(f.agents || "hide");
          [["source","sources"],["project","projects"]].forEach(function (pair) {
            const state = facets[pair[0]], known = new Map(state.selected);
            state.selected.clear();
            (f[pair[1]] || "").split(",").filter(Boolean).forEach(function (key) { state.selected.set(key,known.get(key) || (state.items.get(key) || {}).label || key); });
            updateFacetSummary(pair[0]); renderFacets(pair[0]);
          });
          document.getElementById("search-mode").value = f.mode || "keyword";
          document.getElementById("search-limit").value = f.limit || "25";
        }
        async function applyRoute(initial) {
          if (workspaceNode.hidden) return; // Leave the pending URL intact until either auth flow resolves.
          const raw = window.location.hash, route = parseRoute(raw), key = routeHref(route);
          if (initial) cachedListScroll = 0;
          if (!initial && handledRoute === key) { writeRoute(route, true); return; }
          handledRoute = key;
          const version = ++routeVersion;
          jumpVersion += 1; findVersion += 1;
          const returningStats = workspaceNode.classList.contains("showing-detail") && detailReturnRoute && detailReturnRoute.page === "stats" && route.tab === statsView;
          writeRoute(route, true);
          if (route.page === "detail") {
            if (detailContextSession !== route.id || !workspaceNode.classList.contains("showing-detail")) await openDetail(route.id, null, true);
            else { bumpEpoch(); messageRequest = null; }
            if (version !== routeVersion || workspaceNode.hidden || !workspaceNode.classList.contains("showing-detail")) return;
            await showDetailView(route.view || "transcript");
            if (version !== routeVersion || workspaceNode.hidden || !workspaceNode.classList.contains("showing-detail")) return;
            if (route.ordinal != null) await jumpToOrdinal(route.ordinal, true);
            if (version !== routeVersion || workspaceNode.hidden || !workspaceNode.classList.contains("showing-detail")) return;
            if (route.find) { openTranscriptFind(route.find); await searchFurther(); }
            return;
          }
          bumpEpoch(); clearMessages();
          workspaceNode.classList.remove("showing-detail"); backNode.hidden = true; detailReturnPage = null;
          if (["sessions", "search"].includes(route.page)) {
            activatePage(route.page); applyRouteFilters(route.filters); renderActiveFilters();
            if (key === listRouteKey || (initial && !Object.keys(route.filters || {}).length && route.page === "sessions")) {
              window.scrollTo({top:cachedListScroll, behavior:"instant"}); return;
            }
            await refreshLibrary(true); return;
          }
          if (route.page === "health" && initial) { activatePage("health"); return; }
          if (route.page === "stats" && (activePage === "stats" || returningStats) && statsView === route.tab && routeHref(statsRoute()) === key) { activatePage("stats"); window.scrollTo({top:sessionListScrollTop,behavior:"instant"}); return; }
          if (route.page === "stats") applyStatsRoute(route.filters);
          await navigate(route.page, true, route.tab);
        }
        function restoreRequestedPage() { return applyRoute(true); }
        function historyChanged() {
          const legacy = window.location.hash && !window.location.hash.startsWith("#/");
          if (!workspaceNode.hidden) applyRoute(false).then(function () {
            if (!legacy || !["sessions","search"].includes(activePage) || workspaceNode.classList.contains("showing-detail")) return;
            const version = routeVersion, top = cachedListScroll;
            function restore() { if (version === routeVersion && !workspaceNode.hidden && !workspaceNode.classList.contains("showing-detail")) window.scrollTo({top:top,behavior:"instant"}); }
            // Native legacy fragment scrolling can run after hashchange. Restore after that browser step.
            if (typeof requestAnimationFrame === "function") requestAnimationFrame(restore);
            else if (typeof setTimeout === "function") setTimeout(restore,0);
          }).catch(function () { setStatus(t("Route unavailable. Try opening it again.")); });
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
          ["query", "mode", "limit", "sort", "snapshotId", "cursor"].forEach(function (key) { params.delete(key); });
          setText(status, t("Checking search availability…"));
          setText(document.getElementById("search-capability-summary"), t("Checking search availability…"));
          try {
            const suffix = params.toString().replaceAll("+", "%20");
            const page = await api("GET", "/web/api/search/status" + (suffix ? "?" + suffix : ""));
            if (version !== searchStatusVersion) return;
            const modes = ["keyword", "semantic", "hybrid"];
            if (!page || modes.some(function (mode) { return !["available", "unavailable"].includes(page[mode]); })) throw new Error("invalid search status");
            modes.forEach(function (mode) { document.getElementById("mode-" + mode).disabled = page[mode] !== "available"; });
            const notes = [page.semantic === "available" ? t("Semantic search ready") : t("Semantic search unavailable")];
            if (Number.isSafeInteger(page.embeddedSessionCount) && Number.isSafeInteger(page.eligibleSessionCount)) {
              notes.push(t("Semantic index: {0} / {1} sessions{2}", [page.embeddedSessionCount.toLocaleString(uiLocale), page.eligibleSessionCount.toLocaleString(uiLocale), Number.isFinite(page.progressPercent) ? " (" + page.progressPercent + "%)" : ""]));
            }
            if (page.model) notes.push(page.model);
            if (page.warning) notes.push(page.warning);
            setText(status, notes.join(" · "));
            setText(document.getElementById("search-capability-summary"), t("Search availability · {0}{1}", [page.semantic === "available" ? t("Semantic ready") : page.hybrid === "available" ? t("Hybrid ready") : t("Keyword only"), page.warning ? t(" · warning") : ""]));
          } catch (error) {
            if (version === searchStatusVersion) {
              document.getElementById("mode-semantic").disabled = true;
              document.getElementById("mode-hybrid").disabled = true;
              setText(status, t("Search status unavailable. Submit a search to retry."));
              setText(document.getElementById("search-capability-summary"), t("Search availability unknown · submit to retry"));
            }
          }
        }
        function activeFilterList() {
          const list = [];
          const query = document.getElementById("query");
          if (query.value.trim() && activePage !== "search") list.push(["“" + query.value.trim() + "”", function () { query.value = ""; }]);
          ["source", "project"].forEach(function (kind) {
            facets[kind].selected.forEach(function (label, key) {
              list.push([(kind === "source" ? t("Source: ") : t("Project: ")) + label, function () {
                facets[kind].selected.delete(key);
                updateFacetSummary(kind);
                renderFacets(kind);
              }]);
            });
          });
          [["since", t("Since ")], ["until", t("Until ")]].forEach(function (pair) {
            const input = document.getElementById(pair[0]);
            if (input.value) list.push([pair[1] + input.value, function () { input.value = ""; }]);
          });
          const tools = document.getElementById("hide-tools");
          if (tools.checked) list.push([t("Hiding tool-only"), function () { tools.checked = false; }]);
          const machine = document.getElementById("machineId");
          if (machine.value.trim()) list.push([t("Machine: {0}", [machine.value.trim()]), function () { machine.value = ""; }]);
          if (agentFilter !== "hide") list.push([agentFilter === "only" ? t("Agents only") : t("Including agents"), function () { setAgentFilter("hide"); }]);
          return list;
        }
        function hasActiveFilters() {
          return activeFilterList().length > 0;
        }
        function clearAllFilters() {
          activeFilterList().forEach(function (entry) { entry[1](); });
          refreshLibrary().catch(function () {});
        }
        function renderActiveFilters() {
          const host = document.getElementById("active-filters");
          setText(host, "");
          const list = activeFilterList();
          list.forEach(function (entry) {
            const chip = document.createElement("span");
            chip.className = "chip";
            const label = document.createElement("span");
            label.className = "chip-label";
            setText(label, entry[0]);
            chip.appendChild(label);
            const remove = document.createElement("button");
            remove.type = "button";
            remove.className = "chip-remove";
            remove.setAttribute("aria-label", t("Remove filter {0}", [entry[0]]));
            remove.appendChild(icon("x"));
            remove.addEventListener("click", function () {
              entry[1]();
              refreshLibrary().catch(function () {});
            });
            chip.appendChild(remove);
            host.appendChild(chip);
          });
          if (list.length > 1) {
            const clear = document.createElement("button");
            clear.type = "button";
            clear.className = "chip-clear";
            setText(clear, t("Clear all"));
            clear.addEventListener("click", clearAllFilters);
            host.appendChild(clear);
          }
          host.hidden = !list.length;
        }
        function refreshLibrary(routed) {
          cancelSearchTimer();
          const route = libraryRoute();
          if (!routed) writeRoute(route);
          renderActiveFilters();
          if (activePage !== "search") return loadSessions(false);
          setText(document.getElementById("search-result-status"), "");
          if (!document.getElementById("query").value.trim()) clearInsights();
          const results = document.getElementById("query").value.trim() ? loadRankedSearch() : loadSessions(false);
          return Promise.all([results, loadSearchStatus()]);
        }
        async function loadRankedSearch(more) {
          if (more && (!rankedCursor || !rankedSnapshot || rankedBusy)) return;
          if (!more) clearInsights();
          const token = bumpEpoch();
          if (!more) {
            listRouteKey = ""; clearSessionPaging(); showListSkeleton(); showSessionList(); showDetailEmpty(); clearMessages();
          }
          const status = document.getElementById("search-result-status"), moreButton = document.getElementById("search-more");
          const params = new URLSearchParams(more ? rankedFilters : sessionQuery(false).slice(1));
          const mode = document.getElementById("search-mode").value || "keyword";
          if (!more) {
            if (mode !== "keyword") params.set("mode", mode);
            params.set("limit", document.getElementById("search-limit").value || "25");
            rankedFilters = params.toString();
          } else { params.set("snapshotId",rankedSnapshot); params.set("cursor",rankedCursor); }
          rankedBusy = true; moreButton.disabled = true;
          setText(status, t("Searching…"));
          try {
            const page = await api("GET", "/web/api/search?" + params.toString().replaceAll("+", "%20"));
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || page.query !== params.get("query")) throw new Error("changed search");
            const items = page.items.map(function (hit) {
              if (!hit.session || typeof hit.session.sessionId !== "string") throw new Error("invalid search hit");
              return Object.assign({}, hit.session, { snippet: hit.snippet, matchType: hit.matchType });
            });
            if (more && page.snapshotId !== rankedSnapshot) throw new Error("changed search snapshot");
            if (page.hasMore === true && (!page.snapshotId || !page.nextCursor)) throw new Error("invalid search cursor");
            const query = params.get("query");
            items.forEach(function (item) { item.searchQuery = query; });
            acceptSessionsPage(!!more, { items: items });
            // Search appends a frozen cohort, not the library's previous/next pages.
            sessionPageSizes = []; sessionPage = 0; sessionCursor = ""; sessionSnapshotId = "";
            Array.from(sessionsNode.children).forEach(function (row) { row.hidden = false; }); updateSessionMore();
            rankedSnapshot = page.snapshotId || ""; rankedCursor = page.hasMore === true ? page.nextCursor : "";
            moreButton.hidden = !rankedCursor;
            setStatus(t("signed in"));
            const modes = Array.isArray(page.searchModes) ? page.searchModes.join(" + ") : mode;
            const insightCount = more ? 0 : renderInsights(page.insightResults || []);
            const counts = plural(sessionsNode.children.length, "session") + (insightCount ? " · " + plural(insightCount, "insight") : "");
            setText(status, counts + " · " + (page.warning || modes) + (page.coverage ? " · " + page.coverage : t(" · Legacy server: paging coverage not reported")) + (page.truncated ? t(" · Truncated cohort") : ""));
          } catch (error) {
            if (token === requestEpoch) {
              rankedCursor = ""; moreButton.hidden = true;
              setText(status, t("Search unavailable or this server does not support continuation. Submit again to restart; no query options were silently dropped."));
              if (!more) showListError();
            }
          } finally { if (token === requestEpoch) { rankedBusy = false; moreButton.disabled = false; } }
        }
        document.getElementById("search-more").addEventListener("click",function () { loadRankedSearch(true); });
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
          setText(status, t("Checking edit access…"));
          try {
            const access = await api("GET", "/web/api/auth");
            if (version !== insightWriteVersion || activePage !== "search") return;
            insightCanWrite = access && access.canWrite === true;
            setText(status, insightCanWrite ? t("Save a note to your library. Keyword search is available immediately.") : t("Read only. Sign in with an editor key to save insights."));
          } catch (error) {
            if (version !== insightWriteVersion || activePage !== "search") return;
            setText(status, t("Edit access unavailable. Close and reopen this section to retry."));
          }
          updateInsightWriteControls();
        }
        async function saveInsight() {
          if (!insightCanWrite || insightSavePending || activePage !== "search") return;
          const status = document.getElementById("insight-write-status");
          const content = document.getElementById("insight-content-input").value.trim();
          if (content.length < 10 || content.length > 50000) {
            setText(status, t("Enter an insight between 10 and 50,000 characters.")); return;
          }
          const importance = Number(document.getElementById("insight-importance-input").value);
          if (!Number.isInteger(importance) || importance < 0 || importance > 5) {
            setText(status, t("Importance must be between 0 and 5.")); return;
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
          setText(status, t("Saving…"));
          try {
            const result = await api("POST", "/web/api/insights", JSON.stringify(body));
            if (version !== insightWriteVersion || activePage !== "search") return;
            if (!result || typeof result.id !== "string" || !result.id) throw new Error("invalid save result");
            savedInsightId = result.id;
            document.getElementById("insight-content-input").value = "";
            document.getElementById("insight-saved-read").hidden = false;
            setText(status, t("Saved. {0}", [result.warning || t("Find it with keyword search.")]));
          } catch (error) {
            if (version !== insightWriteVersion || activePage !== "search") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              insightCanWrite = false;
              setText(status, t("Editor access required. Sign in again to save."));
            } else if (error.status === 400 || error.status === 404) {
              setText(status, t("Could not save. Check the note and source session ID before retrying."));
            } else {
              setText(status, t("Could not confirm the save. Search before retrying; your draft is preserved."));
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
        let modalReturnFocus = null, activeModal = null, detailReturnFocus = null;
        function focusVisible(node) {
          if (!node || node.disabled || node.isConnected === false || typeof node.focus !== "function") return false;
          let parent = node;
          while (parent) { if (parent.hidden) return false; parent = parent.parentNode; }
          if (typeof node.checkVisibility === "function" && !node.checkVisibility()) return false;
          node.focus({ preventScroll: true }); return true;
        }
        function openModal(dialog, first) {
          if (dialog.open) return;
          if (activeModal) return;
          modalReturnFocus = document.activeElement; activeModal = dialog;
          dialog.hidden = false; dialog.setAttribute("aria-modal", "true");
          if (typeof dialog.showModal === "function") dialog.showModal(); else dialog.open = true;
          if (!focusVisible(first)) focusVisible(dialog);
        }
        function closeModal(dialog, restoreFocus) {
          if (activeModal !== dialog) { dialog.hidden = true; return; }
          const target = modalReturnFocus; activeModal = null; modalReturnFocus = null;
          if (typeof dialog.close === "function" && dialog.open) dialog.close(); else dialog.open = false;
          dialog.hidden = true;
          if (restoreFocus) focusVisible(target);
        }
        function closeInsight(restoreFocus) {
          insightVersion += 1;
          insightPage = null;
          insightBusy = false;
          const dialog = document.getElementById("insight-dialog");
          closeModal(dialog, restoreFocus === true);
          setText(document.getElementById("insight-body"), "");
          setText(document.getElementById("insight-detail-status"), "");
          document.getElementById("insight-more").hidden = true;
        }
        function clearInsightsPage() {
          insightsList = {items:[],snapshot:"",cursor:"",busy:false};
          setText(document.getElementById("insights-rows"),""); setText(document.getElementById("insights-status"),"");
          document.getElementById("insights-more").hidden = true;
        }
        async function loadInsightsPage(more) {
          if (more && (insightsList.busy || !insightsList.cursor)) return;
          if (!more) clearInsightsPage();
          const state = insightsList, token = requestEpoch;
          const status = document.getElementById("insights-status"), button = document.getElementById("insights-more");
          state.busy = true; button.disabled = true; setText(status,t("Loading insights…"));
          const params = new URLSearchParams({limit:"25"});
          if (more) { params.set("snapshotId",state.snapshot); params.set("cursor",state.cursor); }
          try {
            const page = await api("GET","/web/api/insights?" + params);
            if (token !== requestEpoch || state !== insightsList || activePage !== "insights") return;
            if (!page || !page.snapshotId || !Array.isArray(page.items) || page.items.length > 25 || (more && page.snapshotId !== state.snapshot) || (page.nextCursor && (!page.items.length || page.nextCursor === state.cursor))) throw new Error("invalid insights page");
            const seen = new Set(state.items.map(function (item) { return item.id; }));
            page.items.forEach(function (item) {
              if (!item || typeof item.id !== "string" || !item.id || seen.has(item.id) || typeof item.content !== "string" || !item.content || Array.from(item.content).length > 600 || typeof item.revision !== "string" || !item.revision || (item.sourceSessionId != null && (typeof item.sourceSessionId !== "string" || !item.sourceSessionId))) throw new Error("invalid insight");
              seen.add(item.id);
            });
            page.items.forEach(function (item) {
              const card = document.createElement("article"); card.className = "insight-card";
              const label = document.createElement("p"); label.className = "meta";
              setText(label,(item.sourceSessionId ? t("Linked session note") : t("Global library note")) + (Number.isFinite(item.createdAt) ? " · " + new Date(item.createdAt * 1000).toLocaleString(uiLocale) : t(" · date unavailable")));
              const preview = document.createElement("p"); setText(preview,item.content);
              const read = document.createElement("button"); read.type = "button"; setText(read,t("Read insight")); read.addEventListener("click",function () { loadInsight(item.id,false); });
              card.appendChild(label); card.appendChild(preview); card.appendChild(read);
              if (item.sourceSessionId) { const source = document.createElement("button"); source.type = "button"; setText(source,t("Open source session")); source.addEventListener("click",function () { openDetail(item.sourceSessionId,"insights").catch(function () {}); }); card.appendChild(source); }
              document.getElementById("insights-rows").appendChild(card);
            });
            state.items = state.items.concat(page.items); state.snapshot = page.snapshotId; state.cursor = page.nextCursor || "";
            button.hidden = !state.cursor;
            setText(status,state.items.length ? t("{0} notes loaded · {1}", [state.items.length, state.cursor ? t("More notes in this snapshot") : t("End of snapshot")]) : t("No active insights available. Global and admitted linked notes appear here."));
          } catch (error) {
            if (token !== requestEpoch || state !== insightsList || activePage !== "insights") return;
            button.hidden = true;
            setText(status,[400,404,405,501].includes(error.status) ? t("Insights unavailable on this server. Upgrade the server, then Refresh insights to retry.") : t("Insights changed or are unavailable. Refresh insights to restart the snapshot."));
          } finally { if (token === requestEpoch && state === insightsList) { state.busy = false; button.disabled = false; } }
        }
        document.getElementById("insights-refresh").addEventListener("click",function () { loadInsightsPage(false); });
        document.getElementById("insights-more").addEventListener("click",function () { loadInsightsPage(true); });
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
            setText(label, item.matchType === "semantic" ? t("Semantic match") : t("Keyword match"));
            const preview = document.createElement("p");
            setText(preview, item.content);
            const read = document.createElement("button");
            read.type = "button";
            setText(read, t("Read insight"));
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
          openModal(dialog, document.getElementById("insight-close"));
          insightBusy = true;
          button.disabled = true;
          setText(status, t("Loading insight…"));
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
            setText(status, page.nextOffset == null ? t("Complete · {0} characters", [page.totalLength.toLocaleString(uiLocale)]) : t("{0} of {1} characters", [end.toLocaleString(uiLocale), page.totalLength.toLocaleString(uiLocale)]));
          } catch (error) {
            if (version !== insightVersion) return;
            insightPage = null;
            setText(body, "");
            button.hidden = true;
            setText(status, t("Insight changed or is unavailable. Close and reopen it to retry."));
          } finally {
            if (version === insightVersion) { insightBusy = false; button.disabled = false; }
          }
        }
        document.getElementById("insight-close").addEventListener("click", function () { closeInsight(true); });
        document.getElementById("insight-dialog").addEventListener("cancel", function (event) { event.preventDefault(); closeInsight(true); });
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
          document.getElementById("settings-content").setAttribute("aria-busy", "false");
          setText(document.getElementById("settings-status"), "");
          document.getElementById("settings-more").hidden = true;
        }
        function renderSettings(summary) {
          const content = document.getElementById("settings-content");
          function section(title, collapsed) {
            const element = document.createElement(collapsed ? "details" : "section");
            element.className = "settings-section";
            const heading = document.createElement(collapsed ? "summary" : "h3");
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
          fields(section(t("Database")), [[t("Visible sessions"), summary.totalSessions.toLocaleString(uiLocale)], [t("Web server"), window.location.origin]]);
          const sources = section(t("Active Sources"));
          const badges = document.createElement("div");
          badges.className = "settings-sources";
          summary.sources.forEach(function (source) {
            const badge = document.createElement("span");
            badge.className = "badge " + sourceClass(source.key);
            setText(badge, sourceLabel(source.key));
            badges.appendChild(badge);
          });
          if (!summary.sources.length) setText(badges, t("No sources enabled."));
          sources.appendChild(badges);
          const sync = section(t("Capture & sync provenance"), true);
          const retired = document.createElement("p");
          setText(retired, t("Legacy peer-sync settings are retired in this runtime. Collectors publish captures to this server and its replicas; per-source heartbeats, last captures and replica acknowledgements are shown on the Health page."));
          sync.appendChild(retired);
          const healthLink = document.createElement("a");
          healthLink.href = "#health";
          setText(healthLink, t("Open Health"));
          sync.appendChild(healthLink);
          const unavailable = section(t("Not available in this deployment"), true);
          const unavailableNote = document.createElement("p");
          setText(unavailableNote, t("This Web runs on the central server and reads captured sessions only. The following legacy Web features read or acted on the machine that hosted the old Web and are intentionally not offered here:"));
          unavailable.appendChild(unavailableNote);
          const unavailableList = document.createElement("ul");
          [
            t("Skills, hooks, memory files and hygiene checks of a local machine — use the Engram app on that Mac."),
            t("Live session events and monitor alerts — Health shows per-source capture, ingest and replica observations instead."),
            t("Resume launch and link-sessions filesystem actions — run them on the machine that owns the session."),
            t("Developer mock, lint and log utilities — development-only endpoints, not part of the Web.")
          ].forEach(function (text) {
            const item = document.createElement("li");
            setText(item, text);
            unavailableList.appendChild(item);
          });
          unavailable.appendChild(unavailableList);
          const aliases = section(t("Project Aliases"));
          const explanation = document.createElement("p");
          setText(explanation, t("Project names linked across moved or renamed directories."));
          aliases.appendChild(explanation);
          const table = document.createElement("table");
          table.setAttribute("aria-label", t("Project aliases"));
          const head = document.createElement("thead");
          const row = document.createElement("tr");
          [t("Old Project"), t("New Project"), t("Action")].forEach(function (text) {
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
            setText(empty, t("No visible project aliases."));
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
          setText(status, t("Loading…"));
          document.getElementById("settings-content").setAttribute("aria-busy", "true");
          moreButton.disabled = true;
          try {
            const pendingPage = api("GET", "/web/api/settings" + query);
            if (!more) loadSettingsAccess();
            const page = await pendingPage;
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.sources) || !Array.isArray(page.aliases)
                || (more && page.snapshotId !== settingsSnapshot)) throw new Error("changed settings");
            if (!more) renderSettings(page);
            setStatus(t("signed in"));
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
              setText(remove, t("Delete"));
              remove.setAttribute("aria-label", t("Delete alias {0}", [alias.aliasLabel || alias.alias]));
              remove.addEventListener("click", function () { mutateAlias("remove", { alias: alias.alias, canonical: alias.canonical }); });
              settingsDeleteButtons.push(remove);
              action.appendChild(remove);
              row.appendChild(action);
              settingsAliasRows.appendChild(row);
            });
            settingsSnapshot = page.snapshotId;
            settingsCursor = page.nextCursor || "";
            moreButton.hidden = !settingsCursor;
            setText(status, t("Observed: {0}", [healthTime(page.observedAt)]));
            updateAliasControls();
          } catch (error) {
            if (token === requestEpoch) setText(status, t("Settings unavailable. Refresh to retry."));
          } finally {
            if (token === requestEpoch) { moreButton.disabled = false; document.getElementById("settings-content").setAttribute("aria-busy", "false"); }
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
          setText(status, t("Checking edit access…"));
          try {
            const access = await api("GET", "/web/api/auth");
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            settingsCanWrite = access && access.canWrite === true;
            setText(status, settingsCanWrite ? t("Editor access") : t("Read only. Sign in with an editor key to make changes."));
            updateAliasControls();
            loadSourceSettings();
            if (settingsCanWrite) loadAliasProjects(false);
          } catch (error) {
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            settingsCanWrite = false;
            setText(status, t("Edit access unavailable. Refresh to retry."));
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
          setText(status, t("Loading saved settings…"));
          try {
            const result = await api("GET", "/web/api/settings/ai");
            if (version !== aiConfigVersion || activePage !== "settings") return;
            renderAISettings(result);
            setText(status, settingsCanWrite ? t("Edit values and save your changes.") : t("Read only. Sign in with an editor key to change settings."));
          } catch (error) {
            if (version !== aiConfigVersion || activePage !== "settings") return;
            aiConfigSaved = null;
            setText(status, t("Settings unavailable. Reload to retry."));
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
            if (!validAIConfigValue(field, value)) { setText(status, t("Check {0} before saving.", [field.label])); return; }
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
          if (!Object.keys(patch).length) { setText(status, t("No changes to save.")); return; }
          const version = aiConfigVersion;
          aiConfigBusy = true;
          updateAISettingsControls();
          setText(status, t("Saving…"));
          try {
            const result = await api("POST", "/web/api/settings/ai", JSON.stringify(patch));
            if (version !== aiConfigVersion || activePage !== "settings") return;
            renderAISettings(result);
            setText(status, t("Saved. Environment overrides still take precedence; existing vectors are unchanged."));
          } catch (error) {
            if (version !== aiConfigVersion || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) settingsCanWrite = false;
            aiConfigUncertain = true;
            setText(status, t("Could not confirm saving. Your draft is retained. Reload saved settings before retrying."));
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
          setText(status, t("Loading source settings…"));
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
              [sourceLabel(item.key), item.enabled ? t("Enabled") : t("Disabled")].forEach(function (text) {
                const cell = document.createElement("td");
                setText(cell, text);
                row.appendChild(cell);
              });
              const action = document.createElement("td");
              const button = document.createElement("button");
              button.type = "button";
              setText(button, item.enabled ? t("Disable") : t("Enable"));
              button.setAttribute("aria-label", (item.enabled ? t("Disable ") : t("Enable ")) + sourceLabel(item.key));
              button.addEventListener("click", function () { setWebSourceEnabled(item.key, !item.enabled); });
              action.appendChild(button);
              row.appendChild(action);
              rows.appendChild(row);
              sourceSettingsRows.set(item.key, { item: item, button: button });
            });
            document.getElementById("source-settings").hidden = false;
            setText(status, result.sources.length ? "" : t("No sources reported."));
            if (!settingsSnapshot && result.sources.length && result.sources.every(function (item) { return !item.enabled; })) {
              setText(document.getElementById("settings-status"), t("All sources are disabled. Enable a source below to show sessions."));
              setStatus(t("signed in"));
            }
            updateAliasControls();
          } catch (error) {
            if (version === sourceSettingsVersion && accessVersion === settingsAccessVersion && activePage === "settings") {
              setText(status, t("Source settings unavailable. Refresh to retry."));
            }
          }
        }
        async function setWebSourceEnabled(source, enabled) {
          if (!settingsCanWrite || settingsWriteBusy || activePage !== "settings" || !sourceSettingsRows.has(source) || typeof enabled !== "boolean") return;
          const token = requestEpoch;
          settingsWriteBusy = true;
          updateAliasControls();
          const status = document.getElementById("source-write-status");
          setText(status, t("Saving source setting…"));
          try {
            const result = await api("POST", "/web/api/settings/sources", JSON.stringify({ source: source, enabled: enabled }));
            if (token !== requestEpoch || activePage !== "settings") return;
            if (!result || result.source !== source || result.enabled !== enabled) throw new Error("unconfirmed source setting");
            const refreshed = loadSettings(false);
            const refreshEpoch = requestEpoch;
            await refreshed;
            if (refreshEpoch === requestEpoch && activePage === "settings") setText(status, t(enabled ? "{0} enabled." : "{0} disabled.", [sourceLabel(source)]));
          } catch (error) {
            if (token !== requestEpoch || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              settingsCanWrite = false;
              setText(status, t("Editor access required. Sign in again to edit."));
            } else setText(status, t("Could not confirm the change. Refresh settings before retrying."));
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
          setText(status, t("Loading projects…"));
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
            setText(status, aliasProjects.size ? "" : t("No matching projects."));
          } catch (error) {
            if (version === aliasProjectVersion && accessVersion === settingsAccessVersion && activePage === "settings") setText(status, t("Projects unavailable. Find again to retry."));
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
            setText(document.getElementById("alias-status"), t("Enter an old name or path and select a destination project."));
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
          setText(status, t("Saving…"));
          try {
            const result = await api(action === "add" ? "POST" : "DELETE", "/web/api/settings/aliases", JSON.stringify(pair));
            if (token !== requestEpoch || activePage !== "settings") return;
            if (!result || result.action !== action || (result.changed !== 0 && result.changed !== 1)) throw new Error("invalid write result");
            const refreshed = loadSettings(false);
            const refreshEpoch = requestEpoch;
            await refreshed;
            if (refreshEpoch === requestEpoch && activePage === "settings") setText(status, result.changed ? (action === "add" ? t("Alias added.") : t("Alias removed.")) : t("No change was needed."));
          } catch (error) {
            if (token !== requestEpoch || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              settingsCanWrite = false;
              setText(status, t("Editor access required. Sign in again to edit."));
            } else setText(status, t("Could not confirm the change. Refresh settings before retrying."));
          } finally {
            settingsWriteBusy = false;
            updateAliasControls();
          }
        }
        // --- Charts: numeric observations only. Unknown is never converted to zero.
        function chartNumber(value) { return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null; }
        function dailySeries(items, field, end, days) {
          const byDay = new Map(items.map(function (item) { return [item.key, chartNumber(item[field])]; }));
          const result = [], last = Date.parse(end + "T00:00:00Z");
          if (!Number.isFinite(last) || days < 1 || days > 366) return result;
          for (let i = days - 1; i >= 0; i -= 1) {
            const label = new Date(last - i * 86400000).toISOString().slice(0, 10);
            result.push({label:label, value:byDay.has(label) ? byDay.get(label) : 0});
          }
          return result;
        }
        function chartAmount(value, currency) { return value === null ? t("Not reported") : costValue(value, currency ? "costUsd" : "count"); }
        function renderChart(id, title, data, options) {
          const node = document.getElementById(id); setText(node, ""); node.className = "chart";
          const opts = options || {}, currency = !!opts.currency;
          let rows = data.map(function (item) { return {label:String(item.label == null ? t("Not reported") : item.label), value:chartNumber(item.value), source:item.source}; });
          const total = rows.reduce(function (sum, row) { return sum + (row.value === null ? 0 : row.value); }, 0);
          const unknown = rows.filter(function (row) { return row.value === null; }).length;
          const summary = t("{0} loaded", [chartAmount(total, currency)]) + (chartNumber(opts.fullTotal) === null ? "" : t(" / {0} full", [chartAmount(opts.fullTotal, currency)])) + " · " + (opts.coverage || t("Loaded rows")) + (unknown ? t(" · {0} values not reported", [unknown]) : "");
          const heading = document.createElement("h3"), note = document.createElement("p");
          setText(heading, title); setText(note, summary); node.appendChild(heading); node.appendChild(note);
          if (!rows.length) { const empty = document.createElement("p"); setText(empty, t("No observations for this scope.")); node.appendChild(empty); return; }
          if (!opts.columns) {
            rows.sort(function (a,b) { return (b.value || 0) - (a.value || 0); });
            if (rows.length > 12) {
              const rest = rows.slice(12); rows = rows.slice(0, 12);
              rows.push({label:t("Other loaded groups"), value:rest.every(function (row) { return row.value !== null; }) ? rest.reduce(function (n,row) { return n + row.value; },0) : null});
              // Keep unknown rows distinct so aggregation cannot conceal reported observations.
              if (rest.some(function (row) { return row.value === null; })) {
                rows[12].value = rest.reduce(function (n,row) { return n + (row.value || 0); },0);
                rows.push({label:t("Other unreported groups"), value:null});
              }
            }
          }
          const width = 720, height = 210;
          const max = Math.max(1, ...rows.map(function (row) { return row.value || 0; }));
          if (opts.columns) {
            const image = svg("svg", {viewBox:"0 0 " + width + " " + height, role:"img", "aria-label":title + ": " + summary});
            const imageTitle = svg("title"); setText(imageTitle, title + ": " + summary); image.appendChild(imageTitle);
            rows.forEach(function (row,i) {
              const value = row.value || 0, bar = svg("rect", {x:8 + i * 704 / rows.length, y:170 - value / max * 155, width:Math.max(1,704 / rows.length - 3), height:value / max * 155, class:"chart-bar"});
              bar.dataset.value = String(value);
              const tip = svg("title"); setText(tip, row.label + ": " + chartAmount(row.value,currency)); bar.appendChild(tip); image.appendChild(bar);
            });
            node.appendChild(image);
            const axis = document.createElement("p"); axis.className = "chart-dates";
            setText(axis, t("{0} → {1} · Peak {2}", [rows[0].label, rows[rows.length - 1].label, chartAmount(Math.max(0,...rows.map(function (row) { return row.value || 0; })),currency)])); node.appendChild(axis);
          } else {
            rows.forEach(function (row) {
              const line = document.createElement("div"); line.className = "ranked-row " + sourceClass(row.source);
              const label = document.createElement("span"), amount = document.createElement("strong");
              setText(label,row.label); setText(amount,chartAmount(row.value,currency)); line.appendChild(label); line.appendChild(amount);
              const image = svg("svg", {viewBox:"0 0 720 12", preserveAspectRatio:"none", role:"img","aria-label":title + ": " + summary + " · " + row.label + ": " + chartAmount(row.value,currency)});
              const tip = svg("title"); setText(tip,title + ": " + summary + " · " + row.label + ": " + chartAmount(row.value,currency)); image.appendChild(tip);
              const bar = svg("rect", {width:(row.value || 0) / max * 720,height:12,class:"chart-bar"}); bar.dataset.value = String(row.value || 0); image.appendChild(bar); line.appendChild(image); node.appendChild(line);
            });
          }
          if (!total) { const empty = document.createElement("p"); setText(empty, unknown === data.length ? t("No numeric observations reported.") : t("All reported values are zero.")); node.appendChild(empty); }
          const details = document.createElement("details"), caption = document.createElement("summary"); setText(caption, t("Table · chart values")); details.appendChild(caption);
          const table = document.createElement("table"); table.setAttribute("aria-label", t("{0} chart values", [title]));
          const header = document.createElement("tr"); [t("Group"), currency ? "USD" : t("Value")].forEach(function (value) { const th = document.createElement("th"); th.setAttribute("scope","col"); setText(th,value); header.appendChild(th); }); table.appendChild(header);
          rows.forEach(function (row) { const tr = document.createElement("tr"); [row.label, chartAmount(row.value,currency)].forEach(function (value) { const td = document.createElement("td"); setText(td,value); tr.appendChild(td); }); table.appendChild(tr); });
          details.appendChild(table); node.appendChild(details);
        }
        function updateChartRows(name, items, title, field, fullTotal, cursor, groupBy) {
          chartRows[name].push(...items);
          const columns = groupBy === "day" || groupBy === "week";
          let rows = chartRows[name].map(function (item) { return {label:groupBy === "source" ? sourceLabel(item.key) : groupBy === "hourOfWeek" ? hourOfWeekLabel(item.key) : item.label || item.key, value:item[field], source:groupBy === "source" ? item.key : null}; });
          let bins = columns ? t(" · returned buckets only") : "";
          if (columns) rows.sort(function (a,b) { return String(a.label).localeCompare(String(b.label)); });
          if (groupBy === "day" && !cursor && rows.length && chartRows[name].every(function (item) { return /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(item.key); })) {
            const keys = chartRows[name].map(function (item) { return item.key; }).sort();
            const days = Math.round((Date.parse(keys[keys.length - 1]) - Date.parse(keys[0])) / 86400000) + 1;
            if (days > 0 && days <= 366) { rows = dailySeries(chartRows[name],field,keys[keys.length - 1],days); bins = t(" · calendar dates (zero-filled)"); }
          }
          renderChart(name + "-chart", title, rows, {columns:columns, currency:field === "costUsd", fullTotal:fullTotal, coverage:t("{0} · {1} loaded rows{2}", [cursor ? (chartRows[name].length >= 5000 ? t("Partial: 5,000-row cap; narrow filters") : t("Partial: load more for remaining groups")) : t("All returned groups"), chartRows[name].length, bins])});
        }
        function renderUsageChart(items) {
          const node = document.getElementById("usage-chart"); setText(node, ""); node.className = "chart";
          const title = document.createElement("h3"); setText(title, t("Recorded usage · separate units, not additive")); node.appendChild(title);
          if (!items.length) { const empty = document.createElement("p"); setText(empty, t("No recorded usage observations.")); node.appendChild(empty); }
          items.forEach(function (item) {
            const value = chartNumber(item.value), limit = chartNumber(item.limit), percent = value !== null && limit !== null && limit > 0 ? value / limit * 100 : null;
            const row = document.createElement("div"); row.className = "usage-meter"; row.dataset.tone = percent !== null && percent >= 90 ? "danger" : percent !== null && percent >= 70 ? "warn" : "ok";
            const label = document.createElement("p");
            const text = sourceLabel(item.source) + " · " + item.metric + ": " + chartAmount(value,false) + (item.unit ? " " + item.unit : "") + (limit === null ? t(" · limit not reported") : " / " + chartAmount(limit,false)) + (percent === null ? t(" · ratio unavailable") : " · " + percent.toFixed(1) + "%") + " · " + (item.basis === "indexedSessions" ? t("Indexed sessions (estimate)") : t("Reported"));
            setText(label,text); row.appendChild(label);
            const image = svg("svg", {viewBox:"0 0 720 16", preserveAspectRatio:"none", role:"img", "aria-label":text});
            const tip = svg("title"); setText(tip,text); image.appendChild(tip);
            image.appendChild(svg("rect", {width:720,height:16,class:"usage-track"}));
            if (percent !== null) image.appendChild(svg("rect", {width:Math.min(100,percent) * 7.2,height:16,class:"chart-bar"}));
            row.appendChild(image); node.appendChild(row);
          });
        }
        function clearDashboard() {
          dashboardVersion += 1; dashboardHoursVersion += 1;
          ["kpis", "activity", "hours", "cost", "sources", "projects", "health"].forEach(function (name) { setText(document.getElementById("dashboard-" + name), ""); });
        }
        // Each endpoint walks one cursor at a time; the four independent widgets may run concurrently.
        // Cap both pages and rows, keep partial coverage explicit, and stop chaining on navigation/expiry.
        async function dashboardRead(path, filters, token, version) {
          const params = new URLSearchParams(filters), items = [], keys = new Set(), cursors = new Set();
          params.set("limit", "100");
          let first = null;
          for (let count = 0; count < 10; count += 1) {
            if (token !== requestEpoch || version !== dashboardVersion || activePage !== "dashboard") return null;
            const page = await api("GET", path + "?" + params.toString());
            if (token !== requestEpoch || version !== dashboardVersion || activePage !== "dashboard") return null;
            if (!page || !Array.isArray(page.items) || !page.totals || page.groupBy !== params.get("groupBy") || typeof page.snapshotId !== "string" || !page.snapshotId || typeof page.timeZone !== "string" || page.items.length > 100 || items.length + page.items.length > 1000) throw new Error("Invalid chart page");
            if (first && (page.snapshotId !== first.snapshotId || page.timeZone !== first.timeZone || JSON.stringify(page.totals) !== JSON.stringify(first.totals))) throw new Error("Changed chart snapshot");
            if (!first) first = page;
            page.items.forEach(function (item) { if (typeof item.key !== "string" || keys.has(item.key)) throw new Error("Duplicate chart group"); keys.add(item.key); items.push(item); });
            if (!page.nextCursor) return {page:first, items:items, complete:true};
            if (typeof page.nextCursor !== "string" || cursors.has(page.nextCursor)) throw new Error("Repeated chart cursor");
            cursors.add(page.nextCursor); params.set("snapshotId",first.snapshotId); params.set("cursor",page.nextCursor);
          }
          return {page:first, items:items, complete:false};
        }
        function dashboardKpis(result, end, cost) {
          const container = document.getElementById("dashboard-kpis");
          const fields = cost ? [["costUsd",t("Priced cost (USD)")]] : [["sessionCount",t("Sessions")],["messageCount",t("Messages")],["userMessageCount",t("User messages")],["assistantMessageCount",t("Assistant messages")]];
          fields.forEach(function (field) {
            const tile = document.createElement("div"); tile.className = "kpi";
            const label = document.createElement("span"), value = document.createElement("strong"), note = document.createElement("span");
            setText(label,field[1]); setText(value,chartAmount(chartNumber(result.page.totals[field[0]]),cost));
            setText(note,t("Full range · {0}{1}", [result.page.timeZone, result.complete ? "" : t(" · partial sparkline")]));
            tile.appendChild(label); tile.appendChild(value); tile.appendChild(note);
            const rows = result.complete ? dailySeries(result.items,field[0],end,30) : result.items.slice().sort(function (a,b) { return a.key.localeCompare(b.key); }).map(function (item) { return {label:item.key,value:chartNumber(item[field[0]])}; });
            const max = Math.max(1,...rows.map(function (row) { return row.value || 0; }));
            const image = svg("svg", {viewBox:"0 0 180 32", role:"img","aria-label":t("{0} daily trend, {1} full range · {2}", [field[1], chartAmount(chartNumber(result.page.totals[field[0]]),cost), result.complete ? t("30 dates") : t("loaded dates only")])});
            const tip = svg("title"); setText(tip,t("{0} · daily values in the accompanying table", [field[1]])); image.appendChild(tip);
            // Missing numeric metrics break the sparkline instead of fabricating zero observations.
            rows.forEach(function (row,i) { if (row.value !== null) image.appendChild(svg("rect", {x:i * 180 / rows.length, y:30 - (row.value || 0) / max * 28,width:Math.max(1,180 / rows.length - 1),height:(row.value || 0) / max * 28,fill:"currentColor"})); });
            tile.appendChild(image);
            const details = document.createElement("details"), summary = document.createElement("summary"), table = document.createElement("table");
            setText(summary,t("Daily values")); details.appendChild(summary); table.setAttribute("aria-label",t("{0} daily values", [field[1]]));
            const header = document.createElement("tr"); [t("Date"),cost ? "USD" : t("Value")].forEach(function (text) { const cell = document.createElement("th"); cell.setAttribute("scope","col"); setText(cell,text); header.appendChild(cell); }); table.appendChild(header);
            rows.forEach(function (row) { const tr = document.createElement("tr"); [row.label,chartAmount(row.value,cost)].forEach(function (text) { const cell = document.createElement("td"); setText(cell,text); tr.appendChild(cell); }); table.appendChild(tr); });
            details.appendChild(table); tile.appendChild(details); container.appendChild(tile);
          });
        }
        async function loadDashboard() {
          if (activePage !== "dashboard") return;
          clearDashboard();
          const token = requestEpoch, version = dashboardVersion;
          const today = new Date(), end = today.getFullYear() + "-" + String(today.getMonth() + 1).padStart(2,"0") + "-" + String(today.getDate()).padStart(2,"0");
          const since = dailySeries([],"value",end,30)[0].label;
          const health = document.getElementById("dashboard-health");
          setText(health, overviewStreams === null ? t("Stream observations unavailable. Visit Health to retry; no duplicate overview walk is started here.") : t("{0} streams · reused sign-in/Health snapshot · Observed: {1} · no historical health data", [overviewStreams.length, healthTime(overviewObservedAt)]));
          let activityResult = null, costResult = null;
          const widgets = [["activity","/web/api/stats","day","sessionCount",t("Daily sessions")],["sources","/web/api/stats","source","sessionCount",t("Sessions by source")],["projects","/web/api/stats","project","sessionCount",t("Sessions by project")],["cost","/web/api/costs","day","costUsd",t("Daily priced cost (USD)")]];
          await Promise.all(widgets.map(async function (widget) {
            const node = document.getElementById("dashboard-" + widget[0]); setText(node,t("Loading {0}…", [widget[4].toLowerCase()]));
            try {
              const result = await dashboardRead(widget[1],{groupBy:widget[2], since:since, until:end},token,version);
              if (!result || token !== requestEpoch || version !== dashboardVersion || activePage !== "dashboard") return;
              const currency = widget[3] === "costUsd", daily = widget[2] === "day";
              const rows = daily && result.complete ? dailySeries(result.items,widget[3],end,30) : result.items.map(function (item) { return {label:widget[2] === "source" ? sourceLabel(item.key) : item.label || item.key, value:item[widget[3]], source:widget[2] === "source" ? item.key : null}; });
              if (daily) rows.sort(function (a,b) {return a.label.localeCompare(b.label);});
              renderChart("dashboard-" + widget[0],widget[4],rows,{columns:daily,currency:currency,fullTotal:result.page.totals[widget[3]],coverage:(result.complete ? t("All groups") : t("Partial: 10-page cap; absent days unknown, not zero-filled")) + " · " + since + " → " + end + " · " + result.page.timeZone});
              if (widget[0] === "activity" || currency) {
                if (currency) costResult = result; else activityResult = result;
                setText(document.getElementById("dashboard-kpis"), "");
                if (activityResult) dashboardKpis(activityResult,end,false);
                if (costResult) dashboardKpis(costResult,end,true);
              }
              if (currency) {
                const note = document.createElement("p"); setText(note,t("Unpriced sessions: {0} without attribution; {1} without a matching price. Unpriced tokens: {2} unattributed; {3} without a matching price.", [costValue(result.page.unpricedUnattributedSessions,"count"), costValue(result.page.unpricedNoPriceSessions,"count"), costValue(result.page.unpricedUnattributedTokens,"count"), costValue(result.page.unpricedNoPriceTokens,"count")])); node.appendChild(note);
              }
            } catch (error) {
              if (token === requestEpoch && version === dashboardVersion && activePage === "dashboard") { node.className = "chart"; setText(node,t("{0} unavailable. Refresh dashboard to retry.", [widget[4]])); }
            }
          }));
        }
        function statsRoute(tab) {
          const filters = {};
          [["group","stats-group"],["sources","stats-source"],["projects","stats-project"],["since","stats-since"],["until","stats-until"],["agents","stats-agents"]].forEach(function (pair) {
            const value = document.getElementById(pair[1]).value;
            if (value && !(pair[0] === "group" && value === "source") && !(pair[0] === "agents" && value === "hide")) filters[pair[0]] = value;
          });
          if (document.getElementById("stats-noise").checked) filters.noise = "true";
          return {page:"stats",tab:tab || statsView,filters:filters};
        }
        function applyStatsRoute(filters) {
          const f = filters || {};
          [["group","stats-group","source"],["sources","stats-source",""],["projects","stats-project",""],["since","stats-since",""],["until","stats-until",""],["agents","stats-agents","hide"]].forEach(function (pair) {
            const node = document.getElementById(pair[1]), value = f[pair[0]] || pair[2];
            // Preserve opaque cold-route selections until authorized facet labels are loaded.
            if (["sources","projects"].includes(pair[0]) && value && !Array.from(node.children).some(function (option) { return option.value === value; })) {
              const option = document.createElement("option"); option.value = value; setText(option,value); node.appendChild(option);
            }
            node.value = value;
          });
          document.getElementById("stats-noise").checked = f.noise === "true";
        }
        async function loadStatsChoices() {
          const version = ++statsChoicesVersion, epoch = requestEpoch, status = document.getElementById("stats-choices-status");
          setText(status,t("Loading authorized choices…"));
          try {
            let complete = true;
            for (const kind of ["source","project"]) {
              const node = document.getElementById("stats-" + kind), params = new URLSearchParams({kind:kind,agents:"all",limit:"100"}), items = new Map(), cursors = new Set();
              let snapshot = "";
              for (let pageNumber = 0; pageNumber < 10; pageNumber += 1) {
                const page = await api("GET","/web/api/facets?" + params.toString());
                if (version !== statsChoicesVersion || epoch !== requestEpoch || activePage !== "stats") return;
                if (!page || !Array.isArray(page.items) || (snapshot && page.snapshotId !== snapshot)) throw new Error("Changed facets");
                snapshot = page.snapshotId;
                page.items.forEach(function (item) { items.set(item.key,item.label); });
                if (!page.nextCursor) break;
                if (cursors.has(page.nextCursor)) throw new Error("Repeated facet cursor");
                cursors.add(page.nextCursor); params.set("snapshotId",snapshot); params.set("cursor",page.nextCursor);
                if (pageNumber === 9) complete = false;
              }
              const selected = node.value;
              setText(node,"");
              const all = document.createElement("option"); all.value = ""; setText(all,kind === "source" ? t("All sources") : t("All projects")); node.appendChild(all);
              if (selected && !items.has(selected)) items.set(selected,selected);
              items.forEach(function (label,key) { const option = document.createElement("option"); option.value = key; setText(option,kind === "source" ? sourceLabel(key) : label); node.appendChild(option); });
              node.value = selected;
            }
            setText(status,complete ? t("Authorized choices loaded") : t("Partial choices: 1,000-group cap. Existing route selection retained."));
          } catch (error) { if (version === statsChoicesVersion && epoch === requestEpoch) setText(status,t("Choices unavailable. Retry loading choices.")); }
        }
        function choiceLabel(id, value) {
          if (!value) return "all";
          const option = Array.from(document.getElementById(id).children).find(function (item) { return item.value === value; });
          return option && option.textContent ? option.textContent : value;
        }
        function hourOfWeekLabel(key) {
          if (key === "u.date") return t("Unknown start date");
          const match = /^h[.]([0-6])[.](0[0-9]|1[0-9]|2[0-3])$/.exec(key);
          return match ? [t("Mon"),t("Tue"),t("Wed"),t("Thu"),t("Fri"),t("Sat"),t("Sun")][Number(match[1])] + " " + match[2] + ":00" : key;
        }
        function renderHourOfWeek(id, items, timeZone, complete, total, scope) {
          const node = document.getElementById(id); setText(node,""); node.className = "chart";
          const days = [t("Mon"),t("Tue"),t("Wed"),t("Thu"),t("Fri"),t("Sat"),t("Sun")], bins = new Map(), unknown = items.find(function (item) { return item.key === "u.date"; });
          items.forEach(function (item) { if (/^h[.][0-6][.](0[0-9]|1[0-9]|2[0-3])$/.test(item.key) && Number.isSafeInteger(item.sessionCount) && item.sessionCount >= 0) bins.set(item.key,item.sessionCount); });
          const full = complete && bins.size === 168, title = document.createElement("h3"), note = document.createElement("p");
          setText(title,t("Session starts by weekday / hour")); node.appendChild(title);
          setText(note,t("{0} · {1} · {2}{3} in scope · Unknown start dates: {4}. Counts starts, not work duration or message activity. {5}", [full ? t("Complete: 168 bins") : t("Partial: {0}/168 bins loaded; missing bins unknown", [bins.size]), timeZone, chartAmount(total,false), total === 1 ? t(" session") : t(" sessions"), unknown ? unknown.sessionCount : complete ? "0" : t("not yet known"), scope || t("All start dates · agents hidden · all sources/projects · includes lightweight sessions")])); node.appendChild(note);
          const image = svg("svg",{viewBox:"0 0 780 260",role:"img","aria-label":t("Session starts, Monday first, server timezone {0}{1}", [timeZone, full ? t(", complete") : t(", partial")])});
          const maximum = Math.max(1,...Array.from(bins.values()));
          for (let hour = 0; hour < 24; hour += 3) { const text = svg("text",{x:68+hour*29,y:18,fill:"var(--text)","font-size":13}); setText(text,String(hour).padStart(2,"0")); image.appendChild(text); }
          days.forEach(function (day,d) {
            const text = svg("text",{x:0,y:48+d*29,fill:"var(--text)","font-size":14}); setText(text,day); image.appendChild(text);
            for (let hour = 0; hour < 24; hour += 1) {
              const key = "h." + d + "." + String(hour).padStart(2,"0");
              if (!bins.has(key)) continue; // Unloaded is never fabricated as zero.
              const value = bins.get(key), rect = svg("rect",{x:64+hour*29,y:28+d*29,width:25,height:25,rx:3,fill:value ? "var(--accent)" : "var(--line)","fill-opacity":value ? 0.3+0.7*value/maximum : 1,"data-value":value,"data-key":key});
              const tip = svg("title"); setText(tip,t("{0} {1}:00 · {2} session starts", [day, String(hour).padStart(2,"0"), value])); rect.appendChild(tip); image.appendChild(rect);
            }
          }); node.appendChild(image);
          const legend = document.createElement("p"); setText(legend,t("Blank: not loaded · Neutral: zero starts · Accent intensity: fewer → more starts. Exact counts are available in the data table.")); node.appendChild(legend);
        }
        async function loadDashboardHours() {
          if (activePage !== "dashboard") return;
          const epoch = requestEpoch, version = dashboardVersion, hoursVersion = ++dashboardHoursVersion, node = document.getElementById("dashboard-hours");
          setText(node,t("Loading session starts…"));
          try {
            const result = await dashboardRead("/web/api/stats",{groupBy:"hourOfWeek"},epoch,version);
            if (hoursVersion !== dashboardHoursVersion) return;
            if (result && epoch === requestEpoch && version === dashboardVersion && activePage === "dashboard") {
              renderHourOfWeek("dashboard-hours",result.items,result.page.timeZone,result.complete,result.page.totals.sessionCount);
              const details = document.createElement("details"), summary = document.createElement("summary"), table = document.createElement("table");
              setText(summary,t("Loaded hourly values")); details.appendChild(summary);
              result.items.forEach(function (item) { const row = document.createElement("tr"); [hourOfWeekLabel(item.key),String(item.sessionCount)].forEach(function (value) { const cell = document.createElement("td"); setText(cell,value); row.appendChild(cell); }); table.appendChild(row); });
              details.appendChild(table); node.appendChild(details);
            }
          } catch (error) { if (hoursVersion === dashboardHoursVersion && epoch === requestEpoch && version === dashboardVersion && activePage === "dashboard") setText(node,t("Session-start heatmap unavailable. Older servers may not support hourOfWeek. Daily charts remain available.")); }
        }
        function clearStats() {
          chartRows.stats = []; setText(document.getElementById("stats-chart"), "");
          statsSnapshot = "";
          statsCursor = "";
          statsFilters = "";
          statsTotals = null; statsTimeZone = "";
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
            if (activePage === "stats") writeRoute(statsRoute());
            const source = document.getElementById("stats-source").value, project = document.getElementById("stats-project").value;
            if (source) params.set("sources",source);
            if (project) params.set("projectKeys",project);
            if (params.get("groupBy") === "hourOfWeek") params.set("limit","100");
            const since = document.getElementById("stats-since").value;
            const until = document.getElementById("stats-until").value;
            const agents = document.getElementById("stats-agents").value || "hide";
            if (since) params.set("since", since);
            if (until) params.set("until", until);
            if (agents !== "hide") params.set("agents", agents);
            if (document.getElementById("stats-noise").checked) params.set("excludeNoise", "true");
            statsFilters = params.toString();
          }
          setText(status, t("Loading…"));
          moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/stats?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || !page.totals || page.groupBy !== params.get("groupBy")
                || (more && (page.snapshotId !== statsSnapshot || page.nextCursor === statsCursor))
                || (more && page.timeZone !== statsTimeZone)
                || (statsTotals && statsFields.some(function (field) { return statsTotals[field[0]] !== page.totals[field[0]]; }))) throw new Error("changed statistics");
            statsTimeZone = page.timeZone;
            statsSnapshot = page.snapshotId;
            statsCursor = page.nextCursor || "";
            if (chartRows.stats.length + page.items.length > 5000) throw new Error("Chart row limit reached; narrow the filters");
            statsTotals = page.totals;
            updateChartRows("stats", page.items, t("Session counts"), "sessionCount", page.totals.sessionCount, statsCursor, page.groupBy);
            if (page.groupBy === "hourOfWeek") renderHourOfWeek("stats-chart",chartRows.stats,page.timeZone,!statsCursor,page.totals.sessionCount,
              t("Start dates: {0} → {1} · agents {2} · sources: {3} · projects: {4}{5}", [params.get("since") || t("unbounded"), params.get("until") || t("unbounded"), t(params.get("agents") || "hide"), choiceLabel("stats-source",params.get("sources")), choiceLabel("stats-project",params.get("projectKeys")), params.get("excludeNoise") === "true" ? t(" · excludes lightweight sessions") : t(" · includes lightweight sessions")]));
            const totals = document.getElementById("stats-totals");
            setText(totals, "");
            statsFields.forEach(function (field) {
              const group = document.createElement("div");
              const label = document.createElement("dt");
              const value = document.createElement("dd");
              setText(label, field[1]);
              setText(value, page.totals[field[0]].toLocaleString(uiLocale));
              group.appendChild(label);
              group.appendChild(value);
              totals.appendChild(group);
            });
            page.items.forEach(function (item) {
              const row = document.createElement("tr");
              const label = document.createElement("td");
              setText(label, page.groupBy === "source" ? sourceLabel(item.key) : page.groupBy === "hourOfWeek" ? hourOfWeekLabel(item.key) : item.label);
              row.appendChild(label);
              statsFields.forEach(function (field) {
                const value = document.createElement("td");
                setText(value, item[field[0]].toLocaleString(uiLocale));
                row.appendChild(value);
              });
              document.getElementById("stats-rows").appendChild(row);
            });
            setText(status, t("Grouped by {0} · {1} · Observed: {2}", [groupLabel(page.groupBy), page.timeZone, healthTime(page.observedAt)]));
            moreButton.hidden = !statsCursor || chartRows.stats.length >= 5000;
          } catch (error) {
            if (token === requestEpoch) setText(status, t("Statistics unavailable. This server may not support these options. For legacy settings choose Source/Project/Day/Week, All sources and All projects, then Apply. No filters were silently dropped."));
          } finally {
            if (token === requestEpoch) moreButton.disabled = false;
          }
        }
        async function showStatsView(view, routed) {
          if (!routed && activePage === "stats") { routeVersion += 1; writeRoute(statsRoute(view)); }
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
          chartRows.ai = []; setText(document.getElementById("ai-chart"), "");
          aiSnapshot = ""; aiCursor = ""; aiFilters = ""; aiTotal = null;
          ["ai-status", "ai-rows", "ai-detail", "ai-stats", "ai-stats-status"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("ai-more").hidden = true;
          document.getElementById("ai-detail").hidden = true;
        }
        function aiCounts(parent, pairs, large) {
          const counts = document.createElement("dl"); counts.className = large ? "stats-totals" : "ai-counts";
          pairs.forEach(function (pair) {
            const label = document.createElement("dt"), value = document.createElement("dd");
            setText(label, pair[0]); setText(value, typeof pair[1] === "number" ? costValue(pair[1], "value") : pair[1] == null ? t("Not reported") : pair[1]);
            const pairNode = large ? document.createElement("div") : counts;
            pairNode.appendChild(label); pairNode.appendChild(value); if (large) counts.appendChild(pairNode);
          }); parent.appendChild(counts);
        }
        function aiCard(item, detail) {
          const card = document.createElement("article"); card.className = "health-card";
          const title = document.createElement("h3"); setText(title, item.caller + " · " + item.operation); card.appendChild(title);
          const when = document.createElement("p"); when.className = "meta"; setText(when, healthTime(item.at) + " · " + (item.hasError ? t("Error") : t("Success")) + (item.statusCode == null ? "" : " · HTTP " + item.statusCode)); card.appendChild(when);
          const model = document.createElement("p"); setText(model, item.model || t("Model not reported")); card.appendChild(model);
          aiCounts(card, [[t("Duration (ms)"), item.durationMs], [t("Input tokens"), item.promptTokens], [t("Output tokens"), item.completionTokens], [t("Total tokens"), item.totalTokens]]);
          if (item.error) { const error = document.createElement("p"); setText(error, item.error); card.appendChild(error); }
          if (detail) {
            aiCounts(card, [[t("Call ID"), item.id], [t("Provider"), item.provider], [t("Method"), item.method], [t("Endpoint"), item.url], [t("Session ID"), item.sessionId]]);
          } else {
            const button = document.createElement("button"); button.type = "button"; setText(button, t("View call"));
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
          setText(status, t("Loading…")); button.disabled = true;
          try {
            const page = await api("GET", "/web/api/ai/audit?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || !Number.isSafeInteger(page.total)
                || (more && (page.snapshotId !== aiSnapshot || page.nextCursor === aiCursor))
                || (aiTotal !== null && page.total !== aiTotal)) throw new Error("changed AI observations");
            aiSnapshot = page.snapshotId; aiCursor = page.nextCursor || "";
            if (chartRows.ai.length + page.items.length > 5000) throw new Error("Chart row limit reached; narrow the filters"); aiTotal = page.total;
            chartRows.ai.push(...page.items);
            const errors = chartRows.ai.filter(function (item) { return item.hasError === true; }).length;
            const successes = chartRows.ai.filter(function (item) { return item.hasError === false; }).length;
            renderChart("ai-chart", t("Loaded call outcomes"), [{label:t("Success"),value:successes},{label:t("Error"),value:errors},{label:t("Outcome not reported"),value:chartRows.ai.length - errors - successes}], {fullTotal:page.total, coverage:t("{0} · call-history filters only", [aiCursor ? (chartRows.ai.length >= 5000 ? t("Partial history: 5,000-row cap; narrow filters") : t("Partial history")) : t("All matching calls")])});
            page.items.forEach(function (item) {
              const row = document.createElement("tr");
              [item.caller + " · " + item.operation, healthTime(item.at) + " · " + (item.hasError === true ? t("Error") : item.hasError === false ? t("Success") : t("Not reported")), item.model || t("Not reported"), costValue(item.totalTokens, "tokens")].forEach(function (text) { const cell = document.createElement("td"); setText(cell, text); row.appendChild(cell); });
              const cell = document.createElement("td"), open = document.createElement("button"); open.type = "button"; setText(open, t("View call")); open.addEventListener("click", function () { loadAiDetail(item.id); }); cell.appendChild(open); row.appendChild(cell);
              document.getElementById("ai-rows").appendChild(row);
            });
            setText(status, page.total ? t("{0} · Observed: {1}", [plural(page.total, "call"), healthTime(page.observedAt)]) : t("No recorded AI calls for these filters."));
            button.hidden = !aiCursor || chartRows.ai.length >= 5000;
          } catch (error) { if (token === requestEpoch) setText(status, t("AI call history unavailable. Find calls to retry.")); }
          finally { if (token === requestEpoch) button.disabled = false; }
        }
        async function loadAiDetail(id) {
          const token = requestEpoch, version = ++aiDetailVersion, detail = document.getElementById("ai-detail");
          detail.hidden = false; setText(detail, t("Loading call…"));
          try {
            const page = await api("GET", "/web/api/ai/audit/" + encodeURIComponent(id));
            if (token !== requestEpoch || version !== aiDetailVersion) return;
            if (!page || !page.item || page.item.id !== id) throw new Error("invalid call");
            setText(detail, ""); detail.appendChild(aiCard(page.item, true));
            aiCounts(detail, [[t("Request body"), page.hasRequestBody ? t("Stored") : t("Not stored")], [t("Response body"), page.hasResponseBody ? t("Stored") : t("Not stored")]]);
            const note = document.createElement("p"); note.className = "meta"; setText(note, t("Message bodies are not included in this view.")); detail.appendChild(note);
            if (typeof detail.scrollIntoView === "function") detail.scrollIntoView({ block: "start" });
          } catch (error) { if (token === requestEpoch && version === aiDetailVersion) setText(detail, t("Call unavailable or no longer visible.")); }
        }
        async function loadAiStats() {
          const token = requestEpoch, version = ++aiStatsVersion, status = document.getElementById("ai-stats-status"), content = document.getElementById("ai-stats");
          setText(content, ""); setText(status, t("Loading statistics…"));
          const params = new URLSearchParams();
          ["from", "to"].forEach(function (key) { const value = document.getElementById("ai-" + key).value; if (value) params.set(key, value); });
          try {
            const page = await api("GET", "/web/api/ai/stats?" + params.toString());
            if (token !== requestEpoch || version !== aiStatsVersion) return;
            if (!page || !page.totals || !page.timeRange || !Array.isArray(page.byCaller) || !Array.isArray(page.byModel) || !Array.isArray(page.hourly)) throw new Error("invalid AI statistics");
            const hourly = document.createElement("div"); hourly.id = "ai-hourly-chart"; content.appendChild(hourly);
            renderChart("ai-hourly-chart", t("Hourly AI requests (UTC)"), page.hourly.map(function (item) { return {label:item.hour, value:item.requests}; }).sort(function (a,b) {return a.label.localeCompare(b.label);}), {columns:true, fullTotal:page.totals.requests, coverage:t("Statistics date range only; independent of call-history filters")});
            aiCounts(content, [[t("Requests"), page.totals.requests], [t("Errors"), page.totals.errors], [t("Input tokens"), page.totals.promptTokens], [t("Output tokens"), page.totals.completionTokens], [t("Average duration (ms)"), page.totals.avgDurationMs]], true);
            [[t("By caller"), page.byCaller], [t("By model"), page.byModel], [t("Hourly (UTC)"), page.hourly]].forEach(function (group) {
              const section = document.createElement("details"); section.open = true;
              const heading = document.createElement("summary"); setText(heading, group[0]); section.appendChild(heading);
              const rows = document.createElement("div"); rows.className = "health-grid";
              group[1].forEach(function (item) {
                const card = document.createElement("article"); card.className = "health-card";
                const title = document.createElement("h3"); setText(title, item.hour ? item.hour + " UTC" : item.key); card.appendChild(title);
                const pairs = [[t("Requests"), item.requests]];
                if (item.hour) pairs.push([t("Tokens"), item.tokens]);
                else { if (item.errors != null) pairs.push([t("Errors"), item.errors]); pairs.push([t("Input tokens"), item.promptTokens], [t("Output tokens"), item.completionTokens]); }
                aiCounts(card, pairs); rows.appendChild(card);
              }); section.appendChild(rows); content.appendChild(section);
            });
            setText(status, t("{0} → {1} · Date range only", [page.timeRange.from, page.timeRange.to]));
          } catch (error) { if (token === requestEpoch && version === aiStatsVersion) setText(status, t("AI statistics unavailable. View statistics to retry.")); }
        }
        function clearRepos() {
          chartRows.repos = []; setText(document.getElementById("repos-chart"), "");
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
          setText(status, t("Loading…")); moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/repos?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || page.scope !== "serverFilesystem" || !Array.isArray(page.items) || !Number.isSafeInteger(page.totalRepos)
                || (more && (page.snapshotId !== reposSnapshot || page.nextCursor === reposCursor))
                || (reposTotal !== null && reposTotal !== page.totalRepos)) throw new Error("changed repository observations");
            reposSnapshot = page.snapshotId; reposCursor = page.nextCursor || "";
            if (chartRows.repos.length + page.items.length > 5000) throw new Error("Chart row limit reached; narrow the filters"); reposTotal = page.totalRepos;
            updateChartRows("repos", page.items.map(function (item) { return Object.assign({}, item, { label: item.name }); }), t("Sessions per observed repository"), "sessionCount", null, reposCursor, "repository");
            page.items.forEach(function (item) {
              const card = document.createElement("article"); card.className = "health-card";
              const title = document.createElement("h3"); setText(title, item.name); card.appendChild(title);
              const branch = document.createElement("p"); branch.className = "meta"; setText(branch, item.branch || t("Branch not reported")); card.appendChild(branch);
              const counts = document.createElement("dl");
              [[t("Dirty"), item.dirtyCount], [t("Untracked"), item.untrackedCount], [t("Unpushed"), item.unpushedCount], [t("Sessions"), item.sessionCount]].forEach(function (pair) {
                const label = document.createElement("dt"), value = document.createElement("dd"); setText(label, pair[0]); setText(value, costValue(pair[1], "count")); counts.appendChild(label); counts.appendChild(value);
              }); card.appendChild(counts);
              const commit = document.createElement("p"); setText(commit, item.lastCommitMessage || t("Commit not reported")); card.appendChild(commit);
              const last = document.createElement("p"); last.className = "meta";
              setText(last, (item.lastCommitHash ? item.lastCommitHash.slice(0, 12) + " · " : "") + healthTime(item.lastCommitAt)); card.appendChild(last);
              const observed = document.createElement("p"); observed.className = "meta"; setText(observed, t("Probed: {0}", [healthTime(item.probedAt)])); card.appendChild(observed);
              document.getElementById("repos-rows").appendChild(card);
            });
            setText(status, t("{0} · Observations from this server’s filesystem.", [plural(page.totalRepos, "repository", "repositories")]));
            moreButton.hidden = !reposCursor || chartRows.repos.length >= 5000;
          } catch (error) {
            if (token === requestEpoch) setText(status, t("Repository observations unavailable. Reload observations to retry."));
          } finally { if (token === requestEpoch) moreButton.disabled = false; }
        }
        function clearUsage() {
          setText(document.getElementById("usage-chart"), "");
          setText(document.getElementById("usage-rows"), "");
          setText(document.getElementById("usage-status"), "");
        }
        function recordedTime(value) {
          return healthTime(typeof value === "string" ? Math.floor(Date.parse(value) / 1000) : value);
        }
        async function loadUsage() {
          const token = bumpEpoch(); clearUsage();
          const status = document.getElementById("usage-status"), refresh = document.getElementById("usage-refresh");
          setText(status, t("Loading…")); refresh.disabled = true;
          try {
            const page = await api("GET", "/web/api/usage");
            if (token !== requestEpoch) return;
            if (!page || page.scope !== "server" || !Array.isArray(page.items)) throw new Error("invalid usage");
            renderUsageChart(page.items);
            page.items.forEach(function (item) {
              const row = document.createElement("tr");
              const unit = item.unit ? " " + item.unit : "";
              const amount = costValue(item.value, "value") + unit + (item.limit == null ? "" : " / " + costValue(item.limit, "value") + unit);
              [sourceLabel(item.source), item.metric, amount, item.basis === "indexedSessions" ? t("Indexed sessions") : t("Reported"),
               item.status || t("Not reported"), recordedTime(item.resetAt), recordedTime(item.collectedAt)].forEach(function (value, index) {
                const cell = document.createElement("td"); cell.setAttribute("data-label", [t("Source"), t("Metric"), t("Value / limit"), t("Basis"), t("Status"), t("Resets"), t("Collected")][index]); setText(cell, value); row.appendChild(cell);
              });
              document.getElementById("usage-rows").appendChild(row);
            });
            setText(status, page.items.length ? t("Recorded by this server. Indexed-session metrics are estimates from recorded sessions.") : t("No recorded usage on this server."));
          } catch (error) {
            if (token === requestEpoch) setText(status, t("Usage unavailable. Reload observations to retry."));
          } finally { if (token === requestEpoch) refresh.disabled = false; }
        }
        function clearFiles() {
          chartRows.files = []; setText(document.getElementById("files-chart"), "");
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
          setText(status, t("Loading…")); moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/file-activity?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || !Number.isSafeInteger(page.totalFiles) || !Number.isSafeInteger(page.totalOperations)
                || (more && (page.snapshotId !== filesSnapshot || page.nextCursor === filesCursor))
                || (filesTotals && (filesTotals.files !== page.totalFiles || filesTotals.operations !== page.totalOperations))) throw new Error("changed file activity");
            filesSnapshot = page.snapshotId; filesCursor = page.nextCursor || "";
            if (chartRows.files.length + page.items.length > 5000) throw new Error("Chart row limit reached; narrow the filters");
            filesTotals = {files: page.totalFiles, operations: page.totalOperations};
            updateChartRows("files", page.items.map(function (item) { return Object.assign({}, item, { operations: item.readCount + item.editCount + item.writeCount }); }), t("File operations (reads + edits + writes)"), "operations", page.totalOperations, filesCursor, "file");
            setText(document.getElementById("files-totals"), plural(page.totalFiles, "file") + " · " + plural(page.totalOperations, "operation"));
            page.items.forEach(function (item) {
              const row = document.createElement("tr"), label = document.createElement("td"); setText(label, item.label); row.appendChild(label);
              ["readCount", "editCount", "writeCount", "sessionCount"].forEach(function (field, index) {
                const cell = document.createElement("td"); cell.setAttribute("data-label", [t("Reads"), t("Edits"), t("Writes"), t("Sessions")][index]); setText(cell, costValue(item[field], field)); row.appendChild(cell);
              });
              document.getElementById("files-rows").appendChild(row);
            });
            setText(status, page.totalFiles ? t("Most active files · Observed: {0}", [healthTime(page.observedAt)]) : t("No file activity in this range"));
            moreButton.hidden = !filesCursor || chartRows.files.length >= 5000;
          } catch (error) {
            if (token === requestEpoch) setText(status, t("File activity unavailable. Apply filters to retry."));
          } finally { if (token === requestEpoch) moreButton.disabled = false; }
        }
        function clearTools() {
          chartRows.tools = []; setText(document.getElementById("tools-chart"), "");
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
          setText(status, t("Loading…")); moreButton.disabled = true;
          try {
            const page = await api("GET", "/web/api/tool-analytics?" + params.toString());
            if (token !== requestEpoch) return;
            if (!page || !Array.isArray(page.items) || page.groupBy !== params.get("groupBy")
                || !Number.isSafeInteger(page.totalCalls) || !Number.isSafeInteger(page.groupCount)
                || (more && (page.snapshotId !== toolsSnapshot || page.nextCursor === toolsCursor))
                || (toolsTotals && (toolsTotals.calls !== page.totalCalls || toolsTotals.groups !== page.groupCount))) throw new Error("changed tool activity");
            toolsSnapshot = page.snapshotId; toolsCursor = page.nextCursor || "";
            if (chartRows.tools.length + page.items.length > 5000) throw new Error("Chart row limit reached; narrow the filters");
            toolsTotals = {calls: page.totalCalls, groups: page.groupCount};
            updateChartRows("tools", page.items, t("Tool calls"), "callCount", page.totalCalls, toolsCursor, page.groupBy);
            // Grouped by tool, every row is exactly one tool, so the column carries no information.
            document.getElementById("tools-col-tools").hidden = page.groupBy === "tool";
            setText(document.getElementById("tools-totals"), plural(page.totalCalls, "call") + " · " + plural(page.groupCount, "group"));
            page.items.forEach(function (item) {
              const row = document.createElement("tr"), label = document.createElement("td");
              if (page.groupBy === "session" && item.sessionId) {
                const button = document.createElement("button"); button.type = "button"; setText(button, item.label);
                button.addEventListener("click", function () { openDetail(item.sessionId, "stats").catch(function () {}); });
                label.appendChild(button);
              } else setText(label, item.label);
              row.appendChild(label);
              (page.groupBy === "tool" ? ["callCount", "sessionCount"] : ["callCount", "sessionCount", "toolCount"]).forEach(function (field) {
                const cell = document.createElement("td"); setText(cell, costValue(item[field], field)); row.appendChild(cell);
              });
              document.getElementById("tools-rows").appendChild(row);
            });
            setText(status, page.groupCount ? t("Grouped by {0} · Observed: {1}", [groupLabel(page.groupBy), healthTime(page.observedAt)]) : t("No tool activity in this range"));
            moreButton.hidden = !toolsCursor || chartRows.tools.length >= 5000;
          } catch (error) {
            if (token === requestEpoch) setText(status, t("Tool activity unavailable. Apply filters to retry."));
          } finally { if (token === requestEpoch) moreButton.disabled = false; }
        }
        function clearCosts() {
          chartRows.costs = []; setText(document.getElementById("costs-chart"), "");
          costsSnapshot = "";
          costsCursor = "";
          costsFilters = "";
          costsTotals = null;
          ["costs-totals", "costs-rows", "costs-sessions", "costs-status", "costs-sessions-status", "costs-unpriced"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("costs-more").hidden = true;
        }
        function costValue(value, field) {
          return typeof value === "number" && Number.isFinite(value)
            ? field === "costUsd" ? "$" + value.toLocaleString(uiLocale, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : value.toLocaleString(uiLocale)
            : t("Not reported");
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
          setText(status, t("Loading…"));
          moreButton.disabled = true;
          const groups = (async function () {
            try {
              const page = await api("GET", "/web/api/costs?" + params.toString());
              if (token !== requestEpoch) return;
              if (!page || !Array.isArray(page.items) || !page.totals || page.groupBy !== params.get("groupBy")
                  || (more && (page.snapshotId !== costsSnapshot || page.nextCursor === costsCursor))
                  || (costsTotals && costFields.some(function (field) { return costsTotals[field[0]] !== page.totals[field[0]]; }))) throw new Error("changed costs");
              costsSnapshot = page.snapshotId;
              costsCursor = page.nextCursor || "";
              if (chartRows.costs.length + page.items.length > 5000) throw new Error("Chart row limit reached; narrow the filters");
              costsTotals = page.totals;
              updateChartRows("costs", page.items, t("Priced cost (USD)"), "costUsd", page.totals.costUsd, costsCursor, page.groupBy);
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
              if (Number.isSafeInteger(page.unpricedUnattributedSessions)) unpriced.push(t("{0} no model attribution", [plural(page.unpricedUnattributedSessions, t("session has"), t("sessions have"))]));
              if (Number.isSafeInteger(page.unpricedNoPriceSessions)) unpriced.push(t("{0} no matching price", [plural(page.unpricedNoPriceSessions, t("session has"), t("sessions have"))]));
              if (Number.isSafeInteger(page.unpricedUnattributedTokens)) unpriced.push(t("{0} unattributed tokens", [costValue(page.unpricedUnattributedTokens, "tokens")]));
              if (Number.isSafeInteger(page.unpricedNoPriceTokens)) unpriced.push(t("{0} tokens without a price", [costValue(page.unpricedNoPriceTokens, "tokens")]));
              setText(document.getElementById("costs-unpriced"), unpriced.length ? t("Unpriced usage: {0}.", [unpriced.join("; ")]) : t("Unpriced usage: not reported."));
              setText(status, t("Grouped by {0} · {1}{2}", [groupLabel(page.groupBy), page.timeZone, page.totals.sessionCount === 0 ? t(" · No cost records in this range") : ""]));
              moreButton.hidden = !costsCursor || chartRows.costs.length >= 5000;
            } catch (error) {
              if (token === requestEpoch) setText(status, t("Costs unavailable. Apply filters to retry."));
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
          setText(status, t("Loading…"));
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
              setText(model, item.model || t("Not reported")); row.appendChild(model);
              costFields.filter(function (field) { return field[0] !== "sessionCount"; }).forEach(function (field) {
                const value = document.createElement("td");
                setText(value, costValue(item[field[0]], field[0])); row.appendChild(value);
              });
              document.getElementById("costs-sessions").appendChild(row);
            });
            setText(status, page.items.length ? t("Showing {0} highest-cost sessions", [page.items.length]) : t("No cost records in this range"));
          } catch (error) {
            if (token === requestEpoch) setText(status, t("Session costs unavailable. Apply filters to retry."));
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
          // Only paged session rows are hidden; skeleton, empty and error states have no page.
          if (sessionPageSizes.length) Array.from(sessionsNode.children).forEach(function (row, index) { row.hidden = index < start || index >= start + size; });
          const range = size ? (start + 1) + "–" + (start + size) : "";
          const total = sessionTotal !== null ? sessionTotal.toLocaleString(uiLocale) : null;
          setText(document.getElementById("session-page-status"), range ? (total !== null ? t("{0} of {1}", [range,total]) : range) + (sessionTotal === 1 || (sessionTotal === null && size === 1) ? t(" session") : t(" sessions")) : total === "0" ? t("0 sessions") : "");
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
          return sourceLabels[value] || value || t("Unknown source");
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
          closeCommandPalette(); commandSessions = [];
          rankedCursor = ""; rankedSnapshot = ""; rankedFilters = ""; rankedBusy = false;
          document.getElementById("search-more").hidden = true;
          sessionsNode.setAttribute("aria-busy", "false");
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
          closeCommandPalette();
          sessionActionAccessRequest = null;
          sessionActionCanWrite = false;
          document.getElementById("session-actions").hidden = true;
          document.getElementById("session-actions").open = false;
          setText(document.getElementById("session-action-status"), "");
          renderSessionSummary("");
          updateSessionActionControls();
          detailExtrasVersion += 1;
          detailContextSession = "";
          detailContextGeneration = "";
          detailInfoDetail = null; detailInfoLoaded = false; detailInfoBusy = false; detailInfoEpoch = -1; detailMessageCoverage = null;
          setText(document.getElementById("detail-info-content"), "");
          document.getElementById("detail-info-panel").hidden = true;
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
          const token = requestEpoch, version = detailExtrasVersion, id = detailContextSession, generation = detailContextGeneration;
          const key = JSON.stringify([token, version, id, generation]);
          // Palette review and the native disclosure toggle share one in-flight check.
          if (sessionActionAccessRequest && sessionActionAccessRequest.key === key) return sessionActionAccessRequest.promise;
          const pending = {key:key, promise:null}; sessionActionAccessRequest = pending;
          function current() {
            return sessionActionAccessRequest === pending && token === requestEpoch && version === detailExtrasVersion
              && id === detailContextSession && generation === detailContextGeneration;
          }
          const status = document.getElementById("session-action-status");
          sessionActionCanWrite = false;
          updateSessionActionControls();
          setText(status, t("Checking edit access…"));
          pending.promise = (async function () {
            try {
              const access = await api("GET", "/web/api/auth");
              if (!current()) return;
              sessionActionCanWrite = !!(access && access.canWrite === true);
              setText(status, sessionActionCanWrite ? t("Uses the configured AI provider and saves the result to this session.") : t("Read only. Sign in with an editor key to generate content."));
            } catch (error) {
              if (!current()) return;
              sessionActionCanWrite = false;
              setText(status, t("Edit access unavailable. Reopen this section to retry."));
            } finally {
              if (current()) updateSessionActionControls();
              // An obsolete response must not clear a replacement check or restore its authority.
              if (sessionActionAccessRequest === pending) sessionActionAccessRequest = null;
            }
          })();
          return pending.promise;
        }
        async function generateSessionText(action) {
          if (!sessionActionCanWrite || sessionActionPending || !detailContextSession || !detailContextGeneration || !["summary", "title"].includes(action)) return;
          const version = detailExtrasVersion, id = detailContextSession, generation = detailContextGeneration;
          const status = document.getElementById("session-action-status");
          sessionActionPending = true;
          updateSessionActionControls();
          setText(status, t("Generating {0}…", [t(action)]));
          try {
            const result = await api("POST", "/web/api/sessions/" + encodeURIComponent(id) + "/" + action, JSON.stringify({generation: generation}));
            if (version !== detailExtrasVersion) return;
            if (!result || result.sessionId !== id || result.generation !== generation || typeof result[action] !== "string" || !result[action].trim()) throw new Error("changed generation");
            if (action === "summary") renderSessionSummary(result.summary);
            else {
              const title = detailNode.querySelector("h2");
              if (title) { setText(title, result.displayTitle || result.title); title.title = result.displayTitle || result.title; }
            }
            setText(status, action === "summary" ? t("Summary saved.") : t("Title saved."));
          } catch (error) {
            if (version !== detailExtrasVersion) return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              sessionActionCanWrite = false;
              setText(status, t("Editor access required. Sign in again to generate content."));
            } else if (error.status === 503) {
              setText(status, t("Generation unavailable. Check the server's AI provider settings and try again."));
            } else setText(status, t("Could not confirm generation. Reopen the session before retrying."));
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
          setText(status, t("Starting generation…"));
          try {
            const result = await api("POST", "/web/api/titles/regenerate", JSON.stringify({}));
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            if (!result || !["started", "running"].includes(result.status)) throw new Error("invalid generation status");
            const count = Number.isSafeInteger(result.total) && result.total >= 0 ? " (" + plural(result.total, "session") + ")" : "";
            setText(status, t("{0}{1}. Reload Sessions to see updated titles.", [result.status === "started" ? t("Generation started") : t("Generation is already running"), count]));
          } catch (error) {
            if (version !== settingsAccessVersion || activePage !== "settings") return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) settingsCanWrite = false;
            setText(status, error.status === 503 ? t("Generation unavailable. Check the server's AI provider settings.") : t("Could not confirm generation. Reload Sessions before retrying."));
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
          if (view !== "transcript") closeTranscriptFind();
          if (!detailContextSession || !["transcript", "timeline", "children", "info"].includes(view)) return;
          if (view === "timeline" && !detailContextGeneration) return;
          ["transcript", "timeline", "children", "info"].forEach(function (name) {
            document.getElementById("detail-view-" + name).setAttribute("aria-pressed", String(name === view));
            document.getElementById((name === "children" ? "detail-children" : name === "info" ? "detail-info" : name) + "-panel").hidden = name !== view;
          });
          if (view === "info") {
            if (!detailInfoLoaded) await loadDetailInfo(); else updateDetailInfoCoverage();
          }
          if (view === "children" && !detailChildren.loaded) await loadDetailChildren(false);
          if (view === "timeline" && !detailTimeline.loaded) await loadDetailTimeline(false);
        }
        async function loadDetailChildren(more) {
          const state = detailChildren;
          // A history route cancels reads, not panel data. Only a current read blocks a replacement.
          if (!detailContextSession || (state.busy && state.busyEpoch === requestEpoch) || (more && !state.cursor)) return;
          const sessionId = detailContextSession, version = detailExtrasVersion, token = requestEpoch;
          const rows = document.getElementById("detail-children-rows"), status = document.getElementById("detail-children-status");
          const params = new URLSearchParams({ limit: "20" });
          if (more) { params.set("snapshotId", state.snapshot); params.set("cursor", state.cursor); }
          state.busy = true; state.busyEpoch = token;
          setText(status, t("Loading child sessions…"));
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
            setText(status, rows.children.length ? t("{0} child sessions loaded", [rows.children.length]) : t("No child sessions"));
          } catch (error) {
            if (version === detailExtrasVersion && token === requestEpoch) setText(status, t("Child sessions unavailable. Refresh to retry."));
          } finally {
            if (version === detailExtrasVersion && state.busyEpoch === token) {
              state.busy = false;
              if (token === requestEpoch) document.getElementById("detail-children-more").hidden = !state.cursor;
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
            appendMetaPart(meta, textSpan(item.relationship === "confirmed" ? t("Confirmed") : t("Suggested")));
            button.appendChild(meta);
            button.addEventListener("click", function () { openDetail(item.session.sessionId).catch(function () {}); });
            row.appendChild(button);
            if (detailRelationship.canWrite) {
              const actions = document.createElement("div"); actions.className = "agent-filters";
              const choices = item.relationship === "confirmed" ? [["unlink", t("Unlink")]] : [["confirmSuggestion", t("Confirm")], ["dismissSuggestion", t("Dismiss")]];
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
          setText(status, t("Checking edit access…"));
          try {
            const access = await api("GET", "/web/api/auth");
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            state.canWrite = access && access.canWrite === true;
            setText(status, state.canWrite ? t("Editor access. Changes apply to this parent session.") : t("Read only. Sign in with an editor key to make changes."));
            renderDetailChildren();
          } catch (error) {
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            state.canWrite = false;
            setText(status, t("Edit access unavailable. Retry to check access."));
          } finally {
            if (version === detailExtrasVersion && token === requestEpoch) { state.checking = false; updateRelationshipControls(); }
          }
        }
        async function attachDetailChild() {
          const childId = document.getElementById("relationship-child-id").value.trim();
          if (!childId) { setText(document.getElementById("relationship-status"), t("Enter a child session ID.")); return; }
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
          if (!operation || !childId || childId === parentId) { setText(document.getElementById("relationship-status"), t("Choose a different child session.")); return; }
          if (action !== "link" && !detailChildren.items.some(function (item) {
            return item.session.sessionId === childId && item.relationship === (action === "unlink" ? "confirmed" : "suggested");
          })) return;
          const version = detailExtrasVersion, token = requestEpoch, status = document.getElementById("relationship-status");
          relationshipWritePending = true; updateRelationshipControls(); setText(status, t("Saving relationship…"));
          try {
            const result = await api(operation[0], "/web/api/sessions/" + encodeURIComponent(childId) + "/" + operation[1], JSON.stringify(operation[2]));
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            if (!result || result.sessionId !== childId || result.action !== action || result.ok !== true) throw new Error("Invalid relationship response");
            await loadDetailChildren(false);
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            const labels = { link: t("Child session linked."), unlink: t("Child session unlinked."), confirmSuggestion: t("Suggestion confirmed."), dismissSuggestion: t("Suggestion dismissed.") };
            setText(status, labels[action]); setStatus(t("signed in"));
            if (action === "link") document.getElementById("relationship-child-id").value = "";
          } catch (error) {
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            if (error.status === 401) { expireSession(); return; }
            if (error.status === 403) {
              detailRelationship.canWrite = false; renderDetailChildren();
              setText(status, t("Editor access required. Sign in again to edit."));
            } else if (error.status === 409) {
              await loadDetailChildren(false);
              if (version === detailExtrasVersion && token === requestEpoch) setText(status, t("Relationship changed. Review the refreshed child sessions before retrying."));
            } else setText(status, t("Could not confirm the change. Refresh child sessions before retrying."));
          } finally {
            relationshipWritePending = false;
            updateRelationshipControls();
          }
        }
        async function loadDetailTimeline(more) {
          const state = detailTimeline;
          if (!detailContextSession || !detailContextGeneration || (state.busy && state.busyEpoch === requestEpoch) || (more && state.next == null)) return;
          const sessionId = detailContextSession, generation = detailContextGeneration, version = detailExtrasVersion, token = requestEpoch;
          const rows = document.getElementById("timeline-rows"), status = document.getElementById("timeline-status");
          const offset = more ? state.next : 0;
          const params = new URLSearchParams({ generation: generation, offset: String(offset), limit: "500" });
          state.busy = true; state.busyEpoch = token; setText(status, t("Loading timeline…"));
          document.getElementById("transcript-minimap-more").disabled = true;
          if (minimapOpen) setText(document.getElementById("transcript-minimap-status"), t("Loading map timeline… Loaded coverage is unchanged."));
          try {
            const page = await api("GET", "/web/api/sessions/" + encodeURIComponent(sessionId) + "/timeline?" + params);
            if (version !== detailExtrasVersion || token !== requestEpoch) return;
            let previous = more ? state.lastIndex : -1;
            if (page.sessionId !== sessionId || page.generation !== generation || !Number.isSafeInteger(page.totalEntries) || page.totalEntries < 0 ||
                !Array.isArray(page.entries) || page.entries.length > 500 || (more && page.totalEntries !== state.total) ||
                page.entries.some(function (entry) {
                  const invalid = !Number.isSafeInteger(entry.index) || entry.index < offset || entry.index <= previous || entry.index >= page.totalEntries ||
                    !["message", "tool_use", "tool_result"].includes(entry.type) || typeof entry.preview !== "string";
                  previous = entry.index; return invalid;
                }) || (page.nextOffset != null && (!Number.isSafeInteger(page.nextOffset) || page.nextOffset <= offset || page.nextOffset <= previous || page.nextOffset >= page.totalEntries || !page.entries.length))) throw new Error("Invalid timeline page");
            if (!more) { setText(rows, ""); state.count = 0; outlineEntries = []; }
            outlineEntries = outlineEntries.concat(page.entries);
            const durationMax = Math.max(1, ...page.entries.map(function (entry) { return Number.isFinite(entry.durationToNextMs) ? entry.durationToNextMs : 0; }));
            page.entries.forEach(function (entry) {
              const card = document.createElement("article"); card.className = "message";
              const meta = document.createElement("p"); meta.className = "meta";
              ["#" + entry.index, entry.role, entry.type].forEach(function (part) { appendMetaPart(meta, textSpan(part)); });
              if (entry.timestamp) {
                const time = document.createElement("time"); time.dateTime = entry.timestamp; time.title = entry.timestamp;
                setText(time, recordedTime(entry.timestamp) + " · " + healthAgo(Math.floor(Date.parse(entry.timestamp) / 1000))); appendMetaPart(meta, time);
              }
              if (entry.toolName) appendMetaPart(meta, textSpan(entry.toolName));
              if (entry.tokens) appendMetaPart(meta, textSpan(t("Tokens: {0} in / {1} out", [entry.tokens.input, entry.tokens.output])));
              if (Number.isFinite(entry.durationToNextMs)) appendMetaPart(meta, textSpan(t("{0} s to next", [(entry.durationToNextMs / 1000).toLocaleString(uiLocale)])));
              card.appendChild(meta);
              if (Number.isFinite(entry.durationToNextMs) && entry.durationToNextMs >= 0) {
                const bar = svg("svg", {viewBox:"0 0 300 8", width:300, height:8, role:"img", "aria-label":t("{0} s to next · scaled to longest duration in this page ({1} s)", [entry.durationToNextMs / 1000, durationMax / 1000]), class:"timeline-duration"});
                bar.appendChild(svg("rect", {x:0,y:0,width:300,height:8,fill:"var(--line)"}));
                bar.appendChild(svg("rect", {x:0,y:0,width:300 * entry.durationToNextMs / durationMax,height:8,fill:"var(--accent)", "data-value":entry.durationToNextMs})); card.appendChild(bar);
              }
              const preview = document.createElement("p"); preview.className = "timeline-preview";
              const plain = entry.preview.replace(/[*_`#]/g, "").trim(); setText(preview, clipPreview(plain) + (plain.length >= 100 ? "…" : "")); card.appendChild(preview);
              const jump = document.createElement("a"); jump.setAttribute("href", "#/s/" + encodeURIComponent(sessionId) + "/m/" + entry.index); setText(jump, t("Jump to message #{0}", [entry.index]));
              jump.addEventListener("click", function (event) { event.preventDefault(); showDetailView("transcript"); jumpToOrdinal(entry.index); }); card.appendChild(jump); rows.appendChild(card);
            });
            state.count += page.entries.length; state.lastIndex = previous; state.total = page.totalEntries;
            state.next = page.nextOffset == null ? null : page.nextOffset; state.loaded = true;
            renderTranscriptOutline(); renderTranscriptMinimap();
            setText(status, t("{0} / {1} messages", [state.count, state.total]));
            document.getElementById("transcript-outline-more").hidden = state.next == null;
            setText(document.getElementById("transcript-outline-status"), t("{0} / {1} timeline entries. Unloaded prompts load at most 5 pages per jump; click again to continue.", [state.count, state.total]));
          } catch (error) {
            if (version === detailExtrasVersion && token === requestEpoch) {
              setText(status, t("Timeline unavailable. Refresh the session if its transcript changed."));
              if (minimapOpen) setText(document.getElementById("transcript-minimap-status"), t("Map timeline unavailable. Loaded messages are unchanged. Retry Load map timeline, or refresh the session if its transcript changed."));
            }
          } finally {
            if (version === detailExtrasVersion && state.busyEpoch === token) {
              state.busy = false;
              if (token === requestEpoch) {
                document.getElementById("timeline-more").hidden = state.next == null;
                document.getElementById("transcript-minimap-more").disabled = false;
              }
            }
          }
        }
        // Find indexes decoded payload fields, not rendered DOM text. Original rich/code/raw/copy nodes stay untouched.
        let findOpened = [];
        function closeTranscriptFind(restoreFocus) {
          findVersion += 1; findMatches = []; findIndex = -1;
          document.getElementById("transcript-find").hidden = true;
          document.getElementById("transcript-find-toggle").setAttribute("aria-expanded", "false");
          if (restoreFocus === true) focusVisible(document.getElementById("transcript-find-toggle"));
          document.getElementById("transcript-find-query").value = "";
          transcriptMessages.forEach(function (item) { item.article.classList.remove("find-target"); });
          findOpened.forEach(function (node) { node.open = false; }); findOpened = [];
          setText(document.getElementById("transcript-find-status"), "");
          setText(document.getElementById("transcript-find-preview"), "");
        }
        function openTranscriptFind(value) {
          document.getElementById("transcript-find").hidden = false;
          document.getElementById("transcript-find-toggle").setAttribute("aria-expanded", "true");
          const input = document.getElementById("transcript-find-query");
          if (value != null) input.value = value;
          if (typeof input.focus === "function") input.focus();
          updateTranscriptFind();
        }
        function updateTranscriptFind() {
          const query = document.getElementById("transcript-find-query").value.toLocaleLowerCase();
          const previous = findMatches[findIndex]; findMatches = [];
          if (query) transcriptMessages.forEach(function (item) {
            const fields = [item.content];
            (item.payload.toolCalls || []).forEach(function (call) { fields.push(call.name || "", toolJSON(call.input), toolJSON(call.output)); });
            fields.forEach(function (value, field) {
              const text = String(value).toLocaleLowerCase(); let from = 0, at;
              while ((at = text.indexOf(query, from)) >= 0 && findMatches.length < 10000) { findMatches.push({item:item,field:field,offset:at,text:String(value)}); from = at + query.length; }
            });
          });
          findIndex = previous ? findMatches.findIndex(function (match) { return match.item === previous.item && match.field === previous.field && match.offset === previous.offset; }) : -1;
          renderFindStatus();
        }
        function findMatchHidden(match) {
          if (match.item.article.hidden) return true;
          if (match.field === 0) return !!(match.item.body && match.item.body.hidden);
          const tool = match.item.tools[Math.floor((match.field - 1) / 3)];
          return !!(tool && tool.hidden);
        }
        function renderFindStatus() {
          const preview = document.getElementById("transcript-find-preview"); setText(preview, "");
          const current = findMatches[findIndex];
          if (current) {
            const length = document.getElementById("transcript-find-query").value.length;
            preview.appendChild(textSpan("#" + current.item.ordinal + " · " + current.text.slice(Math.max(0,current.offset - 70),current.offset)));
            const mark = document.createElement("mark"); setText(mark,current.text.slice(current.offset,current.offset + length)); preview.appendChild(mark);
            preview.appendChild(textSpan(current.text.slice(current.offset + length,current.offset + length + 100)));
          }
          const hidden = findMatches.filter(findMatchHidden).length;
          setText(document.getElementById("transcript-find-status"), t("{0} of {1}{2} matches in {3} loaded messages{4}{5}", [findIndex < 0 ? "0" : findIndex + 1, findMatches.length, findMatches.length >= 10000 ? t("+ (match cap)") : "", transcriptMessages.length, hidden ? t(" · {0} hidden by type filter", [hidden]) : "", messageCursor ? t(" · more not searched") : t(" · end of available transcript")]));
          document.getElementById("transcript-find-more").hidden = !messageCursor;
        }
        function moveFind(direction) {
          if (!findMatches.length) { renderFindStatus(); return; }
          findIndex = findIndex < 0 ? (direction < 0 ? findMatches.length - 1 : 0) : (findIndex + direction + findMatches.length) % findMatches.length;
          const match = findMatches[findIndex];
          transcriptMessages.forEach(function (item) { item.article.classList.toggle("find-target", item === match.item); });
          if (!findMatchHidden(match)) {
            match.item.article.querySelectorAll("details").forEach(function (node) { if (!node.open) { findOpened.push(node); node.open = true; } });
            if (typeof match.item.article.scrollIntoView === "function") match.item.article.scrollIntoView({block:"center",behavior:"instant"});
          }
          renderFindStatus();
        }
        async function searchFurther(more) {
          const token = requestEpoch, version = ++findVersion, budget = {remaining:5};
          updateTranscriptFind();
          const count = more ? findMatches.length : 0;
          while (findMatches.length <= count && messageCursor && budget.remaining > 0 && token === requestEpoch && version === findVersion) {
            if (messageRequest) break;
            const cursor = messageCursor;
            await loadMessages(token, messageSessionId, messageGeneration, cursor, budget);
            if (cursor === messageCursor) break;
          }
          if (token !== requestEpoch || version !== findVersion) return;
          if (findMatches.length) { findIndex = Math.min(count,findMatches.length - 1) - 1; moveFind(1); }
          else renderFindStatus();
        }
        document.getElementById("transcript-find-toggle").addEventListener("click", function () { openTranscriptFind(); });
        document.getElementById("transcript-find-query").addEventListener("input", function () { findVersion += 1; findIndex = -1; updateTranscriptFind(); });
        document.getElementById("transcript-find").addEventListener("submit", function (event) { event.preventDefault(); moveFind(1); });
        document.getElementById("transcript-find-query").addEventListener("keydown", function (event) { if (event.key === "Enter" && event.shiftKey && !event.isComposing) { event.preventDefault(); moveFind(-1); } });
        document.getElementById("transcript-find-prev").addEventListener("click", function () { moveFind(-1); });
        document.getElementById("transcript-find-close").addEventListener("click", function () { closeTranscriptFind(true); });
        document.getElementById("transcript-find-more").addEventListener("click", function () { searchFurther(true).catch(function () { toast(t("Find could not load more messages."),"danger"); }); });
        function clearMessages() {
          closeTranscriptFind();
          clearDetailExtras();
          messageSessionId = "";
          messageGeneration = "";
          messageCursor = "";
          messageBuf = null;
          messageRequest = null;
          detailSource = "";
          setText(messagesNode, "");
          transcriptMessages = []; transcriptFilter = "all"; transcriptStep = -1; transcriptAllBusy = false;
          turnUsage = null; turnUsageNode = null; promptNumber = 0; messageTotal = null; activeOutlineOrdinal = null; outlineEntries = []; outlineOpen = false;
          minimapOpen = false; minimapSelected = null;
          document.getElementById("transcript-minimap-more").disabled = false;
          document.getElementById("transcript-minimap-box").hidden = true;
          document.getElementById("transcript-minimap-toggle").setAttribute("aria-expanded", "false");
          setText(document.getElementById("transcript-minimap-status"), "");
          setText(document.getElementById("transcript-minimap-position"), "");
          document.getElementById("transcript-outline-box").hidden = true;
          document.getElementById("transcript-outline-toggle").setAttribute("aria-expanded", "false");
          setText(document.getElementById("transcript-outline-status"), "");
          document.getElementById("transcript-outline-more").hidden = true;
          updateTranscript();
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
            if (token === requestEpoch) setStatus(t("Network unavailable"));
            throw error;
          }
          if (!response.ok) {
            if (token === requestEpoch) {
              if (response.status === 401 && method === "GET") expireSession();
              else {
                setStatus(httpStatusText(response.status));
                if (method === "GET") toast(httpStatusText(response.status), "danger");
              }
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
          // Invalidate before waiting on another auth write, even if this write fails.
          identityDisplayVersion += 1;
          setText(document.getElementById("identity-status"), "");
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
          setStatus(t("signed in"));
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
            if (token === requestEpoch) setStatus(t("signed out"));
          } catch (error) {
            if (token === requestEpoch) setStatus(t("Sign-out failed; local view cleared. Retry to revoke the server session."));
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
            if (activePage !== "search" && document.getElementById("session-sort").value === "lastActivity") params.set("sort", "lastActivity");
            sessionFilters = params.toString();
          }
          if (more && sessionSnapshotId && sessionCursor) {
            params.set("snapshotId", sessionSnapshotId);
            params.set("cursor", sessionCursor);
          }
          const encoded = params.toString().replaceAll("+", "%20");
          return encoded ? ("?" + encoded) : "";
        }
        function setAgentFilter(choice) {
          agentFilter = choice;
          ["hide", "all", "only"].forEach(function (value) {
            document.getElementById("agents-" + value).setAttribute("aria-pressed", String(value === choice));
          });
          ["source", "project"].forEach(function (kind) {
            facets[kind].version += 1;
            facets[kind].loaded = false;
            if (document.getElementById(kind + "-picker").open) loadFacets(kind, false);
          });
        }
        function updateFacetSummary(kind) {
          const selected = facets[kind].selected;
          const label = !selected.size ? (kind === "source" ? t("All sources") : t("All projects")) : selected.size === 1 ? Array.from(selected.values())[0] : plural(selected.size, kind);
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
          setText(document.getElementById("active-filters"), "");
          document.getElementById("active-filters").hidden = true;
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
                setText(document.getElementById(kind + "-status"), t(kind === "source" ? "Select up to 32 sources." : "Select up to 32 projects."));
                return;
              }
              if (input.checked) state.selected.set(item.key, itemLabel);
              else state.selected.delete(item.key);
              updateFacetSummary(kind);
              refreshLibrary().catch(function () {});
            });
            label.appendChild(input);
            if (kind === "source") {
              const dot = document.createElement("span");
              const tint = sourceClass(item.key);
              dot.className = tint ? "source-dot " + tint : "source-dot";
              dot.setAttribute("aria-hidden", "true");
              label.appendChild(dot);
            }
            const name = document.createElement("span");
            setText(name, itemLabel);
            label.appendChild(name);
            const count = document.createElement("span");
            count.className = "facet-count";
            setText(count, item.sessionCount.toLocaleString(uiLocale));
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
          setText(status, t("Loading…"));
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
            setText(status, state.items.size ? "" : t(kind === "source" ? "No matching sources." : "No matching projects."));
          } catch (error) {
            if (epoch === facetEpoch && version === state.version) {
              state.loaded = false;
              setText(status, t("Options unavailable. Reopen to retry."));
            }
          } finally {
            if (epoch === facetEpoch && version === state.version) document.getElementById(kind + "-more").disabled = false;
          }
        }
        async function jumpToSession(event) {
          event.preventDefault();
          const id = document.getElementById("session-id").value.trim();
          if (!id) {
            setStatus(t("Enter a session ID."));
            return;
          }
          const token = bumpEpoch();
          showSessionList();
          showDetailEmpty();
          clearMessages();
          clearSessionPaging();
          setText(sessionsNode, "");
          setStatus(t("Finding session…"));
          sessionFilters = new URLSearchParams({ sessionId: id }).toString().replaceAll("+", "%20");
          const page = await api("GET", "/web/api/sessions?" + sessionFilters);
          if (token !== requestEpoch) return;
          acceptSessionsPage(false, page);
          const items = page.items || [];
          if (items.length === 1 && !page.nextCursor) {
            setStatus("");
            await openDetail(items[0].sessionId);
          } else {
            setStatus(items.length ? t("Several sessions share this ID. Select the matching session.") : t("Session not found."));
          }
        }
        function clearFleet() {
          fleetExpanded.clear();
          fleetRequest += 1;
          if (fleetTimer !== null) clearTimeout(fleetTimer);
          fleetTimer = null;
          ["fleet-content", "fleet-summary", "fleet-status"].forEach(function (id) { setText(document.getElementById(id), ""); });
          document.getElementById("fleet-content").setAttribute("aria-busy", "false");
        }
        function fleetCount(value) { return Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString(uiLocale) : t("Not reported"); }
        function fleetBytes(value) {
          if (!Number.isSafeInteger(value) || value < 0) return t("Not reported");
          if (value < 1024) return value + " B";
          const units = ["KiB", "MiB", "GiB", "TiB", "PiB"];
          let n = value / 1024, i = 0;
          while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
          return n.toFixed(1) + " " + units[i];
        }
        function fleetFresh(value) {
          return Number.isSafeInteger(value) && Date.now() / 1000 >= value && Date.now() / 1000 - value <= 600;
        }
        async function loadFleet() {
          if (activePage !== "fleet") return;
          if (fleetTimer !== null) clearTimeout(fleetTimer);
          fleetTimer = null;
          const token = requestEpoch, version = ++fleetRequest;
          const status = document.getElementById("fleet-status"), content = document.getElementById("fleet-content");
          content.setAttribute("aria-busy", "true"); setText(status, t("Loading machine observations…"));
          function current() { return token === requestEpoch && version === fleetRequest && activePage === "fleet"; }
          try {
            const response = await fetch("/web/api/fleet", {method:"GET", credentials:"same-origin", headers:headers()});
            if (!current()) return;
            if (response.status === 401) { expireSession(); return; }
            if (!response.ok) throw {denied:response.status === 403};
            const data = await response.json();
            if (!current()) return;
            if (!data || data.schemaVersion !== 1 || !Array.isArray(data.machines) || data.machines.length > 64) throw {};
            renderFleet(data);
          } catch (error) {
            if (!current()) return;
            setText(content, ""); setText(document.getElementById("fleet-summary"), ""); fleetExpanded.clear();
            setText(status, error && error.denied ? t("Editor access is required to view fleet-wide host metrics.") : t("Machine observations unavailable. Configure the fleet exporter on the Web host; missing telemetry is not a healthy empty fleet."));
          } finally {
            if (current()) {
              content.setAttribute("aria-busy", "false");
              fleetTimer = setTimeout(function () { if (activePage === "fleet" && !workspaceNode.hidden) loadFleet().catch(function () {}); }, 30000);
            }
          }
        }
        function renderFleet(data) {
          const content = document.getElementById("fleet-content"), summary = document.getElementById("fleet-summary");
          const focusKey = document.activeElement && document.activeElement.dataset.fleetFocus;
          let focusAfter = null;
          function rememberFocus(node, key) { node.dataset.fleetFocus = key; if (focusKey === key) focusAfter = node; }
          setText(content, ""); setText(summary, "");
          fleetExpanded.forEach(function (id) { if (!data.machines.some(function (m) { return m.id === id; })) fleetExpanded.delete(id); });
          const central = data.central;
          const centralFresh = central && fleetFresh(central.observedAt) && fleetFresh(data.generatedAt);
          const centralPrefix = central && !centralFresh ? t("Stale · ") : "";
          const fresh = data.machines.filter(function (m) { return m.status === "ok" && fleetFresh(m.observedAt) && fleetFresh(data.generatedAt); }).length;
          const sessions = central && Array.isArray(central.machines) ? central.machines.reduce(function (n,m) { return n + m.sessions; }, 0) : null;
          [[t("Machines"), data.machines.length], [t("Fresh samples"), fresh], [t("Central sessions"), sessions], [t("FTS pending"), central && central.ftsPending], [t("FTS permanent failures"), central && central.ftsFailed]].forEach(function (entry, index) {
            const stat = document.createElement("div"), title = document.createElement("dt"), value = document.createElement("dd");
            setText(title,entry[0]); setText(value,(index >= 2 ? centralPrefix : "") + fleetCount(entry[1]));
            stat.appendChild(title); stat.appendChild(value); summary.appendChild(stat);
          });
          const note = t("Snapshot: {0}{1} · Central index: {2}", [healthTime(data.generatedAt), fleetFresh(data.generatedAt) ? "" : t(" · Stale or clock ahead"), central ? healthTime(central.observedAt) + (centralFresh ? "" : t(" (stale or clock ahead)")) : t("Not reported")]);
          setText(document.getElementById("fleet-status"), note);
          if (!data.machines.length) { setText(content,t("No machines configured in the fleet exporter.")); return; }
          function makeTable(title, columns, rows) {
            const wrap = document.createElement("div"), table = document.createElement("table"), caption = document.createElement("caption");
            wrap.className = "fleet-table-wrap"; wrap.tabIndex = 0; wrap.setAttribute("role","region"); wrap.setAttribute("aria-label",title);
            table.className = "fleet-table"; setText(caption,title); table.appendChild(caption);
            const head = document.createElement("thead"), headings = document.createElement("tr"), body = document.createElement("tbody");
            columns.forEach(function (text) { const th = document.createElement("th"); th.setAttribute("scope","col"); setText(th,text); headings.appendChild(th); });
            head.appendChild(headings); table.appendChild(head); table.appendChild(body); wrap.appendChild(table);
            rows.forEach(function (values) {
              const row = document.createElement("tr");
              values.forEach(function (text,index) { const cell = document.createElement(index === 0 ? "th" : "td"); if (index === 0) cell.setAttribute("scope","row"); setText(cell,text); row.appendChild(cell); });
              body.appendChild(row);
            });
            return {wrap:wrap,table:table,body:body,headings:headings};
          }
          function line(cell, text) { const span = document.createElement("span"); span.className = "fleet-subline"; setText(span,text); cell.appendChild(span); }
          const overview = makeTable(t("Machines · select a name for details"), [t("Machine"), t("Services / attention"), t("Sessions"), t("Capture (files)"), t("Upload tasks"), t("Index tasks"), t("Free disk"), t("Observation")], []);
          overview.table.classList.add("fleet-overview"); rememberFocus(overview.wrap,"overview");
          const secondary = [2,3,4,5,7]; secondary.forEach(function (i) { overview.headings.children[i].className = "fleet-secondary"; });
          overview.headings.children[4].title = t("Sum of per-replica states, not distinct capture generations");
          data.machines.forEach(function (m, index) {
            const observed = m.status === "ok" && fleetFresh(m.observedAt) && fleetFresh(data.generatedAt);
            const processes = m.processes || [], replicas = m.replicas || [], roots = m.roots || [];
            const stopped = processes.some(function (p) { return p.state === "stopped"; });
            const badRoots = roots.some(function (r) { return r.epochStatus === "mismatch" || r.scanFailed; });
            const retrying = replicas.some(function (r) { return r.failed > 0; });
            const lowDisk = m.disk && (m.disk.freeBytes < 20 * 1024 * 1024 * 1024 || m.disk.freeBytes / m.disk.totalBytes < 0.1);
            const c = central && central.machines.find(function (value) { return value.machineId.toLowerCase() === String(m.machineId || "").toLowerCase(); });
            const capture = m.capture, row = document.createElement("tr"), detailRow = document.createElement("tr");
            row.className = "fleet-machine-row"; detailRow.className = "fleet-detail-row"; detailRow.setAttribute("id","fleet-detail-" + index);
            const name = document.createElement("th"), toggle = document.createElement("button"); name.setAttribute("scope","row");
            toggle.type = "button"; toggle.className = "fleet-toggle"; toggle.setAttribute("aria-controls","fleet-detail-" + index); rememberFocus(toggle,"toggle:" + m.id);
            function disclosure() { const open = fleetExpanded.has(m.id); detailRow.hidden = !open; toggle.setAttribute("aria-expanded",String(open)); setText(toggle,(open ? "▾ " : "▸ ") + m.label); }
            toggle.addEventListener("click",function () { if (fleetExpanded.has(m.id)) fleetExpanded.delete(m.id); else fleetExpanded.add(m.id); disclosure(); });
            disclosure(); name.appendChild(toggle); line(name,t(m.role)); row.appendChild(name);
            const cells = [];
            for (let i = 1; i < 8; i += 1) { const cell = document.createElement("td"); if (secondary.includes(i)) cell.className = "fleet-secondary"; row.appendChild(cell); cells[i] = cell; }
            const state = cells[1]; state.className = "fleet-state";
            if (m.status === "unreachable") state.appendChild(pill("danger",t("Unreachable")));
            else if (!observed) state.appendChild(pill("warn",t("Stale or clock ahead")));
            else if (stopped) state.appendChild(pill("danger",t("Stopped process")));
            else if (!processes.length) state.appendChild(pill("neutral",t("Not reported")));
            else if (processes.some(function (p) { return p.state !== "running"; })) state.appendChild(pill("neutral",t("Process unknown")));
            else state.appendChild(pill("ok",t("Running")));
            if (roots.some(function (r) { return r.captured < r.locators || r.unavailable > 0; })) state.appendChild(pill("warn",t("Capture gaps")));
            if (badRoots) state.appendChild(pill("warn",t("Scan / epoch issue")));
            if (retrying) state.appendChild(pill("warn",t("Upload retry errors")));
            if (c && c.retryable > 0) state.appendChild(pill("warn",t("Index retries")));
            if (lowDisk) state.appendChild(pill("warn",t("Low disk")));
            if ((m.errors || []).length) state.appendChild(pill("warn",t("Missing observations")));
            setText(cells[2], c ? centralPrefix + fleetCount(c.sessions) : t("Not reported"));
            if (capture) { setText(cells[3],t("Captured {0}", [fleetCount(capture.capturedLocators)])); line(cells[3],t("Dirty {0} · Unavailable {1}", [fleetCount(capture.dirtyLocators), fleetCount(capture.unavailableLocators)])); }
            else setText(cells[3],t("Not reported"));
            if (replicas.length) {
              const pending = replicas.reduce(function (n,r) { return n + r.pending; },0), inflight = replicas.reduce(function (n,r) { return n + r.inflight; },0);
              setText(cells[4],t("Pending {0}", [fleetCount(pending)])); line(cells[4],t("In flight {0}", [fleetCount(inflight)]));
              if (pending || inflight) state.appendChild(pill("info",t("Active uploads")));
            } else setText(cells[4],t("Not reported"));
            if (c) { setText(cells[5],t("{0}Pending {1}", [centralPrefix, fleetCount(c.pending)])); line(cells[5],t("Processing {0}", [fleetCount(c.processing)])); } else setText(cells[5],t("Not reported"));
            setText(cells[6],fleetBytes(m.disk && m.disk.freeBytes));
            cells[7].appendChild(pill(observed ? "info" : "warn", observed ? t("Sampled") : m.status === "unreachable" ? t("Unreachable") : t("Stale or clock ahead")));
            line(cells[7],healthAgo(m.observedAt)); cells[7].title = healthTime(m.observedAt);
            overview.body.appendChild(row);
            const detailCell = document.createElement("td"), details = document.createElement("div"); detailCell.colSpan = 8; details.className = "fleet-details";
            const identity = document.createElement("p"); identity.className = "meta";
            setText(identity,t("{0} · sampled {1} · attempted {2}", [m.label, healthTime(m.observedAt), healthTime(m.lastAttemptAt)])); details.appendChild(identity);
            const metrics = document.createElement("div"); metrics.className = "fleet-metrics";
            function block(key, title, rows) { const table = makeTable(title,[t("Metric"),t("Value")],rows); rememberFocus(table.wrap,key + ":" + m.id); metrics.appendChild(table.wrap); }
            block("central", t("Central sessions{0}", [c && !centralFresh ? t(" (stale or clock ahead)") : ""]), [[t("Stored sessions"),fleetCount(c && c.sessions)], [t("Non-hidden, non-skip"),fleetCount(c && c.visibleSessions)],
              [t("Pending / processing"), c ? fleetCount(c.pending) + " / " + fleetCount(c.processing) : t("Not reported")],
              [t("Parsed / index-ready tasks"),c ? fleetCount(c.parsed) + " / " + fleetCount(c.indexReady) : t("Not reported")],
              [t("Received generations"),fleetCount(c && c.publications)],
              [t("Retryable / quarantined"), c ? fleetCount(c.retryable) + " / " + fleetCount(c.quarantined) : t("Not reported")]]);
            block("collector", t("Collector"), [[t("Capture generations"),fleetCount(capture && capture.publications)], [t("Captured files"),fleetCount(capture && capture.capturedLocators)],
              [t("Dirty / cooling files"),capture ? fleetCount(capture.dirtyLocators) + " / " + fleetCount(capture.coolingLocators) : t("Not reported")],
              [t("Unavailable files"),fleetCount(capture && capture.unavailableLocators)], [t("Last capture"),healthTime(capture && capture.lastCaptureAt)]]);
            block("storage", t("Storage"), [[t("Volume used"),m.disk ? fleetBytes(m.disk.totalBytes-m.disk.freeBytes) : t("Not reported")],
              [t("Volume free"),fleetBytes(m.disk && m.disk.freeBytes)], [t("Volume capacity"),fleetBytes(m.disk && m.disk.totalBytes)]]
              .concat((m.storage || []).map(function (d) { return [d.name,fleetBytes(d.usedBytes) + " · " + healthAgo(d.observedAt)]; })));
            details.appendChild(metrics);
            if (m.disk && m.disk.totalBytes > 0) {
              const progress = document.createElement("progress"); progress.max = m.disk.totalBytes; progress.value = m.disk.totalBytes-m.disk.freeBytes;
              progress.setAttribute("aria-label", t("Volume used on {0}", [m.label])); details.appendChild(progress);
              if (lowDisk) { const warning = document.createElement("p"); warning.className = "attention"; setText(warning,t("Low free disk: below 20 GiB or 10% of capacity.")); details.appendChild(warning); }
            }
            const processTable = makeTable(t("Sampled processes"), [t("Service"),t("State"),t("PID"),t("Revision")], processes.length ? processes.map(function (p) { return [p.name,t(p.state),Number.isSafeInteger(p.pid) && p.pid > 0 ? String(p.pid) : t("Not reported"),p.revision ? p.revision.slice(0,8) : t("Not reported")]; }) : [[t("Not reported"),t("Not reported"),t("Not reported"),t("Not reported")]]);
            processTable.table.classList.add("fleet-process-table"); rememberFocus(processTable.wrap,"processes:" + m.id); details.appendChild(processTable.wrap);
            const replicaTable = makeTable(t("Replica publication states"), [t("Replica"),t("Pending"),t("In flight"),t("ACK"),t("Privacy withheld"),t("Retry errors")], replicas.length ? replicas.map(function (r) { return [r.id,fleetCount(r.pending),fleetCount(r.inflight),fleetCount(r.acknowledged),fleetCount(r.withheld),fleetCount(r.failed)]; }) : [[t("Not reported"),t("Not reported"),t("Not reported"),t("Not reported"),t("Not reported"),t("Not reported")]]);
            replicaTable.table.classList.add("fleet-replica-table"); rememberFocus(replicaTable.wrap,"replicas:" + m.id); details.appendChild(replicaTable.wrap);
            if ((m.errors || []).length) { const error = document.createElement("p"); error.className = "attention"; setText(error,t("Missing observations: {0}", [m.errors.join(", ")])); details.appendChild(error); }
            if (roots.length) {
              const sourceTable = makeTable(t("Sources & inventory coverage"), [t("Source / root"), t("Tracked files"), t("Captured"), t("Dirty files"), t("Cooling"), t("Unavailable"), t("Scan"), t("Epoch")], roots.map(function (r) {
                return [sourceLabel(r.source) + " · " + r.id, fleetCount(r.locators),fleetCount(r.captured),fleetCount(r.dirty),fleetCount(r.cooling),fleetCount(r.unavailable),
                  r.scanFailed ? t("Failed") : r.scanning ? t("Scanning · lag {0}", [fleetCount(r.scanLag)]) : r.scanLag ? t("Pending · lag {0}", [fleetCount(r.scanLag)]) : t("Complete"), t(r.epochStatus)];
              }));
              sourceTable.table.classList.add("fleet-source-table"); rememberFocus(sourceTable.wrap,"sources:" + m.id); details.appendChild(sourceTable.wrap);
            }
            if (m.machineId) {
              const link = document.createElement("a"); link.href = routeHref({page:"sessions",filters:{machine:m.machineId}});
              setText(link,t("Browse this machine’s sessions")); rememberFocus(link,"browse:" + m.id); details.appendChild(link);
            }
            detailCell.appendChild(details); detailRow.appendChild(detailCell); overview.body.appendChild(detailRow);
          });
          content.appendChild(overview.wrap);
          if (focusAfter) focusAfter.focus({preventScroll:true});
        }
        function countValue(value) {
          const number = Number(value);
          return number > 0 ? number : 0;
        }
        function showOverviewUnavailable() {
          overviewStreams = null; overviewObservedAt = null;
          setText(healthContent, "");
          setText(document.getElementById("health-summary"), "");
          setText(healthStatus, t("Health is temporarily unavailable."));
          healthContent.setAttribute("aria-busy", "false");
          setText(overviewNode, "");
          const note = document.createElement("p");
          note.className = "empty";
          setText(note, t("Overview is temporarily unavailable."));
          overviewNode.appendChild(note);
        }
        async function loadOverview() {
          healthContent.setAttribute("aria-busy", "true");
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
            if (streams.length + page.streams.length > 2000 || seenCursors.size >= 1000) { showOverviewUnavailable(); return token; }
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
          overviewStreams = streams; overviewObservedAt = observedAt;
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
          const sourceText = names.length ? plural(names.length, "source") : t("No sources yet");
          setText(summary, t("Session library · {0} · {1}", [sourceText, plural(ready, t("ready session"))]));
          overviewNode.appendChild(summary);
          if (streams.length) {
            const identities = document.createElement("details");
            const caption = document.createElement("summary");
            setText(caption, t("Technical details"));
            identities.appendChild(caption);
            const counts = document.createElement("p");
            setText(counts, plural(publications, t("captured file")));
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
        // Relative age for Health rows; exact times remain visible and machine-readable.
        function healthAgo(value) {
          if (!(Number.isSafeInteger(value) && value >= 0 && value <= 253402300799)) return t("Not reported");
          const seconds = Math.floor(Date.now() / 1000 - value);
          if (seconds < 0) return healthTime(value);
          if (seconds < 60) return t("{0}s ago", [seconds]);
          if (seconds < 3600) return t("{0}m ago", [Math.floor(seconds / 60)]);
          if (seconds < 86400) return t("{0}h {1}m ago", [Math.floor(seconds / 3600), Math.floor((seconds % 3600) / 60)]);
          return t("{0}d ago", [Math.floor(seconds / 86400)]);
        }
        function healthTime(value) {
          return Number.isSafeInteger(value) && value >= 0 && value <= 253402300799
            ? new Date(value * 1000).toLocaleString(uiLocale) : t("Not reported");
        }
        // Liveness comes from the collector heartbeat only; capture activity and
        // task attention are reported separately.
        function healthLiveness(heartbeatAt) {
          if (!Number.isSafeInteger(heartbeatAt) || heartbeatAt < 0 || heartbeatAt > 253402300799) return ["neutral", t("No heartbeat")];
          const age = Date.now() / 1000 - heartbeatAt;
          if (age < 0) return ["neutral", t("Clock ahead")];
          if (age < 15 * 60) return ["ok", t("Live")];
          if (age < 24 * 3600) return ["warn", t("Quiet")];
          return ["danger", t("Offline")];
        }
        function pill(tone, text) {
          const node = document.createElement("span");
          node.className = "pill";
          node.dataset.tone = tone;
          setText(node, text);
          return node;
        }
        function renderHealth(streams, observedAt) {
          setText(healthContent, "");
          healthContent.setAttribute("aria-busy", "false");
          setText(healthStatus, streams.length ? t("Observed: {0}", [healthTime(observedAt)]) : t("No registered sources reported."));
          const fleet = { ok: 0, warn: 0, danger: 0, neutral: 0, attention: 0 };
          streams.forEach(function (stream) {
            const card = document.createElement("section");
            card.className = "health-card";
            const head = document.createElement("div");
            head.className = "health-head";
            const heading = document.createElement("h3");
            const source = stream.registry && stream.registry.source;
            const dot = document.createElement("span");
            const tint = sourceClass(source);
            dot.className = tint ? "source-dot " + tint : "source-dot";
            dot.setAttribute("aria-hidden", "true");
            heading.appendChild(dot);
            heading.appendChild(textSpan(sourceLabel(source)));
            head.appendChild(heading);
            const pills = document.createElement("span");
            pills.className = "pills";
            const live = healthLiveness(stream.heartbeatAt);
            fleet[live[0]] += 1;
            pills.appendChild(pill(live[0], live[1]));
            head.appendChild(pills);
            card.appendChild(head);
            const tasks = stream.ingest && stream.ingest.taskCounts;
            if (tasks && (tasks.retryableFailure > 0 || tasks.quarantined > 0)) {
              fleet.attention += 1;
              pills.appendChild(pill("warn", t("Needs attention")));
              const note = document.createElement("p");
              note.className = "attention";
              setText(note, t("Some captures need attention."));
              card.appendChild(note);
            }
            const metrics = document.createElement("dl");
            function row(label, value, exact) {
              const name = document.createElement("dt");
              const detail = document.createElement("dd");
              setText(name, label);
              setText(detail, value);
              if (exact) detail.title = exact;
              metrics.appendChild(name);
              metrics.appendChild(detail);
            }
            function timeRow(label, value) {
              row(label, "", healthTime(value));
              const cell = metrics.lastChild;
              const valid = Number.isSafeInteger(value) && value >= 0 && value <= 253402300799;
              if (!valid) { setText(cell, t("Not reported")); return; }
              const time = document.createElement("time"); time.dateTime = new Date(value * 1000).toISOString(); setText(time, healthAgo(value)); cell.appendChild(time);
              const exact = textSpan(healthTime(value)); exact.className = "health-timestamp"; cell.appendChild(exact);
            }
            function count(label, value) {
              row(label, Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString(uiLocale) : t("Not reported"));
            }
            const capture = document.createElement("p"); capture.className = "meta";
            setText(capture, t("Capture activity · latest observations, not history")); card.appendChild(capture);
            count(t("Captured files"), stream.ingest && stream.ingest.publicationCount);
            [[t("Pending"), "pending"], [t("Processing"), "processing"],
              [t("Parsed (includes skip)"), "parsed"], [t("Indexed for search"), "indexReady"],
              [t("Retryable failures"), "retryableFailure"], [t("Quarantined"), "quarantined"]].forEach(function (metric) {
              count(metric[0], tasks && tasks[metric[1]]);
            });
            count(t("Parse failures"), stream.ingest && stream.ingest.parseFailureTasks);
            count(t("Search-ready sessions"), stream.fts && stream.fts.readyLogicalSessions);
            timeRow(t("Heartbeat"), stream.heartbeatAt);
            timeRow(t("Last capture"), stream.lastCapture && stream.lastCapture.observedAt);
            timeRow(t("Oldest pending"), stream.ingest && stream.ingest.oldestPendingAt);
            row(t("AI state"), stream.ai ? t(stream.ai.state) : t("Not reported"));
            row(t("Replica acknowledgements"), Array.isArray(stream.replicaACKs)
              ? stream.replicaACKs.map(function (ack) { return ack.serverId + ": " + healthAgo(ack.observedAt); }).join("; ") || t("None reported")
              : t("Not reported"), Array.isArray(stream.replicaACKs)
              ? stream.replicaACKs.map(function (ack) { return ack.serverId + ": " + healthTime(ack.observedAt); }).join("; ") : "");
            card.appendChild(metrics);
            const identity = document.createElement("details");
            const caption = document.createElement("summary");
            setText(caption, t("Source identity"));
            identity.appendChild(caption);
            const value = document.createElement("p");
            setText(value, t("Machine: {0} · Instance: {1}", [stream.machineId || t("Not reported"), stream.sourceInstanceId || t("Not reported")]));
            identity.appendChild(value);
            card.appendChild(identity);
            healthContent.appendChild(card);
          });
          const summaryNode = document.getElementById("health-summary");
          setText(summaryNode, "");
          [["ok", fleet.ok, t(" live")], ["warn", fleet.warn, t(" quiet")], ["danger", fleet.danger, t(" offline")],
            ["neutral", fleet.neutral, t(" unknown liveness")]].forEach(function (entry) {
            if (entry[1]) summaryNode.appendChild(pill(entry[0], entry[1].toLocaleString(uiLocale) + entry[2]));
          });
          if (fleet.attention) summaryNode.appendChild(pill("warn", plural(fleet.attention, t("needs attention"), t("need attention"))));
          if (streams.length) {
            // Shared footnotes, shown once instead of on every card.
            [t("Skip-tier sessions stay Parsed and are not a search backlog."),
              t("Quarantined counts include empty transcripts (parse.noVisibleMessages), not a Cursor-only parser failure.")].forEach(function (text) {
              const note = document.createElement("p");
              note.className = "health-note";
              setText(note, text);
              healthContent.appendChild(note);
            });
          }
        }
        function projectText(item) {
          return item.projectLabel || item.projectKey || "";
        }
        function sessionTitle(item) {
          return item.title && item.title !== item.sessionId ? item.title : t("Untitled session");
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
            time.title = date.toLocaleString(uiLocale);
            const seconds = Math.floor((Date.now() - date.getTime()) / 1000);
            const relative = seconds < 0 ? null : seconds < 60 ? t("just now")
              : seconds < 3600 ? t("{0}m ago", [Math.floor(seconds / 60)])
              : seconds < 86400 ? t("{0}h ago", [Math.floor(seconds / 3600)])
              : seconds < 604800 ? t("{0}d ago", [Math.floor(seconds / 86400)]) : null;
            setText(time, relative || date.toLocaleDateString(uiLocale, { year: "numeric", month: "short", day: "numeric" }));
            appendMetaPart(meta, time);
          }
          if (Number.isSafeInteger(item.lastActivityAt)) {
            const activity = document.createElement("span");
            setText(activity, t("Activity: {0}", [Number.isSafeInteger(item.lastActivityAt) ? healthTime(item.lastActivityAt) : t("Unknown")]));
            appendMetaPart(meta, activity);
          }
          [["model", item.model], ["cost", item.costUsd], ["tool", item.toolMessageCount]].forEach(function (entry) {
            const value = entry[1];
            if (entry[0] === "model" ? typeof value !== "string" || !value : entry[0] === "tool" ? !Number.isSafeInteger(value) || value < 0 : typeof value !== "number" || !Number.isFinite(value) || value < 0) return;
            const label = document.createElement("span");
            setText(label, entry[0] === "model" ? value : entry[0] === "cost" ? costValue(value,"costUsd") : t("{0} tool", [value.toLocaleString(uiLocale)]));
            appendMetaPart(meta,label);
          });
          if (showCounts) {
            const counts = [["user", item.userMessageCount], ["assistant", item.assistantMessageCount], ["system", item.systemMessageCount]]
              .filter(function (entry) { return Number.isSafeInteger(entry[1]) && entry[1] > 0; })
              .map(function (entry) { return entry[1].toLocaleString(uiLocale) + " " + t(entry[0]); });
            if (counts.length) {
              const label = document.createElement("span");
              label.className = "message-counts";
              setText(label, counts.join(" · "));
              appendMetaPart(meta, label);
            }
          }
        }
        function appendParentLink(host, item) {
          if (typeof item.parentSessionId !== "string" || !item.parentSessionId) return;
          const link = document.createElement("button"); link.type = "button"; link.className = "parent-link";
          setText(link,t("Parent session"));
          link.addEventListener("click",function () { openDetail(item.parentSessionId).catch(function () {}); });
          host.appendChild(link);
        }
        function appendSessionNesting(host, item) {
          appendParentLink(host,item);
          if (!Number.isSafeInteger(item.childCount) || item.childCount <= 0) return;
          const disclosure = document.createElement("details"); disclosure.className = "session-nesting";
          const summary = document.createElement("summary"); setText(summary,t("({0}) child sessions", [item.childCount]));
          disclosure.appendChild(summary);
          const status = document.createElement("p"); status.className = "nesting-status"; status.setAttribute("role","status");
          const rows = document.createElement("div"); rows.className = "nested-rows";
          const more = document.createElement("button"); more.type = "button"; more.className = "nested-more"; more.hidden = true;
          setText(more,t("Load more child sessions"));
          disclosure.appendChild(status); disclosure.appendChild(rows); disclosure.appendChild(more); host.appendChild(disclosure);
          let loaded = false, busy = false, cursor = "", snapshot = "", total = 0;
          const seen = new Set();
          async function load(continuation) {
            if (busy || (continuation && !cursor)) return;
            busy = true; more.disabled = true;
            const token = requestEpoch;
            const current = function () { return token === requestEpoch && sessionsNode.contains(host); };
            const params = new URLSearchParams(); params.set("limit","50");
            if (continuation) { params.set("snapshotId",snapshot); params.set("cursor",cursor); }
            setText(status,t("Loading child sessions…"));
            try {
              const page = await api("GET","/web/api/sessions/" + encodeURIComponent(item.sessionId) + "/children?" + params);
              if (!current()) return;
              if (!page || page.sessionId !== item.sessionId || !page.snapshotId || (continuation && page.snapshotId !== snapshot) || !Array.isArray(page.items) || page.items.some(function (child) { return !child.session || typeof child.session.sessionId !== "string" || !["confirmed","suggested"].includes(child.relationship); })) throw new Error("Invalid children page");
              if (!continuation) { setText(rows,""); seen.clear(); total = 0; }
              page.items.forEach(function (child) {
                if (seen.has(child.session.sessionId)) return;
                seen.add(child.session.sessionId); total += 1;
                const row = document.createElement("div");
                const button = document.createElement("button"); button.type = "button"; button.className = "nested-session";
                const title = document.createElement("strong"); setText(title,sessionTitle(child.session)); button.appendChild(title);
                const meta = document.createElement("span"); meta.className = "meta";
                appendSessionMetadata(meta,child.session,true);
                const relationship = document.createElement("span"); setText(relationship,child.relationship === "confirmed" ? t("Confirmed") : t("Suggested")); appendMetaPart(meta,relationship);
                button.appendChild(meta); button.addEventListener("click",function () { openDetail(child.session.sessionId).catch(function () {}); });
                row.appendChild(button); appendParentLink(row,child.session); rows.appendChild(row);
              });
              snapshot = page.snapshotId; cursor = page.nextCursor || ""; loaded = true;
              more.hidden = !cursor; setText(more,t("Load more child sessions"));
              setText(status,t("{0} child sessions loaded{1} · Current children snapshot; (N) is from the list snapshot.", [total, cursor ? t(" · More available") : ""]));
            } catch (error) {
              if (!current()) return;
              loaded = false; cursor = ""; snapshot = "";
              setText(rows,""); seen.clear(); total = 0;
              setText(status,t("Child sessions unavailable or unsupported by this older server. Retry or refresh the list; no relationships were inferred."));
              more.hidden = false; setText(more,t("Retry child sessions"));
            } finally { busy = false; if (current()) more.disabled = false; }
          }
          disclosure.addEventListener("toggle",function () { if (disclosure.open && !loaded) load(false); });
          more.addEventListener("click",function () { load(loaded); });
        }
        function sessionDateGroup(startedAt) {
          if (!Number.isSafeInteger(startedAt) || startedAt < 0 || startedAt > 253402300799) return t("Undated");
          const date = new Date(startedAt * 1000);
          const now = new Date(Date.now());
          const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
          const day = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
          const days = Math.round((today - day) / 86400000);
          if (days <= 0) return t("Today");
          if (days === 1) return t("Yesterday");
          if (days < 7) return t("Previous 7 days");
          if (days < 30) return t("Previous 30 days");
          return date.toLocaleDateString(uiLocale, { year: "numeric", month: "long" });
        }
        function acceptSessionsPage(more, page) {
          closeCommandPalette();
          const loaded = new Map(more ? commandSessions.map(function (item) { return [item.id, item]; }) : []);
          (page.items || []).forEach(function (item) { if (typeof item.sessionId === "string" && item.sessionId) loaded.set(item.sessionId, {id:item.sessionId, label:sessionTitle(item)}); });
          commandSessions = Array.from(loaded.values());
          if (!more) { listRouteKey = routeHref(libraryRoute()); selectedSessionIndex = -1; }
          sessionsNode.setAttribute("aria-busy", "false");
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
          if (!more) setText(sessionsNode, "");
          if (!more && !(page.items || []).length) {
            sessionsNode.appendChild(emptyState("inbox", page.warning || t("No sessions found"), "", hasActiveFilters() ? [[t("Clear filters"), clearAllFilters]] : []));
          }
          // Date groups restart on every page; ranked search results stay ungrouped.
          const grouped = !(page.items || []).some(function (item) { return item.matchType || item.snippet; });
          let previousGroup = null;
          (page.items || []).forEach(function (item) {
            const button = document.createElement("button");
            button.type = "button";
            const tint = sourceClass(item.source);
            button.className = tint ? "session " + tint : "session";
            const title = document.createElement("span");
            title.className = "title";
            setText(title, sessionTitle(item));
            title.title = title.textContent;
            button.appendChild(title);
            const meta = document.createElement("span");
            meta.className = "meta";
            appendSessionMetadata(meta, item, true);
            if (item.matchType) {
              const match = document.createElement("span");
              match.className = "match-badge";
              match.dataset.match = item.matchType === "semantic" ? "semantic" : "keyword";
              setText(match, item.matchType === "both" ? t("Keyword + semantic") : item.matchType === "semantic" ? t("Semantic match") : t("Keyword match"));
              appendMetaPart(meta, match);
            }
            button.appendChild(meta);
            if (item.snippet) {
              const snippet = document.createElement("span");
              snippet.className = "search-snippet";
              setHighlightedText(snippet, item.snippet);
              button.appendChild(snippet);
            }
            if (grouped) {
              const group = sessionDateGroup(document.getElementById("session-sort").value === "lastActivity" && activePage !== "search" ? item.lastActivityAt : item.startedAt);
              if (group !== previousGroup) {
                // Decorative: the visible header is absolutely positioned above
                // the row, so #sessions keeps one child per session for paging.
                const head = document.createElement("span");
                head.className = "group-head";
                head.setAttribute("aria-hidden", "true");
                setText(head, group);
                button.appendChild(head);
                button.className += " group-start";
                previousGroup = group;
              }
            }
            button.addEventListener("click", function () {
              openDetail(item.sessionId).catch(function () {});
            });
            if (item.matchType || (Number.isSafeInteger(item.childCount) && item.childCount > 0) || item.parentSessionId) {
              const row = document.createElement("div"); row.className = "session-row";
              row.appendChild(button); appendSessionNesting(row,item);
              if (item.matchType) {
                const match = document.createElement("button"); match.type = "button"; match.className = "open-match parent-link";
                setText(match,t("Open at match"));
                match.addEventListener("click",function () { openDetail(item.sessionId,null,false,{q:item.searchQuery || document.getElementById("query").value.trim()}).catch(function () {}); });
                row.appendChild(match);
              }
              sessionsNode.appendChild(row);
            } else sessionsNode.appendChild(button);
          });
          updateSessionMore();
        }
        async function loadSessions(more) {
          const token = bumpEpoch();
          if (!more) {
            listRouteKey = "";
            clearSessionPaging();
            showListSkeleton();
            showSessionList();
            showDetailEmpty();
            clearMessages();
          }
          let page;
          try {
            page = await api("GET", "/web/api/sessions" + sessionQuery(more));
          } catch (error) {
            if (!more && token === requestEpoch) showListError();
            throw error;
          }
          if (token !== requestEpoch) return;
          acceptSessionsPage(more, page);
          setStatus(t("signed in"));
          return token;
        }
        function showListError() {
          sessionsNode.setAttribute("aria-busy", "false");
          setText(document.getElementById("session-page-status"), "");
          setText(sessionsNode, "");
          sessionsNode.appendChild(emptyState("alert", t("Sessions could not be loaded"), t("Check the connection, then retry. If this server rejects last-activity ordering, select Started (legacy) and retry."), [[t("Retry"), function () { refreshLibrary().catch(function () {}); }]]));
        }
        async function restoreSession() {
          const token = requestEpoch, displayVersion = identityDisplayVersion;
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
            if (token === requestEpoch) setStatus(t("Network unavailable"));
            return;
          }
          if (token !== requestEpoch) return;
          if (response.status === 401) { await identitySignIn(false); return; }
          if (response.status === 503) {
            try {
              response = await probe();
            } catch (error) {
              if (token === requestEpoch) setStatus(t("Network unavailable"));
              return;
            }
            if (token !== requestEpoch) return;
            if (response.status === 401) { await identitySignIn(false); return; }
          }
          if (!response.ok) {
            if (token === requestEpoch) setStatus(t("Temporarily unavailable"));
            return;
          }
          let page;
          try {
            const type = response.headers.get("content-type") || "";
            page = type.indexOf("application/json") >= 0 ? await response.json() : { items: [] };
          } catch (error) {
            if (token === requestEpoch) setStatus(t("Temporarily unavailable"));
            return;
          }
          if (token !== requestEpoch) return;
          setStatus(t("signed in"));
          setSignedIn(true);
          setText(sessionsNode, "");
          showSessionList();
          showDetailEmpty();
          clearMessages();
          acceptSessionsPage(false, page);
          if (token !== requestEpoch) return;
          await loadOverview();
          if (identityMode && displayVersion === identityDisplayVersion && !workspaceNode.hidden) {
            try {
              const access = await api("GET", "/web/api/auth");
              if (displayVersion === identityDisplayVersion && !workspaceNode.hidden && access && typeof access.login === "string") {
                const label = t("Signed in as {0}", [access.login]);
                setText(document.getElementById("identity-status"), label);
                if (token === requestEpoch) setStatus(label);
              }
            } catch (error) {} // Auth display is optional; authorization remains server-owned.
          }
        }
        async function openDetail(sessionId, returnPage, routed, matchLanding) {
          if (!workspaceNode.classList.contains("showing-detail") || returnPage === "stats") detailReturnRoute = returnPage === "insights" ? {page:"insights"} : (returnPage === "stats" || activePage === "stats") ? statsRoute() : libraryRoute();
          if (!routed) {
            routeVersion += 1;
            writeRoute({page:"detail",id:sessionId,find:matchLanding ? matchLanding.q : activePage === "search" ? document.getElementById("query").value.trim() : ""});
          }
          detailReturnPage = returnPage || (detailReturnRoute && detailReturnRoute.page === "stats" ? "stats" : null);
          const version = routeVersion, token = bumpEpoch();
          sessionPagingBusy = false;
          updateSessionMore();
          if (!workspaceNode.classList.contains("showing-detail")) detailReturnFocus = document.activeElement;
          showSessionDetailPane(); focusVisible(backNode);
          setText(detailNode, "");
          clearMessages();
          try {
            const page = await api("GET", "/web/api/sessions/" + encodeURIComponent(sessionId));
            if (token !== requestEpoch) return;
            const detail = page.detail;
            if (!detail || !detail.session) {
              setText(detailNode, t("unavailable"));
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
              messageTotal = shownGeneration.normalizedMessageCount;
              const count = document.createElement("span");
              setText(count, plural(shownGeneration.normalizedMessageCount, "message"));
              appendMetaPart(meta, count);
            }
            heading.appendChild(meta);
            detailNode.appendChild(heading);
            detailSource = session.source ? String(session.source) : "";
            const generation = detail.transcriptGeneration;
            detailInfoDetail = detail;
            detailContextSession = session.sessionId;
            detailContextGeneration = generation || "";
            renderSessionSummary(detail.summary);
            document.getElementById("session-actions").hidden = !generation;
            updateSessionActionControls();
            document.getElementById("detail-view-nav").hidden = false;
            document.getElementById("detail-view-timeline").disabled = !generation;
            showDetailView("transcript");
            if (!generation) {
              const reason = typeof detail.transcriptAvailability === "string" && detail.transcriptAvailability !== "available" ? t("Availability: {0}.", [t(detail.transcriptAvailability)]) : "";
              messagesNode.appendChild(emptyState("inbox", t("Transcript unavailable"), (t("The service has not admitted a readable transcript for this session. {0}", [reason])).trim()));
              if (matchLanding) { openTranscriptFind(matchLanding.q); toast(t("Exact match position unavailable (transcript not admitted). Find is prefilled but no transcript messages are loaded."),"info"); }
              return;
            }
            let provenMatch = null, matchReason = "unverified";
            if (matchLanding) {
              try {
                const params = new URLSearchParams({generation:generation,q:matchLanding.q});
                const match = await api("GET","/web/api/sessions/" + encodeURIComponent(session.sessionId) + "/match?" + params);
                if (token !== requestEpoch || version !== routeVersion) return;
                if (!match || match.sessionId !== session.sessionId || match.generation !== generation) throw new Error("changed match generation");
                if (Number.isSafeInteger(match.messageOrdinal) && match.messageOrdinal >= 0 && match.messageOrdinal < 100000 && !match.reason && ["allTerms","firstTerm"].includes(match.matchScope)) provenMatch = match;
                else matchReason = match.reason || "unverified";
              } catch (error) { if (token !== requestEpoch || version !== routeVersion) return; matchReason = t("unavailable or older server"); }
            }
            await loadMessages(token, session.sessionId, generation, provenMatch && typeof provenMatch.messageCursor === "string" ? provenMatch.messageCursor : "");
            if (matchLanding && token === requestEpoch && version === routeVersion) {
              if (provenMatch) {
                await jumpToOrdinal(provenMatch.messageOrdinal);
                if (provenMatch.matchScope === "firstTerm") toast(t("Landed on the first query term; all terms were not found in one message."),"info");
              } else {
                writeRoute({page:"detail",id:session.sessionId,find:matchLanding.q});
                openTranscriptFind(matchLanding.q); toast(t("Exact match position unavailable ({0}). Find is prefilled; it searches loaded messages, not a guessed snippet position.", [matchReason]),"info");
              }
              return;
            }
            if (!routed && version === routeVersion && token === requestEpoch && activePage === "search") {
              openTranscriptFind(document.getElementById("query").value.trim()); await searchFurther();
            }
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
            if (starts("http://") || starts("https://")) {
              let end = i;
              while (end < source.length && !" <>".includes(source.charAt(end)) && source.charCodeAt(end) > 32) end += 1;
              while (end > i && ".,;!?)".includes(source.charAt(end - 1))) end -= 1;
              const url = source.slice(i, end);
              wrap("a", url, function (node) { node.setAttribute("href", url); node.setAttribute("target", "_blank"); node.setAttribute("rel", "noopener noreferrer"); setText(node, url); });
              i = end; continue;
            }
            if (starts("![")) { parent.appendChild(textSpan(t("Image: "))); i += 1; }
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
            while (j < source.length && "`*_~[!".indexOf(source.charAt(j)) < 0 && source.slice(j, j + 7) !== "http://" && source.slice(j, j + 8) !== "https://") j += 1;
            parent.appendChild(textSpan(source.slice(i, j)));
            i = j;
          }
        }
        function copyCode(button) {
          const block = button.closest(".code-block");
          const pre = block && block.querySelector("pre");
          const text = button.dataset.copyText != null ? button.dataset.copyText : pre ? pre.textContent : "";
          if (!button.dataset.copyLabel) button.dataset.copyLabel = button.textContent;
          function failed() { setText(button, t("Copy failed")); toast(t("Copy failed. Select the text and copy it manually."), "danger"); }
          if (!(typeof navigator !== "undefined" && navigator.clipboard && typeof navigator.clipboard.writeText === "function")) { failed(); return; }
          let pending;
          try { pending = Promise.resolve(navigator.clipboard.writeText(text)); } catch (error) { failed(); return; }
          pending.then(function () {
            setText(button, t("Copied ✓"));
            button.dataset.state = "copied";
            toast(t("Copied to clipboard"), "ok");
            if (typeof setTimeout === "function") setTimeout(function () { setText(button, button.dataset.copyLabel || t("Copy")); button.dataset.state = ""; }, 1600);
          }, failed);
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
              setText(label, language || t("Plain text"));
              const button = document.createElement("button");
              button.type = "button";
              button.className = "copy-btn";
              setText(button, t("Copy"));
              button.addEventListener("click", function () { copyCode(button); });
              header.appendChild(label);
              header.appendChild(button);
              const wrap = document.createElement("button"); wrap.type = "button"; setText(wrap, t("Wrap"));
              wrap.addEventListener("click", function () { block.classList.toggle("wrap-code"); wrap.setAttribute("aria-pressed", String(block.classList.contains("wrap-code"))); });
              header.appendChild(wrap);
              const pre = document.createElement("pre");
              const code = document.createElement("code");
              code.setAttribute("data-lang", language);
              renderSyntaxCode(code, codeLines.join(String.fromCharCode(10)), language);
              pre.appendChild(code);
              block.appendChild(header);
              block.appendChild(pre);
              root.appendChild(block);
              continue;
            }
            if (trimmed.indexOf("> ") === 0) {
              flushParagraph();
              const quote = document.createElement("blockquote");
              while (i < lines.length && lines[i].trimStart().indexOf("> ") === 0) {
                const p = document.createElement("p"); appendInline(p, lines[i].trimStart().slice(2)); quote.appendChild(p); i += 1;
              }
              root.appendChild(quote); continue;
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
            if (firstMark) {
              flushParagraph(); const stack = [];
              while (i < lines.length) {
                const clean = lines[i].trimStart(), item = listMarker(clean); if (!item) break;
                const indent = Math.min(40, lines[i].length - clean.length), tag = item.kind === "ol" ? "ol" : "ul";
                while (stack.length && indent < stack[stack.length - 1].indent) stack.pop();
                let level = stack[stack.length - 1];
                if (level && indent === level.indent && tag !== level.tag) { stack.pop(); level = stack[stack.length - 1]; }
                if (!level || indent > level.indent || tag !== level.tag) {
                  const list = document.createElement(tag);
                  if (level && indent > level.indent && level.last) level.last.appendChild(list); else root.appendChild(list);
                  level = { indent: indent, tag: tag, list: list, last: null }; stack.push(level);
                }
                const li = document.createElement("li");
                if (item.kind === "task") li.appendChild(textSpan(item.done ? "☑ " : "☐ "));
                appendInline(li, item.text); level.list.appendChild(li); level.last = li; i += 1;
              }
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
        function detectedThinking(content) {
          return ["<thinking>", "<antThinking>", "[thinking]", "**Thinking:**"].some(function (prefix) { return content.trimStart().indexOf(prefix) === 0; });
        }
        function toolError(text) {
          return String(text || "").split(String.fromCharCode(10)).some(function (line) {
            return /^error:/i.test(line.trimStart()) || line.indexOf("** TEST FAILED **") === 0 || /exit code[: ]+[1-9]/i.test(line);
          });
        }
        function parsedToolInput(value) {
          try { const parsed = JSON.parse(value); return parsed && typeof parsed === "object" ? parsed : {}; } catch (error) { return {}; }
        }
        function copyTextButton(label, text) {
          const button = document.createElement("button"); button.type = "button"; button.className = "copy-btn";
          button.dataset.copyText = text; setText(button, label);
          button.addEventListener("click", function () { copyCode(button); }); return button;
        }
        function codeSection(parent, label, text) {
          const block = document.createElement("div"); block.className = "code-block";
          const header = document.createElement("div"); header.className = "code-header";
          header.appendChild(textSpan(label)); header.appendChild(copyTextButton(t("Copy"), text)); block.appendChild(header);
          const pre = document.createElement("pre"); setText(pre, text); block.appendChild(pre); parent.appendChild(block); return block;
        }
        function renderUnifiedDiff(root, text) {
          const lines = text.split(String.fromCharCode(10)), rows = [];
          let oldLine = 0, newLine = 0, oldLeft = 0, newLeft = 0, seen = false, valid = true;
          lines.forEach(function (line) {
            let kind = "", number = null;
            const match = line.match(/^@@ -([0-9]+)(,([0-9]+))? [+]([0-9]+)(,([0-9]+))? @@/);
            if (match) {
              if (oldLeft || newLeft) valid = false;
              oldLine = Number(match[1]); newLine = Number(match[4]); oldLeft = match[3] == null ? 1 : Number(match[3]); newLeft = match[6] == null ? 1 : Number(match[6]);
              if (![oldLine, newLine, oldLeft, newLeft].every(Number.isSafeInteger)) valid = false;
              seen = true;
            } else if (oldLeft || newLeft) {
              if (line.indexOf("+") === 0) { kind = " diff-add"; number = "— / " + newLine++; newLeft -= 1; }
              else if (line.indexOf("-") === 0) { kind = " diff-del"; number = oldLine++ + " / —"; oldLeft -= 1; }
              else if (line.indexOf(" ") === 0) { number = oldLine++ + " / " + newLine++; oldLeft -= 1; newLeft -= 1; }
              else if (line.charCodeAt(0) !== 92) valid = false;
              if (oldLeft < 0 || newLeft < 0) valid = false;
            } else if (line && !line.startsWith("--- ") && !line.startsWith("+++ ") && !line.startsWith("diff ") && !line.startsWith("index ") && line.charCodeAt(0) !== 92) valid = false;
            rows.push({text:line, kind:kind, number:number});
          });
          if (!seen || !valid || oldLeft || newLeft) return false;
          const pre = document.createElement("pre"); pre.className = "unified-diff";
          const copy = copyTextButton(t("Copy diff"), text); copy.classList.add("diff-copy"); root.appendChild(copy);
          rows.forEach(function (item, index) {
            const row = document.createElement("span"); row.className = "diff-row" + item.kind;
            if (item.number != null) row.setAttribute("data-line-number", item.number);
            setText(row, item.text + (index < rows.length - 1 ? String.fromCharCode(10) : "")); pre.appendChild(row);
          });
          root.appendChild(pre); return true;
        }
        function renderTool(call) {
          const tools = document.createElement("details"); tools.className = "tool-call";
          const input = toolJSON(call.input), output = toolJSON(call.output), args = parsedToolInput(input);
          const failed = toolError(output); if (failed) tools.className += " tool-error";
          const summary = document.createElement("summary");
          const primary = (typeof args.pattern === "string" ? ["pattern"] : ["file_path", "path", "command", "cmd", "url", "query"]).find(function (key) { return typeof args[key] === "string"; });
          fillDisclosure(summary, call.name || t("Tool"), primary ? args[primary] + (primary === "pattern" && args.path ? " · " + args.path : "") : input);
          if (Number.isFinite(args.offset)) summary.appendChild(textSpan(t("Line {0}{1}", [args.offset, Number.isFinite(args.limit) ? t(" · {0} lines", [args.limit]) : ""])));
          if (failed) { const badge = textSpan(t("Error (detected)")); badge.className = "error-label"; summary.appendChild(badge); }
          tools.appendChild(summary);
          const body = document.createElement("div"); body.className = "tool-content";
          const toggle = document.createElement("button"); toggle.type = "button"; toggle.className = "raw-toggle"; setText(toggle, t("Raw")); body.appendChild(toggle);
          const formatted = document.createElement("div"); formatted.className = "tool-formatted";
          const h = document.createElement("h4"); setText(h, t("Input")); formatted.appendChild(h);
          const edits = Array.isArray(args.edits) ? args.edits : [args]; let renderedEdit = false;
          if (/^(edit|multiedit|search_replace|str_replace.*)$/i.test(call.name || "")) edits.forEach(function (edit) {
            const old = edit.old_string != null ? edit.old_string : edit.old_str, next = edit.new_string != null ? edit.new_string : edit.new_str;
            if (typeof old !== "string" || typeof next !== "string") return;
            const nl = String.fromCharCode(10), oldLines = old ? old.split(nl) : [], newLines = next ? next.split(nl) : [];
            const patch = [t("--- provided old text"), t("+++ provided new text"), "@@ -" + (oldLines.length ? 1 : 0) + "," + oldLines.length + " +" + (newLines.length ? 1 : 0) + "," + newLines.length + " @@"].concat(oldLines.map(function (line) { return "-" + line; }), newLines.map(function (line) { return "+" + line; })).join(nl);
            formatted.appendChild(textSpan(t("Provided replacement · relative lines (not file positions)")));
            renderUnifiedDiff(formatted, patch); renderedEdit = true;
          });
          if (!renderedEdit && !renderUnifiedDiff(formatted, input)) codeSection(formatted, /bash|shell/i.test(call.name || "") ? t("$ Command / input") : t("Input"), input || t("not reported"));
          const oh = document.createElement("h4"); setText(oh, t("Output")); formatted.appendChild(oh);
          const result = document.createElement("div"); result.className = "tool-output";
          if (!renderUnifiedDiff(result, output)) codeSection(result, t("Output"), output || t("not reported"));
          formatted.appendChild(result);
          if (output.split(String.fromCharCode(10)).length > 16) {
            const more = document.createElement("button"); more.type = "button"; setText(more, t("Show more output"));
            more.addEventListener("click", function () { result.classList.toggle("expanded"); setText(more, result.classList.contains("expanded") ? t("Show less output") : t("Show more output")); }); formatted.appendChild(more);
          }
          const raw = document.createElement("div"); raw.className = "tool-raw"; raw.hidden = true;
          codeSection(raw, t("Input (raw)"), input); codeSection(raw, t("Output (raw)"), output);
          toggle.addEventListener("click", function () { raw.hidden = !raw.hidden; formatted.hidden = !raw.hidden; setText(toggle, raw.hidden ? t("Raw") : t("Formatted")); });
          body.appendChild(formatted); body.appendChild(raw); tools.appendChild(body); return tools;
        }
        // Deliberately lexical, not a compiler. Unsupported/ambiguous constructs fail plain, never partially color.
        function tokenizeCode(text, language) {
          const aliases = {json:"json",diff:"diff",patch:"diff",sh:"sh",bash:"sh",shell:"sh",swift:"swift",ts:"js",typescript:"js",js:"js",javascript:"js",py:"py",python:"py"};
          const name = String(language).toLowerCase();
          if (!Object.prototype.hasOwnProperty.call(aliases, name) || text.length > 32768) return null;
          const lang = aliases[name], nl = String.fromCharCode(10), slash = String.fromCharCode(92);
          if (text.split(nl).length > 400) return null;
          if (lang === "json") { try { JSON.parse(text); } catch (error) { return null; } }
          const words = {
            json:"true false null",
            sh:"if then else elif fi for in do done case esac while until function select time true false",
            swift:"let var func return if else guard switch case default for in while repeat break continue class struct enum protocol extension import public private internal static async await throws throw try catch do true false nil self init defer as is some actor",
            js:"const let var function return if else switch case default for in of while do break continue class extends new import export from async await throw try catch finally true false null undefined interface type number string boolean public private static typeof instanceof void this yield",
            py:"def class return if else elif for in while break continue import from as try except finally raise with lambda pass yield async await and or not is None True False global nonlocal"
          };
          const keywords = new Set((words[lang] || "").split(" ")), tokens = [];
          function emit(start, end, type) {
            if (end > start) tokens.push({text:text.slice(start,end), type:type || ""});
            return tokens.length <= 2000;
          }
          if (lang === "diff") {
            let start = 0;
            while (start < text.length) {
              let end = text.indexOf(nl, start); end = end < 0 ? text.length : end + 1;
              const c = text.charAt(start), line = text.slice(start,end);
              if (line.trim() && !["+","-"," ",String.fromCharCode(92)].includes(c) && !["@@","diff ","index ","new file ","deleted file ","rename ","similarity ","old mode ","new mode "].some(function (prefix) { return line.indexOf(prefix) === 0; })) return null;
              const type = line.indexOf("@@") === 0 ? "keyword" : c === "+" ? "add" : c === "-" ? "delete" : c === " " ? "" : "comment";
              if (!emit(start,end,type)) return null; start = end;
            }
            return tokens;
          }
          const digit = c => c >= "0" && c <= "9";
          const letter = c => !!c && ((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c === "_" || c === "$");
          let i = 0, plain = 0;
          while (i < text.length) {
            const start = i, c = text.charAt(i), next = text.charAt(i + 1);
            let type = "";
            if ((lang === "sh" || lang === "py") && c === "#" || (lang === "js" || lang === "swift") && c === "/" && next === "/") {
              i = text.indexOf(nl,i); if (i < 0) i = text.length; type = "comment";
            } else if ((lang === "js" || lang === "swift") && c === "/" && next === "*") {
              i += 2; let depth = 1;
              while (i < text.length && depth) {
                if (lang === "swift" && text.slice(i,i + 2) === "/*") { depth += 1; i += 2; }
                else if (text.slice(i,i + 2) === "*/") { depth -= 1; i += 2; } else i += 1;
              }
              if (depth) return null; type = "comment";
            } else if (c === '"' || (lang !== "json" && c === "'") || (lang === "js" && c === "`")) {
              const triple = (lang === "py" || lang === "swift") && text.slice(i,i + 3) === c.repeat(3);
              const delimiter = triple ? c.repeat(3) : c;
              i += delimiter.length; let closed = false;
              while (i < text.length) {
                if (text.slice(i,i + delimiter.length) === delimiter) { i += delimiter.length; closed = true; break; }
                if (c === "`" && text.slice(i,i + 2) === "${") return null;
                if (text.charAt(i) === nl && !triple && c !== "`" && lang !== "sh") return null;
                if (text.charAt(i) === slash && !(lang === "sh" && c === "'")) i += 2; else i += 1;
              }
              if (!closed) return null; type = "string";
            } else if (digit(c) && (i === 0 || !letter(text.charAt(i - 1)))) {
              i += 1;
              while (i < text.length && (digit(text.charAt(i)) || "abcdefABCDEFxXoObBeE._".includes(text.charAt(i)))) i += 1;
              type = "number";
            } else if (letter(c)) {
              i += 1; while (letter(text.charAt(i)) || digit(text.charAt(i))) i += 1;
              if (keywords.has(text.slice(start,i))) type = "keyword";
            } else if (lang === "js" && c === "/") {
              // Slash can introduce a regex or division. Avoid pretending to parse the grammar.
              return null;
            } else i += 1;
            if (type) {
              if (!emit(plain,start,"") || !emit(start,i,type)) return null;
              plain = i;
            }
          }
          return emit(plain,text.length,"") ? tokens : null;
        }
        function renderSyntaxCode(code, text, language) {
          const nl = String.fromCharCode(10), lines = text.split(nl);
          // Keep oversized fallback a single text node; neither tokens nor line wrappers grow without bound.
          if (text.length > 32768 || lines.length > 400) { setText(code,text); return; }
          const tokens = tokenizeCode(text,language);
          const rows = lines.map(function (line,index) {
            const row = document.createElement("span"); row.className = "code-line"; row.setAttribute("data-line-number",String(index + 1));
            if (!tokens) setText(row,line + (index < lines.length - 1 ? nl : ""));
            code.appendChild(row); return row;
          });
          if (!tokens) return;
          let line = 0;
          tokens.forEach(function (token) {
            const parts = token.text.split(nl);
            parts.forEach(function (part,index) {
              const text = part + (index < parts.length - 1 ? nl : "");
              if (text) { const span = document.createElement("span"); if (token.type) span.className = "syntax-" + token.type; setText(span,text); rows[line].appendChild(span); }
              if (index < parts.length - 1) line += 1;
            });
          });
        }
        function renderMessage(role, payload, messageOrdinal) {
          const kind = role === "user" ? "user" : (role === "tool" || role === "system" ? role : "assistant");
          const ordinal = Number.isSafeInteger(messageOrdinal) && messageOrdinal >= 0 ? messageOrdinal : transcriptMessages.length;
          const article = document.createElement("article");
          const tint = kind === "assistant" ? sourceClass(detailSource) : "";
          article.className = tint ? "message " + kind + " " + tint : "message " + kind;
          article.dataset.ordinal = String(ordinal);
          const previous = transcriptMessages[transcriptMessages.length - 1];
          const priorCalls = previous && previous.payload.toolCalls || [], priorCall = priorCalls[priorCalls.length - 1];
          const related = kind === "tool" && priorCall && !priorCall.output;
          if (related) article.classList.add("associated-result");
          const start = kind === "user" || !previous || previous.kind === "system" || (kind === "assistant" && previous.kind === "user");
          article.classList.add(start ? "turn" : "turn-continuation");
          if (kind === "user") { promptNumber += 1; turnUsageNode = null; turnUsage = null; }
          if ((kind === "user" || kind === "assistant") && start) {
            const roleNode = document.createElement("div"); roleNode.className = "role";
            setText(roleNode, kind === "user" ? t("You") : (detailSource ? sourceLabel(detailSource) : (t(role || "assistant")))); article.appendChild(roleNode);
          }
          const meta = document.createElement("div"); meta.className = "message-meta";
          if (kind === "user") meta.appendChild(textSpan(((transcriptMessages.length ? transcriptMessages[0].ordinal : ordinal) > 0 ? t("Loaded prompt #") : t("Prompt #")) + promptNumber));
          if (payload.timestamp) meta.appendChild(textSpan(payload.timestamp));
          const link = document.createElement("a"); link.setAttribute("href", "#/s/" + encodeURIComponent(detailContextSession) + "/m/" + ordinal); setText(link, "#" + ordinal);
          link.setAttribute("aria-label", t("Message {0} permalink", [ordinal]));
          // Addressable ordinal permalink; the jump is fenced and bounded.
          link.addEventListener("click", function (event) { event.preventDefault(); jumpToOrdinal(ordinal); }); meta.appendChild(link);
          if (start) { const copyLink = copyTextButton(t("Copy link"), window.location.origin + "/web" + link.getAttribute("href")); copyLink.className = "permalink-copy"; meta.appendChild(copyLink); }
          if (kind === "assistant") {
            if (!turnUsageNode || start) { turnUsageNode = textSpan(""); turnUsageNode.className = "turn-usage"; turnUsage = { input: 0, output: 0, cache: 0 }; meta.appendChild(turnUsageNode); }
            if (payload.usage && Number.isFinite(payload.usage.inputTokens) && Number.isFinite(payload.usage.outputTokens)) {
              turnUsage.input += payload.usage.inputTokens; turnUsage.output += payload.usage.outputTokens;
              turnUsage.cache += (payload.usage.cacheReadTokens || 0) + (payload.usage.cacheCreationTokens || 0);
              setText(turnUsageNode, t("{0} in → {1} out", [turnUsage.input, turnUsage.output]) + (turnUsage.cache ? t(" · {0} cache", [turnUsage.cache]) : ""));
            }
          }
          article.appendChild(meta);
          const content = payload && payload.content ? String(payload.content) : "";
          const calls = payload && Array.isArray(payload.toolCalls) ? payload.toolCalls : [];
          const thinking = kind === "assistant" && detectedThinking(content);
          let body = null;
          if (kind === "tool" || kind === "system" || thinking) {
            body = document.createElement("details");
            if (thinking) body.className = "thinking";
            const summary = document.createElement("summary");
            fillDisclosure(summary, thinking ? t("Thinking (detected)") : kind === "tool" ? (related ? t("Result · {0} (proximity)", [priorCall.name || t("Tool")]) : t("Result")) : content.indexOf("<teammate-message") === 0 ? t("System · Agent communication (detected)") : content.indexOf("<") === 0 ? t("System · Hook / meta (detected)") : t("System prompt"), content);
            if (kind === "tool" && toolError(content)) {
              body.classList.add("tool-error"); const badge = textSpan(t("Error (detected)")); badge.className = "error-label"; summary.appendChild(badge);
            }
            body.appendChild(summary); const pre = document.createElement("pre"); setText(pre, content); body.appendChild(pre); article.appendChild(body);
          } else if (content.trim() || calls.length === 0) {
            body = document.createElement("div"); body.className = "body"; renderRichText(body, content); article.appendChild(body);
            ["h1", "h2", "h3", "h4", "h5", "h6"].forEach(function (tag) { body.querySelectorAll(tag).forEach(function (heading) {
              const anchor = document.createElement("a"); anchor.className = "heading-link"; anchor.setAttribute("href", link.getAttribute("href")); setText(anchor, "#");
              anchor.setAttribute("aria-label", t("Link to message {0}", [ordinal])); anchor.addEventListener("click", function (event) { event.preventDefault(); jumpToOrdinal(ordinal); }); heading.appendChild(anchor);
            }); });
          }
          const toolNodes = calls.map(function (call) { const node = renderTool(call); article.appendChild(node); return node; });
          const item = { ordinal: ordinal, kind: kind, thinking: thinking, content: content, payload: payload, article: article, body: body, tools: toolNodes, error: toolError(content) || toolNodes.some(function (node) { return node.classList.contains("tool-error"); }) };
          transcriptMessages.push(item); messagesNode.appendChild(article);
          // Batch derived controls after a fragment page, not once per message (important for long sessions).
          if (!messageRequest) updateTranscript();
        }
        const transcriptTypes = [["all", t("All")], ["user", t("You")], ["assistant", t("Agent")], ["tools", t("Tools")], ["thinking", t("Thinking")], ["errors", t("Errors")], ["system", t("System")]];
        function transcriptMatches(item, type) {
          if (type === "all") return true;
          if (type === "tools") return item.kind === "tool" || item.tools.length > 0;
          if (type === "thinking") return item.thinking;
          if (type === "errors") return item.error;
          return item.kind === type && !item.thinking;
        }
        function updateTranscript() {
          const filters = document.getElementById("transcript-filters");
          const focusedType = filters.contains(document.activeElement) && document.activeElement.dataset.type;
          setText(filters, "");
          transcriptTypes.forEach(function (type) {
            const count = type[0] === "tools" ? transcriptMessages.reduce(function (n, item) { return n + item.tools.length + (item.kind === "tool" ? 1 : 0); }, 0) : transcriptMessages.filter(function (item) { return transcriptMatches(item, type[0]); }).length;
            const button = document.createElement("button"); button.type = "button"; button.dataset.type = type[0]; setText(button, type[1] + " " + count);
            filters.setAttribute("aria-label", t("Message types in loaded messages"));
            button.setAttribute("aria-pressed", String(transcriptFilter === type[0]));
            button.addEventListener("click", function () { transcriptFilter = type[0]; transcriptStep = -1; updateTranscript(); }); filters.appendChild(button);
            if (focusedType === type[0]) focusVisible(button);
          });
          transcriptMessages.forEach(function (item) {
            item.article.hidden = !transcriptMatches(item, transcriptFilter);
            if (item.body) item.body.hidden = transcriptFilter === "tools" && item.kind !== "tool";
            item.tools.forEach(function (node) { node.hidden = !["all", "tools", "errors"].includes(transcriptFilter); });
          });
          setText(document.getElementById("transcript-loaded"), (messageTotal == null ? t("{0} loaded", [transcriptMessages.length]) : t("{0} of {1} loaded", [transcriptMessages.length, messageTotal])) + (messageCursor ? t(" · more available") : ""));
          document.getElementById("transcript-load-all").hidden = !messageCursor;
          document.getElementById("transcript-load-all").disabled = transcriptAllBusy;
          if (messageCursor) setText(moreMessagesNode, t("Load more ({0} loaded)", [transcriptMessages.length]));
          renderTranscriptOutline(); renderTranscriptMinimap(); updateDetailInfoCoverage(); updateTranscriptFind();
        }
        function renderTranscriptOutline() {
          const root = document.getElementById("transcript-outline"); setText(root, "");
          const entries = outlineEntries.length ? outlineEntries : transcriptMessages.map(function (item) { return { index: item.ordinal, role: item.kind, preview: item.content, timestamp:item.payload.timestamp }; });
          entries.forEach(function (entry, i) {
            if (entry.role !== "user") return;
            const loaded = transcriptMessages.find(function (item) { return item.ordinal === entry.index; });
            const next = entries.slice(i + 1).find(function (candidate) { return candidate.role === "user"; });
            // Timeline pages can lag behind decoded messages. Use either source's next real prompt.
            const nextLoaded = transcriptMessages.find(function (item) { return item.kind === "user" && item.ordinal > entry.index; });
            const end = Math.min(next ? next.index : Infinity, nextLoaded ? nextLoaded.ordinal : Infinity);
            const toolNames = new Map();
            const tools = transcriptMessages.filter(function (item) { return item.ordinal >= entry.index && item.ordinal < end; }).reduce(function (sum, item) { (item.payload.toolCalls || []).forEach(function (call) { const name = call.name || t("Tool"); toolNames.set(name, (toolNames.get(name) || 0) + 1); }); return sum + item.tools.length; }, 0);
            const button = document.createElement("button"); button.type = "button"; button.dataset.ordinal = String(entry.index);
            setText(button, t("#{0} · {1} · {2} tools in loaded{3}{4}{5}", [entry.index, clipPreview(entry.preview), tools, toolNames.size ? " (" + Array.from(toolNames).map(function (pair) { return pair[1] + " " + pair[0]; }).join(" · ") + ")" : "", entry.timestamp ? " · " + recordedTime(entry.timestamp) : "", loaded ? "" : t(" · not loaded")]));
            button.setAttribute("aria-current", String(activeOutlineOrdinal === entry.index));
            button.addEventListener("click", function () { jumpToOrdinal(entry.index); }); root.appendChild(button);
          });
        }
        // An ordinal coverage strip, not a fabricated pixel-density thumbnail. At most 120 range buttons.
        function renderTranscriptMinimap() {
          const root = document.getElementById("transcript-minimap");
          const focused = root.contains(document.activeElement) ? document.activeElement.dataset.start : null;
          setText(root, "");
          if (!minimapOpen) return;
          const loaded = new Set(transcriptMessages.map(function (item) { return item.ordinal; }));
          const known = new Set(outlineEntries.map(function (entry) { return entry.index; }));
          let extent = 0;
          loaded.forEach(function (ordinal) { extent = Math.max(extent,ordinal + 1); });
          known.forEach(function (ordinal) { extent = Math.max(extent,ordinal + 1); });
          const reported = Number.isSafeInteger(messageTotal) ? messageTotal : detailTimeline.total;
          const total = Math.max(extent, Number.isSafeInteger(reported) ? reported : 0);
          const count = Math.min(total,120), quotient = Math.floor(total / (count || 1)), remainder = total % (count || 1);
          const groups = [];
          for (let i = 0, start = 0; i < count; i += 1) {
            const size = quotient + (i < remainder ? 1 : 0);
            groups.push({start:start,end:start + size - 1,loaded:0,known:0}); start += size;
          }
          function groupFor(ordinal) {
            // Bounded binary search avoids a total-sized array even for sparse, huge sessions.
            let lo = 0, hi = groups.length - 1;
            while (lo <= hi) { const mid = Math.floor((lo + hi) / 2), g = groups[mid]; if (ordinal < g.start) hi = mid - 1; else if (ordinal > g.end) lo = mid + 1; else return g; }
            return null;
          }
          loaded.forEach(function (ordinal) { const group = groupFor(ordinal); if (group) group.loaded += 1; });
          known.forEach(function (ordinal) { const group = groupFor(ordinal); if (group) group.known += 1; });
          groups.forEach(function (group) {
            const button = document.createElement("button"); button.type = "button";
            button.setAttribute("data-start",String(group.start)); button.setAttribute("data-end",String(group.end));
            button.dataset.loaded = String(group.loaded); button.dataset.known = String(group.known);
            const size = group.end - group.start + 1;
            button.className = group.loaded === size ? "map-loaded" : group.loaded ? "map-partial" : "map-unloaded";
            const label = t("Jump to #{0}{1} · {2} / {3} loaded · {4} timeline known{5}", [group.start, size > 1 ? t(" · range #{0}–#{1}", [group.start, group.end]) : "", group.loaded, size, group.known, group.loaded < size ? t(" · not loaded in part or whole") : ""]);
            button.title = label; button.setAttribute("aria-label", label); setText(button, String(group.start));
            button.addEventListener("click", function () { jumpToOrdinal(group.start); });
            root.appendChild(button);
            if (focused === String(group.start)) focusVisible(button);
          });
          const visible = transcriptMessages.filter(function (item) { return !item.article.hidden; }).length;
          setText(document.getElementById("transcript-minimap-status"), t("{0} / {1} loaded · {2} visible · {3} timeline known. {4}Unloaded targets: at most 5 pages per jump; try again to continue.", [loaded.size, reported == null ? t("{0}+ known ordinal extent (total unknown)", [total]) : total, visible, known.size, total > 120 ? t("Grouped ordinal ranges; jumps target each range start. ") : ""]));
          document.getElementById("transcript-minimap-more").hidden = detailTimeline.loaded && detailTimeline.next == null;
          setText(document.getElementById("transcript-minimap-more"), detailTimeline.loaded ? t("More map timeline") : t("Load map timeline (optional)"));
          updateMinimapViewport();
        }
        function updateMinimapViewport() {
          if (!minimapOpen) return;
          const visible = [];
          if (!document.getElementById("transcript-panel").hidden) transcriptMessages.forEach(function (item) {
            if (item.article.hidden || typeof item.article.getBoundingClientRect !== "function") return;
            const rect = item.article.getBoundingClientRect();
            const height = window.innerHeight;
            const header = document.getElementById("detail-header");
            const top = typeof header.getBoundingClientRect === "function" ? header.getBoundingClientRect().bottom : 0;
            if (Number.isFinite(height) && rect.bottom > Math.max(0,top) && rect.top < height) visible.push(item.ordinal);
          });
          const inView = new Set(visible);
          document.getElementById("transcript-minimap").querySelectorAll("button").forEach(function (button) {
            const start = Number(button.dataset.start), end = Number(button.dataset.end);
            button.setAttribute("aria-current",String(minimapSelected != null && minimapSelected >= start && minimapSelected <= end));
            button.setAttribute("data-viewport",String(visible.some(function (ordinal) { return ordinal >= start && ordinal <= end; })));
          });
          setText(document.getElementById("transcript-minimap-position"), t("{0} · Viewport: {1}", [minimapSelected == null ? t("No jump selected") : t("Selected #{0}{1}", [minimapSelected, transcriptMessages.some(function (item) { return item.ordinal === minimapSelected; }) ? t(" · loaded") : t(" · not loaded")]), inView.size ? t("#{0}–#{1} ({2} visible messages)", [visible[0], visible[visible.length - 1], inView.size]) : t("no transcript messages in view")]));
        }
        let jumpVersion = 0;
        async function jumpToOrdinal(ordinal, routed) {
          if (!Number.isSafeInteger(ordinal) || ordinal < 0) return;
          const version = ++jumpVersion;
          minimapSelected = ordinal; updateMinimapViewport();
          if (!routed && detailContextSession) writeRoute({page:"detail",id:detailContextSession,ordinal:ordinal});
          const token = requestEpoch, budget = {remaining:5};
          while (!transcriptMessages.some(function (item) { return item.ordinal === ordinal; }) && messageCursor && budget.remaining > 0 && token === requestEpoch && version === jumpVersion) {
            if (messageRequest) break;
            try { await loadMessages(token, messageSessionId, messageGeneration, messageCursor, budget); }
            catch (error) { if (token === requestEpoch && version === jumpVersion) toast(t("Message could not be loaded. Try the link again."), "danger"); return; }
          }
          if (token !== requestEpoch) return;
          if (version !== jumpVersion) return;
          updateMinimapViewport();
          const item = transcriptMessages.find(function (candidate) { return candidate.ordinal === ordinal; });
          if (!item) { toast(messageCursor ? t("Message not loaded. Use Load more or try the link again (5-page jump limit).") : t("Message missing from the available transcript."), "warning"); return; }
          transcriptFilter = "all"; activeOutlineOrdinal = ordinal; updateTranscript();
          if (typeof item.article.scrollIntoView === "function") item.article.scrollIntoView({ block: "start", behavior: "instant" });
          item.article.classList.add("jump-target");
          if (typeof setTimeout === "function") setTimeout(function () { item.article.classList.remove("jump-target"); }, 2000);
        }
        let outlineScrollScheduled = false;
        window.addEventListener("scroll", function () {
          if ((!outlineOpen && !minimapOpen) || outlineScrollScheduled) return;
          function update() {
            outlineScrollScheduled = false;
            updateMinimapViewport();
            if (!outlineOpen) return;
            let ordinal = null;
            transcriptMessages.forEach(function (item) {
              if (item.kind === "user" && typeof item.article.getBoundingClientRect === "function" && item.article.getBoundingClientRect().top <= 210) ordinal = item.ordinal;
            });
            if (ordinal !== activeOutlineOrdinal) {
              activeOutlineOrdinal = ordinal;
              document.getElementById("transcript-outline").querySelectorAll("button").forEach(function (button) { button.setAttribute("aria-current", String(Number(button.dataset.ordinal) === ordinal)); });
            }
          }
          if (typeof requestAnimationFrame === "function") { outlineScrollScheduled = true; requestAnimationFrame(update); } else update();
        });
        async function loadAllMessages() {
          if (transcriptAllBusy || messageRequest) return;
          const token = requestEpoch, version = detailExtrasVersion; transcriptAllBusy = true; updateTranscript();
          try {
            let pages = 0;
            while (messageCursor && token === requestEpoch && version === detailExtrasVersion && pages < 100) {
              const cursor = messageCursor; await loadMessages(token, messageSessionId, messageGeneration, cursor); pages += 1;
              if (cursor === messageCursor) break;
              // Yield between pages. No eagerly fetched huge-session history on opening.
              if (typeof requestAnimationFrame === "function") await new Promise(function (resolve) { requestAnimationFrame(resolve); });
            }
          } catch (error) { if (token === requestEpoch) toast(t("Could not load more messages. Retry Load more."), "danger"); }
          finally { if (token === requestEpoch && version === detailExtrasVersion) { transcriptAllBusy = false; updateTranscript(); } }
        }
        function detailInfoCoverage() {
          return { "Loaded messages": transcriptMessages.length, "Generation message count": messageTotal,
            "Truncation": detailMessageCoverage && detailMessageCoverage.truncatedAt, "Parse failure": detailMessageCoverage && detailMessageCoverage.parseFailure };
        }
        function updateDetailInfoCoverage() {
          const values = detailInfoCoverage();
          document.getElementById("detail-info-content").querySelectorAll(".info-coverage").forEach(function (node) {
            const value = values[node.dataset.coverage]; setText(node, value == null || value === "" ? t("not reported") : String(value));
          });
        }
        async function loadDetailInfo() {
          if (!detailContextSession || (detailInfoBusy && detailInfoEpoch === requestEpoch)) return;
          const id = detailContextSession, token = requestEpoch, version = detailExtrasVersion;
          const root = document.getElementById("detail-info-content"); detailInfoBusy = true; detailInfoEpoch = token; setText(root, t("Loading session info…"));
          const params = new URLSearchParams({sessionId:id, agents:"all", limit:"1"});
          try {
            const results = await Promise.all([
              api("GET", "/web/api/costs/sessions?" + params).catch(function () { return null; }),
              api("GET", "/web/api/costs?" + new URLSearchParams({sessionId:id, agents:"all", groupBy:"model", limit:"100"})).catch(function () { return null; })
            ]);
            // Each read can expire the session while its sibling succeeds.
            if (token !== requestEpoch || version !== detailExtrasVersion || id !== detailContextSession) return;
            setText(root, ""); const dl = document.createElement("dl"); root.appendChild(dl);
            function field(label, value) { const dt = document.createElement("dt"), dd = document.createElement("dd"); setText(dt, label); setText(dd, value == null || value === "" ? t("not reported") : String(value)); dl.appendChild(dt); dl.appendChild(dd); return dd; }
            const detail = detailInfoDetail || {}, session = detail.session || {}, identity = session.captureIdentity || {};
            field(t("Session ID"), id); root.appendChild(copyTextButton(t("Copy session ID"), id));
            const native = field(t("Native ID"), session.nativeId), machine = field(t("Machine ID"), identity.machineId);
            if (session.nativeId) native.appendChild(copyTextButton(t("Copy native ID"), session.nativeId));
            if (identity.machineId) machine.appendChild(copyTextButton(t("Copy machine ID"), identity.machineId)); field(t("Source"), session.source ? sourceLabel(session.source) : null);
            const project = field(t("Project"), session.projectLabel || session.projectKey);
            if (session.projectKey) {
              const filter = document.createElement("button"); filter.type = "button"; setText(filter, t("Sessions in project"));
              filter.addEventListener("click", function () {
                facets.project.selected.clear(); facets.project.selected.set(session.projectKey, session.projectLabel || session.projectKey);
                updateFacetSummary("project"); renderFacets("project"); showSessionList(); refreshLibrary().catch(function () {});
              }); project.appendChild(filter);
            }
            field(t("Generation"), detail.transcriptGeneration);
            field(t("Transcript"), detail.transcriptAvailability ? t(detail.transcriptAvailability) : null); field(t("Attempt"), detail.currentAttempt ? [t(detail.currentAttempt.status || "unknown"), detail.currentAttempt.failureCode].filter(Boolean).join(" · ") : null);
            const perSession = results[0] && Array.isArray(results[0].items) ? results[0].items.find(function (item) { return item.session && item.session.sessionId === id; }) : null;
            const costs = results[1], totals = costs && costs.totals;
            field(t("Model"), perSession && perSession.model);
            field(t("Cost (USD)"), perSession && Number.isFinite(perSession.costUsd) ? "$" + perSession.costUsd.toFixed(2) : null);
            ["inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens"].forEach(function (key) { field(t(key), perSession && Number.isFinite(perSession[key]) ? perSession[key] : totals && Number.isFinite(totals[key]) ? totals[key] : null); });
            if (costs && Array.isArray(costs.items)) costs.items.forEach(function (item) { field(t("Model usage · {0}", [item.label]), Number.isFinite(item.inputTokens) && Number.isFinite(item.outputTokens) ? t("{0} in → {1} out", [item.inputTokens, item.outputTokens]) : null); });
            field(t("Unpriced coverage"), costs ? (costs.unpricedUnattributedSessions == null ? t("not reported") : t("{0} unattributed sessions", [costs.unpricedUnattributedSessions])) + " · " + (costs.unpricedNoPriceSessions == null ? t("not reported") : t("{0} sessions without price", [costs.unpricedNoPriceSessions])) : null);
            const coverage = detailInfoCoverage();
            Object.keys(coverage).forEach(function (label) { const node = field(t(label), coverage[label]); node.className = "info-coverage"; node.dataset.coverage = label; });
            const note = document.createElement("p"); setText(note, t("Missing values are not reported, not zero. Model comes only from recorded session cost data; it is never inferred from the source.")); root.appendChild(note);
            if (!results[0] || !results[1]) {
              const missing = document.createElement("p"); setText(missing, t("Cost data unavailable. Missing values are not reported.")); root.appendChild(missing);
              const retry = document.createElement("button"); retry.type = "button"; setText(retry, t("Retry cost data")); retry.addEventListener("click", loadDetailInfo); root.appendChild(retry);
            }
            detailInfoLoaded = true;
          } finally { if (detailInfoEpoch === token && version === detailExtrasVersion) detailInfoBusy = false; }
        }
        document.getElementById("transcript-minimap-toggle").addEventListener("click", function () {
          minimapOpen = !minimapOpen; document.getElementById("transcript-minimap-box").hidden = !minimapOpen;
          this.setAttribute("aria-expanded",String(minimapOpen)); renderTranscriptMinimap();
        });
        document.getElementById("transcript-minimap-more").addEventListener("click", function () { loadDetailTimeline(detailTimeline.loaded); });
        document.getElementById("transcript-minimap").addEventListener("keydown", function (event) {
          if (!event || event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
          const buttons = Array.from(this.querySelectorAll("button")), index = buttons.indexOf(event.target);
          if (index < 0) return;
          const next = event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 : ["ArrowRight","ArrowDown"].includes(event.key) ? Math.min(index + 1,buttons.length - 1) : ["ArrowLeft","ArrowUp"].includes(event.key) ? Math.max(0,index - 1) : -1;
          if (next >= 0) { event.preventDefault(); focusVisible(buttons[next]); }
        });
        window.addEventListener("resize", function () { updateMinimapViewport(); });
        document.getElementById("transcript-outline-toggle").addEventListener("click", function () {
          outlineOpen = !outlineOpen; document.getElementById("transcript-outline-box").hidden = !outlineOpen; document.getElementById("transcript-outline-box").open = outlineOpen;
          this.setAttribute("aria-expanded", String(outlineOpen));
          if (outlineOpen && !detailTimeline.loaded) loadDetailTimeline(false); else renderTranscriptOutline();
        });
        document.getElementById("transcript-outline-more").addEventListener("click", function () { loadDetailTimeline(true); });
        document.getElementById("transcript-load-all").addEventListener("click", loadAllMessages);
        document.getElementById("transcript-end").addEventListener("click", function () { const last = transcriptMessages[transcriptMessages.length - 1]; if (last) jumpToOrdinal(last.ordinal); });
        ["previous", "next"].forEach(function (direction) { document.getElementById("transcript-" + direction).addEventListener("click", function () {
          const matches = transcriptMessages.filter(function (item) { return transcriptMatches(item, transcriptFilter); });
          if (!matches.length) return; transcriptStep = (transcriptStep + (direction === "next" ? 1 : -1) + matches.length) % matches.length;
          const item = matches[transcriptStep]; if (typeof item.article.scrollIntoView === "function") item.article.scrollIntoView({block:"start"});
        }); });
        document.getElementById("transcript-copy-id").addEventListener("click", function () { this.dataset.copyText = detailContextSession; copyCode(this); });
        document.getElementById("transcript-copy").addEventListener("click", function () {
          this.dataset.copyText = transcriptMessages.map(function (item) { return "## " + item.kind + " (#" + item.ordinal + ")" + String.fromCharCode(10) + item.content + (item.payload.toolCalls || []).map(function (call) { return String.fromCharCode(10) + (call.name || t("Tool")) + String.fromCharCode(10) + toolJSON(call.input) + String.fromCharCode(10) + toolJSON(call.output); }).join(""); }).join(String.fromCharCode(10, 10)); copyCode(this);
        });
        function acceptFragment(fragment) {
          const piece = encoder.encode(fragment.payloadFragment || "");
          const ordinal = fragment.messageOrdinal;
          const hash = fragment.payloadSHA256;
          if (!messageBuf || messageBuf.ordinal !== ordinal || messageBuf.hash !== hash) {
            if (messageBuf) {
              setStatus(t("incomplete message"));
              return;
            }
            if (fragment.utf8Offset !== 0) {
              setStatus(t("invalid fragment offset"));
              return;
            }
            messageBuf = { ordinal: ordinal, hash: hash, chunks: [piece], bytes: piece.length, role: fragment.role };
          } else {
            if (fragment.utf8Offset !== messageBuf.bytes) {
              setStatus(t("invalid fragment offset"));
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
            renderMessage(messageBuf.role, JSON.parse(text), messageBuf.ordinal);
            messageBuf = null;
          }
        }
        async function loadMessages(token, sessionId, generation, cursor, budget) {
          if (budget && budget.remaining <= 0) return;
          if (messageRequest && messageRequest.token === token && messageRequest.sessionId === sessionId
              && messageRequest.generation === generation && messageRequest.cursor === cursor) return;
          const pending = { token: token, sessionId: sessionId, generation: generation, cursor: cursor };
          messageRequest = pending;
          messageSessionId = sessionId;
          messageGeneration = generation;
          let path = "/web/api/sessions/" + encodeURIComponent(sessionId) + "/messages?generation=" + encodeURIComponent(generation) + "&maxFragments=100";
          if (cursor) path += "&cursor=" + encodeURIComponent(cursor);
          try {
            if (budget) budget.remaining -= 1;
            const page = await api("GET", path);
            if (token !== requestEpoch) return;
            if ((page.sessionId != null && page.sessionId !== sessionId) || (page.generation != null && page.generation !== generation)) throw new Error("changed generation");
            detailMessageCoverage = {truncatedAt:page.truncatedAt, parseFailure:page.parseFailure};
            (page.fragments || []).forEach(acceptFragment);
            if (page.nextCursor && page.nextCursor === cursor) throw new Error("repeated message cursor");
            messageCursor = page.nextCursor || "";
            updateMessageMore(); updateTranscript();
            if (messageBuf && !messageCursor) setStatus(t("incomplete message"));
            if (messageBuf && messageCursor) {
              if (messageRequest === pending) messageRequest = null;
              await loadMessages(token, sessionId, generation, messageCursor, budget);
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
        document.getElementById("query").addEventListener("input", function (event) {
          bumpEpoch();
          if (event.isComposing || workspaceNode.hidden || !["sessions","search"].includes(activePage)) return;
          const input = document.getElementById("query"), value = input.value.trim(), version = searchInputVersion;
          const length = Array.from(value).length, minimum = activePage === "search" ? 2 : 3;
          if (length && length < minimum) {
            setStatus(t("Short query: submit manually, or open Search for short terms."));
            setText(document.getElementById("search-result-status"), t("Short query: submit manually{0}", [activePage === "sessions" ? t(" or use Search for 1–2 character terms.") : t(" to search this term.")]));
            return;
          }
          if (typeof setTimeout === "function") searchTimer = setTimeout(function () {
            searchTimer = null;
            if (version === searchInputVersion && !workspaceNode.hidden && !workspaceNode.classList.contains("showing-detail")) refreshLibrary().catch(function () {});
          },350);
        });
        document.getElementById("query").addEventListener("compositionend", function () {
          // A final input normally follows compositionend; scheduling again simply replaces the timer.
          const input = document.getElementById("query");
          if (typeof Event === "function" && typeof input.dispatchEvent === "function") input.dispatchEvent(new Event("input", {bubbles:true}));
        });
        document.getElementById("search").addEventListener("submit", function (event) {
          event.preventDefault();
          bumpEpoch();
          refreshLibrary().catch(function () {});
        });
        ["hide", "all", "only"].forEach(function (choice) {
          document.getElementById("agents-" + choice).addEventListener("click", function () {
            setAgentFilter(choice);
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
        // Facet popovers close on an outside click or Escape (focus returns to the summary).
        document.addEventListener("click", function (event) {
          const target = event && event.target;
          if (!target) return;
          ["source", "project"].forEach(function (kind) {
            const picker = document.getElementById(kind + "-picker");
            if (picker.open && typeof picker.contains === "function" && !picker.contains(target)) picker.open = false;
          });
        });
        // Commands are fixed enums plus opaque session IDs, never executable content.
        function commandState() {
          return JSON.stringify([requestEpoch, routeVersion, detailExtrasVersion, detailContextSession, detailContextGeneration]);
        }
        function commandPaletteVisible() {
          const dialog = document.getElementById("command-dialog");
          return !workspaceNode.hidden && activeModal === dialog && dialog.open && !dialog.hidden;
        }
        function closeCommandPalette(restoreFocus) {
          closeModal(document.getElementById("command-dialog"), restoreFocus === true);
          commandRevision += 1; commandResults = []; commandIndex = -1; commandContext = null;
          document.getElementById("command-query").value = "";
          document.getElementById("command-query").removeAttribute("aria-activedescendant");
          setText(document.getElementById("command-results"), "");
          setText(document.getElementById("command-status"), "");
          setText(document.getElementById("command-scope"), "");
        }
        function availableCommands() {
          if (workspaceNode.hidden) return [];
          const result = ["sessions", "search", "dashboard", "stats", "health", "fleet", "settings", "insights"].map(function (page) {
            const english = page === "fleet" ? "Machines · Fleet" : page[0].toUpperCase() + page.slice(1);
            return {kind:"page", value:page, label:t(english), searchLabels:[english, uiMessages[english]], scope:t("Page")};
          });
          commandSessions.forEach(function (item) { result.push({kind:"session", value:item.id, label:item.label, scope:t("Loaded session")}); });
          if (workspaceNode.classList.contains("showing-detail") && detailContextSession) {
            const add = function (value, label) { result.push({kind:"action", value:value, label:t(label), searchLabels:[label, uiMessages[label]], scope:t("Current session")}); };
            add("info", "Session info");
            if (detailContextGeneration) {
              add("find", "Find in loaded messages");
              add("minimap", "Toggle transcript minimap");
              add("access", "Session actions & edit access");
              // Writes stay in their existing UI. Unknown/viewer authority never advertises them.
              if (sessionActionCanWrite === true && !sessionActionPending) {
                add("summary", "Review summary generation…"); add("title", "Review title generation…");
              }
            }
            if (typeof navigator !== "undefined" && navigator.clipboard && typeof navigator.clipboard.writeText === "function") add("copy", "Copy session ID");
          }
          return result;
        }
        function commandScore(label, query) {
          const text = label.slice(0, 512).toLowerCase(), q = query.trim().toLowerCase().slice(0, 120);
          if (!q) return 0;
          if (text === q) return 0;
          if (text.startsWith(q)) return 100 + Math.min(99, text.length - q.length);
          const at = text.indexOf(q);
          if (at >= 0) return 200 + Math.min(99, at);
          let pos = -1, first = -1, gaps = 0;
          for (let i = 0; i < q.length; i += 1) {
            const next = text.indexOf(q[i], pos + 1);
            if (next < 0) return -1;
            if (first < 0) first = next; else gaps += next - pos - 1;
            pos = next;
          }
          return 300 + gaps + first;
        }
        function commandMatchScore(item, query) {
          const scores = [item.label].concat(item.searchLabels || []).filter(Boolean).map(function (label) { return commandScore(label, query); }).filter(function (score) { return score >= 0; });
          return scores.length ? Math.min.apply(null, scores) : -1;
        }
        function selectCommand(index) {
          commandIndex = commandResults.length ? (index + commandResults.length) % commandResults.length : -1;
          const input = document.getElementById("command-query"), rows = document.getElementById("command-results").children;
          Array.from(rows).forEach(function (row, i) { row.setAttribute("aria-selected", String(i === commandIndex)); });
          if (commandIndex < 0) input.removeAttribute("aria-activedescendant");
          else {
            input.setAttribute("aria-activedescendant", "command-option-" + commandIndex);
            if (rows[commandIndex] && typeof rows[commandIndex].scrollIntoView === "function") rows[commandIndex].scrollIntoView({block:"nearest"});
          }
        }
        function renderCommands() {
          if (!commandPaletteVisible()) return;
          commandRevision += 1;
          const revision = commandRevision, query = document.getElementById("command-query").value;
          const matches = availableCommands().map(function (item, order) { return {item:item, order:order, score:commandMatchScore(item, query)}; })
            .filter(function (match) { return match.score >= 0; }).sort(function (a,b) { return a.score - b.score || a.order - b.order; });
          commandResults = matches.slice(0, 60).map(function (match) { return match.item; });
          const root = document.getElementById("command-results"); setText(root, "");
          commandResults.forEach(function (item, index) {
            const row = document.createElement("div"), title = document.createElement("span"), scope = document.createElement("span");
            row.setAttribute("id", "command-option-" + index); row.setAttribute("role", "option"); row.className = "command-option";
            setText(title, item.label); scope.className = "meta"; setText(scope, item.scope); row.appendChild(title); row.appendChild(scope);
            row.addEventListener("click", function () { dispatchCommand(index, revision); }); root.appendChild(row);
          });
          setText(document.getElementById("command-scope"), t("Pages, current-session actions and {0}; not global search. Open Search for the full library.", [plural(commandSessions.length, t("loaded session"))]));
          setText(document.getElementById("command-status"), matches.length ? plural(matches.length, "command") + (matches.length > 60 ? t(" · showing first 60; refine your query") : "") : t("No commands match. Try a page or loaded session title."));
          selectCommand(0);
        }
        function openCommandPalette() {
          if (workspaceNode.hidden || activeModal || (typeof document.querySelector === "function" && document.querySelector("dialog[open]"))) return;
          closeCommandPalette();
          commandContext = commandState();
          openModal(document.getElementById("command-dialog"), document.getElementById("command-query"));
          renderCommands();
        }
        async function reviewCommandAction(action, id, generation, version) {
          // Reuse the route/tab and lazy cookie-access checks; generating still needs its normal button.
          document.getElementById("detail-view-info").click();
          const box = document.getElementById("session-actions"); box.open = true;
          const token = requestEpoch, route = routeVersion;
          await loadSessionActionAccess();
          if (activeModal || token !== requestEpoch || route !== routeVersion || workspaceNode.hidden || id !== detailContextSession || generation !== detailContextGeneration || version !== detailExtrasVersion) return;
          if (sessionActionCanWrite === true && ["summary", "title"].includes(action)) focusVisible(document.getElementById("session-generate-" + action));
          else { const status = document.getElementById("session-action-status"); status.setAttribute("tabindex", "-1"); focusVisible(status); }
        }
        function dispatchCommand(index, revision) {
          if (!commandPaletteVisible() || revision !== commandRevision) return;
          const item = commandResults[index];
          if (!item) return;
          if (commandContext !== commandState() || !availableCommands().some(function (current) { return current.kind === item.kind && current.value === item.value; })) { closeCommandPalette(true); return; }
          const id = detailContextSession, generation = detailContextGeneration, version = detailExtrasVersion;
          closeCommandPalette(true);
          if (item.kind === "page") navigate(item.value).catch(function () {});
          else if (item.kind === "session") openDetail(item.value).catch(function () {});
          else if (item.kind === "action") {
            if (item.value === "info") document.getElementById("detail-view-info").click();
            else if (item.value === "copy") document.getElementById("transcript-copy-id").click();
            else if (["access", "summary", "title"].includes(item.value)) reviewCommandAction(item.value, id, generation, version).catch(function () {});
            else if (["find", "minimap"].includes(item.value)) {
              document.getElementById("detail-view-transcript").click();
              if (item.value === "find") openTranscriptFind();
              else { document.getElementById("transcript-minimap-toggle").click(); focusVisible(document.getElementById("transcript-minimap-toggle")); }
            }
          }
        }
        document.getElementById("command-trigger").addEventListener("click", openCommandPalette);
        document.getElementById("command-close").addEventListener("click", function () { closeCommandPalette(true); });
        document.getElementById("command-dialog").addEventListener("cancel", function (event) { event.preventDefault(); closeCommandPalette(true); });
        document.getElementById("command-query").addEventListener("input", function (event) { if (!event.isComposing) renderCommands(); });
        document.getElementById("command-query").addEventListener("compositionstart", function () {
          commandRevision += 1; commandResults = []; commandIndex = -1;
          setText(document.getElementById("command-results"), ""); document.getElementById("command-query").removeAttribute("aria-activedescendant");
        });
        document.getElementById("command-query").addEventListener("compositionend", renderCommands);
        function editableTarget(target) {
          let node = target;
          while (node) {
            if (["INPUT","TEXTAREA","SELECT"].includes(node.tagName) || node.isContentEditable || (typeof node.getAttribute === "function" && ["", "true", "plaintext-only"].includes(node.getAttribute("contenteditable")))) return true;
            node = node.parentNode;
          }
          return false;
        }
        function closeShortcuts(restoreFocus) { closeModal(document.getElementById("shortcuts-dialog"), restoreFocus === true); }
        function openShortcuts() { if (!workspaceNode.hidden) openModal(document.getElementById("shortcuts-dialog"), document.getElementById("shortcuts-close")); }
        document.addEventListener("focusin", function (event) {
          if (activeModal && activeModal.open && !activeModal.hidden && !activeModal.contains(event.target)) {
            if (!focusVisible(activeModal === document.getElementById("command-dialog") ? document.getElementById("command-query") : activeModal.querySelector("button"))) focusVisible(activeModal);
          }
        });
        document.getElementById("shortcuts-help").addEventListener("click", openShortcuts);
        document.getElementById("shortcuts-close").addEventListener("click", function () { closeShortcuts(true); });
        document.getElementById("shortcuts-dialog").addEventListener("cancel", function (event) { event.preventDefault(); closeShortcuts(true); });
        document.addEventListener("keydown", function (event) {
          if (!event || event.isComposing || event.keyCode === 229) return;
          if (activeModal && activeModal.open && !activeModal.hidden) {
            if (event.key === "Escape") { event.preventDefault(); if (activeModal === document.getElementById("insight-dialog")) closeInsight(true); else if (activeModal === document.getElementById("command-dialog")) closeCommandPalette(true); else closeShortcuts(true); }
            if (commandPaletteVisible() && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey) {
              if (["ArrowDown", "ArrowUp"].includes(event.key)) { event.preventDefault(); selectCommand(commandIndex + (event.key === "ArrowDown" ? 1 : -1)); }
              if (event.key === "Enter" && event.target !== document.getElementById("command-close")) { event.preventDefault(); dispatchCommand(commandIndex, commandRevision); }
            }
            if (event.key === "Tab") {
              const nodes = Array.from(activeModal.querySelectorAll("button, input, select, textarea, a[href], [tabindex]"))
                .filter(function (node) { return !node.disabled && !node.hidden && node.getAttribute("tabindex") !== "-1" && (typeof node.checkVisibility !== "function" || node.checkVisibility()); });
              const index = nodes.indexOf(document.activeElement);
              if (!nodes.length || index < 0 || (event.shiftKey ? index === 0 : index === nodes.length - 1)) {
                event.preventDefault(); focusVisible(nodes.length ? nodes[event.shiftKey ? nodes.length - 1 : 0] : activeModal);
              }
            }
            return;
          }
          if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && String(event.key).toLowerCase() === "k") {
            if (!workspaceNode.hidden && !editableTarget(event.target) && !(typeof document.querySelector === "function" && document.querySelector("dialog[open]"))) { event.preventDefault(); openCommandPalette(); }
            return;
          }
          if (event.metaKey || event.ctrlKey || event.altKey) return;
          const help = document.getElementById("shortcuts-dialog"), insight = document.getElementById("insight-dialog");
          if (help.open) { if (event.key === "Escape") { event.preventDefault(); closeShortcuts(true); } return; }
          if (insight.open || (typeof document.querySelector === "function" && document.querySelector("dialog[open]"))) return;
          const typing = editableTarget(event.target);
          if (event.key === "Escape") {
            let closed = false;
            ["source", "project"].forEach(function (kind) {
              const picker = document.getElementById(kind + "-picker");
              if (!picker.open) return;
              picker.open = false; closed = true;
              const summary = document.getElementById(kind + "-summary");
              if (typeof summary.focus === "function") summary.focus();
            });
            if (!closed && !document.getElementById("transcript-find").hidden) { closeTranscriptFind(true); closed = true; }
            if (typing && !closed) return;
            if (!closed && workspaceNode.classList.contains("showing-detail")) { backNode.click(); closed = true; }
            if (closed) event.preventDefault();
            return;
          }
          if (typing || workspaceNode.hidden) return;
          if (event.key === "?") { event.preventDefault(); openShortcuts(); return; }
          if (event.key === "/") {
            event.preventDefault();
            if (workspaceNode.classList.contains("showing-detail")) openTranscriptFind();
            else { if (!["sessions","search"].includes(activePage)) navigate("search").catch(function () {}); const q = document.getElementById("query"); if (typeof q.focus === "function") q.focus(); }
            return;
          }
          if (!["sessions","search"].includes(activePage) || workspaceNode.classList.contains("showing-detail")) return;
          const rows = Array.from(sessionsNode.querySelectorAll("button.session")).filter(function (row) { return !row.hidden && !row.parentNode.hidden; });
          if (!rows.length) return;
          if (event.key === "j" || event.key === "k") {
            event.preventDefault(); selectedSessionIndex = Math.max(0, Math.min(rows.length - 1, selectedSessionIndex + (event.key === "j" ? 1 : -1)));
            rows.forEach(function (row,i) { row.setAttribute("aria-current",String(i === selectedSessionIndex)); });
            if (typeof rows[selectedSessionIndex].focus === "function") rows[selectedSessionIndex].focus();
          } else if (event.key === "Enter" && selectedSessionIndex >= 0 && rows[selectedSessionIndex]) { event.preventDefault(); rows[selectedSessionIndex].click(); }
        });
        ["sessions", "search", "dashboard", "stats", "health", "fleet", "settings", "insights"].forEach(function (name) {
          const link = document.getElementById("nav-" + name);
          link.setAttribute("href", routeHref({page:name}));
          link.addEventListener("click", function (event) { event.preventDefault(); navigate(name).catch(function () {}); });
          link.insertBefore(icon(name), link.firstChild);
        });
        document.getElementById("search-query").appendChild(icon("search"));
        const commandTrigger = document.getElementById("command-trigger");
        commandTrigger.insertBefore(icon("search"), commandTrigger.firstChild);
        const shortcut = commandTrigger.querySelector("kbd");
        if (shortcut) setText(shortcut, /Mac|iPhone|iPad/.test(navigator.platform || "") ? "⌘ K" : "Ctrl K");
        document.getElementById("ui-language").addEventListener("change", function () {
          changeUILanguage(this.value, !!authWriteTail || settingsWriteBusy || aiConfigBusy || relationshipWritePending || insightSavePending || sessionActionPending || batchTitlePending);
        });
        document.getElementById("project-find").addEventListener("click", function () { loadFacets("project", false); });
        document.getElementById("project-query").addEventListener("keydown", function (event) {
          if (event.key === "Enter") { event.preventDefault(); loadFacets("project", false); }
        });
        backNode.addEventListener("click", function () {
          routeVersion += 1; bumpEpoch(); clearMessages();
          const route = detailReturnRoute || {page:"sessions",filters:{}};
          writeRoute(route); showSessionList();
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
        if (window.history && "scrollRestoration" in window.history) window.history.scrollRestoration = "manual";
        window.addEventListener("hashchange", historyChanged);
        window.addEventListener("popstate", historyChanged);
        ["search-mode", "search-limit"].forEach(function (id) {
          document.getElementById(id).addEventListener("change", function () { if (activePage === "search") refreshLibrary().catch(function () {}); });
        });
        ["transcript", "timeline", "children", "info"].forEach(function (view) {
          document.getElementById("detail-view-" + view).addEventListener("click", function () { routeVersion += 1; jumpVersion += 1; findVersion += 1; writeRoute({page:"detail",id:detailContextSession,view:view === "transcript" ? null : view}); showDetailView(view); });
        });
        document.getElementById("timeline-more").addEventListener("click", function () { loadDetailTimeline(true); });
        document.getElementById("timeline-refresh").addEventListener("click", function () { loadDetailTimeline(false); });
        document.getElementById("detail-children-more").addEventListener("click", function () { if (!relationshipWritePending) loadDetailChildren(true); });
        document.getElementById("detail-children-refresh").addEventListener("click", function () { if (!relationshipWritePending) loadDetailChildren(false); });
        document.getElementById("relationship-edit").addEventListener("click", function () { loadRelationshipAccess(); });
        document.getElementById("relationship-form").addEventListener("submit", function (event) { event.preventDefault(); attachDetailChild(); });
        document.getElementById("fleet-refresh").addEventListener("click", function () { loadFleet().catch(function () {}); });
        document.getElementById("health-refresh").addEventListener("click", function () { navigate("health").catch(function () {}); });
        document.getElementById("alias-form").addEventListener("submit", function (event) { event.preventDefault(); addAlias(); });
        document.getElementById("alias-project-form").addEventListener("submit", function (event) { event.preventDefault(); loadAliasProjects(false); });
        document.getElementById("alias-project-more").addEventListener("click", function () { loadAliasProjects(true); });
        document.getElementById("settings-refresh").addEventListener("click", function () { loadSettings(false); });
        document.getElementById("settings-more").addEventListener("click", function () { loadSettings(true); });
        document.getElementById("session-sort").addEventListener("change", function () { refreshLibrary().catch(function () {}); });
        document.getElementById("stats-choices").addEventListener("click", loadStatsChoices);
        document.getElementById("dashboard-hours-load").addEventListener("click", loadDashboardHours);
        document.getElementById("dashboard-refresh").addEventListener("click", function () { loadDashboard(); });
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
