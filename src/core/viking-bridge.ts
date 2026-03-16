// src/core/viking-bridge.ts

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
  return `viking://sessions/${source}/${project ?? 'unknown'}/${id}`;
}

/** Extract session ID from viking URI: viking://sessions/{source}/{project}/{session_id} */
export function sessionIdFromVikingUri(uri: string): string {
  const match = uri.match(/viking:\/\/sessions\/[^/]+\/[^/]+\/(.+)$/);
  return match?.[1] ?? '';
}

const CIRCUIT_BREAKER_TTL = 5 * 60 * 1000; // 5 minutes

export class VikingBridge {
  private baseUrl: string;
  private headers: Record<string, string>;
  private circuitOpen = false;
  private lastHealthCheck = 0;

  constructor(url: string, apiKey: string) {
    this.baseUrl = url.replace(/\/$/, '');
    this.headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    };
  }

  async isAvailable(): Promise<boolean> {
    try {
      const res = await fetch(`${this.baseUrl}/api/health`, {
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

  async addResource(uri: string, content: string, metadata?: Record<string, string>): Promise<void> {
    const res = await fetch(`${this.baseUrl}/api/resources`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({ uri, content, metadata }),
      signal: AbortSignal.timeout(30000),
    });
    if (!res.ok) {
      throw new Error(`Viking addResource failed (${res.status}): ${await res.text()}`);
    }
  }

  private async searchEndpoint(endpoint: string, query: string, targetUri?: string): Promise<VikingSearchResult[]> {
    try {
      const params = new URLSearchParams({ q: query });
      if (targetUri) params.set('target', targetUri);
      const res = await fetch(`${this.baseUrl}${endpoint}?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return [];
      const data = await res.json();
      return Array.isArray(data?.results) ? data.results : [];
    } catch {
      return [];
    }
  }

  async find(query: string, targetUri?: string): Promise<VikingSearchResult[]> {
    return this.searchEndpoint('/api/find', query, targetUri);
  }

  async grep(pattern: string, targetUri?: string): Promise<VikingSearchResult[]> {
    return this.searchEndpoint('/api/grep', pattern, targetUri);
  }

  private async readLevel(uri: string, level: 'abstract' | 'overview' | 'read'): Promise<string> {
    try {
      const params = new URLSearchParams({ uri, level });
      const res = await fetch(`${this.baseUrl}/api/read?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return '';
      const data = await res.json();
      return typeof data?.content === 'string' ? data.content : '';
    } catch {
      return '';
    }
  }

  async abstract(uri: string): Promise<string> { return this.readLevel(uri, 'abstract'); }
  async overview(uri: string): Promise<string> { return this.readLevel(uri, 'overview'); }
  async read(uri: string): Promise<string> { return this.readLevel(uri, 'read'); }

  async ls(uri: string): Promise<VikingEntry[]> {
    try {
      const params = new URLSearchParams({ uri });
      const res = await fetch(`${this.baseUrl}/api/ls?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return [];
      const data = await res.json();
      return Array.isArray(data?.entries) ? data.entries : [];
    } catch {
      return [];
    }
  }

  async extractMemory(sessionContent: string): Promise<void> {
    const res = await fetch(`${this.baseUrl}/api/memory/extract`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({ content: sessionContent }),
      signal: AbortSignal.timeout(30000),
    });
    if (!res.ok) {
      throw new Error(`Viking extractMemory failed (${res.status})`);
    }
  }

  async findMemories(query: string): Promise<VikingMemory[]> {
    try {
      const params = new URLSearchParams({ q: query });
      const res = await fetch(`${this.baseUrl}/api/memory/search?${params}`, {
        method: 'GET',
        headers: this.headers,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return [];
      const data = await res.json();
      return Array.isArray(data?.memories) ? data.memories : [];
    } catch {
      return [];
    }
  }
}
