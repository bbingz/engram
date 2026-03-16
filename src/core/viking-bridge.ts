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

  // Push a session to OpenViking: create session → add messages → commit
  async addResource(uri: string, content: string, metadata?: Record<string, string>): Promise<void> {
    // Step 1: create session
    const createRes = await fetch(`${this.api}/sessions`, {
      method: 'POST',
      headers: this.headers,
      signal: AbortSignal.timeout(10000),
    });
    if (!createRes.ok) {
      throw new Error(`Viking create session failed (${createRes.status}): ${await createRes.text()}`);
    }
    const createData = await createRes.json();
    const sessionId = createData?.result?.session_id;
    if (!sessionId) throw new Error('Viking create session returned no session_id');

    // Step 2: add content as a single assistant message (carries full session text)
    const msgRes = await fetch(`${this.api}/sessions/${sessionId}/messages`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({ role: 'assistant', content }),
      signal: AbortSignal.timeout(30000),
    });
    if (!msgRes.ok) {
      throw new Error(`Viking add message failed (${msgRes.status}): ${await msgRes.text()}`);
    }

    // Step 3: commit (generates L0/L1/L2 + extracts memories, async)
    fetch(`${this.api}/sessions/${sessionId}/commit?wait=false`, {
      method: 'POST',
      headers: this.headers,
      signal: AbortSignal.timeout(10000),
    }).catch(() => {}); // fire-and-forget
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
      // Normalize response — OpenViking returns {status, result: [...]}
      const results = data?.result ?? data?.results ?? [];
      return Array.isArray(results) ? results : [];
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
