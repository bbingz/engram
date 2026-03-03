import type { SessionInfo } from '../adapters/types.js'

const CDN_PICO = 'https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css'
const CDN_HTMX = 'https://unpkg.com/htmx.org@2.0.4'

export function layout(title: string, body: string): string {
  return `<!DOCTYPE html>
<html lang="en" data-theme="auto">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title} — Engram</title>
  <link rel="stylesheet" href="${CDN_PICO}">
  <script src="${CDN_HTMX}"></script>
  <style>
    :root { --pico-font-size: 16px; }
    .badge { display: inline-block; padding: 0.1em 0.5em; border-radius: 4px; font-size: 0.8em; background: var(--pico-secondary-background); }
    pre { white-space: pre-wrap; word-break: break-word; }
  </style>
</head>
<body>
  <header class="container">
    <nav>
      <ul><li><strong><a href="/">Engram</a></strong></li></ul>
      <ul>
        <li><a href="/">Sessions</a></li>
        <li><a href="/search">Search</a></li>
        <li><a href="/stats">Stats</a></li>
        <li><a href="/settings">Settings</a></li>
      </ul>
    </nav>
  </header>
  <main class="container">${body}</main>
</body>
</html>`
}

export function sessionListPage(sessions: SessionInfo[]): string {
  const rows = sessions.map(s => `
    <article>
      <header>
        <a href="/session/${s.id}"><strong>${escapeHtml(s.summary ?? s.id)}</strong></a>
        <span class="badge">${s.source}</span>
      </header>
      <footer><small>${s.project ?? ''} · ${s.startTime} · ${s.messageCount} msgs</small></footer>
    </article>`).join('\n')

  return layout('Sessions', `
    <hgroup><h2>Sessions</h2><p>${sessions.length} sessions</p></hgroup>
    ${rows}`)
}

export function sessionDetailPage(session: SessionInfo, messages: { role: string; content: string }[]): string {
  const msgHtml = messages.map(m => `
    <article>
      <header><strong>${m.role === 'user' ? 'User' : 'Assistant'}</strong></header>
      <pre>${escapeHtml(m.content)}</pre>
    </article>`).join('\n')

  return layout(session.summary ?? session.id, `
    <hgroup>
      <h2>${escapeHtml(session.summary ?? session.id)}</h2>
      <p><span class="badge">${session.source}</span> · ${session.project ?? ''} · ${session.startTime}</p>
    </hgroup>
    <a href="/">&larr; Back</a><hr>
    ${msgHtml}`)
}

export function searchPage(): string {
  return layout('Search', `
    <h2>Search</h2>
    <input type="search" name="q" id="search-input" placeholder="Search sessions...">
    <div id="search-results"></div>
    <script>
      function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }
      const input = document.getElementById('search-input');
      let timer;
      input.addEventListener('keyup', () => {
        clearTimeout(timer);
        timer = setTimeout(async () => {
          const q = input.value.trim();
          const el = document.getElementById('search-results');
          if (q.length < 3) { el.innerHTML = ''; return; }
          const res = await fetch('/api/search?q=' + encodeURIComponent(q));
          const data = await res.json();
          if (data.warning) { el.innerHTML = '<p>' + esc(data.warning) + '</p>'; return; }
          el.innerHTML = (data.results || []).map(r =>
            '<article><a href="/session/' + esc(r.sessionId) + '"><strong>' + esc(r.summary||r.sessionId) + '</strong></a>'
            + '<p>' + esc(r.snippet||'') + '</p></article>'
          ).join('');
        }, 300);
      });
    </script>`)
}

export function statsPage(groups: { key: string; sessionCount: number; messageCount: number }[], totalSessions: number): string {
  const rows = groups.map(g =>
    `<tr><td>${escapeHtml(g.key)}</td><td>${g.sessionCount}</td><td>${g.messageCount}</td></tr>`
  ).join('\n')

  return layout('Stats', `
    <h2>Stats</h2><p>Total: ${totalSessions}</p>
    <table><thead><tr><th>Source</th><th>Sessions</th><th>Messages</th></tr></thead>
    <tbody>${rows}</tbody></table>`)
}

export function settingsPage(syncConfig: { nodeName: string; peers: { name: string; url: string }[] }): string {
  const peerRows = syncConfig.peers.map(p =>
    `<tr><td>${escapeHtml(p.name)}</td><td>${escapeHtml(p.url)}</td></tr>`
  ).join('\n')

  return layout('Settings', `
    <h2>Settings</h2>
    <h3>Sync</h3>
    <p>Node: <strong>${escapeHtml(syncConfig.nodeName)}</strong></p>
    <table><thead><tr><th>Peer</th><th>URL</th></tr></thead>
    <tbody>${peerRows}</tbody></table>`)
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}
