// src/core/viking-bridge.ts
// HTTP client for OpenViking API — all paths match the real server routes.

import http from 'node:http';
import type { Logger } from './logger.js';
import type { MetricsCollector } from './metrics.js';
import type { Tracer } from './tracer.js';
import type { AiAuditWriter } from './ai-audit.js';

/** Proxy-aware fetch: routes through http_proxy when set (Node's native fetch ignores it). */
function vikingFetch(url: string | URL, init?: RequestInit): Promise<Response> {
  const proxy = process.env.http_proxy || process.env.HTTP_PROXY;
  if (!proxy) return fetch(url, init);

  const target = new URL(String(url));
  // Skip proxy for localhost
  if (target.hostname === 'localhost' || target.hostname === '127.0.0.1') return fetch(url, init);

  const proxyUrl = new URL(proxy);
  const signal = init?.signal as AbortSignal | undefined;

  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: proxyUrl.hostname,
      port: Number(proxyUrl.port),
      path: String(url),
      method: init?.method ?? 'GET',
      headers: {
        ...(init?.headers as Record<string, string>),
        Host: target.host,
      },
    }, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c: Buffer) => chunks.push(c));
      res.on('end', () => {
        const body = Buffer.concat(chunks);
        resolve(new Response(body, {
          status: res.statusCode ?? 500,
          statusText: res.statusMessage ?? '',
          headers: res.headers as Record<string, string>,
        }));
      });
    });

    req.on('error', reject);
    signal?.addEventListener('abort', () => { req.destroy(); reject(new DOMException('Aborted', 'AbortError')); });

    if (init?.body) req.write(init.body);
    req.end();
  });
}

export interface VikingSearchResult {
  uri: string;
  score: number;
  snippet: string;
  metadata?: Record<string, string>;
}

export interface VikingEntry {
  uri: string;
  title?: string;
  type: string;
}

export interface VikingMemory {
  content: string;
  source: string;
  confidence: number;
  createdAt: string;
}

const UNKNOWN_PROJECT = 'unknown';

/** Build composite session ID for Sessions API: source::project::id */
export function toVikingSessionId(source: string, project: string | undefined, id: string): string {
  return `${source}::${project ?? UNKNOWN_PROJECT}::${id}`;
}

/** @deprecated No longer used after Sessions API migration. Kept for backward compatibility with older test data. */
export function toVikingUri(source: string, project: string | undefined, id: string): string {
  return `viking://session/${source}/${project ?? UNKNOWN_PROJECT}/${id}`;
}

/** Extract session ID (UUID) from viking URI.
 *  Old format: viking://session/{source}/{project}/{id}
 *  New format: viking://session/default/{source}::{project}::{id}/... */
export function sessionIdFromVikingUri(uri: string): string {
  // New Sessions API format: composite ID with :: separator
  const compositeMatch = uri.match(/viking:\/\/session\/[^/]+\/([^/]+::[^/]+::([^/]+))/);
  if (compositeMatch) return compositeMatch[2];
  // Old Resources API format: path segments
  const legacyMatch = uri.match(/viking:\/\/session\/[^/]+\/[^/]+\/([^/]+)/);
  return legacyMatch?.[1] ?? '';
}

const CIRCUIT_BREAKER_TTL = 5 * 60 * 1000; // 5 minutes
const MIN_REQUEST_INTERVAL_MS = 100; // throttle: min ms between API requests
const MAX_CONCURRENT_PUSHES = 2; // max concurrent pushSession operations
const DEFAULT_MAX_REQUESTS_PER_HOUR = 1000;

export class VikingBridge {
  private baseUrl: string;
  private headers: Record<string, string>;
  private circuitOpen = false;
  private lastHealthCheck = 0;
  private log?: Logger;
  private metrics?: MetricsCollector;
  private tracer?: Tracer;
  private audit?: AiAuditWriter;

  private api: string; // baseUrl + /api/v1

  // Rate limiting: throttle all API requests
  private lastRequestAt = 0;

  // Hourly budget: hard cap on API requests per hour
  private readonly maxRequestsPerHour: number;
  private hourlyRequestCount = 0;
  private hourlyWindowStart = Date.now();

  // Push concurrency limiter: prevent flooding from concurrent pushSession calls
  private activePushes = 0;
  private pushWaiters: (() => void)[] = [];

  constructor(url: string, apiKey: string, opts?: { agentId?: string; maxRequestsPerHour?: number; audit?: AiAuditWriter; log?: Logger; metrics?: MetricsCollector; tracer?: Tracer }) {
    this.baseUrl = url.replace(/\/$/, '');
    this.api = `${this.baseUrl}/api/v1`;
    this.headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    };
    if (opts?.agentId) this.headers['X-Agent-Id'] = opts.agentId;
    this.maxRequestsPerHour = opts?.maxRequestsPerHour ?? DEFAULT_MAX_REQUESTS_PER_HOUR;
    this.audit = opts?.audit;
    this.log = opts?.log;
    this.metrics = opts?.metrics;
    this.tracer = opts?.tracer;
  }

  /** Check hourly budget and enforce minimum interval between requests.
   *  Throws if hourly budget is exhausted. */
  private async throttle(): Promise<void> {
    const now = Date.now();
    // Reset hourly window
    if (now - this.hourlyWindowStart >= 3_600_000) {
      this.hourlyRequestCount = 0;
      this.hourlyWindowStart = now;
    }
    if (this.hourlyRequestCount >= this.maxRequestsPerHour) {
      const remainingMs = 3_600_000 - (now - this.hourlyWindowStart);
      this.log?.warn('viking hourly budget exhausted', { count: this.hourlyRequestCount, max: this.maxRequestsPerHour, resumeInMs: remainingMs });
      this.metrics?.counter('viking.budget_exhausted', 1);
      throw new Error(`Viking hourly request budget exhausted (${this.maxRequestsPerHour}/hr). Resets in ${Math.ceil(remainingMs / 60000)}min`);
    }
    // Throttle interval
    const wait = MIN_REQUEST_INTERVAL_MS - (now - this.lastRequestAt);
    if (wait > 0) await new Promise(r => setTimeout(r, wait));
    this.lastRequestAt = Date.now();
    this.hourlyRequestCount++;
  }

  private async acquirePushSlot(): Promise<void> {
    if (this.activePushes < MAX_CONCURRENT_PUSHES) {
      this.activePushes++;
      return;
    }
    return new Promise<void>(resolve => {
      this.pushWaiters.push(() => { this.activePushes++; resolve(); });
    });
  }

  private releasePushSlot(): void {
    this.activePushes--;
    const next = this.pushWaiters.shift();
    if (next) next();
  }

  /** Base URL for direct API access (used by health dashboard) */
  get url(): string { return this.baseUrl; }
  get apiHeaders(): Record<string, string> { return this.headers; }

  async isAvailable(): Promise<boolean> {
    const start = Date.now();
    try {
      const res = await vikingFetch(`${this.api}/debug/health`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(3000),
      });
      this.audit?.record({
        caller: 'viking', operation: 'isAvailable', provider: 'viking',
        method: 'GET', url: `${this.api}/debug/health`,
        statusCode: res.status, durationMs: Date.now() - start,
      });
      return res.ok;
    } catch (err) {
      this.audit?.record({
        caller: 'viking', operation: 'isAvailable', provider: 'viking',
        method: 'GET', url: `${this.api}/debug/health`,
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
      });
      return false;
    }
  }

  /** Cached health check — caches both positive and negative results for CIRCUIT_BREAKER_TTL */
  async checkAvailable(): Promise<boolean> {
    const now = Date.now();
    if (now - this.lastHealthCheck < CIRCUIT_BREAKER_TTL) return !this.circuitOpen;
    const wasOpen = this.circuitOpen;
    const ok = await this.isAvailable();
    this.circuitOpen = !ok;
    this.lastHealthCheck = now;
    if (this.circuitOpen && !wasOpen) {
      this.log?.warn('viking circuit breaker opened');
      this.metrics?.counter('viking.circuit_breaker_opens', 1);
    } else if (!this.circuitOpen && wasOpen) {
      this.log?.info('viking circuit breaker closed (recovered)');
    }
    return ok;
  }

  /** Generic POST helper with retry on 5xx. Exponential backoff on 429 with Retry-After. */
  private async post(url: string, body: Record<string, unknown>, timeout = 10000): Promise<unknown> {
    const MAX_RETRIES = 3;
    const path = url.replace(this.api, '');
    await this.throttle();
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const res = await vikingFetch(url, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeout),
      });
      if (res.ok) return res.json();
      if (res.status === 429) {
        // Respect Retry-After header; default to aggressive exponential backoff
        const retryAfter = parseInt(res.headers.get('retry-after') || '', 10);
        const delay = (retryAfter > 0 ? retryAfter * 1000 : 5000) * Math.pow(2, attempt);
        this.log?.warn('viking 429 rate limited', { path, delay, attempt });
        this.metrics?.counter('viking.rate_limited', 1);
        if (attempt < MAX_RETRIES - 1) {
          await new Promise(r => setTimeout(r, delay));
          continue;
        }
        throw new Error(`Viking ${path} rate limited after ${MAX_RETRIES} retries`);
      }
      if (res.status >= 500) {
        if (attempt < MAX_RETRIES - 1) {
          await new Promise(r => setTimeout(r, 2000 * (attempt + 1)));
          continue;
        }
      }
      throw new Error(`Viking ${path} failed (${res.status}): ${await res.text()}`);
    }
    throw new Error(`Viking ${path} failed after ${MAX_RETRIES} retries`);
  }

  /** Push a session via Sessions API (create → add messages serially → commit).
   *  Messages sent serially to preserve conversation order (Viking stores by arrival order).
   *  Built-in MD5 dedup: re-pushing same messages is a no-op.
   *  Concurrency-limited: max MAX_CONCURRENT_PUSHES in parallel. */
  async pushSession(sessionId: string, messages: { role: string; content: string }[]): Promise<void> {
    await this.acquirePushSlot();
    const pushStart = Date.now();
    const span = this.tracer?.startSpan('viking.pushSession', 'viking', {
      attributes: { sessionId, messageCount: messages.length },
    });
    try {
      await this.post(`${this.api}/sessions/custom`, { session_id: sessionId });

      for (const msg of messages) {
        await this.post(`${this.api}/sessions/${sessionId}/messages`, {
          role: msg.role,
          parts: [{ type: 'text', text: msg.content }],
        }, 5000);
      }

      await this.post(`${this.api}/sessions/${sessionId}/commit/async`, {});
      span?.end();
      this.metrics?.histogram('viking.push_duration_ms', Date.now() - pushStart);
      this.metrics?.counter('viking.pushes', 1);
      this.metrics?.counter('viking.messages_pushed', messages.length);
      this.audit?.record({
        caller: 'viking', operation: 'pushSession', provider: 'viking',
        durationMs: Date.now() - pushStart,
        sessionId,
        meta: { messageCount: messages.length },
      });
    } catch (err) {
      span?.setError(err);
      this.log?.error('viking pushSession failed', { sessionId }, err);
      this.audit?.record({
        caller: 'viking', operation: 'pushSession', provider: 'viking',
        durationMs: Date.now() - pushStart,
        sessionId,
        error: err instanceof Error ? err.message : String(err),
        meta: { messageCount: messages.length },
      });
      throw err;
    } finally {
      this.releasePushSlot();
    }
  }

  /** Delete all old resources data (cleanup after migration) */
  async deleteResources(): Promise<void> {
    const start = Date.now();
    const url = `${this.api}/fs?uri=${encodeURIComponent('viking://resources/')}&recursive=true`;
    const res = await vikingFetch(
      url,
      { method: 'DELETE', headers: this.headers, signal: AbortSignal.timeout(60000) } as RequestInit,
    );
    if (!res.ok) {
      const errText = await res.text();
      this.audit?.record({
        caller: 'viking', operation: 'deleteResources', provider: 'viking',
        method: 'DELETE', url,
        statusCode: res.status, durationMs: Date.now() - start,
        error: `${res.status}: ${errText}`,
      });
      throw new Error(`Viking deleteResources failed (${res.status}): ${errText}`);
    }
    this.audit?.record({
      caller: 'viking', operation: 'deleteResources', provider: 'viking',
      method: 'DELETE', url,
      statusCode: res.status, durationMs: Date.now() - start,
    });
  }

  // Push content to OpenViking via resources path (triggers embedding pipeline)
  // Flow: temp_upload .md file → import as resource (async, triggers L0/L1 + embedding)
  async addResource(uri: string, content: string, metadata?: Record<string, string>): Promise<void> {
    const start = Date.now();
    const span = this.tracer?.startSpan('viking.addResource', 'viking', { attributes: { uri } });
    try {
      // Step 1: upload content as a temp .md file
      const boundary = `----engram${Date.now()}`;
      const slug = uri.replace(/[^a-zA-Z0-9-]/g, '_');
      const header = metadata
        ? Object.entries(metadata).map(([k, v]) => `${k}: ${v}`).join(' | ') + '\n\n'
        : '';
      const body = [
        `--${boundary}`,
        `Content-Disposition: form-data; name="file"; filename="${slug}.txt"`,
        'Content-Type: text/plain',
        '',
        header + content,
        `--${boundary}--`,
      ].join('\r\n');

      const uploadRes = await vikingFetch(`${this.api}/resources/temp_upload`, {
        method: 'POST',
        headers: {
          ...this.headers,
          'Content-Type': `multipart/form-data; boundary=${boundary}`,
        },
        body,
        signal: AbortSignal.timeout(30000),
      });
      if (!uploadRes.ok) {
        throw new Error(`Viking temp_upload failed (${uploadRes.status}): ${await uploadRes.text()}`);
      }
      const uploadData = await uploadRes.json();
      const tempPath = uploadData?.result?.temp_path;
      if (!tempPath) throw new Error('Viking temp_upload returned no temp_path');

      // Step 2: import as resource (async — triggers L0/L1 generation + embedding)
      const importRes = await vikingFetch(`${this.api}/resources`, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify({ temp_path: tempPath, wait: false, preserve_structure: true }),
        signal: AbortSignal.timeout(10000),
      });
      if (!importRes.ok) {
        throw new Error(`Viking addResource failed (${importRes.status}): ${await importRes.text()}`);
      }
      span?.end();
      this.audit?.record({
        caller: 'viking', operation: 'addResource', provider: 'viking',
        method: 'POST', url: `${this.api}/resources`,
        statusCode: importRes.status, durationMs: Date.now() - start,
      });
    } catch (err) {
      span?.setError(err);
      this.log?.error('viking addResource failed', { uri }, err);
      this.audit?.record({
        caller: 'viking', operation: 'addResource', provider: 'viking',
        method: 'POST', url: `${this.api}/resources`,
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
      });
      throw err;
    }
  }

  // POST /find — semantic search
  async find(query: string, targetUri?: string): Promise<VikingSearchResult[]> {
    const findStart = Date.now();
    const span = this.tracer?.startSpan('viking.find', 'viking', { attributes: { query: query.slice(0, 100) } });
    try {
      const body: Record<string, unknown> = { query, limit: 20 };
      if (targetUri) body.target_uri = targetUri;
      const res = await vikingFetch(`${this.api}/search/find`, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) {
        span?.setAttribute('status', res.status);
        span?.end();
        this.audit?.record({
          caller: 'viking', operation: 'find', provider: 'viking',
          method: 'POST', url: `${this.api}/search/find`,
          statusCode: res.status, durationMs: Date.now() - findStart,
          requestBody: body, error: `${res.status}`,
        });
        return [];
      }
      const data = await res.json();
      // OpenViking returns {status, result: { memories: [...], resources: [...] }}
      const r = data?.result ?? {};
      const items = [
        ...(Array.isArray(r) ? r : []),
        ...(Array.isArray(r.resources) ? r.resources : []),
        ...(Array.isArray(r.memories) ? r.memories : []),
        ...(Array.isArray(r.skills) ? r.skills : []),
      ];
      const results = items.map(i => ({ uri: i.uri ?? '', score: i.score ?? 0, snippet: i.abstract ?? '', metadata: i.metadata }));
      span?.setAttribute('resultCount', results.length);
      span?.end();
      this.metrics?.histogram('viking.find_duration_ms', Date.now() - findStart);
      this.metrics?.counter('viking.queries', 1);
      this.audit?.record({
        caller: 'viking', operation: 'find', provider: 'viking',
        method: 'POST', url: `${this.api}/search/find`,
        statusCode: res.status, durationMs: Date.now() - findStart,
        requestBody: body, responseBody: data,
      });
      return results;
    } catch (err) {
      span?.setError(err);
      this.log?.error('viking find failed', { query: query.slice(0, 100) }, err);
      this.audit?.record({
        caller: 'viking', operation: 'find', provider: 'viking',
        method: 'POST', url: `${this.api}/search/find`,
        durationMs: Date.now() - findStart,
        error: err instanceof Error ? err.message : String(err),
      });
      return [];
    }
  }

  // POST /grep — pattern search
  async grep(pattern: string, targetUri?: string): Promise<VikingSearchResult[]> {
    const start = Date.now();
    try {
      const body: Record<string, unknown> = { pattern, uri: targetUri ?? 'viking://' };
      const res = await vikingFetch(`${this.api}/search/grep`, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) {
        this.audit?.record({
          caller: 'viking', operation: 'grep', provider: 'viking',
          method: 'POST', url: `${this.api}/search/grep`,
          statusCode: res.status, durationMs: Date.now() - start,
          requestBody: body, error: `${res.status}`,
        });
        return [];
      }
      const data = await res.json();
      const results = data?.result ?? data?.results ?? [];
      this.audit?.record({
        caller: 'viking', operation: 'grep', provider: 'viking',
        method: 'POST', url: `${this.api}/search/grep`,
        statusCode: res.status, durationMs: Date.now() - start,
        requestBody: body, responseBody: data,
      });
      return Array.isArray(results) ? results : [];
    } catch (err) {
      this.audit?.record({
        caller: 'viking', operation: 'grep', provider: 'viking',
        method: 'POST', url: `${this.api}/search/grep`,
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
      });
      return [];
    }
  }

  // GET /abstract?uri= — L0 (~100 tokens)
  async abstract(uri: string): Promise<string> {
    return this.getContent(`${this.api}/content/abstract?uri=${encodeURIComponent(uri)}`, 'abstract');
  }

  // GET /overview?uri= — L1 (~2K tokens)
  async overview(uri: string): Promise<string> {
    return this.getContent(`${this.api}/content/overview?uri=${encodeURIComponent(uri)}`, 'overview');
  }

  // GET /read?uri= — L2 (full content)
  async read(uri: string): Promise<string> {
    return this.getContent(`${this.api}/content/read?uri=${encodeURIComponent(uri)}`, 'read');
  }

  private async getContent(url: string, operation: string): Promise<string> {
    const start = Date.now();
    try {
      const res = await vikingFetch(url, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) {
        this.audit?.record({
          caller: 'viking', operation, provider: 'viking',
          method: 'GET', url,
          statusCode: res.status, durationMs: Date.now() - start,
          error: `${res.status}`,
        });
        return '';
      }
      const data = await res.json();
      // OpenViking returns {status, result: "content"} or {content: "..."}
      const content = data?.result ?? data?.content ?? '';
      this.audit?.record({
        caller: 'viking', operation, provider: 'viking',
        method: 'GET', url,
        statusCode: res.status, durationMs: Date.now() - start,
        responseBody: data,
      });
      return typeof content === 'string' ? content : '';
    } catch (err) {
      this.audit?.record({
        caller: 'viking', operation, provider: 'viking',
        method: 'GET', url,
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
      });
      return '';
    }
  }

  // GET /ls?uri= — list entries
  async ls(uri: string): Promise<VikingEntry[]> {
    const start = Date.now();
    const url = `${this.api}/fs/ls?uri=${encodeURIComponent(uri)}`;
    try {
      const res = await vikingFetch(url, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) {
        this.audit?.record({
          caller: 'viking', operation: 'ls', provider: 'viking',
          method: 'GET', url,
          statusCode: res.status, durationMs: Date.now() - start,
          error: `${res.status}`,
        });
        return [];
      }
      const data = await res.json();
      const entries = data?.result ?? data?.entries ?? [];
      this.audit?.record({
        caller: 'viking', operation: 'ls', provider: 'viking',
        method: 'GET', url,
        statusCode: res.status, durationMs: Date.now() - start,
        responseBody: data,
      });
      return Array.isArray(entries) ? entries : [];
    } catch (err) {
      this.audit?.record({
        caller: 'viking', operation: 'ls', provider: 'viking',
        method: 'GET', url,
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
      });
      return [];
    }
  }

  // Memory operations — these use the same find/grep but with memory-specific URIs
  /** @deprecated Sessions API handles memory extraction server-side. Available for manual memory injection. */
  async extractMemory(sessionContent: string): Promise<void> {
    // Push content as a resource, OpenViking auto-extracts memories
    await this.addResource('viking://memory/extract', sessionContent);
  }

  async findMemories(query: string): Promise<VikingMemory[]> {
    const start = Date.now();
    try {
      const [userResults, agentResults] = await Promise.all([
        this.find(query, 'viking://user/'),
        this.find(query, 'viking://agent/'),
      ]);
      const results = [...userResults, ...agentResults]
        .sort((a, b) => b.score - a.score)
        .map(r => ({
          content: r.snippet,
          source: r.uri,
          confidence: r.score,
          createdAt: r.metadata?.createdAt ?? '',
        }));
      this.audit?.record({
        caller: 'viking', operation: 'findMemories', provider: 'viking',
        durationMs: Date.now() - start,
        meta: { resultCount: results.length },
      });
      return results;
    } catch (err) {
      this.audit?.record({
        caller: 'viking', operation: 'findMemories', provider: 'viking',
        durationMs: Date.now() - start,
        error: err instanceof Error ? err.message : String(err),
      });
      return [];
    }
  }

  // ── Observer proxy methods ─────────────────────────────────────────
  private async getObserver(path: string): Promise<Record<string, unknown> | null> {
    try {
      const res = await vikingFetch(`${this.api}/observer/${path}`, {
        method: 'GET', headers: this.headers, signal: AbortSignal.timeout(5000),
      });
      if (!res.ok) return null;
      const data = await res.json();
      return (data?.result ?? data) as Record<string, unknown>;
    } catch { return null; }
  }

  async observerSystem(): Promise<Record<string, unknown> | null> { return this.getObserver('system'); }
  async observerQueue(): Promise<Record<string, unknown> | null> { return this.getObserver('queue'); }
  async observerVlm(): Promise<Record<string, unknown> | null> { return this.getObserver('vlm'); }
  async observerVikingdb(): Promise<Record<string, unknown> | null> { return this.getObserver('vikingdb'); }
  async observerTransaction(): Promise<Record<string, unknown> | null> { return this.getObserver('transaction'); }
}
