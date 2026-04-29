// src/core/daemon-client.ts
// Thin HTTP client used by the MCP process to forward write operations to the
// daemon. Keeps MCP as a read-only DB client (Phase B of the single-writer
// refactor — see PROGRESS.md). Call sites decide whether to fall back to a
// direct write when the daemon is unreachable, using `DaemonClientError`
// or a thrown AbortError to signal the failure.

import type { FileSettings } from './config.js';
import type { Logger } from './logger.js';

export class DaemonClientError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: unknown,
    message: string,
  ) {
    super(message);
    this.name = 'DaemonClientError';
  }
}

interface DaemonClientOptions {
  baseUrl: string;
  bearerToken?: string;
  /** Per-request timeout; callers may override per call. Default 30s. */
  timeoutMs?: number;
  log?: Logger;
  /** Injection seam for tests; defaults to global fetch. */
  fetchImpl?: typeof fetch;
}

export class DaemonClient {
  private readonly baseUrl: string;
  private readonly bearerToken?: string;
  private readonly defaultTimeoutMs: number;
  private readonly log?: Logger;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: DaemonClientOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/+$/, '');
    this.bearerToken = opts.bearerToken;
    this.defaultTimeoutMs = opts.timeoutMs ?? 30_000;
    this.log = opts.log;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async post<T>(
    path: string,
    body: unknown,
    opts?: { timeoutMs?: number },
  ): Promise<T> {
    return this.request<T>('POST', path, body, opts);
  }

  async delete<T>(
    path: string,
    body?: unknown,
    opts?: { timeoutMs?: number },
  ): Promise<T> {
    return this.request<T>('DELETE', path, body, opts);
  }

  get endpoint(): string {
    return this.baseUrl;
  }

  private async request<T>(
    method: 'POST' | 'DELETE',
    path: string,
    body: unknown,
    opts?: { timeoutMs?: number },
  ): Promise<T> {
    const url = `${this.baseUrl}${path.startsWith('/') ? '' : '/'}${path}`;
    const controller = new AbortController();
    const timeoutMs = opts?.timeoutMs ?? this.defaultTimeoutMs;
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const headers: Record<string, string> = {};
    if (body !== undefined) headers['content-type'] = 'application/json';
    if (this.bearerToken) {
      headers.authorization = `Bearer ${this.bearerToken}`;
    }
    try {
      const res = await this.fetchImpl(url, {
        method,
        signal: controller.signal,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await res.text();
      let parsed: unknown;
      if (text.length === 0) {
        parsed = undefined;
      } else {
        try {
          parsed = JSON.parse(text);
        } catch {
          parsed = text;
        }
      }
      if (!res.ok) {
        const summary =
          typeof parsed === 'object' &&
          parsed !== null &&
          'error' in (parsed as Record<string, unknown>)
            ? String((parsed as Record<string, unknown>).error)
            : `HTTP ${res.status}`;
        throw new DaemonClientError(
          res.status,
          parsed,
          `${method} ${path} failed: ${summary}`,
        );
      }
      return parsed as T;
    } finally {
      clearTimeout(timer);
    }
  }
}

// Build a DaemonClient aimed at the local daemon. Always targets 127.0.0.1
// — the daemon may bind 0.0.0.0 for LAN peers, but MCP is co-located so the
// loopback route is both faster and safe (no CIDR rules required).
export function createDaemonClientFromSettings(
  settings: Pick<FileSettings, 'httpPort' | 'httpBearerToken'>,
  log?: Logger,
): DaemonClient {
  const port = settings.httpPort ?? 3457;
  return new DaemonClient({
    baseUrl: `http://127.0.0.1:${port}`,
    bearerToken: settings.httpBearerToken,
    log,
  });
}

// Decide whether MCP should swallow an HTTP-routing failure and fall back to
// direct DB writes. Centralizes the heuristic so every write tool gets the
// same rolling-deploy safety guarantees.
//
// Fall back when:
//   - Non-DaemonClientError (network error, AbortError) — transport broken
//   - DaemonClientError 404 / 405 / 501 AND no JSON-object body — Hono's
//     default not-found / method-not-allowed, or the endpoint isn't deployed
//     on an older daemon. Hono returns plain text for these; application
//     handlers always JSON-encode.
//   - DaemonClientError 5xx — server error, retry locally
//
// Bubble up (real rejection) when:
//   - 400 / 409 / 413 / 422 — validation / conflict; silent retry to local
//     would mask invalid input
//   - 404 / 405 / 501 WITH a JSON-object body — application-level rejection
//     (e.g., "Session not found", "migration id does not exist"). We accept
//     any JSON object shape, not just {error: ...}, to be resilient to
//     endpoints that return {message: ...} or richer envelopes.
//   - strict === true — always bubble up, no fallback allowed
export function shouldFallbackToDirect(err: unknown, strict: boolean): boolean {
  if (strict) return false;
  if (!(err instanceof DaemonClientError)) return true; // transport error
  const hasJsonObjectBody = typeof err.body === 'object' && err.body !== null;
  if (err.status === 404 || err.status === 405 || err.status === 501) {
    return !hasJsonObjectBody; // transport-level missing-endpoint only
  }
  if (err.status >= 500) return true;
  return false; // 4xx with envelope (or without) — real rejection
}
