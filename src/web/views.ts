import type { SessionInfo } from '../adapters/types.js';

const CDN_HTMX = 'https://unpkg.com/htmx.org@2.0.4';
const CDN_HTMX_SRI =
  'sha384-HGfztofotfshcF7+8n44JQL2oJmowVChPTg48S+jvZoztPfvwD79OC/LTtG6dMp+';

// ---------------------------------------------------------------------------
// Source display info — keep in sync with macos/Engram/Views/SessionDetailView.swift SourceDisplay
// ---------------------------------------------------------------------------

const SOURCE_LABELS: Record<string, string> = {
  'claude-code': 'Claude',
  codex: 'Codex',
  copilot: 'Copilot',
  pi: 'Pi',
  'gemini-cli': 'Gemini',
  kimi: 'Kimi',
  qwen: 'Qwen',
  minimax: 'MiniMax',
  lobsterai: 'Lobster AI',
  cline: 'Cline',
  cursor: 'Cursor',
  windsurf: 'Windsurf',
  antigravity: 'Antigravity',
  opencode: 'OpenCode',
  iflow: 'iFlow',
  vscode: 'VS Code',
};

const SOURCE_COLORS: Record<string, string> = {
  'claude-code': '#e67e22',
  codex: '#27ae60',
  copilot: '#888',
  pi: '#7c3aed',
  'gemini-cli': '#00bcd4',
  kimi: '#e91e8a',
  qwen: '#009688',
  minimax: '#e74c3c',
  lobsterai: '#f1c40f',
  cline: '#00c7b7',
  cursor: '#3498db',
  windsurf: '#8d6e63',
  antigravity: '#00bcd4',
  opencode: '#5c6bc0',
  iflow: '#9b59b6',
  vscode: '#888',
};

function msgCounts(s: {
  userMessageCount: number;
  assistantMessageCount: number;
  systemMessageCount: number;
}): string {
  const parts = [
    `${s.userMessageCount} user`,
    `${s.assistantMessageCount} asst`,
  ];
  if (s.systemMessageCount > 0) parts.push(`${s.systemMessageCount} sys`);
  return parts.join(' &middot; ');
}

function sourceLabel(source: string): string {
  return SOURCE_LABELS[source] ?? source;
}
function sourceColor(source: string): string {
  return SOURCE_COLORS[source] ?? '#64748B';
}
function sourceBadge(source: string): string {
  const c = sourceColor(source);
  return `<span class="badge" style="background:${c};color:#fff">${escapeHtml(sourceLabel(source))}</span>`;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

export function layout(title: string, body: string, currentPath = '/'): string {
  const navItems = [
    { href: '/', label: 'Sessions' },
    { href: '/search', label: 'Search' },
    { href: '/stats', label: 'Stats' },
    { href: '/health', label: 'Health' },
    { href: '/settings', label: 'Settings' },
  ];
  const navHtml = navItems
    .map((item) => {
      const active = currentPath === item.href ? ' class="nav-active"' : '';
      return `<a href="${item.href}"${active}>${item.label}</a>`;
    })
    .join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)} — Engram</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <script src="${CDN_HTMX}" integrity="${CDN_HTMX_SRI}" crossorigin="anonymous"></script>
  <style>
    /* === Reset & Base === */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg: #0F172A; --bg-card: #1E293B; --bg-hover: #273548; --bg-input: #1E293B;
      --text: #F8FAFC; --text-sec: #94A3B8; --text-dim: #64748B; --text-faint: #475569;
      --accent: #22C55E; --accent-dim: rgba(34,197,94,0.12);
      --border: #334155; --border-light: rgba(148,163,184,0.1);
      --code-bg: #0D1117;
      --user-bg: rgba(34,197,94,0.06); --user-border: rgba(34,197,94,0.18);
      --system-orange: #F59E0B; --system-purple: #A855F7;
      --font: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      --mono: 'JetBrains Mono', 'SF Mono', 'Fira Code', monospace;
      --radius: 8px; --radius-lg: 14px;
    }
    html { font-size: 14px; }
    body { font-family: var(--font); background: var(--bg); color: var(--text); line-height: 1.6; min-height: 100vh; }
    a { color: var(--accent); text-decoration: none; transition: opacity 0.15s; }
    a:hover { opacity: 0.8; }
    hr { border: none; border-top: 1px solid var(--border); margin: 1em 0; }
    code { font-family: var(--mono); font-size: 0.88em; }
    code:not(pre code) { padding: 0.15em 0.4em; border-radius: 4px; background: var(--code-bg); color: #E2E8F0; }
    input, select { font-family: var(--font); font-size: 0.9rem; padding: 0.5em 0.75em; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg-input); color: var(--text); outline: none; transition: border-color 0.15s; }
    input:focus, select:focus { border-color: var(--accent); }
    table { width: 100%; border-collapse: collapse; font-size: 0.9em; }
    th, td { text-align: left; padding: 0.5em 0.75em; border-bottom: 1px solid var(--border-light); }
    th { color: var(--text-sec); font-weight: 600; font-size: 0.82em; text-transform: uppercase; letter-spacing: 0.04em; }

    /* === Container === */
    .container { max-width: 960px; margin: 0 auto; padding: 0 1.25em; }

    /* === Nav === */
    .top-nav { background: rgba(15,23,42,0.85); backdrop-filter: blur(12px); border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 50; }
    .top-nav .container { display: flex; align-items: center; height: 48px; gap: 2em; }
    .nav-brand { font-weight: 700; font-size: 1.05rem; color: var(--text); letter-spacing: -0.02em; }
    .nav-links { display: flex; gap: 0.25em; }
    .nav-links a { color: var(--text-dim); font-size: 0.88rem; font-weight: 500; padding: 0.35em 0.7em; border-radius: 6px; transition: color 0.15s, background 0.15s; }
    .nav-links a:hover { color: var(--text); background: var(--bg-card); opacity: 1; }
    .nav-links a.nav-active { color: var(--accent); background: var(--accent-dim); }

    /* === Badge === */
    .badge { display: inline-block; padding: 0.15em 0.5em; border-radius: 4px; font-size: 0.75em; font-weight: 600; vertical-align: middle; }

    /* === Session Card === */
    .session-card { display: block; padding: 0.75em 1em; margin-bottom: 0.35em; border-radius: var(--radius); border: 1px solid var(--border-light); transition: background 0.15s, border-color 0.15s; cursor: pointer; }
    .session-card:hover { background: var(--bg-card); border-color: var(--border); opacity: 1; }
    .session-card .title { font-weight: 600; color: var(--text); margin-bottom: 0.2em; line-height: 1.4; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .session-card .meta { font-size: 0.8em; color: var(--text-dim); display: flex; align-items: center; gap: 0.5em; flex-wrap: wrap; }
    .session-card .meta .sep { color: var(--text-faint); }

    /* === Filter Bar === */
    .filter-bar { display: flex; align-items: center; gap: 0.75em; margin-bottom: 1em; flex-wrap: wrap; }
    .filter-bar select { min-width: 140px; }
    .filter-bar .count { margin-left: auto; font-size: 0.82em; color: var(--text-dim); }
    .chip-group { display: flex; gap: 4px; }
    .chip { font-size: 0.78em; padding: 0.25em 0.65em; border-radius: 999px; border: 1px solid var(--border); color: var(--text-sec); text-decoration: none; transition: all 0.15s; }
    .chip:hover { border-color: var(--accent); color: var(--accent); opacity: 1; }
    .chip.active { background: var(--accent); color: #fff; border-color: var(--accent); }

    /* === Multi-Select Dropdown === */
    .ms { position: relative; }
    .ms-trigger { display: inline-flex; align-items: center; gap: 0.4em; font-family: var(--font); font-size: 0.9rem; padding: 0.45em 0.7em; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg-input); color: var(--text-sec); cursor: pointer; white-space: nowrap; transition: border-color 0.15s; min-width: 130px; }
    .ms-trigger:hover { border-color: var(--accent); }
    .ms-trigger.ms-has-sel { color: var(--text); border-color: var(--accent); }
    .ms-arrow { font-size: 0.7em; margin-left: auto; }
    .ms-dropdown { display: none; position: absolute; top: calc(100% + 4px); left: 0; min-width: 200px; max-height: 280px; overflow-y: auto; background: var(--bg-card); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: 0 8px 24px rgba(0,0,0,0.3); z-index: 100; padding: 0.35em 0; }
    .ms.open .ms-dropdown { display: block; }
    .ms-option { display: flex; align-items: center; gap: 0.5em; padding: 0.35em 0.75em; font-size: 0.88em; cursor: pointer; color: var(--text-sec); transition: background 0.1s; }
    .ms-option:hover { background: var(--bg-hover); }
    .ms-option input[type="checkbox"] { accent-color: var(--accent); }
    .ms-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
    .ms-clear { display: block; font-size: 0.78em; padding: 0.3em 0.75em; color: var(--accent); cursor: pointer; border-bottom: 1px solid var(--border-light); margin-bottom: 0.2em; }
    .ms-clear:hover { opacity: 0.8; }
    .ms-search { width: calc(100% - 1em); margin: 0.25em 0.5em; font-size: 0.85em; padding: 0.35em 0.5em; border: 1px solid var(--border); border-radius: 5px; background: var(--bg-input); color: var(--text); }
    .ms-search:focus { border-color: var(--accent); outline: none; }
    .ms-option.hidden { display: none; }
    .goto-form { display: flex; }
    .goto-input { width: 140px; font-size: 0.82em; padding: 0.4em 0.6em; font-family: var(--mono); }

    /* === Pagination === */
    .pagination { display: flex; justify-content: center; align-items: center; gap: 0.75em; margin: 1.5em 0; font-size: 0.88em; }
    .pagination a { padding: 0.35em 0.8em; border-radius: 6px; border: 1px solid var(--border); color: var(--text-sec); transition: all 0.15s; }
    .pagination a:hover { background: var(--bg-card); color: var(--text); border-color: var(--accent); opacity: 1; }
    .pagination .current { color: var(--text-dim); }

    /* === Chat === */
    .chat { display: flex; flex-direction: column; gap: 0.6em; padding-bottom: 2em; }
    .msg { max-width: 88%; }
    .msg.user { align-self: flex-end; }
    .msg.assistant { align-self: flex-start; }
    .msg .role { font-size: 0.7em; font-weight: 700; margin-bottom: 0.15em; padding-left: 0.3em; }
    .msg.user .role { text-align: right; padding-right: 0.3em; color: var(--text-dim); }
    .msg .bubble { padding: 0.75em 1em; border-radius: var(--radius-lg); line-height: 1.6; word-break: break-word; }
    .msg.user .bubble { background: var(--user-bg); border: 1px solid var(--user-border); color: var(--text); border-bottom-right-radius: 4px; }
    .msg.assistant .bubble { background: var(--bg-card); border: 1px solid var(--border-light); border-bottom-left-radius: 4px; }

    /* === Markdown in Bubbles === */
    .bubble h1, .bubble h2, .bubble h3, .bubble h4 { margin: 0.5em 0 0.25em; color: var(--text); }
    .bubble h1 { font-size: 1.35em; } .bubble h2 { font-size: 1.2em; } .bubble h3 { font-size: 1.08em; }
    .bubble p { margin: 0.3em 0; }
    .bubble ul, .bubble ol { margin: 0.3em 0; padding-left: 1.5em; }
    .bubble li { margin: 0.12em 0; }
    .bubble hr { border: none; border-top: 1px solid var(--border); margin: 0.5em 0; }
    .bubble table { width: auto; margin: 0.5em 0; font-size: 0.9em; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
    .bubble th { background: rgba(148,163,184,0.08); }
    .bubble th, .bubble td { border-bottom: 1px solid var(--border-light); padding: 0.3em 0.6em; }
    .bubble a { color: var(--accent); }

    /* === Code Block === */
    .code-block { margin: 0.5em 0; border-radius: var(--radius); overflow: hidden; background: var(--code-bg); border: 1px solid var(--border-light); }
    .code-block .code-header { display: flex; justify-content: space-between; align-items: center; padding: 0.35em 0.75em; font-size: 0.72em; color: var(--text-dim); background: rgba(0,0,0,0.2); border-bottom: 1px solid var(--border-light); }
    .code-block pre { margin: 0; padding: 0.75em; overflow-x: auto; font-size: 0.85em; background: transparent; color: #E2E8F0; }
    .code-block code { background: transparent; color: inherit; }
    .copy-btn { cursor: pointer; border: none; background: transparent; color: var(--text-dim); font-family: var(--font); font-size: 0.85em; padding: 0.2em 0.5em; border-radius: 4px; transition: all 0.15s; }
    .copy-btn:hover { background: rgba(255,255,255,0.08); color: var(--text-sec); }

    /* === Task List === */
    .task-list { list-style: none; padding-left: 0.2em; }
    .task-list li { display: flex; align-items: baseline; gap: 0.4em; }
    .task-done { color: var(--text-dim); text-decoration: line-through; }

    /* === System Message === */
    .msg.system { align-self: stretch; max-width: 100%; }
    .msg.system .bubble { background: transparent; cursor: pointer; font-size: 0.82em; padding: 0.5em 0.75em; }
    .msg.system .bubble.sys-prompt { border: 1px dashed rgba(245,158,11,0.3); }
    .msg.system .bubble.sys-agent { border: 1px dashed rgba(168,85,247,0.3); }
    .msg.system .system-content { display: none; margin-top: 0.5em; font-family: var(--mono); font-size: 0.8em; white-space: pre-wrap; word-break: break-word; max-height: 400px; overflow-y: auto; color: var(--text-dim); padding: 0.5em; border-radius: 6px; background: rgba(0,0,0,0.15); }
    .msg.system .bubble.expanded .system-content { display: block; }
    .msg.system .system-icon { margin-right: 0.4em; }

    /* === Session Header (Detail) === */
    .session-header { position: sticky; top: 48px; z-index: 10; background: var(--bg); border-bottom: 1px solid var(--border-light); padding: 1em 0; margin-bottom: 1em; }
    .session-header h2 { font-size: 1.2em; font-weight: 600; margin-bottom: 0.25em; line-height: 1.3; }
    .session-header .meta { font-size: 0.82em; color: var(--text-dim); display: flex; align-items: center; gap: 0.5em; flex-wrap: wrap; }
    .back-link { display: inline-flex; align-items: center; gap: 0.3em; font-size: 0.85em; color: var(--text-sec); margin-bottom: 0.75em; }
    .back-link:hover { color: var(--accent); opacity: 1; }

    /* === Stats === */
    .stat-card { background: var(--bg-card); border: 1px solid var(--border-light); border-radius: var(--radius); padding: 0.75em 1em; margin-bottom: 0.5em; }
    .stat-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.4em; }
    .stat-bar-bg { height: 6px; border-radius: 3px; background: var(--border-light); overflow: hidden; margin-bottom: 0.35em; }
    .stat-bar { height: 100%; border-radius: 3px; transition: width 0.3s; }
    .stat-values { display: flex; gap: 1.5em; font-size: 0.82em; color: var(--text-sec); }
    .stat-tabs { display: flex; gap: 0.25em; margin-bottom: 1em; }
    .stat-tabs a { padding: 0.35em 0.75em; border-radius: 6px; font-size: 0.85em; color: var(--text-dim); border: 1px solid transparent; transition: all 0.15s; }
    .stat-tabs a:hover { color: var(--text); background: var(--bg-card); opacity: 1; }
    .stat-tabs a.active { color: var(--accent); background: var(--accent-dim); border-color: rgba(34,197,94,0.2); }

    /* === Settings === */
    .settings-section { background: var(--bg-card); border: 1px solid var(--border-light); border-radius: var(--radius); padding: 1em 1.25em; margin-bottom: 1em; }
    .settings-section h3 { font-size: 0.95em; font-weight: 600; margin-bottom: 0.75em; color: var(--text); }
    .settings-row { display: flex; justify-content: space-between; align-items: center; padding: 0.4em 0; font-size: 0.88em; }
    .settings-row .label { color: var(--text-sec); }
    .settings-row .value { color: var(--text); font-family: var(--mono); font-size: 0.9em; }

    /* === Search === */
    .search-hint { font-size: 0.82em; color: var(--text-dim); margin-top: 0.5em; }
    .search-input { width: 100%; font-size: 1rem; padding: 0.6em 1em; }
    .recent-label { font-size: 0.82em; color: var(--text-dim); margin: 1.5em 0 0.5em; text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600; }
    .search-modes { font-size: 0.78em; color: var(--text-dim); margin: 0.4em 0; }
    .match-badge { display: inline-block; font-size: 0.7em; padding: 1px 6px; border-radius: 3px; font-weight: 500; margin-right: 6px; vertical-align: middle; }
    mark { background: #6c5ce7; color: #fff; padding: 0 2px; border-radius: 2px; }
    .mode-toggle { display: flex; gap: 4px; margin: 0.6em 0; }
    .mode-btn { background: var(--bg-card); border: 1px solid var(--border); padding: 4px 12px; border-radius: 4px; font-size: 0.82em; cursor: pointer; color: var(--text-dim); transition: all 0.15s; }
    .mode-btn:hover { border-color: var(--text-dim); }
    .mode-btn.active { background: #6c5ce7; color: #fff; border-color: #6c5ce7; }
    .embedding-status { font-size: 0.78em; color: var(--text-dim); margin-bottom: 0.6em; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
    .status-dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; }
    .status-dot.available { background: #27ae60; }
    .status-dot.unavailable { background: #e74c3c; }
    .progress-bar { width: 120px; height: 4px; background: var(--border); border-radius: 2px; margin-left: 6px; overflow: hidden; }
    .progress-fill { height: 100%; background: #6c5ce7; border-radius: 2px; transition: width 0.3s; }

    /* === Page Headers === */
    .page-header { margin: 1.5em 0 1em; }
    .page-header h2 { font-size: 1.4em; font-weight: 700; margin-bottom: 0.15em; }
    .page-header p { font-size: 0.88em; color: var(--text-dim); }

    /* === Empty State === */
    .empty-state { text-align: center; padding: 3em 1em; color: var(--text-dim); }
    .empty-state .icon { font-size: 2em; margin-bottom: 0.3em; }

    /* === Light Mode === */
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #F8FAFC; --bg-card: #FFFFFF; --bg-hover: #F1F5F9; --bg-input: #FFFFFF;
        --text: #0F172A; --text-sec: #475569; --text-dim: #64748B; --text-faint: #94A3B8;
        --accent: #16A34A; --accent-dim: rgba(22,163,74,0.08);
        --border: #E2E8F0; --border-light: rgba(15,23,42,0.06);
        --code-bg: #F1F5F9;
        --user-bg: rgba(22,163,74,0.05); --user-border: rgba(22,163,74,0.15);
      }
      .top-nav { background: rgba(248,250,252,0.85); }
      .nav-brand { color: var(--text); }
      code:not(pre code) { color: #1E293B; }
      .code-block pre { color: #1E293B; }
      .code-block .code-header { background: rgba(0,0,0,0.04); }
      .copy-btn:hover { background: rgba(0,0,0,0.05); color: var(--text-sec); }
      .msg.system .system-content { background: rgba(0,0,0,0.03); }
      .bubble th { background: rgba(0,0,0,0.03); }
      .ms-dropdown { box-shadow: 0 8px 24px rgba(0,0,0,0.1); }
    }

    /* === Responsive === */
    @media (max-width: 640px) {
      .container { padding: 0 0.75em; }
      .msg { max-width: 95%; }
      .filter-bar { flex-direction: column; align-items: stretch; gap: 0.5em; }
      .ms-trigger { width: 100%; }
      .goto-input { width: 100%; }
      .session-header { top: 0; }
    }
  </style>
</head>
<body>
  <nav class="top-nav">
    <div class="container">
      <a href="/" class="nav-brand">Engram</a>
      <div class="nav-links">${navHtml}</div>
    </div>
  </nav>
  <main class="container" style="padding-top:1em;padding-bottom:3em">${body}</main>
  <script>
    function copyCode(btn) {
      const pre = btn.closest('.code-block').querySelector('pre');
      navigator.clipboard.writeText(pre.textContent).then(() => {
        btn.textContent = 'Copied!';
        setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
      });
    }
    function toggleSystem(el) {
      el.closest('.bubble').classList.toggle('expanded');
    }
    function toggleDropdown(id) {
      var el = document.getElementById(id);
      var wasOpen = el.classList.contains('open');
      document.querySelectorAll('.ms.open').forEach(function(m) { m.classList.remove('open'); });
      if (!wasOpen) el.classList.add('open');
    }
    document.addEventListener('click', function(e) {
      if (!e.target.closest('.ms')) {
        document.querySelectorAll('.ms.open').forEach(function(m) { m.classList.remove('open'); });
      }
    });
    function updateMultiFilter(param) {
      var container = document.getElementById('ms-' + param);
      var checked = [];
      container.querySelectorAll('.ms-option input[type="checkbox"]:checked').forEach(function(cb) {
        checked.push(cb.closest('.ms-option').dataset.value);
      });
      var url = new URL(window.location.href);
      if (checked.length) { url.searchParams.set(param, checked.join(',')); } else { url.searchParams.delete(param); }
      url.searchParams.delete('offset');
      window.location.href = url.toString();
    }
    function clearFilter(param) {
      var url = new URL(window.location.href);
      url.searchParams.delete(param);
      url.searchParams.delete('offset');
      window.location.href = url.toString();
    }
    function filterOptions(input) {
      var q = input.value.toLowerCase();
      var labels = input.closest('.ms-dropdown').querySelectorAll('.ms-option');
      labels.forEach(function(label) {
        var text = label.dataset.value.toLowerCase();
        label.classList.toggle('hidden', q.length > 0 && text.indexOf(q) === -1);
      });
    }
  </script>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// Session list page
// ---------------------------------------------------------------------------

interface SessionListOpts {
  offset: number;
  limit: number;
  hasMore: boolean;
  total: number;
  selectedSources: string[];
  sources: string[];
  selectedProjects: string[];
  projects: string[];
  selectedOrigins: string[];
  origins: string[];
  agents?: 'hide' | 'only';
}

export function sessionListPage(
  sessions: SessionInfo[],
  opts: SessionListOpts,
): string {
  const {
    offset,
    limit,
    total,
    selectedSources,
    sources,
    selectedProjects,
    projects,
    selectedOrigins,
    origins,
    agents,
  } = opts;

  // Helper: build URL with current filters, overriding specific params
  function filterUrl(
    overrides: Record<string, string[] | string | undefined> = {},
  ): string {
    const p = new URLSearchParams();
    const srcs =
      overrides.sources !== undefined
        ? (Array.isArray(overrides.sources)
            ? overrides.sources
            : [overrides.sources]
          ).filter(Boolean)
        : selectedSources;
    const prjs =
      overrides.projects !== undefined
        ? (Array.isArray(overrides.projects)
            ? overrides.projects
            : [overrides.projects]
          ).filter(Boolean)
        : selectedProjects;
    const orgs =
      overrides.origins !== undefined
        ? (Array.isArray(overrides.origins)
            ? overrides.origins
            : [overrides.origins]
          ).filter(Boolean)
        : selectedOrigins;
    const ag = (
      overrides.agents !== undefined ? overrides.agents : (agents ?? 'hide')
    ) as string;
    if (srcs.length) p.set('source', srcs.join(','));
    if (prjs.length) p.set('project', prjs.join(','));
    if (orgs.length) p.set('origin', orgs.join(','));
    if (ag && ag !== 'hide') p.set('agents', ag);
    const qs = p.toString();
    return qs ? `/?${qs}` : '/';
  }

  // Source multi-select dropdown
  const sourceCheckboxes = sources
    .map((s) => {
      const checked = selectedSources.includes(s) ? ' checked' : '';
      const color = sourceColor(s);
      return `<label class="ms-option" data-value="${escapeHtml(s)}">
      <input type="checkbox"${checked} onchange="updateMultiFilter('source')">
      <span class="ms-dot" style="background:${color}"></span>
      ${escapeHtml(sourceLabel(s))}
    </label>`;
    })
    .join('');

  const sourceTriggerLabel =
    selectedSources.length === 0
      ? 'All sources'
      : selectedSources.length === 1
        ? sourceLabel(selectedSources[0])
        : `${selectedSources.length} sources`;

  // Project multi-select dropdown (with search)
  const projectCheckboxes = projects
    .map((p) => {
      const checked = selectedProjects.includes(p) ? ' checked' : '';
      return `<label class="ms-option" data-value="${escapeHtml(p)}">
      <input type="checkbox"${checked} onchange="updateMultiFilter('project')">
      ${escapeHtml(p)}
    </label>`;
    })
    .join('');

  const projectTriggerLabel =
    selectedProjects.length === 0
      ? 'All projects'
      : selectedProjects.length === 1
        ? selectedProjects[0]
        : `${selectedProjects.length} projects`;

  const originCheckboxes = origins
    .map((o) => {
      const checked = selectedOrigins.includes(o) ? ' checked' : '';
      return `<label class="ms-option" data-value="${escapeHtml(o)}">
      <input type="checkbox"${checked} onchange="updateMultiFilter('origin')">
      ${escapeHtml(o)}
    </label>`;
    })
    .join('');

  const originTriggerLabel =
    selectedOrigins.length === 0
      ? 'All nodes'
      : selectedOrigins.length === 1
        ? selectedOrigins[0]
        : `${selectedOrigins.length} nodes`;

  // Agent filter chips
  const chipAll = `<a href="${filterUrl({ agents: 'all' })}" class="chip${!agents ? ' active' : ''}" title="Show all sessions">All</a>`;
  const chipHide = `<a href="${filterUrl({ agents: '' })}" class="chip${agents === 'hide' ? ' active' : ''}" title="Hide agent/subagent sessions">Hide Agents</a>`;
  const chipOnly = `<a href="${filterUrl({ agents: 'only' })}" class="chip${agents === 'only' ? ' active' : ''}" title="Show only agent sessions">Agents Only</a>`;

  const filterHtml = `
    <div class="filter-bar">
      <div class="ms" id="ms-source">
        <button type="button" class="ms-trigger${selectedSources.length ? ' ms-has-sel' : ''}" onclick="toggleDropdown('ms-source')">
          ${escapeHtml(sourceTriggerLabel)}
          <span class="ms-arrow">&#9662;</span>
        </button>
        <div class="ms-dropdown">
          ${selectedSources.length ? '<a class="ms-clear" onclick="clearFilter(\'source\')">Clear</a>' : ''}
          ${sourceCheckboxes}
        </div>
      </div>
      <div class="ms" id="ms-project">
        <button type="button" class="ms-trigger${selectedProjects.length ? ' ms-has-sel' : ''}" onclick="toggleDropdown('ms-project')">
          ${escapeHtml(projectTriggerLabel)}
          <span class="ms-arrow">&#9662;</span>
        </button>
        <div class="ms-dropdown">
          ${selectedProjects.length ? '<a class="ms-clear" onclick="clearFilter(\'project\')">Clear</a>' : ''}
          <input type="text" class="ms-search" placeholder="Search projects…" oninput="filterOptions(this)">
          ${projectCheckboxes}
        </div>
      </div>
      <div class="ms" id="ms-origin">
        <button type="button" class="ms-trigger${selectedOrigins.length ? ' ms-has-sel' : ''}" onclick="toggleDropdown('ms-origin')">
          ${escapeHtml(originTriggerLabel)}
          <span class="ms-arrow">&#9662;</span>
        </button>
        <div class="ms-dropdown">
          ${selectedOrigins.length ? '<a class="ms-clear" onclick="clearFilter(\'origin\')">Clear</a>' : ''}
          ${originCheckboxes}
        </div>
      </div>
      <div class="chip-group">${chipAll}${chipHide}${chipOnly}</div>
      <form action="/goto" method="get" class="goto-form">
        <input type="text" name="id" class="goto-input" placeholder="Session ID…" title="Paste a session UUID to jump to it">
      </form>
      <span class="count">${total} sessions</span>
    </div>`;

  // Session cards
  const rows = sessions
    .map((s) => {
      const title = escapeHtml(truncate(s.summary ?? s.id, 120));
      const date = relativeDate(s.startTime);
      const fullDate = formatDate(s.startTime);
      const isAgent = s.agentRole || s.filePath?.includes('/subagents/');
      const agentTag = isAgent
        ? '<span style="font-size:0.72em;color:#A855F7;font-weight:600">agent</span>'
        : '';
      const proj = s.project
        ? `<span>${escapeHtml(s.project)}</span><span class="sep">&middot;</span>`
        : '';
      const origin =
        s.origin && s.origin !== 'local'
          ? `<span>${escapeHtml(s.origin)}</span><span class="sep">&middot;</span>`
          : '';
      return `<a href="/session/${encodeURIComponent(s.id)}" class="session-card">
      <div class="title">${title}</div>
      <div class="meta">
        ${sourceBadge(s.source)} ${agentTag}
        <span class="sep">&middot;</span>
        ${origin}
        ${proj}
        <span title="${escapeHtml(fullDate)}">${escapeHtml(date)}</span>
        <span class="sep">&middot;</span>
        <span>${msgCounts(s)}</span>
      </div>
    </a>`;
    })
    .join('\n');

  // Pagination
  function pageUrl(off: number): string {
    const p = new URLSearchParams();
    p.set('offset', String(off));
    p.set('limit', String(limit));
    if (selectedSources.length) p.set('source', selectedSources.join(','));
    if (selectedProjects.length) p.set('project', selectedProjects.join(','));
    if (selectedOrigins.length) p.set('origin', selectedOrigins.join(','));
    if (agents && agents !== 'hide') p.set('agents', agents);
    return `/?${p.toString()}`;
  }
  const showing =
    total > 0
      ? `${offset + 1}\u2013${Math.min(offset + limit, total)} of ${total}`
      : '0';
  let paginationHtml = '';
  if (total > limit) {
    const prevOffset = Math.max(0, offset - limit);
    const nextOffset = offset + limit;
    paginationHtml = `<div class="pagination">
      ${offset > 0 ? `<a href="${pageUrl(prevOffset)}">&larr; Prev</a>` : ''}
      <span class="current">${showing}</span>
      ${nextOffset < total ? `<a href="${pageUrl(nextOffset)}">Next &rarr;</a>` : ''}
    </div>`;
  }

  return layout(
    'Sessions',
    `
    <div class="page-header"><h2>Sessions</h2></div>
    ${filterHtml}
    ${rows || '<div class="empty-state"><div class="icon">&#128196;</div><p>No sessions found.</p></div>'}
    ${paginationHtml}`,
    '/',
  );
}

// ---------------------------------------------------------------------------
// Session detail page
// ---------------------------------------------------------------------------

export function sessionDetailPage(
  session: SessionInfo,
  messages: { role: string; content: string }[],
): string {
  const msgHtml = messages
    .filter((m) => m.content.trim())
    .map((m) => {
      const isUser = m.role === 'user';
      const category = isUser ? classifySystem(m.content) : 'none';

      if (category !== 'none') {
        const isAgent = category === 'agentComm';
        const icon = isAgent ? '&#8644;' : '&#9881;';
        const label = isAgent ? 'Agent Communication' : 'System Prompt';
        const cls = isAgent ? 'sys-agent' : 'sys-prompt';
        const preview = escapeHtml(m.content.substring(0, 100));
        return `
      <div class="msg system">
        <div class="bubble ${cls}" onclick="toggleSystem(this)">
          <span class="system-icon">${icon}</span>
          <strong>${label}</strong>
          <span style="margin-left:0.4em;color:var(--text-faint);font-weight:400">${preview}…</span>
          <div class="system-content">${escapeHtml(m.content)}</div>
        </div>
      </div>`;
      }

      const label = isUser ? 'You' : sourceLabel(session.source);
      const color = isUser ? 'var(--text-dim)' : sourceColor(session.source);
      const rendered = renderMarkdown(m.content);
      return `
    <div class="msg ${isUser ? 'user' : 'assistant'}">
      <div class="role" style="color:${color}">${escapeHtml(label)}</div>
      <div class="bubble">${rendered}</div>
    </div>`;
    })
    .join('\n');

  const sessionTitle = session.summary ?? truncate(session.id, 80);

  return layout(
    sessionTitle,
    `
    <a href="/" class="back-link">&larr; Back to sessions</a>
    <div class="session-header">
      <h2>${escapeHtml(sessionTitle)}</h2>
      <div class="meta">
        ${sourceBadge(session.source)}
        <span class="sep">&middot;</span>
        ${session.project ? `<span>${escapeHtml(session.project)}</span><span class="sep">&middot;</span>` : ''}
        <span>${formatDate(session.startTime)}</span>
        <span class="sep">&middot;</span>
        <span>${msgCounts(session)}</span>
        ${session.model ? `<span class="sep">&middot;</span><code>${escapeHtml(session.model)}</code>` : ''}
      </div>
    </div>
    <div class="chat">${msgHtml}</div>`,
    '/',
  );
}

// ---------------------------------------------------------------------------
// Search page
// ---------------------------------------------------------------------------

export function searchPage(recentSessions?: SessionInfo[]): string {
  let recentHtml = '';
  if (recentSessions && recentSessions.length > 0) {
    const cards = recentSessions
      .map(
        (
          s,
        ) => `<a href="/session/${encodeURIComponent(s.id)}" class="session-card">
      <div class="title">${escapeHtml(truncate(s.summary ?? s.id, 100))}</div>
      <div class="meta">
        ${sourceBadge(s.source)}
        <span class="sep">&middot;</span>
        <span>${escapeHtml(relativeDate(s.startTime))}</span>
        <span class="sep">&middot;</span>
        <span>${msgCounts(s)}</span>
      </div>
    </a>`,
      )
      .join('\n');
    recentHtml = `<div class="recent-label">Recent sessions</div>${cards}`;
  }

  return layout(
    'Search',
    `
    <div class="page-header"><h2>Search</h2></div>
    <div id="embedding-status" class="embedding-status"></div>
    <input type="search" name="q" id="search-input" class="search-input" placeholder="Search sessions…" autofocus>
    <div class="mode-toggle">
      <button class="mode-btn active" data-mode="hybrid">hybrid</button>
      <button class="mode-btn" data-mode="keyword">keyword</button>
      <button class="mode-btn" data-mode="semantic">semantic</button>
      <span style="border-left:1px solid var(--border);margin:0 8px"></span>
      <button class="mode-btn active" data-filter="agents" title="Include/exclude agent & subagent sessions">agents</button>
      <button class="mode-btn active" data-filter="tools" title="Include/exclude sessions with only tool calls and no human messages">tool-only</button>
    </div>
    <div id="search-modes" class="search-modes"></div>
    <div id="search-results"></div>
    <div id="recent-section">${recentHtml}</div>
    <script>
      function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }
      function sanitizeSnippet(s) { return s.replace(/<(?!\\/?mark>)[^>]+>/g, ''); }
      function matchBadge(type) {
        const c = { keyword: '#3498db', semantic: '#9b59b6', both: '#27ae60' };
        const l = { keyword: 'keyword', semantic: 'semantic', both: 'keyword + semantic' };
        return '<span class="match-badge" style="background:' + (c[type]||'#888') + '33;color:' + (c[type]||'#888') + '">' + esc(l[type]||type) + '</span>';
      }

      // Mode toggle
      let currentMode = 'hybrid';
      let includeAgents = true;
      let includeTools = true;
      document.querySelectorAll('.mode-btn[data-mode]').forEach(btn => {
        btn.addEventListener('click', () => {
          document.querySelectorAll('.mode-btn[data-mode]').forEach(b => b.classList.remove('active'));
          btn.classList.add('active');
          currentMode = btn.dataset.mode;
          const q = document.getElementById('search-input').value.trim();
          if (q.length >= 2) doSearch(q);
        });
      });
      document.querySelectorAll('.mode-btn[data-filter]').forEach(btn => {
        btn.addEventListener('click', () => {
          btn.classList.toggle('active');
          if (btn.dataset.filter === 'agents') includeAgents = btn.classList.contains('active');
          if (btn.dataset.filter === 'tools') includeTools = btn.classList.contains('active');
          const q = document.getElementById('search-input').value.trim();
          if (q.length >= 2) doSearch(q);
        });
      });

      // Embedding status
      fetch('/api/search/status').then(r=>r.json()).then(s => {
        const el = document.getElementById('embedding-status');
        if (s.available) {
          const pct = s.progress;
          const bar = pct < 100
            ? '<div class="progress-bar"><div class="progress-fill" style="width:' + pct + '%"></div></div>'
            : '';
          el.innerHTML = '<span class="status-dot available"></span>'
            + esc(s.model || 'embedding') + ' &middot; '
            + esc(s.embeddedCount + '/' + s.totalSessions) + ' sessions'
            + (pct < 100 ? ' (' + pct + '%)' : '')
            + bar;
        } else {
          el.innerHTML = '<span class="status-dot unavailable"></span>Semantic search unavailable — no embedding provider';
        }
      }).catch(() => {}); // intentional: client-side fetch, non-critical status display

      const input = document.getElementById('search-input');
      let timer, controller;
      function doSearch(q) {
        if (controller) controller.abort();
        controller = new AbortController();
        const el = document.getElementById('search-results');
        const recent = document.getElementById('recent-section');
        const modes = document.getElementById('search-modes');
        recent.style.display = 'none';
        const filterParams = (!includeAgents ? '&agents=hide' : '') + (!includeTools ? '&tools=hide' : '');
        fetch('/api/search?q=' + encodeURIComponent(q) + '&mode=' + currentMode + filterParams, { signal: controller.signal })
          .then(r => r.json())
          .then(data => {
            modes.textContent = data.searchModes?.length ? 'Searched via: ' + data.searchModes.join(' + ') : '';
            if (data.warning) { el.innerHTML = '<p style="color:var(--text-dim)">' + esc(data.warning) + '</p>'; return; }
            const results = data.results || [];
            if (results.length === 0) { el.innerHTML = '<div class="empty-state"><p>No results found.</p></div>'; return; }
            el.innerHTML = results.map(r =>
              '<a href="/session/' + encodeURIComponent(r.session?.id||'') + '" class="session-card">'
              + '<div class="title">' + esc(r.session?.summary||r.session?.id||'') + '</div>'
              + '<div class="meta">'
              + matchBadge(r.matchType||'keyword')
              + '<span style="color:var(--text-dim)">' + sanitizeSnippet(r.snippet||'') + '</span>'
              + '</div></a>'
            ).join('');
          })
          .catch(e => { if (e.name !== 'AbortError') throw e; });
      }
      input.addEventListener('input', () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const q = input.value.trim();
          const el = document.getElementById('search-results');
          const recent = document.getElementById('recent-section');
          const modes = document.getElementById('search-modes');
          if (q.length < 2) { el.innerHTML = ''; recent.style.display = ''; modes.textContent = ''; return; }
          doSearch(q);
        }, 300);
      });
    </script>`,
    '/search',
  );
}

// ---------------------------------------------------------------------------
// Stats page
// ---------------------------------------------------------------------------

interface StatsGroup {
  key: string;
  sessionCount: number;
  messageCount: number;
  userMessageCount: number;
  assistantMessageCount: number;
  toolMessageCount: number;
}

export function statsPage(
  groups: StatsGroup[],
  totalSessions: number,
  groupBy = 'source',
  excludeNoise = true,
): string {
  const maxSessions = Math.max(...groups.map((g) => g.sessionCount), 1);

  const cards = groups
    .map((g) => {
      const pct = Math.round((g.sessionCount / maxSessions) * 100);
      const color = SOURCE_COLORS[g.key] ?? '#64748B';
      const label = SOURCE_LABELS[g.key]
        ? sourceBadge(g.key)
        : `<span style="font-weight:600">${escapeHtml(g.key)}</span>`;
      return `<div class="stat-card">
      <div class="stat-header">${label}</div>
      <div class="stat-bar-bg"><div class="stat-bar" style="width:${pct}%;background:${color}"></div></div>
      <div class="stat-values">
        <span>${g.sessionCount} sessions</span>
        <span>${g.userMessageCount} user</span>
        <span>${g.assistantMessageCount} asst</span>
        ${g.toolMessageCount > 0 ? `<span>${g.toolMessageCount} tools</span>` : ''}
      </div>
    </div>`;
    })
    .join('\n');

  const tabs = ['source', 'project', 'origin', 'day']
    .map((g) => {
      const active = g === groupBy ? ' active' : '';
      const label =
        g === 'source'
          ? 'By Source'
          : g === 'project'
            ? 'By Project'
            : g === 'origin'
              ? 'By Node'
              : 'By Day';
      return `<a href="/stats?group_by=${g}&exclude_noise=${excludeNoise ? '1' : '0'}" class="stat-tabs-item${active}">${label}</a>`;
    })
    .join('');

  const noiseToggle = `<a href="/stats?group_by=${groupBy}&exclude_noise=${excludeNoise ? '0' : '1'}" class="mode-btn${excludeNoise ? ' active' : ''}" style="margin-left:auto;font-size:0.85em">${excludeNoise ? '✓ Hide noise' : 'Show all'}</a>`;

  return layout(
    'Stats',
    `
    <div class="page-header"><h2>Stats</h2><p>${totalSessions} total sessions</p></div>
    <div class="stat-tabs">${tabs}${noiseToggle}</div>
    ${cards || '<div class="empty-state"><p>No data available.</p></div>'}`,
    '/stats',
  );
}

// ---------------------------------------------------------------------------
// Settings page
// ---------------------------------------------------------------------------

interface SettingsData {
  nodeName: string;
  peers: { name: string; url: string }[];
  totalSessions?: number;
  sources?: string[];
  port?: number;
  aliases?: { alias: string; canonical: string }[];
}

export function settingsPage(config: SettingsData): string {
  // Database section
  const dbRows = [
    config.totalSessions != null
      ? `<div class="settings-row"><span class="label">Total sessions</span><span class="value">${config.totalSessions}</span></div>`
      : '',
    config.port
      ? `<div class="settings-row"><span class="label">Web server</span><span class="value">http://localhost:${config.port}</span></div>`
      : '',
  ]
    .filter(Boolean)
    .join('');

  // Sources section
  const sourcesHtml =
    config.sources && config.sources.length > 0
      ? config.sources.map((s) => sourceBadge(s)).join(' ')
      : '<span style="color:var(--text-dim)">No sources detected</span>';

  // Sync section
  const peerRows =
    config.peers.length > 0
      ? `<table><thead><tr><th>Peer</th><th>URL</th></tr></thead><tbody>${config.peers
          .map(
            (p) =>
              `<tr><td>${escapeHtml(p.name)}</td><td style="font-family:var(--mono);font-size:0.88em">${escapeHtml(p.url)}</td></tr>`,
          )
          .join('')}</tbody></table>`
      : '<p style="color:var(--text-dim);font-size:0.88em">No peers configured</p>';

  return layout(
    'Settings',
    `
    <div class="page-header"><h2>Settings</h2></div>

    <div class="settings-section">
      <h3>Database</h3>
      ${dbRows}
    </div>

    <div class="settings-section">
      <h3>Active Sources</h3>
      <div style="display:flex;gap:0.4em;flex-wrap:wrap">${sourcesHtml}</div>
    </div>

    <div class="settings-section">
      <h3>Sync</h3>
      <div class="settings-row"><span class="label">Node name</span><span class="value">${escapeHtml(config.nodeName)}</span></div>
      <div style="margin-top:0.75em">${peerRows}</div>
    </div>

    <div class="settings-section">
      <h3>Project Aliases</h3>
      <p style="font-size:0.82em;color:var(--text-dim);margin-bottom:0.75em">Link project names so sessions from moved/renamed directories appear together.</p>
      <div id="alias-list">${
        config.aliases && config.aliases.length > 0
          ? `<table><thead><tr><th>Old Project</th><th>New Project</th><th></th></tr></thead><tbody>${config.aliases
              .map(
                (a) => `<tr>
                <td>${escapeHtml(a.alias)}</td>
                <td>${escapeHtml(a.canonical)}</td>
                <td><button class="alias-del" data-alias="${escapeHtml(a.alias)}" data-canonical="${escapeHtml(a.canonical)}" style="background:none;border:none;color:#e74c3c;cursor:pointer;font-size:1em">✕</button></td>
              </tr>`,
              )
              .join('')}</tbody></table>`
          : '<p style="color:var(--text-dim);font-size:0.88em">No aliases configured</p>'
      }</div>
      <div style="display:flex;gap:8px;margin-top:0.75em;align-items:center">
        <input type="text" id="alias-old" placeholder="Old project name" style="flex:1;padding:4px 8px;font-size:0.88em">
        <span style="color:var(--text-dim)">→</span>
        <input type="text" id="alias-new" placeholder="New project name" style="flex:1;padding:4px 8px;font-size:0.88em">
        <button id="alias-add-btn" style="padding:4px 12px;font-size:0.88em">Add</button>
      </div>
      <script>
        document.getElementById('alias-add-btn').addEventListener('click', async () => {
          const alias = document.getElementById('alias-old').value.trim();
          const canonical = document.getElementById('alias-new').value.trim();
          if (!alias || !canonical) return;
          await fetch('/api/project-aliases', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ alias, canonical })
          });
          location.reload();
        });
        document.querySelectorAll('.alias-del').forEach(btn => {
          btn.addEventListener('click', async () => {
            await fetch('/api/project-aliases', {
              method: 'DELETE',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ alias: btn.dataset.alias, canonical: btn.dataset.canonical })
            });
            location.reload();
          });
        });
      </script>
    </div>`,
    '/settings',
  );
}

// ---------------------------------------------------------------------------
// Markdown renderer (server-side, no dependencies)
// ---------------------------------------------------------------------------

function renderMarkdown(raw: string): string {
  const lines = raw.split('\n');
  const out: string[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trimStart();

    // Fenced code block
    if (trimmed.startsWith('```')) {
      const lang = escapeHtml(trimmed.slice(3).trim());
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trimStart().startsWith('```')) {
        codeLines.push(lines[i]);
        i++;
      }
      i++; // skip closing fence
      const code = escapeHtml(codeLines.join('\n'));
      out.push(`<div class="code-block">
        <div class="code-header"><span>${lang}</span><button class="copy-btn" onclick="copyCode(this)">Copy</button></div>
        <pre><code>${code}</code></pre>
      </div>`);
      continue;
    }

    // Horizontal rule
    const stripped = trimmed.replace(/ /g, '');
    if (
      stripped.length >= 3 &&
      (/^-{3,}$/.test(stripped) ||
        /^\*{3,}$/.test(stripped) ||
        /^_{3,}$/.test(stripped))
    ) {
      flushParagraph(out);
      out.push('<hr>');
      i++;
      continue;
    }

    // Heading
    const headingMatch = trimmed.match(/^(#{1,6})\s+(.+)$/);
    if (headingMatch) {
      flushParagraph(out);
      const level = headingMatch[1].length;
      out.push(`<h${level}>${inlineMarkdown(headingMatch[2])}</h${level}>`);
      i++;
      continue;
    }

    // Table (detect header + separator)
    if (
      trimmed.startsWith('|') &&
      trimmed.endsWith('|') &&
      i + 1 < lines.length
    ) {
      const nextTrimmed = lines[i + 1].trim();
      if (nextTrimmed.startsWith('|') && /^[\s|:-]+$/.test(nextTrimmed)) {
        flushParagraph(out);
        out.push(renderTable(lines, i));
        while (
          i < lines.length &&
          lines[i].trim().startsWith('|') &&
          lines[i].trim().endsWith('|')
        )
          i++;
        continue;
      }
    }

    // Task list item
    const taskMatch = trimmed.match(/^[-*]\s+\[([ xX])\]\s+(.*)$/);
    if (taskMatch) {
      flushParagraph(out);
      const items: string[] = [];
      while (i < lines.length) {
        const tm = lines[i].trimStart().match(/^[-*]\s+\[([ xX])\]\s+(.*)$/);
        if (!tm) break;
        const done = tm[1] !== ' ';
        const icon = done ? '&#9745;' : '&#9744;';
        const cls = done ? ' class="task-done"' : '';
        items.push(
          `<li>${icon} <span${cls}>${inlineMarkdown(tm[2])}</span></li>`,
        );
        i++;
      }
      out.push(`<ul class="task-list">${items.join('')}</ul>`);
      continue;
    }

    // Unordered list item
    const bulletMatch = trimmed.match(/^[-*]\s+(.+)$/);
    if (bulletMatch && !trimmed.match(/^[-*]\s+\[/)) {
      flushParagraph(out);
      const items: string[] = [];
      while (i < lines.length) {
        const bm = lines[i].trimStart().match(/^[-*]\s+(.+)$/);
        if (!bm || lines[i].trimStart().match(/^[-*]\s+\[/)) break;
        items.push(`<li>${inlineMarkdown(bm[1])}</li>`);
        i++;
      }
      out.push(`<ul>${items.join('')}</ul>`);
      continue;
    }

    // Ordered list item
    const olMatch = trimmed.match(/^\d+\.\s+(.+)$/);
    if (olMatch) {
      flushParagraph(out);
      const items: string[] = [];
      while (i < lines.length) {
        const om = lines[i].trimStart().match(/^\d+\.\s+(.+)$/);
        if (!om) break;
        items.push(`<li>${inlineMarkdown(om[1])}</li>`);
        i++;
      }
      out.push(`<ol>${items.join('')}</ol>`);
      continue;
    }

    // Blank line → close paragraph
    if (trimmed === '') {
      flushParagraph(out);
      i++;
      continue;
    }

    // Regular text → accumulate for paragraph
    out.push(`<!--p-->${inlineMarkdown(trimmed)}`);
    i++;
  }
  flushParagraph(out);
  return out.join('\n');
}

/** Collect consecutive <!--p--> lines into <p> */
function flushParagraph(out: string[]): void {
  const pLines: string[] = [];
  while (out.length > 0 && out[out.length - 1].startsWith('<!--p-->')) {
    pLines.unshift(out.pop()!.slice(7));
  }
  if (pLines.length > 0) {
    out.push(`<p>${pLines.join('<br>')}</p>`);
  }
}

/** Inline markdown: bold, italic, strikethrough, inline code, links */
function inlineMarkdown(text: string): string {
  let s = escapeHtml(text);
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\*\*\*(.+?)\*\*\*/g, '<strong><em>$1</em></strong>');
  s = s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/__(.+?)__/g, '<strong>$1</strong>');
  s = s.replace(/\*(.+?)\*/g, '<em>$1</em>');
  s = s.replace(/_(.+?)_/g, '<em>$1</em>');
  s = s.replace(/~~(.+?)~~/g, '<del>$1</del>');
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_match, text, url) => {
    const decoded = url
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"');
    if (!/^https?:\/\//i.test(decoded)) return text;
    return `<a href="${url}" target="_blank" rel="noopener">${text}</a>`;
  });
  return s;
}

function renderTable(lines: string[], start: number): string {
  const parseRow = (line: string) =>
    line
      .trim()
      .slice(1, -1)
      .split('|')
      .map((c) => c.trim());

  const headers = parseRow(lines[start]);
  const rows: string[][] = [];
  for (let j = start + 2; j < lines.length; j++) {
    const t = lines[j].trim();
    if (!t.startsWith('|') || !t.endsWith('|')) break;
    rows.push(parseRow(lines[j]));
  }

  const ths = headers.map((h) => `<th>${inlineMarkdown(h)}</th>`).join('');
  const trs = rows
    .map(
      (r) =>
        `<tr>${r.map((c) => `<td>${inlineMarkdown(c)}</td>`).join('')}</tr>`,
    )
    .join('');

  return `<table><thead><tr>${ths}</tr></thead><tbody>${trs}</tbody></table>`;
}

// ---------------------------------------------------------------------------
// Health dashboard
// ---------------------------------------------------------------------------

/** Format timestamp to local readable string: "2026-03-17 10:23"
 *  Handles both ISO (with Z/+offset) and SQLite UTC (without timezone suffix). */
function formatLocalTime(ts: string): string {
  if (!ts) return '—';
  // SQLite datetime('now') produces "YYYY-MM-DD HH:MM:SS" in UTC without Z — append Z so JS parses as UTC
  const iso =
    /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/.test(ts) &&
    !ts.includes('Z') &&
    !ts.includes('+')
      ? `${ts.replace(' ', 'T')}Z`
      : ts;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return ts;
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

interface HealthSource {
  name: string;
  sessionCount: number;
  latestIndexed: string;
  dailyCounts: number[];
  derived?: boolean;
  derivedFrom?: string | null;
  path?: string;
  pathExists?: boolean;
  watcherType: string;
}

interface HealthData {
  sources: HealthSource[];
  summary: {
    activeSources: number;
    totalSources: number;
    lastIndexed?: string | null;
  };
}

export function healthPage(data: HealthData): string {
  const { sources, summary } = data;

  const rows = sources
    .map((s) => {
      const latestDate = new Date(s.latestIndexed);
      const ageMs = Date.now() - latestDate.getTime();
      const ageHours = ageMs / 3600000;
      const status =
        ageHours < 24 ? '&#x1F7E2;' : ageHours < 168 ? '&#x1F7E1;' : '&#x26AA;';
      const statusLabel =
        ageHours < 24 ? 'Active' : ageHours < 168 ? 'Stale' : 'Inactive';
      const ago =
        ageHours < 1
          ? `${Math.round(ageMs / 60000)}m ago`
          : ageHours < 24
            ? `${Math.round(ageHours)}h ago`
            : `${Math.round(ageHours / 24)}d ago`;

      const maxDaily = Math.max(...s.dailyCounts, 1);
      const sparkline = s.dailyCounts
        .map((c: number) => {
          const h = Math.round((c / maxDaily) * 20);
          return `<div style="width:8px;height:${h}px;background:var(--accent);border-radius:1px;"></div>`;
        })
        .join('');

      const derived = s.derived
        ? `<span style="color:#888;font-size:11px;">(via ${escapeHtml(s.derivedFrom ?? '')})</span>`
        : '';
      const pathCheck = s.path ? (s.pathExists ? '&#x2705;' : '&#x274C;') : '';

      return `<tr>
      <td><strong>${escapeHtml(s.name)}</strong> ${derived}</td>
      <td>${s.sessionCount}</td>
      <td>${ago}</td>
      <td><div style="display:flex;align-items:end;gap:2px;height:20px;">${sparkline}</div></td>
      <td style="white-space:nowrap;">${status} ${statusLabel}</td>
      <td style="font-size:11px;color:#888;">${escapeHtml(s.path || '\u2014')} ${pathCheck}</td>
      <td style="font-size:11px;color:#888;">${escapeHtml(s.watcherType)}</td>
    </tr>`;
    })
    .join('\n');

  const lastIndexedStr = summary.lastIndexed
    ? formatLocalTime(summary.lastIndexed)
    : 'never';

  return layout(
    'Index Health',
    `
    <h2>Index Health Dashboard</h2>
    <p style="color:#888;">${summary.activeSources}/${summary.totalSources} sources active &middot; last indexed ${escapeHtml(lastIndexedStr)}</p>

    <table style="width:100%;border-collapse:collapse;margin:20px 0;">
      <thead>
        <tr style="text-align:left;border-bottom:1px solid #333;">
          <th>Source</th><th>Sessions</th><th>Last Indexed</th><th>7-Day</th><th>Status</th><th>Path</th><th>Watcher</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  `,
    '/health',
  );
}

// ---------------------------------------------------------------------------
// System injection detection — keep in sync with macos/Engram/Core/MessageParser.swift classifySystem
// ---------------------------------------------------------------------------

type SystemCategory = 'none' | 'systemPrompt' | 'agentComm';

function classifySystem(content: string): SystemCategory {
  // Agent communication
  if (content.startsWith('# AGENTS.md instructions for ')) return 'agentComm';
  if (content.includes('<command-name>')) return 'agentComm';
  if (content.includes('<command-message>')) return 'agentComm';
  if (content.startsWith('<local-command-caveat>')) return 'agentComm';
  if (content.startsWith('<local-command-stdout>')) return 'agentComm';
  if (content.startsWith('Unknown skill: ')) return 'agentComm';
  if (content.startsWith('Invoke the superpowers:')) return 'agentComm';
  if (content.startsWith('Base directory for this skill:')) return 'agentComm';

  // System prompts
  if (content.includes('<INSTRUCTIONS>')) return 'systemPrompt';
  if (content.startsWith('<system-reminder>')) return 'systemPrompt';
  if (content.startsWith('<environment_context>')) return 'systemPrompt';
  if (content.startsWith('<EXTREMELY_IMPORTANT>')) return 'systemPrompt';
  if (content.startsWith('\nYou are Qwen Code')) return 'systemPrompt';
  if (content.startsWith('You are Qwen Code')) return 'systemPrompt';

  return 'none';
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return iso.slice(0, 16);
  }
}

function relativeDate(iso: string): string {
  try {
    const now = Date.now();
    const then = new Date(iso).getTime();
    const diff = now - then;
    if (diff < 0) return formatDate(iso);
    if (diff < 60_000) return 'just now';
    if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
    if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
    if (diff < 172_800_000) return 'yesterday';
    if (diff < 604_800_000) return `${Math.floor(diff / 86_400_000)}d ago`;
    return formatDate(iso);
  } catch {
    return iso.slice(0, 16);
  }
}

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return `${s.slice(0, max)}…`;
}
