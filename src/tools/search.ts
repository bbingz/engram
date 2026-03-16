// src/tools/search.ts
import { isNoiseSession, type Database, type SearchFilters } from '../core/db.js'
import type { SessionInfo, SourceName } from '../adapters/types.js'
import type { VectorStore } from '../core/vector-store.js'
import { sessionIdFromVikingUri, type VikingBridge } from '../core/viking-bridge.js'

export interface SearchDeps {
  vectorStore?: VectorStore
  embed?: (text: string) => Promise<Float32Array | null>
  viking?: VikingBridge | null
}

export interface SearchResult {
  session: SessionInfo
  snippet: string
  matchType: 'keyword' | 'semantic' | 'both'
  score: number
}

export const searchTool = {
  name: 'search',
  description: 'Full-text and semantic search across all session content. Supports Chinese and English.',
  inputSchema: {
    type: 'object' as const,
    required: ['query'],
    properties: {
      query: { type: 'string', description: 'Search keywords (at least 2 characters for semantic, 3 for keyword)' },
      source: { type: 'string', enum: ['codex', 'claude-code', 'gemini-cli', 'opencode', 'iflow', 'qwen', 'kimi', 'cline', 'cursor', 'vscode', 'antigravity', 'windsurf'] },
      project: { type: 'string' },
      since: { type: 'string' },
      limit: { type: 'number', description: 'Default 10, max 50' },
      mode: { type: 'string', enum: ['hybrid', 'keyword', 'semantic'], description: 'Search mode (default: hybrid)' },
    },
    additionalProperties: false,
  },
}

const RRF_K = 60

function rrfScore(rank: number): number {
  return 1 / (RRF_K + rank)
}

export async function handleSearch(
  db: Database,
  params: { query: string; source?: SourceName; project?: string; since?: string; limit?: number; mode?: string; agents?: 'hide'; tools?: 'hide' },
  deps: SearchDeps = {}
): Promise<{ results: SearchResult[]; query: string; searchModes: string[]; warning?: string }> {
  const limit = Math.min(params.limit ?? 10, 50)
  const mode = params.mode ?? 'hybrid'
  const searchModes: string[] = []

  // --- UUID direct lookup ---
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  if (uuidPattern.test(params.query.trim())) {
    const session = db.getSession(params.query.trim())
    if (session) {
      return { results: [{ session, snippet: '', matchType: 'keyword', score: 1 }], query: params.query, searchModes: ['id'] }
    }
    return { results: [], query: params.query, searchModes: ['id'], warning: 'No session found with this ID' }
  }

  const filters: SearchFilters = {
    source: params.source,
    project: params.project,
    since: params.since,
  }

  // --- FTS keyword search ---
  const ftsScores = new Map<string, { score: number; snippet: string }>()

  if (mode !== 'semantic' && params.query.length >= 3) {
    searchModes.push('keyword')
    const ftsResults = db.searchSessions(params.query, limit * 3, filters)
    const seen = new Set<string>()
    let rank = 1
    for (const match of ftsResults) {
      if (seen.has(match.sessionId)) continue
      seen.add(match.sessionId)
      ftsScores.set(match.sessionId, { score: rrfScore(rank), snippet: match.snippet })
      rank++
    }
  }

  // --- Semantic vector search ---
  const vecScores = new Map<string, { score: number; distance: number }>()

  if (mode !== 'keyword' && params.query.length >= 2 && deps.vectorStore && deps.embed) {
    try {
      const queryVec = await deps.embed(params.query)
      if (queryVec) {
        searchModes.push('semantic')
        const vecResults = deps.vectorStore.search(queryVec, limit * 2)
        let rank = 1
        for (const vr of vecResults) {
          vecScores.set(vr.sessionId, { score: rrfScore(rank), distance: vr.distance })
          rank++
        }
      }
    } catch { /* vector search unavailable */ }
  }

  // --- Viking semantic + keyword search ---
  const VIKING_RRF_BOOST = 0.002
  const vikingScores = new Map<string, { score: number; snippet: string }>()

  if (deps.viking && params.query.length >= 2) {
    try {
      const [findResults, grepResults] = await Promise.all([
        deps.viking.find(params.query),
        params.query.length >= 3 ? deps.viking.grep(params.query) : Promise.resolve([]),
      ])
      const allViking = [...findResults, ...grepResults]
      if (findResults.length > 0) searchModes.push('viking-semantic')
      if (grepResults.length > 0) searchModes.push('viking-keyword')
      const seen = new Set<string>()
      let rank = 1
      for (const vr of allViking) {
        const sessionId = sessionIdFromVikingUri(vr.uri)
        if (!sessionId || seen.has(sessionId)) continue
        seen.add(sessionId)
        vikingScores.set(sessionId, { score: rrfScore(rank) + VIKING_RRF_BOOST, snippet: vr.snippet })
        rank++
      }
    } catch { /* Viking search failed, continue with FTS */ }
  }

  // --- RRF merge ---
  const allSessionIds = new Set([...ftsScores.keys(), ...vecScores.keys(), ...vikingScores.keys()])
  const merged: { sessionId: string; score: number; snippet: string; matchType: 'keyword' | 'semantic' | 'both' }[] = []

  for (const sessionId of allSessionIds) {
    const fts = ftsScores.get(sessionId)
    const vec = vecScores.get(sessionId)
    const viking = vikingScores.get(sessionId)
    const score = (fts?.score ?? 0) + (vec?.score ?? 0) + (viking?.score ?? 0)
    const matchType = fts && vec ? 'both' : fts ? 'keyword' : viking ? 'semantic' : 'semantic'
    merged.push({ sessionId, score, snippet: viking?.snippet ?? fts?.snippet ?? '', matchType })
  }

  merged.sort((a, b) => b.score - a.score)

  // --- Build results with session data ---
  const results: SearchResult[] = []
  for (const m of merged) {
    if (results.length >= limit) break
    const session = db.getSession(m.sessionId)
    if (!session) continue
    if (params.agents === 'hide' && isNoiseSession(session)) continue
    if (params.tools === 'hide' && session.toolMessageCount > 0 && session.userMessageCount === 0) continue
    // Semantic-only results need JS-level filtering (sqlite-vec can't JOIN)
    if (m.matchType === 'semantic') {
      if (filters.source && session.source !== filters.source) continue
      if (filters.project) {
        const expanded = db.resolveProjectAliases([filters.project])
        if (!expanded.some(p => session.project?.includes(p))) continue
      }
      if (filters.since && session.startTime < filters.since) continue
    }
    results.push({
      session,
      snippet: m.snippet || session.summary || '',
      matchType: m.matchType,
      score: m.score,
    })
  }

  const warning = searchModes.length === 0
    ? (params.query.length < 3 ? 'Search query needs at least 3 characters for keyword search (2 for semantic)' : undefined)
    : undefined

  return { results, query: params.query, searchModes, warning }
}
