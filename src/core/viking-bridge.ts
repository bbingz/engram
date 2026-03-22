// src/core/viking-bridge.ts
// HTTP client for OpenViking API — all paths match the real server routes.

import http from 'node:http';
import type { Logger } from './logger.js';
import type { MetricsCollector } from './metrics.js';
import type { Tracer } from './tracer.js';

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

/** Build a viking URI from session components */
export function toVikingUri(source: string, project: string | undefined, id: string): string {
  return `viking://session/${source}/${project ?? 'unknown'}/${id}`;
}

/** Extract session ID from viking URI: viking://sessions/{source}/{project}/{session_id} */
export function sessionIdFromVikingUri(uri: string): string {
  const match = uri.match(/viking:\/\/session\/[^/]+\/[^/]+\/(.+)$/);
  return match?.[1] ?? '';
}

const CIRCUIT_BREAKER_TTL = 5 * 60 * 1000; // 5 minutes

export class VikingBridge {
  private baseUrl: string;
  private headers: Record<string, string>;
  private circuitOpen = false;
  private lastHealthCheck = 0;
  private log?: Logger;
  private metrics?: MetricsCollector;
  private tracer?: Tracer;

  private api: string; // baseUrl + /api/v1

  constructor(url: string, apiKey: string, opts?: { log?: Logger; metrics?: MetricsCollector; tracer?: Tracer }) {
    this.baseUrl = url.replace(/\/$/, '');
    this.api = `${this.baseUrl}/api/v1`;
    this.headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    };
    this.log = opts?.log;
    this.metrics = opts?.metrics;
    this.tracer = opts?.tracer;
  }

  /** Base URL for direct API access (used by health dashboard) */
  get url(): string { return this.baseUrl; }
  get apiHeaders(): Record<string, string> { return this.headers; }

  async isAvailable(): Promise<boolean> {
    try {
      const res = await vikingFetch(`${this.api}/debug/health`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(3000),
      });
      return res.ok;
    } catch {
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

  /** Generic POST helper with retry on 429/5xx. Retries up to 3 times with linear backoff. */
  private async post(url: string, body: Record<string, unknown>, timeout = 10000): Promise<unknown> {
    const MAX_RETRIES = 3;
    const path = url.replace(this.api, '');
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const res = await vikingFetch(url, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeout),
      });
      if (res.ok) return res.json();
      if (res.status === 429 || res.status >= 500) {
        if (attempt < MAX_RETRIES - 1) {
          await new Promise(r => setTimeout(r, 1000 * (attempt + 1)));
        }
        continue;
      }
      throw new Error(`Viking ${path} failed (${res.status}): ${await res.text()}`);
    }
    throw new Error(`Viking ${path} failed after ${MAX_RETRIES} retries`);
  }

  /** Push a session via Sessions API (create → add messages serially → commit).
   *  Messages sent serially to preserve conversation order (Viking stores by arrival order).
   *  Built-in MD5 dedup: re-pushing same messages is a no-op. */
  async pushSession(sessionId: string, messages: { role: string; content: string }[]): Promise<void> {
    const pushStart = Date.now();
    const span = this.tracer?.startSpan('viking.pushSession', 'viking', {
      attributes: { sessionId, messageCount: messages.length },
    });
    try {
      await this.post(`${this.api}/sessions/custom`, { session_id: sessionId });

      for (const msg of messages) {
        await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
          role: msg.role,
          content: msg.content,
        }, 5000);
      }

      await this.post(`${this.api}/sessions/${sessionId}/commit/async`, {});
      span?.end();
      this.metrics?.histogram('viking.push_duration_ms', Date.now() - pushStart);
      this.metrics?.counter('viking.pushes', 1);
    } catch (err) {
      span?.setError(err);
      this.log?.error('viking pushSession failed', { sessionId }, err);
      throw err;
    }
  }

  /** Delete all old resources data (cleanup after migration) */
  async deleteResources(): Promise<void> {
    const res = await vikingFetch(
      `${this.api}/fs?uri=${encodeURIComponent('viking://resources/')}&recursive=true`,
      { method: 'DELETE', headers: this.headers, signal: AbortSignal.timeout(60000) } as RequestInit,
    );
    if (!res.ok) {
      throw new Error(`Viking deleteResources failed (${res.status}): ${await res.text()}`);
    }
  }

  // Push content to OpenViking via resources path (triggers embedding pipeline)
  // Flow: temp_upload .md file → import as resource (async, triggers L0/L1 + embedding)
  async addResource(uri: string, content: string, metadata?: Record<string, string>): Promise<void> {
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
    } catch (err) {
      span?.setError(err);
      this.log?.error('viking addResource failed', { uri }, err);
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
        return [];
      }
      const data = await res.json();
      // OpenViking returns {status, result: { memories: [...], resources: [...] }}
      const r = data?.result ?? {};
      const items = [
        ...(Array.isArray(r) ? r : []),
        ...(Array.isArray(r.resources) ? r.resources : []),
        ...(Array.isArray(r.memories) ? r.memories : []),
      ];
      const results = items.map(i => ({ uri: i.uri ?? '', score: i.score ?? 0, snippet: i.abstract ?? '', metadata: i.metadata }));
      span?.setAttribute('resultCount', results.length);
      span?.end();
      this.metrics?.histogram('viking.find_duration_ms', Date.now() - findStart);
      this.metrics?.counter('viking.queries', 1);
      return results;
    } catch (err) {
      span?.setError(err);
      this.log?.error('viking find failed', { query: query.slice(0, 100) }, err);
      return [];
    }
  }

  // POST /grep — pattern search
  async grep(pattern: string, targetUri?: string): Promise<VikingSearchResult[]> {
    try {
      const body: Record<string, unknown> = { pattern, uri: targetUri ?? 'viking://' };
      const res = await vikingFetch(`${this.api}/search/grep`, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return [];
      const data = await res.json();
      const results = data?.result ?? data?.results ?? [];
      return Array.isArray(results) ? results : [];
    } catch {
      return [];
    }
  }

  // GET /abstract?uri= — L0 (~100 tokens)
  async abstract(uri: string): Promise<string> {
    return this.getContent(`${this.api}/content/abstract?uri=${encodeURIComponent(uri)}`);
  }

  // GET /overview?uri= — L1 (~2K tokens)
  async overview(uri: string): Promise<string> {
    return this.getContent(`${this.api}/content/overview?uri=${encodeURIComponent(uri)}`);
  }

  // GET /read?uri= — L2 (full content)
  async read(uri: string): Promise<string> {
    return this.getContent(`${this.api}/content/read?uri=${encodeURIComponent(uri)}`);
  }

  private async getContent(url: string): Promise<string> {
    try {
      const res = await vikingFetch(url, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return '';
      const data = await res.json();
      // OpenViking returns {status, result: "content"} or {content: "..."}
      const content = data?.result ?? data?.content ?? '';
      return typeof content === 'string' ? content : '';
    } catch {
      return '';
    }
  }

  // GET /ls?uri= — list entries
  async ls(uri: string): Promise<VikingEntry[]> {
    try {
      const res = await vikingFetch(`${this.api}/fs/ls?uri=${encodeURIComponent(uri)}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return [];
      const data = await res.json();
      const entries = data?.result ?? data?.entries ?? [];
      return Array.isArray(entries) ? entries : [];
    } catch {
      return [];
    }
  }

  // Memory operations — these use the same find/grep but with memory-specific URIs
  async extractMemory(sessionContent: string): Promise<void> {
    // Push content as a resource, OpenViking auto-extracts memories
    await this.addResource('viking://memory/extract', sessionContent);
  }

  async findMemories(query: string): Promise<VikingMemory[]> {
    try {
      const results = await this.find(query, 'viking://memory/');
      return results.map(r => ({
        content: r.snippet,
        source: r.uri,
        confidence: r.score,
        createdAt: r.metadata?.createdAt ?? '',
      }));
    } catch {
      return [];
    }
  }
}
