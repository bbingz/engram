// src/core/viking-bridge.ts
// HTTP client for OpenViking API — all paths match the real server routes.

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

  private api: string; // baseUrl + /api/v1

  constructor(url: string, apiKey: string) {
    this.baseUrl = url.replace(/\/$/, '');
    this.api = `${this.baseUrl}/api/v1`;
    this.headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    };
  }

  /** Base URL for direct API access (used by health dashboard) */
  get url(): string { return this.baseUrl; }
  get apiHeaders(): Record<string, string> { return this.headers; }

  async isAvailable(): Promise<boolean> {
    try {
      const res = await fetch(`${this.api}/debug/health`, {
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
    const ok = await this.isAvailable();
    this.circuitOpen = !ok;
    this.lastHealthCheck = now;
    return ok;
  }

  // Push content to OpenViking via resources path (triggers embedding pipeline)
  // Flow: temp_upload .md file → import as resource (async, triggers L0/L1 + embedding)
  async addResource(uri: string, content: string, metadata?: Record<string, string>): Promise<void> {
    // Step 1: upload content as a temp .md file
    const boundary = `----engram${Date.now()}`;
    const slug = uri.replace(/[^a-zA-Z0-9-]/g, '_');
    const header = metadata
      ? Object.entries(metadata).map(([k, v]) => `${k}: ${v}`).join(' | ') + '\n\n'
      : '';
    const body = [
      `--${boundary}`,
      `Content-Disposition: form-data; name="file"; filename="${slug}.md"`,
      'Content-Type: text/markdown',
      '',
      header + content,
      `--${boundary}--`,
    ].join('\r\n');

    const uploadRes = await fetch(`${this.api}/resources/temp_upload`, {
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
    const importRes = await fetch(`${this.api}/resources`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({ temp_path: tempPath, wait: false }),
      signal: AbortSignal.timeout(10000),
    });
    if (!importRes.ok) {
      throw new Error(`Viking addResource failed (${importRes.status}): ${await importRes.text()}`);
    }
  }

  // POST /find — semantic search
  async find(query: string, targetUri?: string): Promise<VikingSearchResult[]> {
    try {
      const body: Record<string, unknown> = { query, limit: 20 };
      if (targetUri) body.target_uri = targetUri;
      const res = await fetch(`${this.api}/search/find`, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return [];
      const data = await res.json();
      // OpenViking returns {status, result: { memories: [...], resources: [...] }}
      const r = data?.result ?? {};
      const items = [
        ...(Array.isArray(r) ? r : []),
        ...(Array.isArray(r.resources) ? r.resources : []),
        ...(Array.isArray(r.memories) ? r.memories : []),
      ];
      return items.map(i => ({ uri: i.uri ?? '', score: i.score ?? 0, snippet: i.abstract ?? '', metadata: i.metadata }));
    } catch {
      return [];
    }
  }

  // POST /grep — pattern search
  async grep(pattern: string, targetUri?: string): Promise<VikingSearchResult[]> {
    try {
      const body: Record<string, unknown> = { pattern, uri: targetUri ?? 'viking://' };
      const res = await fetch(`${this.api}/search/grep`, {
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
      const res = await fetch(url, {
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
      const res = await fetch(`${this.api}/fs/ls?uri=${encodeURIComponent(uri)}`, {
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
