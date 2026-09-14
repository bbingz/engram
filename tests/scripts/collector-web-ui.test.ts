import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createContext, runInContext } from 'node:vm';
import { describe, expect, it } from 'vitest';

// Execute the shipped constant script, not a second implementation of the UI.
// Real HTTP/IPC and browser acceptance remain separate integration checks.
const source = readFileSync(
  resolve(
    import.meta.dirname,
    '../../macos/EngramRemoteServer/Core/WebUIRoutes.swift',
  ),
  'utf8',
);
const scriptMatch = source.match(
  /static let javascript = """\n([\s\S]*?)\n {8}"""/,
)?.[1];
if (!scriptMatch) throw new Error('Missing shipped Web viewer script');
const script = scriptMatch;

class Element {
  tagName = 'DIV';
  className = '';
  hidden = false;
  value = '';
  disabled = false;
  checked = false;
  open = false;
  title = '';
  dateTime = '';
  type = '';
  parent: Element | null = null;
  children: Element[] = [];
  private text = '';
  private attrs = new Map<string, string>();
  private listeners: { type: string; fn: () => void }[] = [];

  get textContent(): string {
    return this.text + this.children.map((child) => child.textContent).join('');
  }

  set textContent(value: string) {
    this.text = value;
    this.children = [];
  }

  appendChild(child: Element): void {
    child.parent = this;
    this.children.push(child);
  }

  setAttribute(name: string, value: string): void {
    this.attrs.set(name, value);
  }

  getAttribute(name: string): string | null {
    return this.attrs.get(name) ?? null;
  }

  addEventListener(type: string, fn: () => void): void {
    this.listeners.push({ type, fn });
  }

  click(): void {
    if (this.type === 'checkbox') this.checked = !this.checked;
    for (const listener of this.listeners) {
      if (listener.type === 'click') listener.fn();
      if (this.type === 'checkbox' && listener.type === 'change') listener.fn();
    }
  }

  matches(selector: string): boolean {
    if (selector.startsWith('.')) {
      return this.className.split(/\s+/).includes(selector.slice(1));
    }
    const [tag, cls] = selector.split('.');
    if (tag && this.tagName !== tag.toUpperCase()) return false;
    return !cls || this.className.split(/\s+/).includes(cls);
  }

  closest(selector: string): Element | null {
    let node: Element | null = this;
    while (node) {
      if (node.matches(selector)) return node;
      node = node.parent;
    }
    return null;
  }

  querySelector(selector: string): Element | null {
    for (const child of this.children) {
      if (child.matches(selector)) return child;
      const nested = child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }
}

function shipped(kind: 'html' | 'css' | 'javascript'): string {
  const block = source.match(
    new RegExp(`static let ${kind} = """\\n([\\s\\S]*?)\\n {8}"""`),
  )?.[1];
  if (!block) throw new Error(`Missing shipped Web viewer ${kind}`);
  return block;
}

function harness(initialAuthCookie?: string) {
  const nodes = new Map<string, Element>();
  const node = (id: string) => {
    let value = nodes.get(id);
    if (!value) {
      value = new Element();
      nodes.set(id, value);
    }
    return value;
  };
  const requests: {
    path: string;
    method: string;
    body: string | undefined;
    cookieAtDispatch: string | null;
    settled: boolean;
    resolve: (body: unknown, status?: number) => void;
    reject: () => void;
    resolveMalformed: () => void;
  }[] = [];
  const modelAuth = initialAuthCookie !== undefined;
  let cookie: string | null = initialAuthCookie ?? null;
  const activeCookies = new Set(initialAuthCookie ? [initialAuthCookie] : []);
  const issuedCookies: string[] = [];
  const revokedCookies: (string | null)[] = [];
  let maximumInflightAuth = 0;
  const copied: string[] = [];
  const documentListeners: { type: string; fn: () => void }[] = [];
  const windowListeners: { type: string; fn: () => void }[] = [];
  const context = createContext({
    window: {
      location: { hash: '', origin: 'https://viewer.example' },
      addEventListener: (type: string, fn: () => void) =>
        windowListeners.push({ type, fn }),
      scrollY: 0,
      scrollTo(options: { top: number }) {
        this.scrollY = options.top;
      },
    },
    document: {
      getElementById: node,
      createElement: (tag?: string) => {
        const element = new Element();
        element.tagName = String(tag || 'div').toUpperCase();
        return element;
      },
      addEventListener: (type: string, fn: () => void) => {
        documentListeners.push({ type, fn });
      },
    },
    navigator: {
      clipboard: {
        writeText: (value: string) => {
          copied.push(value);
          return Promise.resolve();
        },
      },
    },
    TextEncoder,
    TextDecoder,
    URLSearchParams,
    fetch: (path: string, options?: { method?: string; body?: string }) =>
      new Promise((fulfill, reject) => {
        const request: (typeof requests)[number] = {
          path,
          method: options?.method ?? 'GET',
          body: options?.body,
          cookieAtDispatch: cookie,
          settled: false,
          reject: () => {
            if (request.settled) return;
            request.settled = true;
            reject(new Error('test-only disconnected transport'));
          },
          resolveMalformed: () => {
            if (request.settled) return;
            request.settled = true;
            fulfill({
              ok: true,
              status: 200,
              headers: {
                get: () => 'application/json',
              },
              json: async () => {
                throw new Error('test-only malformed json');
              },
            });
          },
          resolve: (body: unknown, status = 200) => {
            if (request.settled) return;
            request.settled = true;
            // Browser cookie effects precede the JS fetch continuation. An
            // epoch check cannot undo a late successful Set-Cookie response.
            if (modelAuth && path === '/web/api/auth' && status === 204) {
              if (request.method === 'POST') {
                cookie = `test-cookie-${issuedCookies.length + 1}`;
                issuedCookies.push(cookie);
                activeCookies.add(cookie);
              } else if (request.method === 'DELETE') {
                revokedCookies.push(request.cookieAtDispatch);
                if (request.cookieAtDispatch) {
                  activeCookies.delete(request.cookieAtDispatch);
                }
                cookie = null;
              }
            }
            fulfill({
              ok: status >= 200 && status < 300,
              status,
              headers: {
                get: () => (status === 204 ? '' : 'application/json'),
              },
              json: async () => body,
            });
          },
        };
        requests.push(request);
        maximumInflightAuth = Math.max(
          maximumInflightAuth,
          requests.filter(
            (pending) => pending.path === '/web/api/auth' && !pending.settled,
          ).length,
        );
      }),
  });
  runInContext(script, context);
  return {
    node,
    requests,
    copied,
    auth: {
      cookie: () => cookie,
      maximumInflight: () => maximumInflightAuth,
      activeCookies,
      issuedCookies,
      revokedCookies,
    },
    call: (expression: string) =>
      runInContext(expression, context) as Promise<void>,
    dispatchDocument: (type: string) => {
      for (const listener of documentListeners) {
        if (listener.type === type) listener.fn();
      }
    },
    dispatchWindow: (type: string) => {
      for (const listener of windowListeners)
        if (listener.type === type) listener.fn();
    },
  };
}

describe('legacy session ID navigation', () => {
  it('resolves a native ID before opening its canonical session', async () => {
    const ui = harness();
    ui.node('session-id').value = '  native + id  ';
    const pending = ui.call('jumpToSession({ preventDefault() {} })');
    expect(ui.requests[0].path).toBe(
      '/web/api/sessions?sessionId=native%20%2B%20id',
    );
    ui.requests[0].resolve({
      items: [{ sessionId: 'capture:canonical/id', source: 'codex' }],
    });
    for (let step = 0; step < 12; step += 1) await Promise.resolve();
    expect(ui.requests[1].path).toBe(
      '/web/api/sessions/capture%3Acanonical%2Fid',
    );
    ui.requests[1].resolve({
      detail: {
        session: {
          sessionId: 'capture:canonical/id',
          title: 'Resolved session',
        },
      },
    });
    await pending;
    expect(ui.node('detail').textContent).toContain('Resolved session');
    expect(ui.node('workspace').className).toBe('showing-detail');
  });

  it('shows ambiguous identities for selection and retains the ID on pagination', async () => {
    const ui = harness();
    ui.node('session-id').value = 'same-id';
    const pending = ui.call('jumpToSession({ preventDefault() {} })');
    ui.requests[0].resolve({
      snapshotId: 'snapshot',
      nextCursor: 'cursor',
      items: [
        { sessionId: 'machine-a', title: 'First machine' },
        { sessionId: 'machine-b', title: 'Second machine' },
      ],
    });
    await pending;
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('sessions').children).toHaveLength(2);
    expect(ui.node('status').textContent).toContain('Select');
    ui.node('query').value = 'unrelated edited search';
    const more = ui.call('loadSessions(true)');
    const query = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    expect(query.get('sessionId')).toBe('same-id');
    expect(query.get('query')).toBeNull();
    expect(query.get('cursor')).toBe('cursor');
    ui.requests[1].resolve({
      snapshotId: 'snapshot',
      items: [{ sessionId: 'machine-c' }],
    });
    await more;
    expect(ui.node('sessions').children).toHaveLength(3);
  });

  it('does not reveal a resolved session after logout supersedes the lookup', async () => {
    const ui = harness();
    ui.node('session-id').value = 'old-id';
    const pending = ui.call('jumpToSession({ preventDefault() {} })');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({
      items: [{ sessionId: 'canonical-id', title: 'Private title' }],
    });
    await pending;
    expect(ui.requests).toHaveLength(2);
    expect(ui.node('sessions').textContent).toBe('');
    expect(ui.node('detail').textContent).toBe('');
    expect(ui.node('status').textContent).toBe('signed out');
  });

  it('provides the ID form and rejects empty input without a request', async () => {
    expect(shipped('html')).toContain('id="session-jump"');
    expect(shipped('html')).toContain('id="session-id"');
    const ui = harness();
    ui.node('session-id').value = '  ';
    await ui.call('jumpToSession({ preventDefault() {} })');
    expect(ui.requests).toHaveLength(0);
    expect(ui.node('status').textContent).toContain('Enter a session ID');
  });
});

describe('native ranked search and readiness', () => {
  it('renders measured embedding progress and gates modes from current scoped status', async () => {
    const ui = harness();
    ui.node('since').value = '2026-09-01';
    const pending = ui.call('loadSearchStatus()');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(ui.requests[0].path).toContain('/web/api/search/status');
    expect(query.get('since')).toBe('2026-09-01');
    expect(query.has('query')).toBe(false);
    ui.requests[0].resolve({
      keyword: 'available',
      semantic: 'available',
      hybrid: 'available',
      eligibleSessionCount: 20,
      embeddedSessionCount: 12,
      progressPercent: 60,
      model: 'test-embedding',
    });
    await pending;
    expect(ui.node('search-capabilities').textContent).toContain('12 / 20');
    expect(ui.node('search-capabilities').textContent).toContain('60%');
    expect(ui.node('search-capabilities').textContent).toContain(
      'test-embedding',
    );
    expect(ui.node('mode-semantic').disabled).toBe(false);
    expect(ui.node('mode-hybrid').disabled).toBe(false);
  });

  it('uses ranked search with current filters and renders safe snippets plus fallback warnings', async () => {
    const ui = harness();
    await ui.call('activatePage("search")');
    ui.node('query').value = 'debug trace';
    ui.node('search-mode').value = 'hybrid';
    ui.node('search-limit').value = '25';
    ui.node('hide-tools').checked = true;
    const pending = ui.call('loadRankedSearch()');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(ui.requests[0].path).toContain('/web/api/search?');
    expect(query.get('query')).toBe('debug trace');
    expect(query.get('mode')).toBe('hybrid');
    expect(query.get('limit')).toBe('25');
    expect(query.get('tools')).toBe('hide');
    ui.requests[0].resolve({
      query: 'debug trace',
      searchModes: ['keyword'],
      warning: 'Semantic search unavailable; using keyword.',
      items: [
        {
          session: { sessionId: 'result', title: 'Debugging', source: 'codex' },
          snippet: '<script>plain transcript text</script>',
          matchType: 'keyword',
        },
      ],
    });
    await pending;
    expect(ui.node('search-result-status').textContent).toContain(
      'Semantic search unavailable',
    );
    expect(
      ui.node('sessions').children[0].querySelector('.search-snippet')
        ?.textContent,
    ).toBe('<script>plain transcript text</script>');
    expect(ui.node('sessions').textContent).toContain('Keyword match');
    expect(ui.node('sessions').textContent).toContain('Debugging');
    expect(ui.node('session-page-status').textContent).not.toContain(' of ');
    expect(ui.node('more').hidden).toBe(true);
  });

  // Web parity closeout: the legacy Web rendered service `<mark>` highlights
  // (`5013bab7:src/web/views.ts` sanitizeSnippet); the native Web showed the
  // literal tags. Only the mark markers become elements; other markup stays text.
  it('renders search snippet <mark> highlights as mark elements without parsing HTML', async () => {
    const ui = harness();
    await ui.call('activatePage("search")');
    ui.node('query').value = 'xcodegen';
    const pending = ui.call('loadRankedSearch()');
    ui.requests[0].resolve({
      query: 'xcodegen',
      searchModes: ['keyword'],
      items: [
        {
          session: { sessionId: 'hit', title: 'Build', source: 'codex' },
          snippet:
            '…run `<mark>xcodegen</mark> generate` then <script>alert(1)</script> and <mark>xcodegen</mark>\n…\nsecond row <mark>unterminated',
          matchType: 'keyword',
        },
      ],
    });
    await pending;
    const snippet = ui
      .node('sessions')
      .children[0].querySelector('.search-snippet');
    expect(snippet).not.toBeNull();
    expect(
      snippet!.children.map((node) => [node.tagName, node.textContent]),
    ).toEqual([
      ['SPAN', '…run `'],
      ['MARK', 'xcodegen'],
      ['SPAN', ' generate` then <script>alert(1)</script> and '],
      ['MARK', 'xcodegen'],
      ['SPAN', '\n…\nsecond row <mark>unterminated'],
    ]);
    expect(snippet!.querySelector('script')).toBeNull();
    expect(snippet!.textContent).toBe(
      '…run `xcodegen generate` then <script>alert(1)</script> and xcodegen\n…\nsecond row <mark>unterminated',
    );
  });

  it('clears readiness and ranked results on logout and ignores late responses', async () => {
    const ui = harness();
    await ui.call('activatePage("search")');
    ui.node('query').value = 'private';
    const status = ui.call('loadSearchStatus()');
    const search = ui.call('loadRankedSearch()');
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({
      keyword: 'available',
      semantic: 'available',
      hybrid: 'available',
      model: 'private-model',
    });
    ui.requests[1].resolve({
      query: 'private',
      searchModes: ['semantic'],
      items: [{ session: { sessionId: 'private' }, snippet: 'Private match' }],
    });
    await Promise.all([status, search]);
    expect(ui.node('search-capabilities').textContent).toBe('');
    expect(ui.node('search-result-status').textContent).toBe('');
    expect(ui.node('sessions').textContent).toBe('');
    expect(ui.node('mode-semantic').disabled).toBe(true);
  });
});

describe('legacy session paging and search filters', () => {
  it('shows one page at a time and revisits previous pages without losing the cursor', async () => {
    const ui = harness();
    const first = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      snapshotId: 'pages',
      totalCount: 3,
      nextCursor: 'second',
      items: [
        { sessionId: 'one', title: 'One' },
        { sessionId: 'two', title: 'Two' },
      ],
    });
    await first;
    expect(ui.node('session-page-status').textContent).toBe(
      '1–2 of 3 sessions',
    );
    const next = ui.call('changeSessionPage(1)');
    expect(
      new URLSearchParams(ui.requests[1].path.split('?')[1]).get('cursor'),
    ).toBe('second');
    ui.requests[1].resolve({
      snapshotId: 'pages',
      totalCount: 3,
      items: [{ sessionId: 'three', title: 'Three' }],
    });
    await next;
    expect(ui.node('sessions').children.map((child) => child.hidden)).toEqual([
      true,
      true,
      false,
    ]);
    expect(ui.node('session-page-status').textContent).toBe(
      '3–3 of 3 sessions',
    );
    await ui.call('changeSessionPage(-1)');
    expect(ui.node('sessions').children.map((child) => child.hidden)).toEqual([
      false,
      false,
      true,
    ]);
    await ui.call('changeSessionPage(1)');
    expect(ui.requests).toHaveLength(2);
    expect(ui.node('sessions').children.map((child) => child.hidden)).toEqual([
      true,
      true,
      false,
    ]);
  });

  it('pins dates and tool-output choice across continuation and resets pages on a new filter', async () => {
    const ui = harness();
    ui.node('query').value = 'needle';
    ui.node('since').value = '2026-09-01';
    ui.node('until').value = '2026-09-13';
    ui.node('hide-tools').checked = true;
    const first = ui.call('loadSessions(false)');
    const initial = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    ui.requests[0].resolve({
      snapshotId: 'pages',
      totalCount: 2,
      nextCursor: 'second',
      items: [{ sessionId: 'one' }],
    });
    await first;
    expect(initial.get('since')).toBe('2026-09-01');
    expect(initial.get('until')).toBe('2026-09-13');
    expect(initial.get('tools')).toBe('hide');
    ui.node('since').value = '2020-01-01';
    ui.node('hide-tools').checked = false;
    const more = ui.call('loadSessions(true)');
    const continued = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    ui.requests[1].resolve({
      snapshotId: 'pages',
      totalCount: 2,
      items: [{ sessionId: 'two' }],
    });
    await more;
    expect(continued.get('since')).toBe('2026-09-01');
    expect(continued.get('tools')).toBe('hide');
    const replacement = ui.call('loadSessions(false)');
    ui.requests[2].resolve({
      snapshotId: 'new-pages',
      totalCount: 1,
      items: [{ sessionId: 'new' }],
    });
    await replacement;
    expect(ui.node('sessions').children).toHaveLength(1);
    expect(ui.node('sessions').children[0].hidden).toBe(false);
    expect(ui.node('session-page-status').textContent).toBe(
      '1–1 of 1 sessions',
    );
    expect(ui.node('session-previous').hidden).toBe(true);
  });

  it('keeps paging usable when opening a detail supersedes a pending next page', async () => {
    const ui = harness();
    const first = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      snapshotId: 'pages',
      nextCursor: 'next',
      items: [{ sessionId: 'one' }],
    });
    await first;
    const next = ui.call('changeSessionPage(1)');
    const detail = ui.call('openDetail("one")');
    ui.requests[2].resolve({ detail: null });
    await detail;
    await ui.call('showSessionList()');
    ui.requests[1].resolve({
      snapshotId: 'pages',
      items: [{ sessionId: 'late' }],
    });
    await next;
    expect(ui.node('more').disabled).toBe(false);
    expect(ui.node('sessions').textContent).not.toContain('late');
  });

  it('does not invent totals for older responses and clears pagination on logout', async () => {
    const ui = harness();
    const first = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      snapshotId: 'old',
      items: [{ sessionId: 'one' }],
    });
    await first;
    expect(ui.node('session-page-status').textContent).toBe('1–1 sessions');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    expect(ui.node('session-page-status').textContent).toBe('');
    expect(ui.node('session-previous').hidden).toBe(true);
  });
});

describe('native Settings page', () => {
  it('restores the legacy sections with native values, safe alias labels and alias pagination', async () => {
    const ui = harness();
    const first = ui.call('navigate("settings")');
    const summary = {
      snapshotId: 'settings-snapshot',
      observedAt: 1789270000,
      totalSessions: 120,
      sources: [{ key: 'codex', label: 'codex' }],
      nodeName: { availability: 'unavailable' },
      peers: { availability: 'unavailable' },
      port: { availability: 'unavailable' },
    };
    ui.requests[0].resolve({
      ...summary,
      nextCursor: 'alias-next',
      aliases: [
        {
          alias: 'p.old',
          canonical: 'p.new',
          aliasLabel: 'Old Project',
          canonicalLabel: 'Engram',
        },
      ],
    });
    await first;
    const content = ui.node('settings-content');
    for (const text of [
      'Database',
      'Active Sources',
      'Sync',
      'Project Aliases',
      '120',
      'Codex',
      'https://viewer.example',
      'Old Project',
      'Engram',
    ]) {
      expect(content.textContent).toContain(text);
    }
    expect(content.textContent).not.toContain('p.old');
    expect(content.textContent).not.toContain('No peers configured');
    // Legacy local-machine probes are explicitly mapped, never silently omitted
    // (docs/superpowers/plans/2026-09-13-web-native-parity.md, legacy GET inventory).
    expect(content.textContent).toContain('Health page');
    expect(content.textContent).toContain('Not available in this deployment');
    for (const retired of [
      'Skills, hooks, memory files and hygiene checks',
      'Live session events and monitor alerts',
      'Resume launch and link-sessions',
      'Developer mock, lint and log utilities',
    ]) {
      expect(content.textContent).toContain(retired);
    }
    const more = ui.call('loadSettings(true)');
    const query = new URLSearchParams(ui.requests[2].path.split('?')[1]);
    expect(query.get('snapshotId')).toBe('settings-snapshot');
    expect(query.get('cursor')).toBe('alias-next');
    ui.requests[2].resolve({
      ...summary,
      aliases: [
        {
          alias: 'research',
          canonical: 'notes',
          aliasLabel: 'Research',
          canonicalLabel: 'Notes',
        },
      ],
    });
    await more;
    expect(content.querySelector('tbody')?.children).toHaveLength(2);
    expect(content.textContent).toContain('Research');
    expect(ui.node('settings-more').hidden).toBe(true);
  });

  it('loads the settings read endpoint and reports failure without inventing settings', async () => {
    const ui = harness();
    const pending = ui.call('navigate("settings")').catch(() => {});
    const path = ui.requests[0].path;
    ui.requests[0].resolve({}, 503);
    await pending;
    expect(path).toBe('/web/api/settings');
    expect(ui.node('settings-status').textContent).toContain('unavailable');
    expect(ui.node('settings-content').textContent).toBe('');
    expect(shipped('html')).toContain('href="#settings"');
  });

  it('clears settings on logout and ignores a late response', async () => {
    const ui = harness();
    ui.node('settings-content').textContent = 'Private project alias';
    const pending = ui.call('navigate("settings")').catch(() => {});
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({}, 503);
    await pending;
    expect(ui.node('settings-content').textContent).toBe('');
    expect(ui.node('settings-status').textContent).toBe('');
  });
});

describe('Settings alias editing', () => {
  const summary = {
    snapshotId: 'settings',
    totalSessions: 1,
    sources: [],
    aliases: [
      {
        alias: 'p.old',
        canonical: 'p.new',
        aliasLabel: 'Old',
        canonicalLabel: 'New',
      },
    ],
  };
  async function ready(editor: boolean) {
    const ui = harness();
    const pending = ui.call('navigate("settings")');
    ui.requests[0].resolve(summary);
    await pending;
    expect(ui.requests[1].path).toBe('/web/api/auth');
    ui.requests[1].resolve({ canWrite: editor });
    for (let i = 0; i < 5; i++) await Promise.resolve();
    return ui;
  }
  it('keeps viewers read only and obtains editor authority from the current cookie', async () => {
    const ui = await ready(false);
    expect(ui.node('alias-editor').hidden).toBe(true);
    expect(ui.node('settings-access').textContent).toContain('Read only');
    const before = ui.requests.length;
    await ui.call('mutateAlias("remove", {alias:"p.old", canonical:"p.new"})');
    expect(ui.requests).toHaveLength(before);
  });
  it('deletes the published pair, waits for success, and refreshes authoritative settings', async () => {
    const ui = await ready(true);
    const before = ui.requests.length;
    const pending = ui.call(
      'mutateAlias("remove", {alias:"p.old", canonical:"p.new"})',
    );
    expect(ui.requests[before].method).toBe('DELETE');
    expect(JSON.parse(ui.requests[before].body ?? '')).toEqual({
      alias: 'p.old',
      canonical: 'p.new',
    });
    expect(ui.node('settings-content').textContent).toContain('Old');
    await ui.call('mutateAlias("remove", {alias:"p.old", canonical:"p.new"})');
    expect(ui.requests).toHaveLength(before + 1);
    ui.requests[before].resolve({
      action: 'remove',
      alias: 'p.old',
      canonical: 'p.new',
      changed: 1,
    });
    for (let i = 0; i < 5; i++) await Promise.resolve();
    expect(ui.requests[before + 1].path).toBe('/web/api/settings');
    ui.requests[before + 1].resolve({ ...summary, aliases: [] });
    await pending;
    expect(
      ui.node('settings-content').querySelector('tbody')?.children,
    ).toHaveLength(0);
    expect(ui.node('alias-status').textContent).toContain('removed');
  });
  it('adds explicit path text to a selected authorized project and reports denied writes', async () => {
    const ui = await ready(true);
    const picker = ui.requests.find((request) =>
      request.path.startsWith('/web/api/facets?'),
    );
    expect(picker).toBeDefined();
    picker?.resolve({
      snapshotId: 'projects',
      items: [{ key: 'p.new', label: 'New' }],
    });
    for (let i = 0; i < 5; i++) await Promise.resolve();
    ui.node('alias-text').value = '/old/engram';
    ui.node('alias-canonical').value = 'p.new';
    const pending = ui.call('addAlias()');
    const write = ui.requests.at(-1);
    expect(write?.method).toBe('POST');
    expect(JSON.parse(write?.body ?? '')).toEqual({
      alias: '/old/engram',
      canonical: 'p.new',
    });
    write?.resolve({}, 403);
    await pending;
    expect(ui.node('alias-status').textContent).toContain('Editor access');
    expect(ui.node('settings-content').textContent).toContain('Old');
    expect(ui.node('alias-editor').hidden).toBe(true);
  });
  it('pages destination projects with a pinned query and keeps their published identities', async () => {
    const ui = await ready(true);
    ui.requests.at(-1)?.resolve({
      snapshotId: 'projects',
      nextCursor: 'next',
      items: [{ key: 'p.new', label: 'New' }],
    });
    for (let i = 0; i < 5; i++) await Promise.resolve();
    ui.node('alias-project-query').value = 'not submitted';
    const more = ui.call('loadAliasProjects(true)');
    const query = new URLSearchParams(ui.requests.at(-1)?.path.split('?')[1]);
    expect(query.get('snapshotId')).toBe('projects');
    expect(query.get('cursor')).toBe('next');
    expect(query.has('query')).toBe(false);
    ui.requests.at(-1)?.resolve({
      snapshotId: 'projects',
      items: [{ key: 'p.other', label: '<Other>' }],
    });
    await more;
    expect(
      ui.node('alias-canonical').children.map((item) => item.value),
    ).toEqual(['p.new', 'p.other']);
    expect(ui.node('alias-canonical').textContent).toContain('<Other>');
    expect(ui.node('alias-project-more').hidden).toBe(true);
  });
  it('does not restore editor access from a response arriving after logout', async () => {
    const ui = harness();
    const first = ui.call('navigate("settings")');
    ui.requests[0].resolve(summary);
    await first;
    const access = ui.requests[1];
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    access.resolve({ canWrite: true });
    for (let i = 0; i < 5; i++) await Promise.resolve();
    expect(ui.node('alias-editor').hidden).toBe(true);
    expect(ui.requests).toHaveLength(3);
  });
  it('expires a rejected write session and does not infer success from a failed request', async () => {
    const ui = await ready(true);
    const pending = ui.call(
      'mutateAlias("remove", {alias:"p.old", canonical:"p.new"})',
    );
    ui.requests.at(-1)?.resolve({}, 401);
    await pending;
    expect(ui.node('status').textContent).toBe('Session expired');
    expect(ui.node('settings-content').textContent).toBe('');
    expect(ui.node('alias-editor').hidden).toBe(true);
  });
  it('ignores delayed write success after logout', async () => {
    const ui = await ready(true);
    const pending = ui.call(
      'mutateAlias("remove", {alias:"p.old", canonical:"p.new"})',
    );
    const write = ui.requests.at(-1);
    const logout = ui.call('logout()');
    ui.requests.at(-1)?.resolve(undefined, 204);
    await logout;
    const count = ui.requests.length;
    write?.resolve({
      action: 'remove',
      alias: 'p.old',
      canonical: 'p.new',
      changed: 1,
    });
    await pending;
    expect(ui.requests).toHaveLength(count);
    expect(ui.node('settings-content').textContent).toBe('');
    expect(ui.node('alias-status').textContent).toBe('');
  });
});

describe('native source configuration', () => {
  async function ready(editor: boolean, allOff = false) {
    const ui = harness();
    const pending = ui.call('navigate("settings")');
    ui.requests[0].resolve(
      allOff
        ? {}
        : {
            snapshotId: 'settings',
            totalSessions: 1,
            sources: [],
            aliases: [],
          },
      allOff ? 503 : 200,
    );
    await pending;
    const access = ui.requests.find(
      (request) => request.path === '/web/api/auth',
    );
    expect(access).toBeDefined();
    access?.resolve({ canWrite: editor });
    for (let i = 0; i < 5; i++) await Promise.resolve();
    const sources = ui.requests.find(
      (request) => request.path === '/web/api/settings/sources',
    );
    expect(sources).toBeDefined();
    sources?.resolve({
      sources: [
        { key: 'codex', label: 'codex', enabled: !allOff },
        { key: 'cursor', label: 'cursor', enabled: false },
      ],
    });
    for (let i = 0; i < 5; i++) await Promise.resolve();
    return ui;
  }
  it('shows real disabled states to a viewer without allowing writes', async () => {
    const ui = await ready(false);
    expect(ui.node('source-settings').hidden).toBe(false);
    expect(ui.node('source-settings-rows').textContent).toContain(
      'CodexEnabled',
    );
    expect(ui.node('source-settings-rows').textContent).toContain(
      'CursorDisabled',
    );
    expect(
      ui.node('source-settings-rows').querySelector('button')?.disabled,
    ).toBe(true);
    const count = ui.requests.length;
    await ui.call('setWebSourceEnabled("codex", false)');
    expect(ui.requests).toHaveLength(count);
  });
  it('retains re-enable controls when all sources are off and metadata is unavailable', async () => {
    const ui = await ready(true, true);
    expect(ui.node('source-settings').hidden).toBe(false);
    expect(
      ui.node('source-settings-rows').querySelector('button')?.disabled,
    ).toBe(false);
    const pending = ui.call('setWebSourceEnabled("codex", true)');
    const write = ui.requests.at(-1);
    expect(write?.method).toBe('POST');
    expect(JSON.parse(write?.body ?? '')).toEqual({
      source: 'codex',
      enabled: true,
    });
    write?.resolve({ source: 'codex', enabled: true });
    await new Promise<void>((resolve) => setImmediate(resolve));
    const reload = ui.requests.find(
      (request) => request.path === '/web/api/settings' && !request.settled,
    );
    expect(reload).toBeDefined();
    const refreshedAccess = ui.requests.find(
      (request) => request.path === '/web/api/auth' && !request.settled,
    );
    refreshedAccess?.resolve({ canWrite: true });
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(
      ui.requests.filter((request) =>
        request.path.startsWith('/web/api/facets?'),
      ),
    ).toHaveLength(2);
    reload?.resolve({
      snapshotId: 'fresh',
      totalSessions: 1,
      sources: [{ key: 'codex', label: 'codex' }],
      aliases: [],
    });
    await pending;
    expect(ui.node('source-write-status').textContent).toContain('enabled');
    expect(ui.node('status').textContent).toBe('signed in');
  });
  it('does not change a source state before confirmation and blocks duplicate writes', async () => {
    const ui = await ready(true);
    const pending = ui.call('setWebSourceEnabled("codex", false)');
    const write = ui.requests.at(-1);
    const count = ui.requests.length;
    expect(ui.node('source-settings-rows').textContent).toContain(
      'CodexEnabled',
    );
    await ui.call('setWebSourceEnabled("cursor", true)');
    expect(ui.requests).toHaveLength(count);
    write?.resolve({}, 503);
    await pending;
    expect(ui.node('source-settings-rows').textContent).toContain(
      'CodexEnabled',
    );
    expect(ui.node('source-write-status').textContent).toContain(
      'Could not confirm',
    );
  });
  it('discards late configuration responses after logout', async () => {
    const ui = await ready(true);
    const pending = ui.call('setWebSourceEnabled("codex", false)');
    const write = ui.requests.at(-1);
    const logout = ui.call('logout()');
    ui.requests.at(-1)?.resolve(undefined, 204);
    await logout;
    const count = ui.requests.length;
    write?.resolve({ source: 'codex', enabled: false });
    await pending;
    expect(ui.requests).toHaveLength(count);
    expect(ui.node('source-settings-rows').textContent).toBe('');
    expect(ui.node('source-write-status').textContent).toBe('');
  });
});

describe('detail children and timeline', () => {
  async function ready(generation = true) {
    const ui = harness();
    const pending = ui.call('openDetail("parent")');
    ui.requests[0].resolve({
      detail: {
        session: {
          sessionId: 'parent',
          title: 'Parent session',
          source: 'codex',
        },
        ...(generation ? { transcriptGeneration: 'gen-1' } : {}),
      },
    });
    await new Promise<void>((resolve) => setImmediate(resolve));
    if (generation) ui.requests[1].resolve({ fragments: [] });
    await pending;
    return ui;
  }
  it('loads child sessions on demand even without a transcript and distinguishes relationship kinds', async () => {
    const ui = await ready(false);
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('detail-view-timeline').disabled).toBe(true);
    const pending = ui.call('showDetailView("children")');
    expect(ui.requests[1].path).toContain('/web/api/sessions/parent/children');
    ui.requests[1].resolve({
      sessionId: 'parent',
      snapshotId: 'children-1',
      items: [
        {
          relationship: 'confirmed',
          session: {
            sessionId: 'child-one',
            title: '<Confirmed>',
            source: 'codex',
          },
        },
        {
          relationship: 'suggested',
          session: {
            sessionId: 'child-two',
            title: 'Suggested child',
            source: 'cursor',
          },
        },
      ],
    });
    await pending;
    expect(ui.node('detail-children-rows').textContent).toContain('Confirmed');
    expect(ui.node('detail-children-rows').textContent).toContain('Suggested');
    expect(ui.node('detail-children-rows').textContent).toContain(
      '<Confirmed>',
    );
    ui.node('detail-children-rows')
      .children[0].querySelector('button')
      ?.click();
    expect(ui.requests.at(-1)?.path).toBe('/web/api/sessions/child-one');
  });
  it('pins child continuation to its parent and snapshot', async () => {
    const ui = await ready();
    const first = ui.call('showDetailView("children")');
    ui.requests.at(-1)?.resolve({
      sessionId: 'parent',
      snapshotId: 'children-1',
      nextCursor: 'next',
      items: [
        {
          relationship: 'confirmed',
          session: { sessionId: 'one', title: 'One' },
        },
      ],
    });
    await first;
    const more = ui.call('loadDetailChildren(true)');
    const query = new URLSearchParams(ui.requests.at(-1)?.path.split('?')[1]);
    expect(query.get('snapshotId')).toBe('children-1');
    expect(query.get('cursor')).toBe('next');
    ui.requests.at(-1)?.resolve({
      sessionId: 'parent',
      snapshotId: 'children-1',
      items: [
        {
          relationship: 'suggested',
          session: { sessionId: 'two', title: 'Two' },
        },
      ],
    });
    await more;
    expect(ui.node('detail-children-rows').children).toHaveLength(2);
    expect(ui.node('detail-children-more').hidden).toBe(true);
  });
  it('refreshes children even when the service repeats a valid first-page cursor', async () => {
    const ui = await ready();
    const page = {
      sessionId: 'parent',
      snapshotId: 'children-1',
      nextCursor: 'next',
      items: [
        {
          relationship: 'confirmed',
          session: { sessionId: 'one', title: 'One' },
        },
      ],
    };
    const first = ui.call('showDetailView("children")');
    ui.requests.at(-1)?.resolve(page);
    await first;
    const refresh = ui.call('loadDetailChildren(false)');
    ui.requests.at(-1)?.resolve(page);
    await refresh;
    expect(ui.node('detail-children-status').textContent).toBe(
      '1 child sessions loaded',
    );
    expect(ui.node('detail-children-rows').children).toHaveLength(1);
  });
  it('shows timeline metadata and pages original ordinals in the pinned generation', async () => {
    const ui = await ready();
    expect(ui.requests).toHaveLength(2);
    const pending = ui.call('showDetailView("timeline")');
    const query = new URLSearchParams(ui.requests.at(-1)?.path.split('?')[1]);
    expect(query.get('generation')).toBe('gen-1');
    expect(query.get('offset')).toBe('0');
    ui.requests.at(-1)?.resolve({
      sessionId: 'parent',
      generation: 'gen-1',
      totalEntries: 3,
      nextOffset: 2,
      entries: [
        {
          index: 0,
          role: 'user',
          type: 'message',
          preview: '<user preview>',
          timestamp: '2026-09-13T00:00:00Z',
          durationToNextMs: 2500,
        },
        {
          index: 1,
          role: 'assistant',
          type: 'tool_use',
          preview: 'Inspect file',
          toolName: 'read_file',
          tokens: { input: 120, output: 45 },
        },
      ],
    });
    await pending;
    expect(ui.node('timeline-rows').textContent).toContain('<user preview>');
    expect(ui.node('timeline-rows').textContent).toContain('read_file');
    expect(ui.node('timeline-rows').textContent).toContain('120');
    expect(ui.node('timeline-status').textContent).toContain('2 / 3');
    const more = ui.call('loadDetailTimeline(true)');
    expect(
      new URLSearchParams(ui.requests.at(-1)?.path.split('?')[1]).get('offset'),
    ).toBe('2');
    ui.requests.at(-1)?.resolve({
      sessionId: 'parent',
      generation: 'gen-1',
      totalEntries: 3,
      entries: [
        {
          index: 2,
          role: 'tool',
          type: 'tool_result',
          preview: 'File contents',
        },
      ],
    });
    await more;
    expect(ui.node('timeline-rows').children).toHaveLength(3);
    expect(ui.node('timeline-more').hidden).toBe(true);
    await ui.call('showDetailView("transcript")');
    expect(ui.node('transcript-panel').hidden).toBe(false);
  });
  it('rejects changed timeline generations instead of showing unrelated content', async () => {
    const ui = await ready();
    const pending = ui.call('showDetailView("timeline")');
    ui.requests.at(-1)?.resolve({
      sessionId: 'parent',
      generation: 'other-generation',
      totalEntries: 1,
      entries: [
        {
          index: 0,
          role: 'user',
          type: 'message',
          preview: 'Wrong generation',
        },
      ],
    });
    await pending;
    expect(ui.node('timeline-rows').textContent).toBe('');
    expect(ui.node('timeline-status').textContent).toContain('unavailable');
  });
  it('clears both detail views and ignores a late timeline after logout', async () => {
    const ui = await ready();
    const pending = ui.call('showDetailView("timeline")');
    const timeline = ui.requests.at(-1);
    const logout = ui.call('logout()');
    ui.requests.at(-1)?.resolve(undefined, 204);
    await logout;
    timeline?.resolve({
      sessionId: 'parent',
      generation: 'gen-1',
      totalEntries: 1,
      entries: [
        { index: 0, role: 'user', type: 'message', preview: 'Private preview' },
      ],
    });
    await pending;
    expect(ui.node('timeline-rows').textContent).toBe('');
    expect(ui.node('detail-children-rows').textContent).toBe('');
    expect(ui.node('detail-view-nav').hidden).toBe(true);
  });
});

describe('detail relationship editing', () => {
  const children = {
    sessionId: 'parent',
    snapshotId: 'children-1',
    items: [
      {
        relationship: 'confirmed',
        session: { sessionId: 'linked', title: 'Linked child' },
      },
      {
        relationship: 'suggested',
        session: { sessionId: 'suggested', title: 'Suggested child' },
      },
    ],
  };
  async function ready(editor = true) {
    const ui = harness();
    const detail = ui.call('openDetail("parent")');
    ui.requests[0].resolve({
      detail: { session: { sessionId: 'parent', title: 'Parent' } },
    });
    await detail;
    const list = ui.call('showDetailView("children")');
    ui.requests.at(-1)?.resolve(children);
    await list;
    const access = ui.call('loadRelationshipAccess()');
    ui.requests.at(-1)?.resolve({ canWrite: editor });
    await access;
    return ui;
  }
  it('keeps relationship writes unavailable for viewer sessions', async () => {
    const ui = await ready(false);
    expect(ui.node('relationship-form').hidden).toBe(true);
    expect(ui.node('relationship-access').textContent).toContain('Read only');
    const before = ui.requests.length;
    await ui.call('mutateRelationship("unlink", "linked", "parent")');
    expect(ui.requests).toHaveLength(before);
    expect(ui.node('detail-children-rows').textContent).not.toContain('Unlink');
  });
  it('attaches a child to the viewed parent and waits for confirmation before refreshing', async () => {
    const ui = await ready();
    ui.node('relationship-child-id').value = ' new-child ';
    const pending = ui.call('attachDetailChild()');
    const write = ui.requests.at(-1);
    expect(write?.method).toBe('POST');
    expect(write?.path).toBe('/web/api/sessions/new-child/link');
    expect(JSON.parse(write?.body || '{}')).toEqual({ parentId: 'parent' });
    expect(ui.node('detail-children-rows').children).toHaveLength(2);
    const count = ui.requests.length;
    await ui.call('attachDetailChild()');
    expect(ui.requests).toHaveLength(count);
    write?.resolve({ sessionId: 'new-child', action: 'link', ok: true });
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(ui.requests.at(-1)?.path).toContain('/parent/children?');
    ui.requests.at(-1)?.resolve({
      ...children,
      items: [
        ...children.items,
        {
          relationship: 'confirmed',
          session: { sessionId: 'new-child', title: 'New child' },
        },
      ],
    });
    await pending;
    expect(ui.node('detail-children-rows').children).toHaveLength(3);
    expect(ui.node('relationship-child-id').value).toBe('');
    expect(ui.node('relationship-status').textContent).toContain('linked');
  });
  it.each([
    ['unlink', 'linked', 'DELETE', 'link', {}],
    [
      'confirmSuggestion',
      'suggested',
      'POST',
      'confirm-suggestion',
      { suggestedParentId: 'parent' },
    ],
    [
      'dismissSuggestion',
      'suggested',
      'DELETE',
      'suggestion',
      { suggestedParentId: 'parent' },
    ],
  ])(
    'sends the scoped %s operation and refreshes child relationships',
    async (action, child, method, path, body) => {
      const ui = await ready();
      const pending = ui.call(
        `mutateRelationship(${JSON.stringify(action)}, ${JSON.stringify(child)}, "parent")`,
      );
      const write = ui.requests.at(-1);
      expect(write?.method).toBe(method);
      expect(write?.path).toBe(`/web/api/sessions/${child}/${path}`);
      expect(JSON.parse(write?.body || '{}')).toEqual(body);
      write?.resolve({ sessionId: child, action, ok: true });
      await new Promise<void>((resolve) => setImmediate(resolve));
      ui.requests.at(-1)?.resolve({ ...children, items: [] });
      await pending;
      expect(ui.node('detail-children-rows').children).toHaveLength(0);
    },
  );
  it('refreshes a changed suggestion on conflict without claiming success', async () => {
    const ui = await ready();
    const pending = ui.call(
      'mutateRelationship("confirmSuggestion", "suggested", "parent")',
    );
    ui.requests.at(-1)?.resolve({}, 409);
    await new Promise<void>((resolve) => setImmediate(resolve));
    ui.requests.at(-1)?.resolve({ ...children, items: [] });
    await pending;
    expect(ui.node('relationship-status').textContent).toContain('changed');
    expect(ui.node('detail-children-rows').children).toHaveLength(0);
  });
  it('revokes editor controls on write denial', async () => {
    const ui = await ready();
    const pending = ui.call('mutateRelationship("unlink", "linked", "parent")');
    ui.requests.at(-1)?.resolve({}, 403);
    await pending;
    expect(ui.node('relationship-form').hidden).toBe(true);
    expect(ui.node('relationship-status').textContent).toContain(
      'Editor access required',
    );
  });
  it('does not restore relationship controls after a late access reply following logout', async () => {
    const ui = await ready(false);
    const pending = ui.call('loadRelationshipAccess()');
    const access = ui.requests.at(-1);
    const logout = ui.call('logout()');
    ui.requests.at(-1)?.resolve(undefined, 204);
    await logout;
    access?.resolve({ canWrite: true });
    await pending;
    expect(ui.node('relationship-form').hidden).toBe(true);
    expect(ui.node('detail-children-rows').textContent).toBe('');
  });
});

describe('native paged statistics', () => {
  const totals = {
    sessionCount: 120,
    messageCount: 900,
    userMessageCount: 300,
    assistantMessageCount: 400,
    toolMessageCount: 200,
  };
  it('renders server totals and pins the submitted grouping, dates and noise choice across pages', async () => {
    const ui = harness();
    ui.node('stats-group').value = 'project';
    ui.node('stats-since').value = '2026-09-01';
    ui.node('stats-until').value = '2026-09-13';
    ui.node('stats-noise').checked = true;
    const first = ui.call('navigate("stats")');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(query.get('groupBy')).toBe('project');
    expect(query.get('since')).toBe('2026-09-01');
    expect(query.get('until')).toBe('2026-09-13');
    expect(query.get('excludeNoise')).toBe('true');
    ui.requests[0].resolve({
      snapshotId: 'stats',
      groupBy: 'project',
      timeZone: 'Asia/Shanghai',
      totals,
      items: [
        {
          key: 'one',
          label: 'Engram',
          sessionCount: 80,
          messageCount: 600,
          userMessageCount: 200,
          assistantMessageCount: 300,
          toolMessageCount: 100,
        },
      ],
      nextCursor: 'next',
    });
    await first;
    expect(ui.node('stats-totals').textContent).toContain('Sessions120');
    expect(ui.node('stats-rows').children).toHaveLength(1);
    expect(ui.node('stats-status').textContent).toContain('Asia/Shanghai');
    ui.node('stats-group').value = 'day';
    ui.node('stats-since').value = '2020-01-01';
    const more = ui.call('loadStats(true)');
    const continued = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    expect(continued.get('groupBy')).toBe('project');
    expect(continued.get('since')).toBe('2026-09-01');
    expect(continued.get('cursor')).toBe('next');
    ui.requests[1].resolve({
      snapshotId: 'stats',
      groupBy: 'project',
      timeZone: 'Asia/Shanghai',
      totals,
      items: [
        {
          key: 'two',
          label: 'Research',
          sessionCount: 40,
          messageCount: 300,
          userMessageCount: 100,
          assistantMessageCount: 100,
          toolMessageCount: 100,
        },
      ],
    });
    await more;
    expect(ui.node('stats-rows').children).toHaveLength(2);
    expect(ui.node('stats-more').hidden).toBe(true);
    expect(ui.node('stats-totals').textContent).toContain('Sessions120');
  });

  it('does not repaint a late statistics response after logout', async () => {
    const ui = harness();
    const pending = ui.call('navigate("stats")');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({
      snapshotId: 'stats',
      groupBy: 'source',
      timeZone: 'UTC',
      totals,
      items: [{ key: 'private', label: 'Private group', ...totals }],
    });
    await pending;
    expect(ui.node('stats-rows').textContent).toBe('');
    expect(ui.node('stats-totals').textContent).toBe('');
  });

  it('renders unavailable statistics without inventing zero totals', async () => {
    const ui = harness();
    const pending = ui.call('navigate("stats")');
    ui.requests[0].resolve({}, 503);
    await pending;
    expect(ui.node('stats-status').textContent).toContain('unavailable');
    expect(ui.node('stats-totals').textContent).toBe('');
    expect(shipped('html')).toContain('href="#stats"');
  });
});

describe('native costs in Stats', () => {
  const totals = {
    costUsd: 12.34,
    sessionCount: 120,
    inputTokens: 9000,
    outputTokens: 3000,
    cacheReadTokens: 2000,
    cacheCreationTokens: 500,
  };
  const grouped = {
    snapshotId: 'costs',
    observedAt: 1,
    groupBy: 'project',
    timeZone: 'Asia/Shanghai',
    totals,
    items: [{ key: 'engram', label: 'Engram', ...totals }],
    unpricedUnattributedSessions: 2,
    unpricedNoPriceSessions: 1,
  };
  const top = {
    observedAt: 1,
    items: [
      {
        session: {
          sessionId: 'cost/session',
          title: 'Review migration',
          source: 'codex',
        },
        model: 'test-model',
        costUsd: 3.21,
        inputTokens: 100,
        outputTokens: 20,
        cacheReadTokens: 5,
        cacheCreationTokens: 2,
      },
    ],
  };

  it('shows full cost totals and pins group/date filters across continuation', async () => {
    const ui = harness();
    ui.node('costs-group').value = 'project';
    ui.node('costs-since').value = '2026-09-01';
    ui.node('costs-until').value = '2026-09-13';
    ui.node('costs-agents').value = 'all';
    ui.node('costs-limit').value = '100';
    const first = ui.call('showStatsView("costs")');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(query.get('groupBy')).toBe('project');
    expect(query.get('since')).toBe('2026-09-01');
    expect(query.get('until')).toBe('2026-09-13');
    expect(query.get('agents')).toBe('all');
    const topQuery = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    expect(topQuery.get('limit')).toBe('100');
    expect(topQuery.has('groupBy')).toBe(false);
    ui.requests[0].resolve({
      ...grouped,
      items: [{ ...grouped.items[0], costUsd: 5 }],
      nextCursor: 'next',
    });
    ui.requests[1].resolve(top);
    await first;
    expect(ui.node('costs-totals').textContent).toContain('$12.34');
    expect(ui.node('costs-totals').textContent).toContain('Sessions120');
    expect(ui.node('costs-unpriced').textContent).toContain('2');
    expect(ui.node('costs-status').textContent).toContain('Asia/Shanghai');
    ui.node('costs-group').value = 'day';
    ui.node('costs-since').value = '2020-01-01';
    const more = ui.call('loadCosts(true)');
    const next = new URLSearchParams(ui.requests[2].path.split('?')[1]);
    expect(next.get('groupBy')).toBe('project');
    expect(next.get('since')).toBe('2026-09-01');
    expect(next.get('snapshotId')).toBe('costs');
    expect(next.get('cursor')).toBe('next');
    ui.requests[2].resolve({
      ...grouped,
      items: [
        { ...grouped.items[0], key: 'other', label: 'Other', costUsd: 7.34 },
      ],
    });
    await more;
    expect(ui.requests).toHaveLength(3);
    expect(ui.node('costs-rows').children).toHaveLength(2);
    expect(ui.node('costs-more').hidden).toBe(true);
    expect(ui.node('costs-totals').textContent).toContain('$12.34');
  });

  it('opens a nested cost session and returns to the costs view', async () => {
    const ui = harness();
    ui.node('costs-group').value = 'project';
    const pending = ui.call('showStatsView("costs")');
    ui.requests[0].resolve(grouped);
    ui.requests[1].resolve(top);
    await pending;
    expect(ui.node('costs-sessions').textContent).toContain('Review migration');
    expect(ui.node('costs-sessions').textContent).toContain('$3.21');
    const button = ui.node('costs-sessions').querySelector('button');
    expect(button).not.toBeNull();
    button?.click();
    expect(ui.requests[2].path).toBe('/web/api/sessions/cost%2Fsession');
    ui.requests[2].resolve({
      detail: {
        session: top.items[0].session,
        transcriptAvailability: 'unavailable',
      },
    });
    for (let tick = 0; tick < 16; tick += 1) await Promise.resolve();
    expect(ui.node('back').textContent).toBe('Costs');
    ui.node('back').click();
    expect(ui.node('stats-page').hidden).toBe(false);
    expect(ui.node('costs-content').hidden).toBe(false);
    expect(ui.node('costs-sessions').textContent).toContain('Review migration');
  });

  it('clears costs and ignores both late responses after logout', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("costs")');
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve(grouped);
    ui.requests[1].resolve(top);
    await pending;
    for (const id of [
      'costs-totals',
      'costs-rows',
      'costs-sessions',
      'costs-status',
      'costs-unpriced',
    ])
      expect(ui.node(id).textContent).toBe('');
  });

  it('reports an unavailable cost service without inventing zero totals', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("costs")');
    ui.requests[0].resolve({}, 503);
    ui.requests[1].resolve({}, 503);
    await pending;
    expect(ui.node('costs-status').textContent).toContain('unavailable');
    expect(ui.node('costs-sessions-status').textContent).toContain(
      'unavailable',
    );
    expect(ui.node('costs-totals').textContent).toBe('');
  });
});

describe('native tool analytics in Stats', () => {
  const page = {
    snapshotId: 'tools',
    observedAt: 1,
    groupBy: 'tool',
    totalCalls: 12,
    groupCount: 2,
    items: [
      {
        key: 'read',
        label: 'Read',
        callCount: 8,
        sessionCount: 3,
        toolCount: 1,
      },
    ],
    nextCursor: 'next',
  };

  it('preserves filters and full totals across tool pages', async () => {
    const ui = harness();
    ui.node('tools-project').value = 'alpha';
    ui.node('tools-since').value = '2026-09-01';
    ui.node('tools-agents').value = 'all';
    const first = ui.call('showStatsView("tools")');
    expect(ui.requests[0].path).toContain('/web/api/tool-analytics?');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(query.get('project')).toBe('alpha');
    expect(query.get('since')).toBe('2026-09-01');
    expect(query.get('agents')).toBe('all');
    ui.requests[0].resolve(page);
    await first;
    expect(ui.node('tools-totals').textContent).toContain('12 calls');
    expect(ui.node('tools-totals').textContent).toContain('2 groups');
    expect(ui.node('stats-content').hidden).toBe(true);
    ui.node('tools-project').value = 'changed';
    const next = ui.call('loadTools(true)');
    expect(
      new URLSearchParams(ui.requests[1].path.split('?')[1]).get('project'),
    ).toBe('alpha');
    ui.requests[1].resolve({
      ...page,
      items: [{ ...page.items[0], key: 'edit', label: 'Edit', callCount: 4 }],
      nextCursor: undefined,
    });
    await next;
    expect(ui.node('tools-rows').children).toHaveLength(2);
    expect(ui.node('tools-more').hidden).toBe(true);
    expect(ui.node('tools-totals').textContent).toContain('12 calls');
  });

  it('opens analytics session detail and returns to Tools', async () => {
    const ui = harness();
    ui.node('tools-group').value = 'session';
    const pending = ui.call('showStatsView("tools")');
    ui.requests[0].resolve({
      ...page,
      groupBy: 'session',
      items: [
        { ...page.items[0], sessionId: 'tool/session', label: 'Fix capture' },
      ],
      nextCursor: undefined,
    });
    await pending;
    ui.node('tools-rows').querySelector('button')?.click();
    expect(ui.requests[1].path).toBe('/web/api/sessions/tool%2Fsession');
    ui.requests[1].resolve({
      detail: {
        session: {
          sessionId: 'tool/session',
          title: 'Fix capture',
          source: 'codex',
        },
        transcriptAvailability: 'unavailable',
      },
    });
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(ui.node('back').textContent).toBe('Tools');
    ui.node('back').click();
    expect(ui.node('tools-content').hidden).toBe(false);
  });

  it('ignores late tool responses after logout', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("tools")');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve(page);
    await pending;
    expect(ui.node('tools-rows').textContent).toBe('');
    expect(ui.node('tools-totals').textContent).toBe('');
  });

  it('reports unavailable tools without invented counts', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("tools")');
    ui.requests[0].resolve({}, 503);
    await pending;
    expect(ui.node('tools-status').textContent).toContain('unavailable');
    expect(ui.node('tools-totals').textContent).toBe('');
  });
});

describe('native file activity in Stats', () => {
  const page = {
    snapshotId: 'files',
    observedAt: 1,
    totalFiles: 2,
    totalOperations: 12,
    items: [
      {
        key: 'path-a',
        label: 'macos › Core › App.swift',
        readCount: 6,
        editCount: 1,
        writeCount: 1,
        sessionCount: 3,
      },
    ],
    nextCursor: 'next',
  };

  it('shows actual action counts and retains full totals across filtered pages', async () => {
    const ui = harness();
    ui.node('files-project').value = 'engram';
    ui.node('files-since').value = '2026-09-01';
    ui.node('files-until').value = '2026-09-13';
    ui.node('files-agents').value = 'all';
    const first = ui.call('showStatsView("files")');
    expect(ui.requests[0].path).toContain('/web/api/file-activity?');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(query.get('project')).toBe('engram');
    expect(query.get('since')).toBe('2026-09-01');
    expect(query.get('until')).toBe('2026-09-13');
    expect(query.get('agents')).toBe('all');
    ui.requests[0].resolve(page);
    await first;
    expect(ui.node('files-totals').textContent).toContain('2 files');
    expect(ui.node('files-totals').textContent).toContain('12 operations');
    expect(
      ui.node('files-rows').children[0].children.map((c) => c.textContent),
    ).toEqual(['macos › Core › App.swift', '6', '1', '1', '3']);
    expect(ui.node('tools-content').hidden).toBe(true);
    ui.node('files-project').value = 'changed';
    const next = ui.call('loadFiles(true)');
    const nextQuery = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    expect(nextQuery.get('project')).toBe('engram');
    expect(nextQuery.get('snapshotId')).toBe('files');
    ui.requests[1].resolve({
      ...page,
      items: [
        {
          ...page.items[0],
          key: 'path-b',
          label: 'Tests › App.swift',
          readCount: 4,
          editCount: 0,
          writeCount: 0,
        },
      ],
      nextCursor: undefined,
    });
    await next;
    expect(ui.node('files-rows').children).toHaveLength(2);
    expect(ui.node('files-more').hidden).toBe(true);
    expect(ui.node('files-totals').textContent).toContain('12 operations');
  });

  it('rejects changed totals on a continued file page', async () => {
    const ui = harness();
    const first = ui.call('showStatsView("files")');
    ui.requests[0].resolve(page);
    await first;
    const next = ui.call('loadFiles(true)');
    ui.requests[1].resolve({ ...page, totalFiles: 9, nextCursor: undefined });
    await next;
    expect(ui.node('files-status').textContent).toContain('unavailable');
    expect(ui.node('files-rows').children).toHaveLength(1);
  });

  it('clears file activity and ignores late responses after logout', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("files")');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve(page);
    await pending;
    expect(ui.node('files-rows').textContent).toBe('');
    expect(ui.node('files-totals').textContent).toBe('');
  });

  it('distinguishes empty activity from an unavailable backend', async () => {
    const ui = harness();
    let pending = ui.call('showStatsView("files")');
    ui.requests[0].resolve({
      ...page,
      totalFiles: 0,
      totalOperations: 0,
      items: [],
      nextCursor: undefined,
    });
    await pending;
    expect(ui.node('files-status').textContent).toContain('No file activity');
    pending = ui.call('loadFiles(false)');
    ui.requests[1].resolve({}, 503);
    await pending;
    expect(ui.node('files-status').textContent).toContain('unavailable');
    expect(ui.node('files-totals').textContent).toBe('');
  });
});

describe('native recorded usage in Stats', () => {
  const page = {
    scope: 'server',
    observedAt: 1,
    items: [
      {
        source: 'claude-code',
        metric: '5h token total',
        value: 800,
        unit: 'tokens',
        limit: 2000,
        basis: 'indexedSessions',
        collectedAt: '2026-09-13T08:00:00Z',
        resetAt: '2026-09-13T10:00:00Z',
        status: 'normal',
      },
      {
        source: 'codex',
        metric: 'weekly usage',
        value: 45,
        unit: '%',
        basis: 'reported',
        collectedAt: '2026-09-12T08:00:00Z',
      },
    ],
  };
  it('shows metric values, limits and actual observation provenance', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("usage")');
    expect(ui.requests[0].path).toBe('/web/api/usage');
    ui.requests[0].resolve(page);
    await pending;
    expect(ui.node('usage-rows').textContent).toContain(
      '800 tokens / 2,000 tokens',
    );
    expect(ui.node('usage-rows').textContent).toContain('Indexed sessions');
    expect(ui.node('usage-rows').textContent).toContain('Reported');
    expect(ui.node('usage-rows').children[0].children[5].textContent).toBe(
      new Date('2026-09-13T10:00:00Z').toLocaleString(),
    );
    expect(ui.node('usage-rows').children[0].children[6].textContent).toBe(
      new Date('2026-09-13T08:00:00Z').toLocaleString(),
    );
    expect(ui.node('usage-status').textContent).toContain('server');
    expect(ui.node('files-content').hidden).toBe(true);
  });
  it('ignores late usage responses after logout', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("usage")');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve(page);
    await pending;
    expect(ui.node('usage-rows').textContent).toBe('');
  });
  it('distinguishes no observations from service failure', async () => {
    const ui = harness();
    let pending = ui.call('showStatsView("usage")');
    ui.requests[0].resolve({ ...page, items: [] });
    await pending;
    expect(ui.node('usage-status').textContent).toContain('No recorded usage');
    pending = ui.call('loadUsage()');
    ui.requests[1].resolve({}, 503);
    await pending;
    expect(ui.node('usage-status').textContent).toContain('unavailable');
    expect(ui.node('usage-rows').textContent).toBe('');
  });
});

describe('native repository observations in Stats', () => {
  const page = {
    snapshotId: 'repos',
    observedAt: 1,
    scope: 'serverFilesystem',
    totalRepos: 2,
    items: [
      {
        key: 'repo-a',
        name: 'Engram',
        branch: 'feature/capture',
        dirtyCount: 3,
        untrackedCount: 1,
        unpushedCount: 2,
        sessionCount: 24,
        lastCommitHash: 'abcdef1234567890',
        lastCommitMessage: 'Restore capture indexing',
        lastCommitAt: '2026-09-13T08:00:00Z',
        probedAt: '2026-09-13T08:05:00Z',
      },
    ],
    nextCursor: 'next',
  };
  it('shows stored branch and working-tree observations with complete paging', async () => {
    const ui = harness();
    const first = ui.call('showStatsView("repos")');
    expect(ui.requests[0].path).toContain('/web/api/repos');
    ui.requests[0].resolve(page);
    await first;
    expect(ui.node('repos-rows').textContent).toContain('Engram');
    expect(ui.node('repos-rows').textContent).toContain('feature/capture');
    expect(ui.node('repos-rows').textContent).toContain('Dirty3');
    expect(ui.node('repos-rows').textContent).toContain('Untracked1');
    expect(ui.node('repos-rows').textContent).toContain(
      'Restore capture indexing',
    );
    expect(ui.node('repos-status').textContent).toContain('2 repositories');
    const next = ui.call('loadRepos(true)');
    expect(
      new URLSearchParams(ui.requests[1].path.split('?')[1]).get('snapshotId'),
    ).toBe('repos');
    ui.requests[1].resolve({
      ...page,
      items: [{ ...page.items[0], key: 'repo-b', name: 'Collector' }],
      nextCursor: undefined,
    });
    await next;
    expect(ui.node('repos-rows').children).toHaveLength(2);
    expect(ui.node('repos-more').hidden).toBe(true);
  });
  it('ignores repository results after logout', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("repos")');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve(page);
    await pending;
    expect(ui.node('repos-rows').textContent).toBe('');
  });
  it('reports unavailable observations without claiming a clean working tree', async () => {
    const ui = harness();
    const pending = ui.call('showStatsView("repos")');
    ui.requests[0].resolve({}, 503);
    await pending;
    expect(ui.node('repos-status').textContent).toContain('unavailable');
    expect(ui.node('repos-rows').textContent).toBe('');
  });
});

describe('native Health page and navigation', () => {
  it('renders every overview page with actual task counts and explicit missing observations', async () => {
    const ui = harness();
    const pending = ui.call('navigate("health")');
    expect(ui.node('library-page').hidden).toBe(true);
    expect(ui.node('health-page').hidden).toBe(false);
    ui.requests[0].resolve({
      snapshotId: 'health',
      nextCursor: 'next',
      streams: [
        {
          machineId: 'machine-a',
          sourceInstanceId: 'instance-a',
          registry: { source: 'codex' },
          ingest: {
            publicationCount: 40,
            taskCounts: {
              pending: 3,
              processing: 1,
              parsed: 2,
              indexReady: 34,
              retryableFailure: 0,
              quarantined: 0,
            },
            parseFailureTasks: 0,
          },
          fts: { readyLogicalSessions: 12 },
          heartbeatAt: null,
          replicaACKs: null,
        },
      ],
    });
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    expect(
      new URLSearchParams(ui.requests[1].path.split('?')[1]).get('cursor'),
    ).toBe('next');
    ui.requests[1].resolve({
      snapshotId: 'health',
      streams: [
        {
          machineId: 'machine-b',
          sourceInstanceId: 'instance-b',
          registry: { source: 'cursor' },
          ingest: {
            publicationCount: 9,
            taskCounts: {
              pending: 0,
              processing: 0,
              parsed: 0,
              indexReady: 7,
              retryableFailure: 1,
              quarantined: 1,
            },
            parseFailureTasks: 1,
          },
        },
      ],
    });
    await pending;
    const health = ui.node('health-content');
    expect(health.textContent).toContain('Codex');
    expect(health.textContent).toContain('Cursor');
    expect(health.textContent).toContain('Pending3');
    expect(health.textContent).toContain('Retryable failures1');
    expect(health.textContent).toContain('Quarantined1');
    expect(health.textContent).toContain('Not reported');
    expect(health.textContent).not.toContain('All systems healthy');
  });

  it('discards a late Health response after hash navigation back to Sessions', async () => {
    const ui = harness();
    ui.call('setSignedIn(true)');
    const pending = ui.call('navigate("health")');
    ui.call('window.location.hash = "#sessions"');
    ui.dispatchWindow('hashchange');
    expect(ui.node('library-page').hidden).toBe(false);
    expect(ui.node('health-page').hidden).toBe(true);
    ui.requests[1].resolve({
      items: [{ sessionId: 'fresh', title: 'Library after back' }],
    });
    ui.requests[0].resolve({
      streams: [{ registry: { source: 'private-late' } }],
    });
    await pending;
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    expect(ui.node('sessions').textContent).toContain('Library after back');
    expect(ui.node('health-content').textContent).not.toContain('private-late');
    expect(ui.node('nav-sessions').getAttribute('aria-current')).toBe('page');
  });

  it('restores a Health bookmark from the already-loaded overview without fetching twice', async () => {
    const ui = harness();
    ui.call('window.location.hash = "#health"');
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({ items: [] });
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    ui.requests[1].resolve({ streams: [] });
    for (let step = 0; step < 14; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(2);
    expect(ui.node('health-page').hidden).toBe(false);
    expect(ui.node('nav-health').getAttribute('aria-current')).toBe('page');
  });

  it('shows Health unavailability and clears its private content when signed out', async () => {
    const ui = harness();
    const pending = ui.call('navigate("health")');
    ui.requests[0].resolve({}, 503);
    await pending;
    expect(ui.node('health-status').textContent).toContain('unavailable');
    ui.node('health-content').textContent = 'Private machine';
    const logout = ui.call('logout()');
    expect(ui.node('health-content').textContent).toBe('');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    const html = shipped('html');
    for (const page of ['sessions', 'search', 'health'])
      expect(html).toContain(`href="#${page}"`);
  });
});

describe('native paged facet pickers', () => {
  it('loads actual source choices and submits multiple selected values', async () => {
    const ui = harness();
    const loaded = ui.call('loadFacets("source", false)');
    expect(ui.requests[0].path).toBe('/web/api/facets?kind=source');
    ui.requests[0].resolve({
      snapshotId: 'facets',
      items: [
        { key: 'codex', label: 'Codex', sessionCount: 14 },
        { key: 'cursor', label: 'Cursor', sessionCount: 8 },
      ],
    });
    await loaded;
    ui.node('source-options').children[0].children[0].click();
    ui.requests[1].resolve({ items: [] });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.node('source-options').children[1].children[0].click();
    expect(
      new URLSearchParams(ui.requests[2].path.split('?')[1]).get('sources'),
    ).toBe('codex,cursor');
    expect(ui.node('source-summary').textContent).toBe('2 sources');
    ui.requests[2].resolve({
      snapshotId: 'sessions',
      nextCursor: 'next',
      items: [],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    const more = ui.call('loadSessions(true)');
    expect(
      new URLSearchParams(ui.requests[3].path.split('?')[1]).get('sources'),
    ).toBe('codex,cursor');
    ui.requests[3].resolve({ snapshotId: 'sessions', items: [] });
    await more;
    ui.node('source-clear').click();
    expect(ui.node('source-summary').textContent).toBe('All sources');
    expect(
      new URLSearchParams(ui.requests[4].path.split('?')[1]).has('sources'),
    ).toBe(false);
    ui.requests[4].resolve({ items: [] });
  });

  it('pages searchable projects using opaque identities and the submitted query', async () => {
    const ui = harness();
    ui.node('project-query').value = 'Design + UI';
    const loaded = ui.call('loadFacets("project", false)');
    expect(ui.requests[0].path).toContain('query=Design%20%2B%20UI');
    ui.requests[0].resolve({
      snapshotId: 'facets',
      nextCursor: 'next-project',
      items: [{ key: 'opaque-first', label: 'Design + UI', sessionCount: 6 }],
    });
    await loaded;
    ui.node('project-query').value = 'not submitted';
    const more = ui.call('loadFacets("project", true)');
    const params = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    expect(params.get('query')).toBe('Design + UI');
    expect(params.get('snapshotId')).toBe('facets');
    expect(params.get('cursor')).toBe('next-project');
    ui.requests[1].resolve({
      snapshotId: 'facets',
      items: [{ key: 'opaque-second', label: 'Design + UI', sessionCount: 2 }],
    });
    await more;
    expect(ui.node('project-options').children).toHaveLength(2);
    ui.node('project-options').children[1].children[0].click();
    expect(
      new URLSearchParams(ui.requests[2].path.split('?')[1]).get('projectKeys'),
    ).toBe('opaque-second');
    ui.requests[2].resolve({ items: [] });
  });

  it('clears choices and ignores an in-flight facet response on logout', async () => {
    const ui = harness();
    const loaded = ui.call('loadFacets("project", false)');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({
      snapshotId: 'private',
      items: [{ key: 'private', label: 'Private project', sessionCount: 7 }],
    });
    await loaded;
    expect(ui.node('project-options').textContent).toBe('');
    expect(ui.node('project-summary').textContent).toBe('All projects');
    expect(ui.node('project-more').hidden).toBe(true);
  });

  it('expires a current unauthorized facet request and keeps errors out of labels', async () => {
    const ui = harness();
    const loaded = ui.call('loadFacets("source", false)');
    ui.requests[0].resolve({ secret: 'do not display' }, 401);
    await loaded;
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('status').textContent).toBe('Session expired');
    expect(ui.node('source-options').textContent).toBe('');
  });
});

describe('legacy agent filters and session metadata', () => {
  it('applies agent chips and keeps the submitted choice on continuation', async () => {
    const ui = harness();
    ui.node('agents-only').click();
    expect(
      new URLSearchParams(ui.requests[0]?.path.split('?')[1]).get('agents'),
    ).toBe('only');
    ui.requests[0].resolve({
      snapshotId: 'snapshot',
      nextCursor: 'next',
      items: [],
    });
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    expect(ui.node('agents-only').getAttribute('aria-pressed')).toBe('true');
    expect(ui.node('agents-hide').getAttribute('aria-pressed')).toBe('false');
    const next = ui.call('loadSessions(true)');
    expect(
      new URLSearchParams(ui.requests[1].path.split('?')[1]).get('agents'),
    ).toBe('only');
    ui.requests[1].resolve({ snapshotId: 'snapshot', items: [] });
    await next;
  });

  it('does not restore an older agent selection when its response arrives late', async () => {
    const ui = harness();
    ui.node('agents-all').click();
    ui.node('agents-hide').click();
    expect(ui.requests).toHaveLength(2);
    ui.requests[1].resolve({
      items: [{ sessionId: 'main', title: 'Main session' }],
    });
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    ui.requests[0].resolve({
      items: [{ sessionId: 'child', title: 'Outdated agent result' }],
    });
    for (let step = 0; step < 10; step += 1) await Promise.resolve();
    expect(ui.node('sessions').textContent).toContain('Main session');
    expect(ui.node('sessions').textContent).not.toContain(
      'Outdated agent result',
    );
    expect(ui.node('agents-hide').getAttribute('aria-pressed')).toBe('true');
  });

  it('renders known per-role counts and agent identity without inventing unknown counts', async () => {
    const ui = harness();
    const pending = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      items: [
        {
          sessionId: 'child',
          isAgent: true,
          userMessageCount: 0,
          assistantMessageCount: 1234,
          systemMessageCount: 2,
        },
        { sessionId: 'legacy', isAgent: false, userMessageCount: null },
      ],
    });
    await pending;
    const first = ui.node('sessions').children[0];
    expect(first.querySelector('.agent-label')?.textContent).toBe('agent');
    expect(first.querySelector('.message-counts')?.textContent).toBe(
      '0 user · 1,234 assistant · 2 system',
    );
    const second = ui.node('sessions').children[1];
    expect(second.querySelector('.agent-label')).toBeNull();
    expect(second.querySelector('.message-counts')).toBeNull();
  });

  it('shows relative dates with the exact timestamp available on the time element', async () => {
    const ui = harness();
    ui.call('Date.now = () => 1789214400000');
    const pending = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      items: [
        { sessionId: 'recent', startedAt: 1789214280 },
        { sessionId: 'yesterday', startedAt: 1789128000 },
        { sessionId: 'old', startedAt: 1609459200 },
        { sessionId: 'unknown', startedAt: null },
      ],
    });
    await pending;
    const cards = ui.node('sessions').children;
    expect(cards[0].querySelector('time')?.textContent).toBe('2m ago');
    expect(cards[0].querySelector('time')?.dateTime).toBe(
      new Date(1789214280000).toISOString(),
    );
    expect(cards[0].querySelector('time')?.title).toContain('2026');
    expect(cards[1].querySelector('time')?.textContent).toBe('1d ago');
    expect(cards[2].querySelector('time')?.textContent).toContain('2021');
    expect(cards[3].querySelector('time')).toBeNull();
    const html = shipped('html');
    for (const id of ['agents-hide', 'agents-all', 'agents-only'])
      expect(html).toContain(`id="${id}"`);
  });
});

describe('shipped collector Web viewer behavior', () => {
  it('keeps long unbroken transcript tokens within the reader viewport', () => {
    const css = source.match(/static let css = """\n([\s\S]*?)\n {8}"""/)?.[1];
    expect(css).toMatch(/body\s*\{[^}]*overflow-wrap:\s*anywhere/);
  });

  it('clears private content immediately when logout starts, even if the server fails', async () => {
    const ui = harness();
    for (const id of ['overview', 'sessions', 'detail', 'messages']) {
      ui.node(id).textContent = 'private transcript';
    }
    const pending = ui.call('logout()');
    const observed = pending.catch(() => undefined);
    const beforeResponse = ui.node('messages').textContent;
    ui.requests[0].resolve({}, 503);
    await observed;
    expect(beforeResponse).toBe('');
    for (const id of ['overview', 'sessions', 'detail', 'messages']) {
      expect(ui.node(id).textContent).toBe('');
    }
    expect(ui.node('status').textContent).toContain('failed');
  });

  it('does not let an older failed read replace a later signed-out status', async () => {
    const ui = harness();
    const oldRead = ui.call('loadSessions(false)').catch(() => undefined);
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({}, 503);
    await oldRead;
    expect(ui.node('status').textContent).toBe('signed out');
    expect(ui.node('sessions').textContent).toBe('');
  });

  it('coalesces repeated clicks for the same in-flight message page', async () => {
    const ui = harness();
    const first = ui.call('loadMessages(0, "session", "generation", "cursor")');
    const second = ui.call(
      'loadMessages(0, "session", "generation", "cursor")',
    );
    const requestCount = ui.requests.length;
    for (const request of ui.requests) request.resolve({ fragments: [] });
    await Promise.all([first, second]);
    expect(requestCount).toBe(1);
  });

  it('does not restart session loading after logout supersedes login overview', async () => {
    const ui = harness();
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[0].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[1].path.startsWith('/web/api/sessions')).toBe(true);
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve({ items: [] });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    const count = ui.requests.length;
    // Drain an incorrectly admitted request too, so RED leaves no pending work.
    ui.requests[3]?.resolve({ streams: [] });
    await login;
    expect(count).toBe(3);
    expect(ui.node('status').textContent).toBe('signed out');
    expect(ui.node('sessions').textContent).toBe('');
  });

  it('loads sessions when login overview returns 503 (repro)', async () => {
    const ui = harness();
    ui.node('credential').value = 'test-only';
    const pending = ui
      .call('login({ preventDefault() {} })')
      .catch(() => undefined);
    ui.requests[0].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[1].path.startsWith('/web/api/sessions')).toBe(true);
    ui.requests[1].resolve({
      snapshotId: 'snapshot',
      items: [{ sessionId: 'session-1', title: 'Fix login', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[2].path).toBe('/web/api/overview?limit=2');
    ui.requests[2].resolve({}, 503);
    await pending;
    expect(ui.node('sessions').textContent).toContain('Fix login');
    expect(ui.node('overview').textContent).toMatch(/unavailable/i);
    expect(ui.node('overview').textContent).not.toMatch(/503/);
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('workspace').hidden).toBe(false);
  });

  it('signs out and shows Session expired when a current sessions read returns 401 (repro)', async () => {
    const ui = harness();
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[0].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[1].resolve({
      snapshotId: 'snapshot',
      items: [{ sessionId: 'keep', title: 'Private session', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[2].resolve({ streams: [] });
    await login;
    expect(ui.node('workspace').hidden).toBe(false);
    const expired = ui.call('loadSessions(false)').catch(() => undefined);
    ui.requests[3].resolve({}, 401);
    await expired;
    expect(ui.node('status').textContent).toBe('Session expired');
    expect(ui.node('status').textContent).not.toBe('401');
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('logout').hidden).toBe(true);
    expect(ui.node('signed-out').hidden).toBe(false);
    expect(ui.node('sessions').textContent).toBe('');
    expect(ui.node('overview').textContent).toBe('');
    expect(ui.node('detail').textContent).toBe('');
    expect(ui.node('messages').textContent).toBe('');
    expect(
      ui.requests.filter((request) => request.path === '/web/api/auth').length,
    ).toBe(1);
  });

  it('signs out when the optional current overview read returns 401 (repro)', async () => {
    const ui = harness();
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[0].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[1].resolve({
      snapshotId: 'snapshot',
      items: [{ sessionId: 'keep', title: 'Private session', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[2].path).toBe('/web/api/overview?limit=2');
    ui.requests[2].resolve({}, 401);
    await login;
    expect(ui.node('status').textContent).toBe('Session expired');
    expect(ui.node('overview').textContent).not.toMatch(/unavailable/i);
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('sessions').textContent).toBe('');
  });

  it('does not let a stale sessions 401 log out a newer signed-in epoch', async () => {
    const ui = harness();
    const stale = ui.call('loadSessions(false)').catch(() => undefined);
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[1].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[2].resolve({
      snapshotId: 'fresh',
      items: [{ sessionId: 'new', title: 'Newer session', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[3].resolve({ streams: [] });
    await login;
    ui.requests[0].resolve({}, 401);
    await stale;
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.node('workspace').hidden).toBe(false);
    expect(ui.node('login').hidden).toBe(true);
    expect(ui.node('sessions').textContent).toContain('Newer session');
  });

  it('does not let a stale overview 401 log out a newer search epoch', async () => {
    const ui = harness();
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[0].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[1].resolve({
      snapshotId: 'first',
      items: [{ sessionId: 'old', title: 'Old session', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[2].path).toBe('/web/api/overview?limit=2');
    const search = ui.call('loadSessions(false)');
    ui.requests[3].resolve({
      snapshotId: 'second',
      items: [{ sessionId: 'new', title: 'Newer session', source: 'codex' }],
    });
    await search;
    ui.requests[2].resolve({}, 401);
    await login;
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.node('workspace').hidden).toBe(false);
    expect(ui.node('login').hidden).toBe(true);
    expect(ui.node('sessions').textContent).toContain('Newer session');
    expect(ui.node('sessions').textContent).not.toContain('Old session');
    expect(ui.node('overview').textContent).not.toMatch(/unavailable/i);
  });

  it('keeps a wrong-credential login 401 as a login failure, not session expiry', async () => {
    const ui = harness();
    ui.node('credential').value = 'wrong';
    const pending = ui
      .call('login({ preventDefault() {} })')
      .catch(() => undefined);
    ui.requests[0].resolve({}, 401);
    await pending;
    expect(ui.node('status').textContent).toBe('401');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('logout').hidden).toBe(true);
    expect(
      ui.requests.every((request) => request.path === '/web/api/auth'),
    ).toBe(true);
  });

  it('does not let a failed overview clobber a newer session list or status', async () => {
    const ui = harness();
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[0].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[1].resolve({
      snapshotId: 'first',
      items: [{ sessionId: 'old', title: 'Old session', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[2].path).toBe('/web/api/overview?limit=2');
    const search = ui.call('loadSessions(false)');
    ui.requests[3].resolve({
      snapshotId: 'second',
      items: [{ sessionId: 'new', title: 'Newer session', source: 'codex' }],
    });
    await search;
    ui.requests[2].resolve({}, 503);
    await login;
    expect(ui.node('sessions').textContent).toContain('Newer session');
    expect(ui.node('sessions').textContent).not.toContain('Old session');
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('status').textContent).not.toBe('503');
    expect(ui.node('overview').textContent).not.toMatch(/unavailable/i);
  });

  it('binds continuation to submitted filters, not fields edited without submitting', async () => {
    const ui = harness();
    ui.node('query').value = 'original';
    ui.call(
      'facets.source.selected.clear(); facets.source.selected.set("claude-code", "Claude Code")',
    );
    const first = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      snapshotId: 'snapshot',
      nextCursor: 'cursor',
      items: [],
    });
    await first;
    ui.node('query').value = 'changed';
    ui.call(
      'facets.source.selected.clear(); facets.source.selected.set("codex", "Codex")',
    );
    const next = ui.call('loadSessions(true)');
    const params = new URL(ui.requests[1].path, 'https://viewer.example')
      .searchParams;
    ui.requests[1].resolve({ snapshotId: 'snapshot', items: [] });
    await next;
    expect(params.get('query')).toBe('original');
    expect(params.get('sources')).toBe('claude-code');
    expect(params.get('snapshotId')).toBe('snapshot');
    expect(params.get('cursor')).toBe('cursor');
  });

  it('shows an explicit empty state for a successful empty search', async () => {
    const ui = harness();
    const request = ui.call('loadSessions(false)');
    ui.requests[0].resolve({ snapshotId: 'snapshot', items: [] });
    await request;
    expect(ui.node('sessions').textContent).toBe('No sessions found');
  });

  it('shows a safe error when the active read cannot reach the server', async () => {
    const ui = harness();
    const request = ui.call('loadSessions(false)').catch(() => undefined);
    ui.requests[0].reject();
    await request;
    expect(ui.node('status').textContent).toBe('Network unavailable');
    expect(ui.node('status').textContent).not.toContain('test-only');
  });

  it('reassembles multi-page Unicode without interpreting embedded markup', async () => {
    const ui = harness();
    const content = `constellation ${'星🙂'.repeat(40_000)} <img src=x onerror=alert(1)>`;
    const payload = JSON.stringify({ content });
    const split = payload.indexOf('星', 100_000);
    const prefix = payload.slice(0, split);
    const suffix = payload.slice(split);
    const fragment = {
      messageOrdinal: 0,
      payloadSHA256: 'a'.repeat(64),
      role: 'assistant',
    };
    const first = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: prefix,
          utf8Offset: 0,
          isLastFragment: false,
        },
      ],
      nextCursor: 'continuation',
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('messages').children).toHaveLength(0);
    expect(ui.requests[1].path).toContain('cursor=continuation');
    ui.requests[1].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: suffix,
          utf8Offset: new TextEncoder().encode(prefix).length,
          isLastFragment: true,
        },
      ],
    });
    await first;
    expect(ui.node('messages').children).toHaveLength(1);
    const body = ui
      .node('messages')
      .children[0].children.find((child) => child.className === 'body');
    expect(body?.tagName).toBe('DIV');
    expect(body?.querySelector('img')).toBeNull();
    expect(body?.querySelector('script')).toBeNull();
    expect(body?.textContent).toBe(content);
    expect(ui.node('messages').textContent).toContain(content);
  });

  it('collapses tool and system roles without toolCalls and keeps their CSS class', async () => {
    const ui = harness();
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'c'.repeat(64),
          role: 'tool',
          payloadFragment: JSON.stringify({
            content: 'function_call_output huge dump',
          }),
          utf8Offset: 0,
          isLastFragment: true,
        },
        {
          messageOrdinal: 1,
          payloadSHA256: 'd'.repeat(64),
          role: 'system',
          payloadFragment: JSON.stringify({ content: 'system notice' }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const [tool, system] = ui.node('messages').children;
    expect(tool.className).toBe('message tool');
    expect(system.className).toBe('message system');
    expect(tool.className).not.toContain('assistant');
    expect(system.className).not.toContain('assistant');
    expect(tool.children.some((child) => child.className === 'body')).toBe(
      false,
    );
    const toolDump = tool.children.find((child) => child.tagName === 'DETAILS');
    expect(toolDump?.children[0]?.textContent).toContain('Tool');
    expect(toolDump?.children[0]?.textContent).toContain(
      'function_call_output huge dump',
    );
    expect(
      toolDump?.children.find((child) => child.tagName === 'PRE')?.textContent,
    ).toBe('function_call_output huge dump');
    const systemDump = system.children.find(
      (child) => child.tagName === 'DETAILS',
    );
    expect(systemDump?.children[0]?.textContent).toContain('System');
    expect(systemDump?.textContent).toContain('system notice');
  });

  it('does not collapse user text that looks like a wrapper', async () => {
    const ui = harness();
    const content = '<command-message>goal</command-message> please review';
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'e'.repeat(64),
          role: 'user',
          payloadFragment: JSON.stringify({ content }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const article = ui.node('messages').children[0];
    expect(article.className).toBe('message user');
    const body = article.children.find((child) => child.className === 'body');
    expect(body?.tagName).toBe('DIV');
    expect(body?.textContent).toBe(content);
    expect(article.children.some((child) => child.tagName === 'DETAILS')).toBe(
      false,
    );
  });

  it('keeps fragment chunks as Uint8Array until the last fragment', async () => {
    const ui = harness();
    const payload = JSON.stringify({ content: 'ab' });
    const first = payload.slice(0, 8);
    const second = payload.slice(8);
    const fragment = {
      messageOrdinal: 0,
      payloadSHA256: 'f'.repeat(64),
      role: 'assistant',
    };
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: first,
          utf8Offset: 0,
          isLastFragment: false,
        },
      ],
      nextCursor: 'more',
    });
    expect(script).toContain('chunks');
    const fragmentCode = script.slice(
      script.indexOf('function acceptFragment'),
      script.indexOf('async function loadMessages'),
    );
    expect(fragmentCode).not.toContain('Array.from(');
    expect(script).not.toContain('bytes.push');
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('messages').children).toHaveLength(0);
    expect(ui.requests[1].path).toContain('cursor=more');
    ui.requests[1].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: second,
          utf8Offset: new TextEncoder().encode(first).length,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    expect(
      ui
        .node('messages')
        .children[0].children.find((child) => child.className === 'body')
        ?.textContent,
    ).toBe('ab');
  });

  it('auto-fetches continuation until the first message is complete (repro)', async () => {
    const ui = harness();
    const payload = JSON.stringify({ content: 'first page only half' });
    const prefix = payload.slice(0, 12);
    const suffix = payload.slice(12);
    const fragment = {
      messageOrdinal: 0,
      payloadSHA256: 'k'.repeat(64),
      role: 'assistant',
    };
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: prefix,
          utf8Offset: 0,
          isLastFragment: false,
        },
      ],
      nextCursor: 'page-2',
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('messages').children).toHaveLength(0);
    expect(ui.requests).toHaveLength(2);
    expect(ui.requests[1].method).toBe('GET');
    expect(ui.requests[1].path).toContain('cursor=page-2');
    ui.requests[1].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: suffix,
          utf8Offset: new TextEncoder().encode(prefix).length,
          isLastFragment: true,
        },
      ],
      nextCursor: 'later',
    });
    await pending;
    expect(ui.node('messages').children).toHaveLength(1);
    expect(
      ui
        .node('messages')
        .children[0].children.find((child) => child.className === 'body')
        ?.textContent,
    ).toBe('first page only half');
    expect(ui.node('more-messages').hidden).toBe(false);
    expect(ui.requests).toHaveLength(2);
  });

  it('does not auto-fetch after a page that ends with a complete message', async () => {
    const ui = harness();
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'l'.repeat(64),
          role: 'tool',
          payloadFragment: JSON.stringify({ content: 'complete tool dump' }),
          utf8Offset: 0,
          isLastFragment: true,
        },
        {
          messageOrdinal: 1,
          payloadSHA256: 'm'.repeat(64),
          role: 'system',
          payloadFragment: JSON.stringify({ content: 'complete system' }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
      nextCursor: 'later',
    });
    await pending;
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('messages').children).toHaveLength(2);
    expect(ui.node('messages').children[0].className).toBe('message tool');
    expect(ui.node('messages').children[1].className).toBe('message system');
    expect(
      ui
        .node('messages')
        .children[0].children.some((child) => child.className === 'body'),
    ).toBe(false);
    expect(ui.node('more-messages').hidden).toBe(false);
  });

  it('does not let a pending message continuation undo logout', async () => {
    const ui = harness();
    const payload = JSON.stringify({
      content: 'should not appear after logout',
    });
    const prefix = payload.slice(0, 10);
    const suffix = payload.slice(10);
    const fragment = {
      messageOrdinal: 0,
      payloadSHA256: 'n'.repeat(64),
      role: 'assistant',
    };
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: prefix,
          utf8Offset: 0,
          isLastFragment: false,
        },
      ],
      nextCursor: 'page-2',
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve({
      fragments: [
        {
          ...fragment,
          payloadFragment: suffix,
          utf8Offset: new TextEncoder().encode(prefix).length,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    expect(ui.node('messages').children).toHaveLength(0);
    expect(ui.node('messages').textContent).toBe('');
    expect(ui.node('status').textContent).toBe('signed out');
  });

  it('keeps XSS markup inert while formatting markdown and fenced code', async () => {
    const ui = harness();
    const content = [
      '# Title <img src=x onerror=alert(1)>',
      '',
      'See [xss](javascript:alert(1)) and [ok](https://example.com/a).',
      '',
      '```js',
      'const x = "<script>alert(1)</script>";',
      '```',
    ].join('\n');
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'g'.repeat(64),
          role: 'assistant',
          payloadFragment: JSON.stringify({ content }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const body = ui
      .node('messages')
      .children[0].children.find((child) => child.className === 'body');
    expect(body?.querySelector('h1')?.textContent).toBe(
      'Title <img src=x onerror=alert(1)>',
    );
    expect(body?.querySelector('img')).toBeNull();
    expect(body?.querySelector('script')).toBeNull();
    const link = body?.querySelector('a');
    expect(link?.textContent).toBe('ok');
    expect(link?.getAttribute('href')).toBe('https://example.com/a');
    expect(body?.textContent).toContain('[xss](javascript:alert(1))');
    expect(link?.getAttribute('href')?.startsWith('javascript')).not.toBe(true);
    expect(
      body?.querySelector('.code-block')?.querySelector('pre')?.textContent,
    ).toBe('const x = "<script>alert(1)</script>";');
  });

  it('copies fenced code verbatim and preserves long unformatted text', async () => {
    const ui = harness();
    const long = `keep ${'星'.repeat(200)} <b>plain</b>`;
    const code = ['line one', '  indented <script>', 'final \\n slash'].join(
      '\n',
    );
    const content = `${long}\n\n\`\`\`\n${code}\n\`\`\``;
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'h'.repeat(64),
          role: 'user',
          payloadFragment: JSON.stringify({ content }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const body = ui
      .node('messages')
      .children[0].children.find((child) => child.className === 'body');
    expect(body?.textContent).toContain(long);
    expect(body?.querySelector('b')).toBeNull();
    expect(
      body?.querySelector('.code-block')?.querySelector('pre')?.textContent,
    ).toBe(code);
    body?.querySelector('.copy-btn')?.click();
    expect(ui.copied).toEqual([code]);
  });

  it('preserves unsupported markdown link targets as literal text', async () => {
    const ui = harness();
    const fileLink = '[notes](file:///tmp/project/notes.md)';
    const pathLink = '[readme](../README.md)';
    const content = `See ${fileLink} and ${pathLink} plus [ok](https://example.com/doc).`;
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'i'.repeat(64),
          role: 'assistant',
          payloadFragment: JSON.stringify({ content }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const body = ui
      .node('messages')
      .children[0].children.find((child) => child.className === 'body');
    expect(body?.textContent).toContain(fileLink);
    expect(body?.textContent).toContain(pathLink);
    expect(body?.querySelector('a')?.textContent).toBe('ok');
    expect(body?.querySelector('a')?.getAttribute('href')).toBe(
      'https://example.com/doc',
    );
  });

  it('keeps wide markdown tables inside a locally scrollable wrapper', async () => {
    const css = shipped('css');
    expect(css).toMatch(/\.message\s*\{[^}]*min-width:\s*0/);
    expect(css).toMatch(/\.table-wrap[^}]*overflow-x:\s*auto/);
    const ui = harness();
    const cells = Array.from({ length: 20 }, (_, index) => `C${index}`);
    const content = [
      `| ${cells.join(' | ')} |`,
      `| ${cells.map(() => '---').join(' | ')} |`,
      `| ${cells.map((_, index) => `v${index}`).join(' | ')} |`,
    ].join('\n');
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'j'.repeat(64),
          role: 'assistant',
          payloadFragment: JSON.stringify({ content }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const body = ui
      .node('messages')
      .children[0].children.find((child) => child.className === 'body');
    const wrap = body?.querySelector('.table-wrap');
    expect(wrap?.querySelector('table')?.tagName).toBe('TABLE');
    expect(wrap?.querySelector('thead')?.textContent).toContain('C19');
    expect(wrap?.querySelector('tbody')?.textContent).toContain('v19');
  });

  it('restores signed-in list on reload when a cookie is already valid (repro)', async () => {
    const ui = harness();
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    ui.dispatchDocument('DOMContentLoaded');
    expect(ui.requests).toHaveLength(1);
    expect(ui.requests[0].method).toBe('GET');
    expect(ui.requests[0].path.startsWith('/web/api/sessions')).toBe(true);
    expect(
      ui.requests.every((request) => request.path !== '/web/api/auth'),
    ).toBe(true);
    ui.requests[0].resolve({
      snapshotId: 'restored',
      items: [{ sessionId: 's1', title: 'Restored session', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[1].path).toBe('/web/api/overview?limit=2');
    ui.requests[1].resolve({ streams: [] });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('workspace').hidden).toBe(false);
    expect(ui.node('signed-out').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(true);
    expect(ui.node('logout').hidden).toBe(false);
    expect(ui.node('lede').hidden).toBe(true);
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('sessions').textContent).toContain('Restored session');
  });

  it('retries a reload 503 once and then restores the signed-in list (repro)', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    expect(ui.requests).toHaveLength(1);
    expect(ui.requests[0].path.startsWith('/web/api/sessions')).toBe(true);
    ui.requests[0].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(2);
    expect(ui.requests[1].method).toBe('GET');
    expect(ui.requests[1].path.startsWith('/web/api/sessions')).toBe(true);
    ui.requests[1].resolve({
      snapshotId: 'restored-retry',
      items: [
        { sessionId: 's1', title: 'Restored after 503', source: 'codex' },
      ],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[2].path).toBe('/web/api/overview?limit=2');
    ui.requests[2].resolve({ streams: [] });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('workspace').hidden).toBe(false);
    expect(ui.node('login').hidden).toBe(true);
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('sessions').textContent).toContain('Restored after 503');
    expect(
      ui.requests.filter((request) =>
        request.path.startsWith('/web/api/sessions'),
      ).length,
    ).toBe(2);
  });

  it('shows a restore status after a second reload 503 (repro)', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(2);
    ui.requests[1].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(2);
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('status').textContent).toBe('Temporarily unavailable');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(
      ui.requests.every(
        (request) => !request.path.startsWith('/web/api/overview'),
      ),
    ).toBe(true);
  });

  it('does not retry a reload probe 401', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({}, 401);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('status').textContent).toBe('');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.node('login').hidden).toBe(false);
  });

  it('does not retry a reload probe network failure', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].reject();
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('status').textContent).toBe('Network unavailable');
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('workspace').hidden).toBe(true);
  });

  it('does not retry a reload probe 500', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({}, 500);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('status').textContent).toBe('Temporarily unavailable');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.node('login').hidden).toBe(false);
  });

  it('shows a restore status when the reload probe body is malformed', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolveMalformed();
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('status').textContent).toBe('Temporarily unavailable');
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('workspace').hidden).toBe(true);
  });

  it('does not retry a reload 503 after logout supersedes the probe', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(
      ui.requests.filter((request) =>
        request.path.startsWith('/web/api/sessions'),
      ).length,
    ).toBe(1);
    expect(ui.node('status').textContent).toBe('signed out');
    expect(ui.node('login').hidden).toBe(false);
  });

  it('does not apply a stale reload 503 retry after logout', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[1].path.startsWith('/web/api/sessions')).toBe(true);
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve({
      items: [
        { sessionId: 'stale', title: 'Stale 503 retry', source: 'codex' },
      ],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('sessions').textContent).not.toContain('Stale 503 retry');
    expect(ui.node('status').textContent).toBe('signed out');
  });

  it('does not retry a reload 503 after login supersedes the probe', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[1].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[2].resolve({
      items: [{ sessionId: 'fresh', title: 'After login', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[3].resolve({ streams: [] });
    await login;
    ui.requests[0].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(
      ui.requests.filter((request) =>
        request.path.startsWith('/web/api/sessions'),
      ).length,
    ).toBe(2);
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('sessions').textContent).toContain('After login');
  });

  it('does not apply a stale reload 503 retry after login', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests[1].path.startsWith('/web/api/sessions')).toBe(true);
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[2].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[3].resolve({
      items: [{ sessionId: 'fresh', title: 'After login', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[4].resolve({ streams: [] });
    await login;
    ui.requests[1].resolve({
      items: [
        { sessionId: 'stale', title: 'Stale 503 retry', source: 'codex' },
      ],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('sessions').textContent).toContain('After login');
    expect(ui.node('sessions').textContent).not.toContain('Stale 503 retry');
  });

  it('treats a 503 retry 401 as a silent signed-out probe', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({}, 503);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[1].resolve({}, 401);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.requests).toHaveLength(2);
    expect(ui.node('status').textContent).toBe('');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('workspace').hidden).toBe(true);
  });

  it('stays signed out silently when the reload probe returns 401', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.requests[0].resolve({}, 401);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('status').textContent).toBe('');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.requests).toHaveLength(1);
    expect(
      ui.requests.every((request) => request.path !== '/web/api/auth'),
    ).toBe(true);
  });

  it('does not let a pending reload restore undo a later logout', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({
      items: [{ sessionId: 'stale', title: 'Stale restore', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[2]?.resolve({ streams: [] });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('sessions').textContent).toBe('');
    expect(ui.node('sessions').textContent).not.toContain('Stale restore');
    expect(ui.node('status').textContent).toBe('signed out');
  });

  it('does not let a pending reload restore 401 undo a later login', async () => {
    const ui = harness();
    ui.dispatchDocument('DOMContentLoaded');
    ui.node('credential').value = 'test-only';
    const login = ui.call('login({ preventDefault() {} })');
    ui.requests[1].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[2].resolve({
      items: [{ sessionId: 'fresh', title: 'After login', source: 'codex' }],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[0].resolve({}, 401);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[3].resolve({ streams: [] });
    await login;
    expect(ui.node('workspace').hidden).toBe(false);
    expect(ui.node('login').hidden).toBe(true);
    expect(ui.node('status').textContent).toBe('signed in');
    expect(ui.node('status').textContent).not.toBe('Session expired');
    expect(ui.node('sessions').textContent).toContain('After login');
  });
});

describe('shipped collector Web viewer presentation', () => {
  it('opens a conversation at the top and returns to the previous list position', () => {
    const ui = harness();
    ui.call('window.scrollY = 740');
    ui.call('showSessionDetailPane()');
    expect(ui.call('window.scrollY')).toBe(0);
    ui.call('window.scrollY = 1900');
    ui.call('showSessionList()');
    expect(ui.call('window.scrollY')).toBe(740);
  });
  it('ships labeled filters, list/detail navigation, and a signed-out welcome', () => {
    const html = shipped('html');
    expect(html).toContain('id="workspace"');
    expect(html).toContain('id="signed-out"');
    expect(html).toContain('id="lede"');
    expect(html).toMatch(
      /<label[^>]*id="search-query"[^>]*>\s*<span class="visually-hidden">Search<\/span>/,
    );
    expect(html).toContain('id="source-picker"');
    expect(html).toContain('id="source-summary">All sources');
    expect(html).toContain('id="project-picker"');
    expect(html).toContain('id="project-summary">All projects');
    expect(html).toContain('for="project-query"');
    expect(html).toMatch(/<label[^>]*>Credential/);
    expect(html).not.toMatch(/visually-hidden">Credential/);
    expect(html).not.toMatch(/visually-hidden">Machine ID/);
    expect(html).toMatch(/Advanced filters/);
    expect(html).toMatch(/<label[^>]*>Machine ID/);
    expect(html).toContain('id="query"');
    expect(html).toContain('id="machineId"');
    expect(html).toContain('id="project-query"');
    expect(html).toContain('id="back"');
    expect(html).toMatch(/Sign in to browse your session library/i);
    expect(html).toMatch(/session library/i);
    expect(html).not.toMatch(/replica/i);
    expect(html).not.toMatch(/publication/i);
    expect(html).not.toMatch(/<script(?![^>]*\bsrc=)/i);
    expect(html).not.toMatch(/<style/i);
    expect(html).not.toMatch(/\sstyle=/i);
  });

  it('reuses the native slate/green light-dark session-card language', () => {
    const css = shipped('css');
    expect(css).toContain('--bg:#0f172a');
    expect(css).toContain('--accent:#22c55e');
    expect(css).toContain('--panel:#1e293b');
    expect(css).toMatch(/color-scheme:\s*dark/);
    expect(css).toMatch(/#workspace\s*\{[^}]*max-width:\s*960px/);
    expect(css).toContain('#workspace:not(.showing-detail) .detail-pane');
    expect(css).not.toMatch(
      /#(?:workspace|library-page)[^{]*\{[^}]*grid-template-columns/,
    );
    expect(css).toMatch(/\[hidden\]\s*\{[^}]*display:\s*none\s*!important/);
    expect(css).toMatch(/showing-detail[\s\S]*list-pane/);
    expect(css).toContain('.session');
    expect(css).toContain('.badge');
    expect(css).toContain('.message.user');
    expect(css).toContain('.source-pi');
    expect(css).toContain('.source-grok');
    expect(css).toMatch(/\.visually-hidden\s*\{/);
    expect(css).toMatch(/#search\s*\{[^}]*flex-wrap:\s*wrap/);
    expect(css).not.toMatch(/#search[^{]*\{[^}]*flex-wrap:\s*nowrap/);
    expect(css).toMatch(/\.message\.tool[\s\S]*max-width:\s*100%/);
    expect(css).toMatch(/\.message\s+\.body[\s\S]*border-radius:\s*14px/);
    expect(css).toMatch(/\.message\s+\.body[\s\S]*font:\s*inherit/);
    expect(css).toMatch(/pre\s*\{[^}]*ui-monospace/);
    expect(css).toMatch(/body\s*\{[^}]*overflow-wrap:\s*anywhere/);
  });

  it('clamps mobile detail headings to three 18px lines and keeps the full title', async () => {
    const css = shipped('css');
    const mobileAt = css.indexOf('@media (max-width: 879px)');
    expect(mobileAt).toBeGreaterThan(-1);
    expect(css.slice(0, mobileAt)).not.toMatch(/#detail h2/);
    const mobile = css.slice(mobileAt);
    expect(mobile).toMatch(/#detail h2\s*\{[^}]*font-size:\s*18px/);
    expect(mobile).toMatch(/#detail h2\s*\{[^}]*-webkit-line-clamp:\s*3/);
    const longTitle =
      '<goalal-bootstrap>Begin working on this goal: codex 进行了大量的工作，需要你派出多个子代理（如果有限制就分批）每个 PR、每组 PR 和完整项目都 review 好，记得，不需要你修改，你只是 reviewer。';
    const ui = harness();
    const detail = ui.call('openDetail("session-1")');
    ui.requests[0].resolve({
      detail: {
        session: {
          sessionId: 'session-1',
          title: longTitle,
          source: 'commandcode',
        },
      },
    });
    await detail;
    const heading = ui.node('detail').children[0];
    const h2 = heading.children[0];
    expect(h2.tagName).toBe('H2');
    expect(h2.textContent).toBe(longTitle);
    expect(h2.title).toBe(longTitle);
  });

  it('starts signed out and reveals the workspace only after login', async () => {
    const ui = harness();
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('logout').hidden).toBe(true);
    expect(ui.node('signed-out').hidden).toBe(false);
    expect(ui.node('lede').hidden).toBe(false);
    ui.node('credential').value = 'test-only';
    const pending = ui.call('login({ preventDefault() {} })');
    ui.requests[0].resolve(undefined, 204);
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[1].resolve({ items: [] });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[2].resolve({ streams: [] });
    await pending;
    expect(ui.node('workspace').hidden).toBe(false);
    expect(ui.node('signed-out').hidden).toBe(true);
    expect(ui.node('login').hidden).toBe(true);
    expect(ui.node('logout').hidden).toBe(false);
    expect(ui.node('lede').hidden).toBe(true);
    const signedOut = ui.call('logout()');
    ui.requests[3].resolve(undefined, 204);
    await signedOut;
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('signed-out').hidden).toBe(false);
    expect(ui.node('login').hidden).toBe(false);
    expect(ui.node('logout').hidden).toBe(true);
    expect(ui.node('lede').hidden).toBe(false);
  });

  it('reads every overview page before presenting complete totals (repro)', async () => {
    const ui = harness();
    const pending = ui.call('loadOverview()');
    ui.requests[0].resolve({
      snapshotId: 'snapshot-a',
      nextCursor: 'cursor+b',
      streams: [
        { registry: { source: 'codex' }, fts: { readyLogicalSessions: 8 } },
      ],
    });
    await flushAuthWork();
    expect(ui.requests).toHaveLength(2);
    const query = new URL(ui.requests[1].path, 'https://example.test')
      .searchParams;
    expect(query.get('limit')).toBe('2');
    expect(query.get('snapshotId')).toBe('snapshot-a');
    expect(query.get('cursor')).toBe('cursor+b');
    expect(ui.node('overview').textContent).not.toContain('8 ready sessions');
    ui.requests[1].resolve({
      snapshotId: 'snapshot-a',
      streams: [
        {
          registry: { source: 'claude-code' },
          fts: { readyLogicalSessions: 3 },
        },
      ],
    });
    await pending;
    expect(ui.node('overview').textContent).toContain('2 sources');
    expect(ui.node('overview').textContent).toContain('11 ready sessions');
  });

  it('does not present partial overview totals after a later page fails', async () => {
    const ui = harness();
    const pending = ui.call('loadOverview()');
    ui.requests[0].resolve({
      snapshotId: 'snapshot-a',
      nextCursor: 'next',
      streams: [
        { registry: { source: 'codex' }, fts: { readyLogicalSessions: 8 } },
      ],
    });
    await flushAuthWork();
    expect(ui.requests).toHaveLength(2);
    ui.requests[1].resolve(undefined, 503);
    await pending;
    expect(ui.node('overview').textContent).toMatch(/unavailable/i);
    expect(ui.node('overview').textContent).not.toContain('8 ready sessions');
  });

  it('ignores a stale later overview page after a newer request epoch', async () => {
    const ui = harness();
    ui.call('setSignedIn(true)');
    const pending = ui.call('loadOverview()');
    ui.requests[0].resolve({
      snapshotId: 'snapshot-a',
      nextCursor: 'next',
      streams: [],
    });
    await flushAuthWork();
    expect(ui.requests).toHaveLength(2);
    ui.call('bumpEpoch()');
    ui.requests[1].resolve(undefined, 401);
    await pending;
    expect(ui.node('workspace').hidden).toBe(false);
    expect(ui.node('overview').textContent).not.toMatch(/unavailable/i);
  });

  it.each([
    { snapshotId: 'snapshot-b', nextCursor: 'other', streams: [] },
    { snapshotId: 'snapshot-a', nextCursor: 'next', streams: [] },
  ])('rejects inconsistent overview continuation %j', async (continuation) => {
    const ui = harness();
    const pending = ui.call('loadOverview()');
    ui.requests[0].resolve({
      snapshotId: 'snapshot-a',
      nextCursor: 'next',
      streams: [],
    });
    await flushAuthWork();
    expect(ui.requests).toHaveLength(2);
    ui.requests[1].resolve(continuation);
    await pending;
    expect(ui.requests).toHaveLength(2);
    expect(ui.node('overview').textContent).toMatch(/unavailable/i);
  });

  it('summarizes overview streams with counts instead of UUID dumps', async () => {
    const ui = harness();
    const pending = ui.call('loadOverview()');
    ui.requests[0].resolve({
      streams: [
        {
          machineId: 'A0000000-1111-2222-3333-444444444444',
          sourceInstanceId: '22222222-3333-4444-5555-666666666666',
          registry: { source: 'codex' },
          ingest: { publicationCount: 12 },
          fts: { readyLogicalSessions: 8 },
        },
        {
          machineId: 'B0000000-1111-2222-3333-444444444444',
          sourceInstanceId: '33333333-4444-5555-6666-777777777777',
          registry: { source: 'claude-code' },
          ingest: { publicationCount: 4 },
          fts: { readyLogicalSessions: 3 },
        },
      ],
    });
    await pending;
    const summary = ui.node('overview').children[0]?.textContent ?? '';
    expect(summary).toMatch(/session library/i);
    expect(summary).toContain('2 sources');
    expect(ui.node('overview').textContent).toContain('Codex');
    expect(ui.node('overview').textContent).toContain('Claude Code');
    expect(summary).toMatch(/11/);
    expect(summary).not.toMatch(/publication/i);
    expect(summary).not.toMatch(/replica/i);
    expect(summary).not.toMatch(
      /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
    );
    const identities = ui
      .node('overview')
      .children.find((child) => child.tagName === 'DETAILS');
    expect(identities).toBeTruthy();
    expect(identities?.textContent).toContain(
      'A0000000-1111-2222-3333-444444444444',
    );
    expect(identities?.textContent).toMatch(/16/);
  });

  it('renders session cards with source badges and project labels', async () => {
    const ui = harness();
    const pending = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      snapshotId: 'snapshot',
      items: [
        {
          sessionId: 'session-1',
          title: 'Fix login',
          source: 'claude-code',
          projectKey: 'raw-project-key',
          projectLabel: 'Engram',
        },
      ],
    });
    await pending;
    const card = ui.node('sessions').children[0];
    expect(card.className).toContain('session');
    expect(card.textContent).toContain('Fix login');
    expect(card.textContent).toContain('Claude Code');
    expect(card.textContent).toContain('Engram');
    expect(card.textContent).not.toContain('raw-project-key');
    expect(
      card.children.some(
        (child) =>
          child.className.includes('badge') ||
          child.children.some((nested) => nested.className.includes('badge')),
      ),
    ).toBe(true);
  });

  it('shows source-specific badges and real session dates on library cards', async () => {
    const ui = harness();
    const pending = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      items: [
        {
          sessionId: 'dated',
          title: 'Restore Web',
          source: 'claude-code',
          startedAt: 1789214400,
        },
        {
          sessionId: 'undated',
          title: 'Imported history',
          source: 'codex',
          startedAt: null,
        },
      ],
    });
    await pending;
    const dated = ui.node('sessions').children[0].children[1];
    expect(dated.children[0].className).toContain('source-claude-code');
    expect(
      dated.children.find((child) => child.tagName === 'TIME')?.title,
    ).toContain('2026');
    const undated = ui.node('sessions').children[1].children[1];
    expect(undated.children[0].className).toContain('source-codex');
    expect(undated.children.some((child) => child.tagName === 'TIME')).toBe(
      false,
    );
  });

  it('shows message counts only for the displayed transcript generation', async () => {
    for (const matches of [true, false]) {
      const ui = harness();
      const pending = ui.call('openDetail("session-1")');
      ui.requests[0].resolve({
        detail: {
          session: {
            sessionId: 'session-1',
            source: 'codex',
            title: 'Read history',
            startedAt: 1789214400,
          },
          transcriptGeneration: 'shown-generation',
          lastReady: {
            generationId: matches ? 'shown-generation' : 'old-generation',
            normalizedMessageCount: 13558,
          },
        },
      });
      for (let tick = 0; tick < 8; tick += 1) await Promise.resolve();
      ui.requests[1].resolve({ fragments: [] });
      await pending;
      const meta = ui.node('detail').children[0].children[1];
      expect(meta.children.some((child) => child.tagName === 'TIME')).toBe(
        true,
      );
      expect(meta.textContent.includes('13,558 messages')).toBe(matches);
    }
  });

  it('uses a readable fallback when metadata exposes its internal identity as the title', async () => {
    const ui = harness();
    const pending = ui.call('loadSessions(false)');
    const id = 'remote:capture-v1.machine.stream:opaque-session-id';
    ui.requests[0].resolve({
      snapshotId: 'snapshot',
      items: [
        { sessionId: id, title: id, source: 'codex', projectLabel: 'Engram' },
      ],
    });
    await pending;
    expect(ui.node('sessions').textContent).toContain('Untitled session');
    expect(ui.node('sessions').textContent).toContain('Engram');
    expect(ui.node('sessions').textContent).not.toContain(id);
    const detail = ui.call(`openDetail(${JSON.stringify(id)})`);
    ui.requests[1].resolve({
      detail: { session: { sessionId: id, title: id, source: 'codex' } },
    });
    await detail;
    expect(ui.node('detail').textContent).toContain('Untitled session');
    expect(ui.node('detail').textContent).not.toContain(id);
  });

  it.each(['', '  \n'])(
    'omits an empty text bubble for tool-only content %j',
    async (content) => {
      const ui = harness();
      await ui.call(
        `renderMessage('assistant', ${JSON.stringify({
          content,
          toolCalls: [{ name: 'bash', input: 'echo hello', output: 'hello' }],
        })})`,
      );
      const article = ui.node('messages').children[0];
      expect(article.className).toContain('message assistant');
      expect(
        article.children.find((child) => child.className === 'body'),
      ).toBeUndefined();
      const tools = article.children.find(
        (child) => child.className === 'tool-call',
      );
      expect(tools?.textContent).toContain('echo hello');
      expect(tools?.textContent).toContain('hello');
    },
  );

  it('keeps tool JSON collapsed behind details and paints untrusted text only', async () => {
    const ui = harness();
    const payload = JSON.stringify({
      content: 'hello <b>there</b>',
      toolCalls: [
        { name: 'Read', input: '{"path":"/secret"}', output: '{"ok":true}' },
      ],
    });
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'b'.repeat(64),
          role: 'assistant',
          payloadFragment: payload,
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const article = ui.node('messages').children[0];
    expect(article.className).toContain('message assistant');
    const body = article.children.find((child) => child.className === 'body');
    expect(body?.tagName).toBe('DIV');
    expect(body?.textContent).toBe('hello <b>there</b>');
    expect(body?.querySelector('b')).toBeNull();
    const tools = article.children.find((child) => child.tagName === 'DETAILS');
    expect(tools?.className).toBe('tool-call');
    expect(tools?.children[0]?.textContent).toContain('Read');
    expect(tools?.children[0]?.textContent).toContain('{"path":"/secret"}');
    expect(tools?.textContent).toContain('{"path":"/secret"}');
    expect(tools?.textContent).toContain('{"ok":true}');
  });

  it('clips tool and system summaries to a single-line preview', async () => {
    const ui = harness();
    const content = `${'line\n'.repeat(8)}tail ${'x'.repeat(120)}`;
    const pending = ui.call('loadMessages(0, "session", "generation", "")');
    ui.requests[0].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'p'.repeat(64),
          role: 'system',
          payloadFragment: JSON.stringify({ content }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const dump = ui
      .node('messages')
      .children[0].children.find((child) => child.tagName === 'DETAILS');
    const summary = dump?.children[0];
    const preview = summary?.children.find((child) =>
      child.className.includes('preview'),
    );
    expect(preview?.textContent).not.toContain('\n');
    expect(preview?.textContent?.length).toBeLessThanOrEqual(100);
    expect(
      dump?.children.find((child) => child.tagName === 'PRE')?.textContent,
    ).toBe(content);
  });

  it('labels assistant turns from the active detail source', async () => {
    const ui = harness();
    const pending = ui.call('openDetail("grok-1")');
    ui.requests[0].resolve({
      detail: {
        session: { sessionId: 'grok-1', title: 'Grok chat', source: 'grok' },
        transcriptGeneration: 'gen-1',
      },
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[1].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'q'.repeat(64),
          role: 'assistant',
          payloadFragment: JSON.stringify({ content: 'from grok' }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await pending;
    const article = ui.node('messages').children[0];
    expect(article.className).toContain('message assistant');
    expect(article.className).toContain('source-grok');
    expect(article.children[0].className).toBe('role');
    expect(article.children[0].textContent).toBe('Grok');
    expect(article.textContent).toContain('from grok');
  });

  it('does not keep a prior detail source after navigation or logout', async () => {
    const ui = harness();
    const first = ui.call('openDetail("grok-1")');
    ui.requests[0].resolve({
      detail: {
        session: { sessionId: 'grok-1', title: 'Grok chat', source: 'grok' },
        transcriptGeneration: 'gen-1',
      },
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    const second = ui.call('openDetail("pi-1")');
    ui.requests[2].resolve({
      detail: {
        session: { sessionId: 'pi-1', title: 'Pi chat', source: 'pi' },
        transcriptGeneration: 'gen-2',
      },
    });
    ui.requests[1].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 'r'.repeat(64),
          role: 'assistant',
          payloadFragment: JSON.stringify({ content: 'stale grok' }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[3].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 's'.repeat(64),
          role: 'assistant',
          payloadFragment: JSON.stringify({ content: 'from pi' }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await first;
    await second;
    expect(ui.node('messages').textContent).toContain('from pi');
    expect(ui.node('messages').textContent).not.toContain('stale grok');
    expect(ui.node('messages').children[0].className).toContain('source-pi');
    expect(ui.node('messages').children[0].children[0].textContent).toBe('Pi');
    const logout = ui.call('logout()');
    ui.requests[4].resolve(undefined, 204);
    await logout;
    const orphan = ui.call(
      'loadMessages(requestEpoch, "session", "generation", "")',
    );
    ui.requests[5].resolve({
      fragments: [
        {
          messageOrdinal: 0,
          payloadSHA256: 't'.repeat(64),
          role: 'assistant',
          payloadFragment: JSON.stringify({ content: 'after logout' }),
          utf8Offset: 0,
          isLastFragment: true,
        },
      ],
    });
    await orphan;
    const later = ui.node('messages').children[0];
    expect(later.children[0].textContent).toBe('assistant');
    expect(later.className).toBe('message assistant');
    expect(later.textContent).toContain('after logout');
  });

  it('hides exhausted paging and keeps an explicit no-selection detail state', async () => {
    const ui = harness();
    expect(ui.node('more').hidden).toBe(true);
    expect(ui.node('more-messages').hidden).toBe(true);
    const first = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      snapshotId: 'snapshot',
      nextCursor: 'cursor',
      items: [{ sessionId: 'session-1', title: 'One', source: 'codex' }],
    });
    await first;
    expect(ui.node('more').hidden).toBe(false);
    expect(ui.node('detail').textContent).toMatch(/Select a session/i);
    expect(ui.node('workspace').className).not.toContain('showing-detail');
    expect(ui.node('back').hidden).toBe(true);
    const next = ui.call('loadSessions(true)');
    ui.requests[1].resolve({ snapshotId: 'snapshot', items: [] });
    await next;
    expect(ui.node('more').hidden).toBe(true);
    const detail = ui.call('openDetail("session-1")');
    ui.requests[2].resolve({
      detail: {
        session: { sessionId: 'session-1', title: 'One', source: 'codex' },
        transcriptGeneration: 'gen-1',
      },
    });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    ui.requests[3].resolve({ fragments: [] });
    await detail;
    expect(ui.node('detail').textContent).not.toMatch(/Select a session/i);
    expect(ui.node('workspace').className).toContain('showing-detail');
    expect(ui.node('back').hidden).toBe(false);
    expect(ui.node('more-messages').hidden).toBe(true);
    await ui.call('showSessionList()');
    expect(ui.node('workspace').className).not.toContain('showing-detail');
    expect(ui.node('back').hidden).toBe(true);
  });
});

// The HTTP reader percent-decodes components and preserves literal plus.
// URL.searchParams would silently translate plus to space and hide this bug.
function wireQueryFields(path: string): Record<string, string> {
  const query = path.slice(path.indexOf('?') + 1);
  return Object.fromEntries(
    query.split('&').map((field) => {
      const separator = field.indexOf('=');
      return [
        decodeURIComponent(field.slice(0, separator)),
        decodeURIComponent(field.slice(separator + 1)),
      ];
    }),
  );
}

describe('Web viewer query encoding matches the HTTP component contract', () => {
  it('sends a multiword query with percent-encoded spaces instead of literal plus', async () => {
    const ui = harness();
    ui.node('query').value = 'aurora shadowsecond';
    const pending = ui.call('loadSessions(false)');
    const path = ui.requests[0].path;
    ui.requests[0].resolve({ snapshotId: 'snapshot', items: [] });
    await pending;
    expect(path).toContain('query=aurora%20shadowsecond');
    expect(wireQueryFields(path).query).toBe('aurora shadowsecond');
  });

  it('keeps a literal plus distinct from a query space', async () => {
    const ui = harness();
    ui.node('query').value = 'C++';
    const pending = ui.call('loadSessions(false)');
    const path = ui.requests[0].path;
    ui.requests[0].resolve({ snapshotId: 'snapshot', items: [] });
    await pending;
    expect(path).toContain('query=C%2B%2B');
    expect(wireQueryFields(path).query).toBe('C++');
  });

  it('preserves submitted spaces and literal plus across a continuation despite edited fields', async () => {
    const ui = harness();
    const originalQuery = 'aurora + shadowsecond';
    ui.node('query').value = originalQuery;
    ui.call(
      'facets.source.selected.clear(); facets.source.selected.set("codex", "Codex")',
    );
    const first = ui.call('loadSessions(false)');
    const firstPath = ui.requests[0].path;
    ui.requests[0].resolve({
      snapshotId: 'snapshot-id',
      nextCursor: 'cursor-token',
      items: [],
    });
    await first;
    ui.node('query').value = 'edited query';
    ui.call(
      'facets.source.selected.clear(); facets.source.selected.set("claude-code", "Claude Code")',
    );
    const next = ui.call('loadSessions(true)');
    const nextPath = ui.requests[1].path;
    ui.requests[1].resolve({ snapshotId: 'snapshot-id', items: [] });
    await next;
    expect(firstPath).toContain('query=aurora%20%2B%20shadowsecond');
    expect(wireQueryFields(firstPath).query).toBe(originalQuery);
    expect(wireQueryFields(nextPath)).toEqual({
      query: originalQuery,
      sources: 'codex',
      snapshotId: 'snapshot-id',
      cursor: 'cursor-token',
    });
  });
});

async function flushAuthWork(): Promise<void> {
  for (let step = 0; step < 32; step += 1) await Promise.resolve();
}

function authScenario() {
  const ui = harness('existing-cookie');
  const actions: Promise<void>[] = [];
  let unsettledActions = 0;
  return {
    ui,
    start(expression: string) {
      unsettledActions += 1;
      actions.push(
        ui.call(expression).then(
          () => {
            unsettledActions -= 1;
          },
          () => {
            unsettledActions -= 1;
          },
        ),
      );
    },
    authRequests: () =>
      ui.requests.filter((request) => request.path === '/web/api/auth'),
    async drain() {
      // Also finish incorrectly admitted auth/read requests on RED. All test
      // assertions follow this join, including when scenario setup throws.
      for (let round = 0; round < 32; round += 1) {
        for (const request of ui.requests.filter(
          (request) => !request.settled,
        )) {
          request.resolve(
            { streams: [], items: [], fragments: [], snapshotId: 'auth-test' },
            request.path === '/web/api/auth' ? 204 : 200,
          );
        }
        await flushAuthWork();
        if (
          unsettledActions === 0 &&
          ui.requests.every((request) => request.settled)
        ) {
          await Promise.all(actions);
          return;
        }
      }
      throw new Error('Auth scenario did not drain its queued actions');
    },
  };
}

describe('Web auth writes follow user intent, including browser cookie effects', () => {
  it('waits for a delayed login before logout revokes that exact newly issued cookie', async () => {
    const scenario = authScenario();
    const { ui } = scenario;
    let methodsWhileLoginPending: string[] = [];
    let immediatelyCleared: string[] = [];
    try {
      for (const id of ['overview', 'sessions', 'detail', 'messages']) {
        ui.node(id).textContent = 'private transcript';
      }
      ui.node('credential').value = 'later-login';
      scenario.start('login({ preventDefault() {} })');
      await flushAuthWork();
      scenario.start('logout()');
      immediatelyCleared = ['overview', 'sessions', 'detail', 'messages'].map(
        (id) => ui.node(id).textContent,
      );
      await flushAuthWork();
      methodsWhileLoginPending = scenario
        .authRequests()
        .map((request) => request.method);
      // If DELETE was wrongly sent concurrently, deliver it before POST. This
      // leaves the old implementation signed out with a fresh live cookie.
      scenario
        .authRequests()
        .find((request) => request.method === 'DELETE')
        ?.resolve(undefined, 204);
      scenario
        .authRequests()
        .find((request) => request.method === 'POST')
        ?.resolve(undefined, 204);
      await flushAuthWork();
      scenario
        .authRequests()
        .find((request) => request.method === 'DELETE')
        ?.resolve(undefined, 204);
    } finally {
      await scenario.drain();
    }
    expect(immediatelyCleared).toEqual(['', '', '', '']);
    expect(methodsWhileLoginPending).toEqual(['POST']);
    expect(ui.auth.maximumInflight()).toBe(1);
    expect(scenario.authRequests().map((request) => request.method)).toEqual([
      'POST',
      'DELETE',
    ]);
    expect(ui.auth.issuedCookies).toEqual(['test-cookie-1']);
    expect(
      scenario.authRequests().map((request) => request.cookieAtDispatch),
    ).toEqual(['existing-cookie', 'test-cookie-1']);
    expect(ui.auth.revokedCookies).toEqual(['test-cookie-1']);
    expect(ui.auth.activeCookies.has('test-cookie-1')).toBe(false);
    expect(ui.auth.cookie()).toBeNull();
    expect(ui.node('status').textContent).toBe('signed out');
    expect(
      ui.requests.filter((request) => request.method === 'GET'),
    ).toHaveLength(0);
  });

  it('queues an explicit later login behind a pending logout so the later cookie wins', async () => {
    const scenario = authScenario();
    const { ui } = scenario;
    let methodsWhileLogoutPending: string[] = [];
    try {
      scenario.start('logout()');
      await flushAuthWork();
      ui.node('credential').value = 'explicit-later-login';
      scenario.start('login({ preventDefault() {} })');
      await flushAuthWork();
      methodsWhileLogoutPending = scenario
        .authRequests()
        .map((request) => request.method);
      // A wrongly concurrent POST finishes first; late DELETE then clears its
      // cookie. A serialized implementation cannot issue this early POST.
      scenario
        .authRequests()
        .find((request) => request.method === 'POST')
        ?.resolve(undefined, 204);
      await flushAuthWork();
      scenario
        .authRequests()
        .find((request) => request.method === 'DELETE')
        ?.resolve(undefined, 204);
      await flushAuthWork();
      scenario
        .authRequests()
        .find((request) => request.method === 'POST')
        ?.resolve(undefined, 204);
    } finally {
      await scenario.drain();
    }
    expect(methodsWhileLogoutPending).toEqual(['DELETE']);
    expect(ui.auth.maximumInflight()).toBe(1);
    expect(scenario.authRequests().map((request) => request.method)).toEqual([
      'DELETE',
      'POST',
    ]);
    expect(
      scenario.authRequests().map((request) => request.cookieAtDispatch),
    ).toEqual(['existing-cookie', null]);
    expect(ui.auth.revokedCookies).toEqual(['existing-cookie']);
    expect(ui.auth.issuedCookies).toEqual(['test-cookie-1']);
    expect(ui.auth.cookie()).toBe('test-cookie-1');
    expect(ui.auth.activeCookies.has('test-cookie-1')).toBe(true);
    expect(ui.node('status').textContent).toBe('signed in');
  });

  it('still issues a queued logout when the preceding login request rejects', async () => {
    const scenario = authScenario();
    const { ui } = scenario;
    let methodsBeforeRejection: string[] = [];
    try {
      ui.node('credential').value = 'rejected-login';
      scenario.start('login({ preventDefault() {} })');
      await flushAuthWork();
      scenario.start('logout()');
      await flushAuthWork();
      methodsBeforeRejection = scenario
        .authRequests()
        .map((request) => request.method);
      scenario
        .authRequests()
        .find((request) => request.method === 'POST')
        ?.reject();
      await flushAuthWork();
      scenario
        .authRequests()
        .find((request) => request.method === 'DELETE')
        ?.resolve(undefined, 204);
    } finally {
      await scenario.drain();
    }
    expect(methodsBeforeRejection).toEqual(['POST']);
    expect(ui.auth.maximumInflight()).toBe(1);
    expect(scenario.authRequests().map((request) => request.method)).toEqual([
      'POST',
      'DELETE',
    ]);
    expect(ui.auth.issuedCookies).toEqual([]);
    expect(ui.auth.revokedCookies).toEqual(['existing-cookie']);
    expect(ui.auth.cookie()).toBeNull();
    expect(ui.node('status').textContent).toBe('signed out');
  });

  it('reports failed logout honestly and permits a later login after that failed auth write', async () => {
    const scenario = authScenario();
    const { ui } = scenario;
    let failedStatus = '';
    let cookieAfterFailure: string | null = null;
    let messagesAfterFailure = '';
    try {
      ui.node('messages').textContent = 'private transcript';
      scenario.start('logout()');
      await flushAuthWork();
      scenario
        .authRequests()
        .find((request) => request.method === 'DELETE')
        ?.resolve({}, 503);
      await flushAuthWork();
      failedStatus = ui.node('status').textContent;
      cookieAfterFailure = ui.auth.cookie();
      messagesAfterFailure = ui.node('messages').textContent;
      ui.node('credential').value = 'login-after-failed-logout';
      scenario.start('login({ preventDefault() {} })');
      await flushAuthWork();
      scenario
        .authRequests()
        .find((request) => request.method === 'POST')
        ?.resolve(undefined, 204);
    } finally {
      await scenario.drain();
    }
    expect(failedStatus).toContain('Sign-out failed');
    expect(failedStatus).toContain('Retry to revoke');
    expect(failedStatus).not.toBe('signed out');
    expect(ui.auth.maximumInflight()).toBe(1);
    expect(cookieAfterFailure).toBe('existing-cookie');
    expect(messagesAfterFailure).toBe('');
    expect(scenario.authRequests().map((request) => request.method)).toEqual([
      'DELETE',
      'POST',
    ]);
    expect(ui.auth.revokedCookies).toEqual([]);
    expect(ui.auth.cookie()).toBe('test-cookie-1');
    expect(ui.auth.activeCookies.has('test-cookie-1')).toBe(true);
    expect(ui.node('status').textContent).toBe('signed in');
  });
});

describe('native AI call history in Stats', () => {
  const item = {
    id: '17',
    at: 1789274106,
    caller: 'summary',
    operation: 'chat',
    model: 'provider/model:latest',
    provider: 'compatible',
    statusCode: 200,
    durationMs: 1250,
    promptTokens: 120,
    completionTokens: 30,
    totalTokens: 150,
    hasError: false,
    sessionId: 'captured-session',
  };
  const page = {
    snapshotId: 'audit',
    observedAt: 1789274106,
    total: 2,
    items: [item],
    nextCursor: 'next',
  };

  it('keeps audit filters and full totals across held pages', async () => {
    const ui = harness();
    ui.node('ai-caller').value = 'summary';
    ui.node('ai-model').value = 'provider/model:latest';
    ui.node('ai-session').value = 'captured-session';
    ui.node('ai-from').value = '2026-09-12';
    ui.node('ai-to').value = '2026-09-13';
    ui.node('ai-errors').value = 'false';
    const first = ui.call('showStatsView("ai")');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(ui.requests[0].path).toContain('/web/api/ai/audit?');
    expect(Object.fromEntries(query)).toMatchObject({
      caller: 'summary',
      model: 'provider/model:latest',
      sessionId: 'captured-session',
      from: '2026-09-12',
      to: '2026-09-13',
      hasError: 'false',
    });
    ui.requests[0].resolve(page);
    await first;
    expect(ui.node('ai-status').textContent).toContain('2 calls');
    expect(ui.node('ai-rows').textContent).toContain('provider/model:latest');
    expect(ui.node('ai-rows').textContent).toContain('150');
    ui.node('ai-model').value = 'changed';
    const next = ui.call('loadAiAudit(true)');
    const continued = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    expect(continued.get('snapshotId')).toBe('audit');
    expect(continued.get('model')).toBe('provider/model:latest');
    ui.requests[1].resolve({
      ...page,
      items: [{ ...item, id: '16' }],
      nextCursor: undefined,
    });
    await next;
    expect(ui.node('ai-rows').children).toHaveLength(2);
    expect(ui.node('ai-more').hidden).toBe(true);
  });

  it('loads call details without rendering arbitrary body or metadata fields', async () => {
    const ui = harness();
    const pending = ui.call('loadAiDetail("17")');
    expect(ui.requests[0].path).toBe('/web/api/ai/audit/17');
    ui.requests[0].resolve({
      observedAt: 1789274106,
      item: {
        ...item,
        hasError: true,
        statusCode: 429,
        error: '<script>failure</script>',
        method: 'POST',
        url: 'https://example.test/chat',
        requestBody: 'secret body',
      },
      hasRequestBody: true,
      hasResponseBody: false,
      meta: 'private metadata',
    });
    await pending;
    const detail = ui.node('ai-detail').textContent;
    expect(detail).toContain('429');
    expect(detail).toContain('<script>failure</script>');
    expect(detail).toContain('captured-session');
    expect(detail).toContain('Stored');
    expect(detail).not.toContain('secret body');
    expect(detail).not.toContain('private metadata');
  });

  it('shows resolved stats interval, totals, caller/model and hourly breakdowns', async () => {
    const ui = harness();
    ui.node('ai-from').value = '2026-09-12';
    ui.node('ai-to').value = '2026-09-13';
    const pending = ui.call('loadAiStats()');
    const query = new URLSearchParams(ui.requests[0].path.split('?')[1]);
    expect(ui.requests[0].path).toContain('/web/api/ai/stats?');
    expect(Object.fromEntries(query)).toEqual({
      from: '2026-09-12',
      to: '2026-09-13',
    });
    ui.requests[0].resolve({
      observedAt: 1789274106,
      timeRange: { from: '2026-09-11T16:00:00Z', to: '2026-09-13T16:00:00Z' },
      totals: {
        requests: 9,
        errors: 2,
        promptTokens: 1200,
        completionTokens: 300,
        avgDurationMs: 850,
      },
      byCaller: [
        {
          key: 'summary',
          requests: 9,
          errors: 2,
          promptTokens: 1200,
          completionTokens: 300,
        },
      ],
      byModel: [
        {
          key: 'provider/model:latest',
          requests: 9,
          promptTokens: 1200,
          completionTokens: 300,
        },
      ],
      hourly: [{ hour: '2026-09-13T09:00', requests: 9, tokens: 1500 }],
    });
    await pending;
    expect(ui.node('ai-stats').textContent).toContain('Requests9');
    expect(ui.node('ai-stats').textContent).toContain('Errors2');
    expect(ui.node('ai-stats').textContent).toContain('1,200');
    expect(ui.node('ai-stats').textContent).toContain('provider/model:latest');
    expect(ui.node('ai-stats').textContent).toContain('2026-09-13T09:00 UTC');
    expect(ui.node('ai-stats-status').textContent).toContain(
      '2026-09-11T16:00:00Z',
    );
  });

  it('clears AI content and ignores an in-flight detail after logout', async () => {
    const ui = harness();
    const pending = ui.call('loadAiDetail("17")');
    const logout = ui.call('logout()');
    ui.requests[1].resolve(undefined, 204);
    await logout;
    ui.requests[0].resolve({
      observedAt: 1789274106,
      item,
      hasRequestBody: false,
      hasResponseBody: false,
    });
    await pending;
    expect(ui.node('ai-detail').textContent).toBe('');
    expect(ui.node('ai-rows').textContent).toBe('');
    expect(ui.node('ai-stats').textContent).toBe('');
  });

  it('does not let a detail request cancel an in-flight history page', async () => {
    const ui = harness();
    const listing = ui.call('loadAiAudit(false)');
    const detail = ui.call('loadAiDetail("17")');
    ui.requests[1].resolve({
      observedAt: 1789274106,
      item,
      hasRequestBody: false,
      hasResponseBody: false,
    });
    await detail;
    ui.requests[0].resolve(page);
    await listing;
    expect(ui.node('ai-rows').children).toHaveLength(1);
    expect(ui.node('ai-more').disabled).toBe(false);
    expect(ui.node('ai-detail').textContent).toContain('Call ID17');
  });

  it('ignores an older detail response after a different call is selected', async () => {
    const ui = harness();
    const old = ui.call('loadAiDetail("17")');
    const current = ui.call('loadAiDetail("16")');
    ui.requests[1].resolve({
      observedAt: 1789274106,
      item: { ...item, id: '16', model: 'new-model' },
      hasRequestBody: false,
      hasResponseBody: false,
    });
    await current;
    ui.requests[0].resolve({
      observedAt: 1789274106,
      item,
      hasRequestBody: false,
      hasResponseBody: false,
    });
    await old;
    expect(ui.node('ai-detail').textContent).toContain('new-model');
    expect(ui.node('ai-detail').textContent).not.toContain(
      'provider/model:latest',
    );
  });

  it('distinguishes no calls from audit service failure', async () => {
    const ui = harness();
    let pending = ui.call('loadAiAudit(false)');
    ui.requests[0].resolve({
      ...page,
      total: 0,
      items: [],
      nextCursor: undefined,
    });
    await pending;
    expect(ui.node('ai-status').textContent).toContain('No recorded AI calls');
    pending = ui.call('loadAiAudit(false)');
    ui.requests[1].resolve({}, 503);
    await pending;
    expect(ui.node('ai-status').textContent).toContain('unavailable');
    expect(ui.node('ai-rows').textContent).toBe('');
  });
});

describe('insight search and complete reading', () => {
  const hit = {
    id: 'note-a',
    content: '<script>Memory preview</script>',
    sourceSessionId: 'session-a',
    matchType: 'semantic',
    score: 0.9,
  };
  const detail = {
    id: 'note-a',
    revision: 'revision-a',
    offset: 0,
    totalLength: 5,
    content: 'A🙂中',
    nextOffset: 3,
    sourceSessionId: 'session-a',
  };

  it('shows insight matches even when no session matches exist', async () => {
    const ui = harness();
    await ui.call('activatePage("search")');
    ui.node('query').value = 'memory';
    const pending = ui.call('loadRankedSearch()');
    ui.requests[0].resolve({
      query: 'memory',
      items: [],
      searchModes: ['semantic'],
      insightResults: [hit],
    });
    await pending;
    expect(ui.node('insight-results').hidden).toBe(false);
    expect(ui.node('insight-rows').textContent).toContain(
      '<script>Memory preview</script>',
    );
    expect(ui.node('insight-rows').textContent).toContain('Semantic match');
    expect(ui.node('search-result-status').textContent).toContain('1 insight');
    ui.node('insight-rows').children[0].querySelector('button')?.click();
    expect(ui.requests[1].path).toContain('/web/api/insights/note-a');
    ui.requests[1].resolve(detail);
    await new Promise((resolve) => setImmediate(resolve));
    expect(ui.node('insight-body').textContent).toBe('A🙂中');
  });

  it('continues full Unicode content with the returned revision and scalar offset', async () => {
    const ui = harness();
    const first = ui.call('loadInsight("note-a", false)');
    ui.requests[0].resolve(detail);
    await first;
    expect(ui.node('insight-dialog').hidden).toBe(false);
    expect(ui.node('insight-more').hidden).toBe(false);
    const next = ui.call('loadInsight("note-a", true)');
    const params = new URLSearchParams(ui.requests[1].path.split('?')[1]);
    expect(params.get('offset')).toBe('3');
    expect(params.get('revision')).toBe('revision-a');
    ui.requests[1].resolve({
      ...detail,
      offset: 3,
      content: '🚀Z',
      nextOffset: undefined,
    });
    await next;
    expect(ui.node('insight-body').textContent).toBe('A🙂中🚀Z');
    expect(ui.node('insight-more').hidden).toBe(true);
    expect(ui.node('insight-detail-status').textContent).toContain('Complete');
  });

  it('clears partial content when its revision changes between pages', async () => {
    const ui = harness();
    const first = ui.call('loadInsight("note-a", false)');
    ui.requests[0].resolve(detail);
    await first;
    const next = ui.call('loadInsight("note-a", true)');
    ui.requests[1].resolve({
      ...detail,
      revision: 'revision-b',
      offset: 3,
      content: 'ZZ',
      nextOffset: undefined,
    });
    await next;
    expect(ui.node('insight-body').textContent).toBe('');
    expect(ui.node('insight-detail-status').textContent).toContain('changed');
    expect(ui.node('insight-more').hidden).toBe(true);
  });

  it('closing the reader prevents a late response from reopening it', async () => {
    const ui = harness();
    const pending = ui.call('loadInsight("note-a", false)');
    ui.node('insight-close').click();
    ui.requests[0].resolve(detail);
    await pending;
    expect(ui.node('insight-dialog').hidden).toBe(true);
    expect(ui.node('insight-body').textContent).toBe('');
  });

  it('logout clears insight results and ignores an in-flight detail', async () => {
    const ui = harness();
    await ui.call('activatePage("search")');
    ui.node('query').value = 'memory';
    const search = ui.call('loadRankedSearch()');
    ui.requests[0].resolve({
      query: 'memory',
      items: [],
      searchModes: ['keyword'],
      insightResults: [hit],
    });
    await search;
    const pending = ui.call('loadInsight("note-a", false)');
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve(detail);
    await pending;
    expect(ui.node('insight-rows').textContent).toBe('');
    expect(ui.node('insight-body').textContent).toBe('');
    expect(ui.node('insight-dialog').hidden).toBe(true);
  });
});

describe('saving insights from search', () => {
  async function editor() {
    const ui = harness();
    await ui.call('activatePage("search")');
    const access = ui.call('loadInsightWriteAccess()');
    ui.requests[0].resolve({ canWrite: true });
    await access;
    return ui;
  }

  it('shows the form only after editor access is confirmed', async () => {
    const ui = harness();
    await ui.call('activatePage("search")');
    const access = ui.call('loadInsightWriteAccess()');
    expect(ui.node('insight-save-form').hidden).toBe(true);
    ui.requests[0].resolve({ canWrite: false });
    await access;
    expect(ui.node('insight-save-form').hidden).toBe(true);
    expect(ui.node('insight-write-status').textContent).toContain('Read only');
    ui.node('insight-content-input').value = 'A useful library insight';
    await ui.call('saveInsight()');
    expect(ui.requests).toHaveLength(1);
  });

  it('saves supplied text and classification with a single explicit write', async () => {
    const ui = await editor();
    ui.node('insight-content-input').value =
      '  Preserve the native Web workflow.  ';
    ui.node('insight-wing-input').value = 'Engineering';
    ui.node('insight-room-input').value = 'Engram';
    ui.node('insight-importance-input').value = '4';
    ui.node('insight-source-input').value = 'session-a';
    const pending = ui.call('saveInsight()');
    expect(ui.requests[1].method).toBe('POST');
    expect(ui.requests[1].path).toBe('/web/api/insights');
    expect(JSON.parse(ui.requests[1].body || '{}')).toEqual({
      content: 'Preserve the native Web workflow.',
      wing: 'Engineering',
      room: 'Engram',
      importance: 4,
      sourceSessionId: 'session-a',
    });
    await ui.call('saveInsight()');
    expect(ui.requests).toHaveLength(2);
    ui.requests[1].resolve({
      id: 'saved-note',
      warning: 'Keyword search is available immediately',
    });
    await pending;
    expect(ui.node('insight-content-input').value).toBe('');
    expect(ui.node('insight-write-status').textContent).toContain('Saved');
    expect(ui.node('insight-write-status').textContent).toContain('Keyword');
    expect(ui.node('insight-saved-read').hidden).toBe(false);
  });

  it('keeps an invalid short draft without sending it', async () => {
    const ui = await editor();
    ui.node('insight-content-input').value = 'short';
    await ui.call('saveInsight()');
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('insight-content-input').value).toBe('short');
    expect(ui.node('insight-write-status').textContent).toContain('10');
  });

  it('preserves an uncertain save draft and never automatically retries', async () => {
    const ui = await editor();
    ui.node('insight-content-input').value = 'A useful library insight';
    const pending = ui.call('saveInsight()');
    ui.requests[1].resolve({}, 503);
    await pending;
    expect(ui.node('insight-content-input').value).toBe(
      'A useful library insight',
    );
    expect(ui.node('insight-write-status').textContent).toContain(
      'Search before retrying',
    );
    expect(ui.requests).toHaveLength(2);
  });

  it('clears the draft when the write session has expired', async () => {
    const ui = await editor();
    ui.node('insight-content-input').value = 'A useful library insight';
    const pending = ui.call('saveInsight()');
    ui.requests[1].resolve({}, 401);
    await pending;
    expect(ui.node('insight-content-input').value).toBe('');
    expect(ui.node('workspace').hidden).toBe(true);
    expect(ui.node('insight-save-form').hidden).toBe(true);
  });

  it('logout clears drafts and ignores the late save result', async () => {
    const ui = await editor();
    ui.node('insight-content-input').value = 'A useful library insight';
    const pending = ui.call('saveInsight()');
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve({ id: 'saved-note' });
    await pending;
    expect(ui.node('insight-content-input').value).toBe('');
    expect(ui.node('insight-write-status').textContent).toBe('');
    expect(ui.node('insight-save-form').hidden).toBe(true);
    expect(ui.node('insight-saved-read').hidden).toBe(true);
  });
});

describe('session summary and title actions', () => {
  async function ready() {
    const ui = harness();
    await ui.call(
      'detailContextSession="session-a"; detailContextGeneration="generation-a"',
    );
    const pending = ui.call('loadSessionActionAccess()');
    ui.requests[0].resolve({ canWrite: true });
    await pending;
    return ui;
  }

  it('renders a previously saved full summary in session detail', async () => {
    const ui = harness();
    const summary = 'Full saved summary. '.repeat(40);
    const pending = ui.call('openDetail("session-a")');
    ui.requests[0].resolve({
      detail: {
        session: { sessionId: 'session-a', title: 'A session' },
        summary,
      },
    });
    await pending;
    expect(ui.node('session-summary').hidden).toBe(false);
    expect(ui.node('session-summary-text').textContent).toContain(
      summary.trim(),
    );
  });

  it('does not generate for a viewer', async () => {
    const ui = harness();
    await ui.call(
      'detailContextSession="session-a"; detailContextGeneration="generation-a"',
    );
    const pending = ui.call('loadSessionActionAccess()');
    ui.requests[0].resolve({ canWrite: false });
    await pending;
    await ui.call('generateSessionText("summary")');
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('session-generate-summary').disabled).toBe(true);
    expect(ui.node('session-action-status').textContent).toContain('Read only');
  });

  it('sends the displayed generation and preserves the full returned summary', async () => {
    const ui = await ready();
    const summary = 'A complete generated summary. '.repeat(40);
    const pending = ui.call('generateSessionText("summary")');
    expect(ui.requests[1].path).toBe('/web/api/sessions/session-a/summary');
    expect(JSON.parse(ui.requests[1].body || '{}')).toEqual({
      generation: 'generation-a',
    });
    await ui.call('generateSessionText("summary")');
    expect(ui.requests).toHaveLength(2);
    ui.requests[1].resolve({
      sessionId: 'session-a',
      generation: 'generation-a',
      summary,
    });
    await pending;
    expect(ui.node('session-summary-text').textContent).toContain(
      summary.trim(),
    );
    expect(ui.node('session-action-status').textContent).toContain(
      'Summary saved',
    );
  });

  it('uses the effective display title without replacing a custom name', async () => {
    const ui = harness();
    const detail = ui.call('openDetail("session-a")');
    ui.requests[0].resolve({
      detail: { session: { sessionId: 'session-a', title: 'My custom title' } },
    });
    await detail;
    await ui.call('detailContextGeneration="generation-a"');
    const access = ui.call('loadSessionActionAccess()');
    ui.requests[1].resolve({ canWrite: true });
    await access;
    const pending = ui.call('generateSessionText("title")');
    expect(ui.requests[2].path).toBe('/web/api/sessions/session-a/title');
    ui.requests[2].resolve({
      sessionId: 'session-a',
      generation: 'generation-a',
      title: 'AI generated title',
      displayTitle: 'My custom title',
    });
    await pending;
    expect(ui.node('detail').querySelector('h2')?.textContent).toBe(
      'My custom title',
    );
    expect(ui.node('session-action-status').textContent).toContain(
      'Title saved',
    );
  });

  it('rejects a response for a different transcript generation', async () => {
    const ui = await ready();
    const pending = ui.call('generateSessionText("summary")');
    ui.requests[1].resolve({
      sessionId: 'session-a',
      generation: 'generation-b',
      summary: 'stale content',
    });
    await pending;
    expect(ui.node('session-summary-text').textContent).toBe('');
    expect(ui.node('session-action-status').textContent).toContain('Reopen');
  });

  it('ignores an in-flight generation after logout', async () => {
    const ui = await ready();
    const pending = ui.call('generateSessionText("summary")');
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve({
      sessionId: 'session-a',
      generation: 'generation-a',
      summary: 'private result',
    });
    await pending;
    expect(ui.node('session-summary-text').textContent).toBe('');
    expect(ui.node('session-actions').hidden).toBe(true);
  });

  it('reports bulk generation as started rather than completed', async () => {
    const ui = harness();
    await ui.call('activePage="settings"; settingsCanWrite=true');
    const pending = ui.call('generateMissingTitles()');
    expect(ui.requests[0].path).toBe('/web/api/titles/regenerate');
    expect(ui.requests[0].method).toBe('POST');
    ui.requests[0].resolve({ status: 'started', total: 12 });
    await pending;
    expect(ui.node('batch-title-status').textContent).toContain('started');
    expect(ui.node('batch-title-status').textContent).toContain('12');
    expect(ui.node('batch-title-status').textContent).not.toContain(
      'completed',
    );
  });
});

describe('native AI settings editing', () => {
  const settings = {
    aiProtocol: 'openai',
    aiBaseURL: 'https://provider.example/v1',
    aiModel: 'existing-model',
    summaryLanguage: '中文',
    summaryMaxSentences: 3,
    summaryStyle: '',
    summaryPrompt: '',
    summaryMaxTokens: 200,
    summaryTemperature: 0.3,
    summarySampleFirst: 20,
    summarySampleLast: 30,
    summaryTruncateChars: 500,
    titleProvider: 'ollama',
    titleBaseUrl: 'http://localhost:11434',
    titleModel: 'existing-title-model',
    embeddingBaseURL: 'https://provider.example/v1',
    embeddingModel: 'existing-embedding',
    embeddingDimension: 1536,
    embeddingIncludeDimensions: false,
    aiAudit: { enabled: true, logBodies: false, maxBodySize: 10000 },
  };
  async function ready(editor = true) {
    const ui = harness();
    await ui.call(`activePage="settings"; settingsCanWrite=${editor}`);
    const pending = ui.call('loadAISettings()');
    expect(ui.requests[0].path).toBe('/web/api/settings/ai');
    ui.requests[0].resolve({ settings });
    await pending;
    return ui;
  }
  // HQ publishes the legacy `aiProtocol: "disabled"` (summaries off). The form
  // must render it as a choice and let an editor switch protocols (repro).
  it('renders the disabled protocol choice and saves a protocol switch (repro)', async () => {
    const ui = harness();
    await ui.call('activePage="settings"; settingsCanWrite=true');
    const pending = ui.call('loadAISettings()');
    ui.requests[0].resolve({
      settings: { ...settings, aiProtocol: 'disabled' },
    });
    await pending;
    expect(ui.node('ai-config-status').textContent).not.toContain(
      'unavailable',
    );
    expect(ui.node('ai-config-aiProtocol').value).toBe('disabled');
    expect(ui.node('ai-config-save').disabled).toBe(false);
    ui.node('ai-config-aiProtocol').value = 'openai';
    const save = ui.call('saveAISettings()');
    expect(JSON.parse(ui.requests[1].body || '{}')).toEqual({
      aiProtocol: 'openai',
    });
    ui.requests[1].resolve({ settings });
    await save;
    expect(ui.node('ai-config-aiProtocol').value).toBe('openai');
  });
  it('shows saved values to viewers and prevents writes', async () => {
    const ui = await ready(false);
    expect(ui.node('ai-config-aiModel').value).toBe('existing-model');
    expect(ui.node('ai-config-save').disabled).toBe(true);
    const count = ui.requests.length;
    await ui.call('saveAISettings()');
    expect(ui.requests).toHaveLength(count);
  });
  it('saves only edited native fields and prevents duplicate submissions', async () => {
    const ui = await ready();
    ui.node('ai-config-summaryMaxTokens').value = '800';
    ui.node('ai-config-summaryPrompt').value = 'Decisions\nNext steps';
    const pending = ui.call('saveAISettings()');
    const write = ui.requests[1];
    expect(write.method).toBe('POST');
    expect(JSON.parse(write.body || '{}')).toEqual({
      summaryMaxTokens: 800,
      summaryPrompt: 'Decisions\nNext steps',
    });
    await ui.call('saveAISettings()');
    expect(ui.requests).toHaveLength(2);
    write.resolve({
      settings: {
        ...settings,
        summaryMaxTokens: 800,
        summaryPrompt: 'Decisions\nNext steps',
      },
    });
    await pending;
    expect(ui.node('ai-config-status').textContent).toContain('Saved');
    expect(ui.node('ai-config-summaryMaxTokens').value).toBe('800');
  });
  it('rejects blank or out-of-range numeric fields before sending', async () => {
    const ui = await ready();
    ui.node('ai-config-summaryMaxTokens').value = '';
    await ui.call('saveAISettings()');
    expect(ui.requests).toHaveLength(1);
    expect(ui.node('ai-config-status').textContent).toContain('Check');
    ui.node('ai-config-summaryMaxTokens').value = '32769';
    await ui.call('saveAISettings()');
    expect(ui.requests).toHaveLength(1);
  });
  it('keeps an uncertain draft and requires reload before retrying', async () => {
    const ui = await ready();
    ui.node('ai-config-aiModel').value = 'new-model';
    const pending = ui.call('saveAISettings()');
    ui.requests[1].reject();
    await pending;
    expect(ui.node('ai-config-aiModel').value).toBe('new-model');
    expect(ui.node('ai-config-status').textContent).toContain('Reload');
    expect(ui.node('ai-config-save').disabled).toBe(true);
  });
  it('clears private prompt text on logout and ignores late responses', async () => {
    const ui = await ready();
    ui.node('ai-config-summaryPrompt').value = 'Private drafting instruction';
    const pending = ui.call('saveAISettings()');
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve({
      settings: { ...settings, summaryPrompt: 'Private drafting instruction' },
    });
    await pending;
    expect(ui.node('ai-config-summaryPrompt').value).toBe('');
    expect(ui.node('ai-config-status').textContent).toBe('');
  });
  it('saves audit changes as one bounded native block without credentials', async () => {
    const ui = await ready();
    ui.node('ai-config-aiAudit.logBodies').checked = true;
    const pending = ui.call('saveAISettings()');
    const patch = JSON.parse(ui.requests[1].body || '{}');
    expect(patch).toEqual({
      aiAudit: { enabled: true, logBodies: true, maxBodySize: 10000 },
    });
    expect(ui.requests[1].body).not.toContain('ApiKey');
    ui.requests[1].resolve({
      settings: { ...settings, aiAudit: patch.aiAudit },
    });
    await pending;
  });
});
