// src/tools/search.ts
import type { Database } from '../core/db.js'
import type { SourceName } from '../adapters/types.js'

export const searchTool = {
  name: 'search',
  description: '在所有会话内容中全文搜索。支持中英文。',
  inputSchema: {
    type: 'object' as const,
    required: ['query'],
    properties: {
      query: { type: 'string', description: '搜索关键词（至少 3 个字符）' },
      source: { type: 'string', enum: ['codex', 'claude-code', 'gemini-cli', 'opencode', 'iflow', 'qwen', 'kimi', 'cline'] },
      project: { type: 'string' },
      since: { type: 'string' },
      limit: { type: 'number', description: '默认 10，最大 50' },
    },
    additionalProperties: false,
  },
}

export async function handleSearch(
  db: Database,
  params: { query: string; source?: SourceName; project?: string; since?: string; limit?: number }
) {
  const limit = Math.min(params.limit ?? 10, 50)

  // FTS5 trigram 需要至少 3 个字符
  if (params.query.length < 3) {
    return { results: [], query: params.query, warning: '搜索词至少需要 3 个字符' }
  }

  const matches = db.searchSessions(params.query, limit * 3)

  const results: { session: ReturnType<Database['getSession']>; snippet: string }[] = []
  const seen = new Set<string>()

  for (const match of matches) {
    if (seen.has(match.sessionId)) continue
    seen.add(match.sessionId)

    const session = db.getSession(match.sessionId)
    if (!session) continue
    if (params.source && session.source !== params.source) continue
    if (params.project && !session.project?.includes(params.project)) continue
    if (params.since && session.startTime < params.since) continue

    const idx = match.content.indexOf(params.query)
    const start = Math.max(0, idx - 80)
    const end = Math.min(match.content.length, idx + params.query.length + 80)
    const snippet = (start > 0 ? '...' : '') + match.content.slice(start, end) + (end < match.content.length ? '...' : '')

    results.push({ session, snippet })
    if (results.length >= limit) break
  }

  return { results, query: params.query }
}
