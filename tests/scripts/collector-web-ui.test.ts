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
  value = '';
  disabled = false;
  children: Element[] = [];
  private text = '';

  get textContent(): string {
    return this.text + this.children.map((child) => child.textContent).join('');
  }

  set textContent(value: string) {
    this.text = value;
    this.children = [];
  }

  appendChild(child: Element): void {
    this.children.push(child);
  }

  addEventListener(): void {}
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
    cookieAtDispatch: string | null;
    settled: boolean;
    resolve: (body: unknown, status?: number) => void;
    reject: () => void;
  }[] = [];
  const modelAuth = initialAuthCookie !== undefined;
  let cookie: string | null = initialAuthCookie ?? null;
  const activeCookies = new Set(initialAuthCookie ? [initialAuthCookie] : []);
  const issuedCookies: string[] = [];
  const revokedCookies: (string | null)[] = [];
  let maximumInflightAuth = 0;
  const context = createContext({
    document: { getElementById: node, createElement: () => new Element() },
    TextEncoder,
    TextDecoder,
    URLSearchParams,
    fetch: (path: string, options?: { method?: string }) =>
      new Promise((fulfill, reject) => {
        const request: (typeof requests)[number] = {
          path,
          method: options?.method ?? 'GET',
          cookieAtDispatch: cookie,
          settled: false,
          reject: () => {
            if (request.settled) return;
            request.settled = true;
            reject(new Error('test-only disconnected transport'));
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
    auth: {
      cookie: () => cookie,
      maximumInflight: () => maximumInflightAuth,
      activeCookies,
      issuedCookies,
      revokedCookies,
    },
    call: (expression: string) =>
      runInContext(expression, context) as Promise<void>,
  };
}

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
    expect(ui.requests[1].path).toBe('/web/api/overview');
    const logout = ui.call('logout()');
    ui.requests[2].resolve(undefined, 204);
    await logout;
    ui.requests[1].resolve({ streams: [] });
    for (let step = 0; step < 8; step += 1) await Promise.resolve();
    const count = ui.requests.length;
    // Drain an incorrectly admitted request too, so RED leaves no pending work.
    ui.requests[3]?.resolve({ items: [] });
    await login;
    expect(count).toBe(3);
    expect(ui.node('status').textContent).toBe('signed out');
  });

  it('binds continuation to submitted filters, not fields edited without submitting', async () => {
    const ui = harness();
    ui.node('query').value = 'original';
    ui.node('source').value = 'claude-code';
    const first = ui.call('loadSessions(false)');
    ui.requests[0].resolve({
      snapshotId: 'snapshot',
      nextCursor: 'cursor',
      items: [],
    });
    await first;
    ui.node('query').value = 'changed';
    ui.node('source').value = 'codex';
    const next = ui.call('loadSessions(true)');
    const params = new URL(ui.requests[1].path, 'https://viewer.example')
      .searchParams;
    ui.requests[1].resolve({ snapshotId: 'snapshot', items: [] });
    await next;
    expect(params.get('query')).toBe('original');
    expect(params.get('source')).toBe('claude-code');
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
    await first;
    expect(ui.node('messages').children).toHaveLength(0);
    const next = ui.call(
      'loadMessages(0, "session", "generation", "continuation")',
    );
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
    await next;
    expect(ui.node('messages').children).toHaveLength(1);
    expect(ui.node('messages').textContent).toBe(`assistant ${content}`);
    expect(ui.node('messages').children[0].children).toHaveLength(0);
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
    ui.node('source').value = 'codex';
    const first = ui.call('loadSessions(false)');
    const firstPath = ui.requests[0].path;
    ui.requests[0].resolve({
      snapshotId: 'snapshot-id',
      nextCursor: 'cursor-token',
      items: [],
    });
    await first;
    ui.node('query').value = 'edited query';
    ui.node('source').value = 'claude-code';
    const next = ui.call('loadSessions(true)');
    const nextPath = ui.requests[1].path;
    ui.requests[1].resolve({ snapshotId: 'snapshot-id', items: [] });
    await next;
    expect(firstPath).toContain('query=aurora%20%2B%20shadowsecond');
    expect(wireQueryFields(firstPath).query).toBe(originalQuery);
    expect(wireQueryFields(nextPath)).toEqual({
      query: originalQuery,
      source: 'codex',
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
