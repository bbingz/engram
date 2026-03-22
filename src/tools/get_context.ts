import { basename } from 'path'
import type { Database } from '../core/db.js'
import type { Logger } from '../core/logger.js'
import type { VectorStore } from '../core/vector-store.js'
import type { LiveSession } from '../core/live-sessions.js'
import type { MonitorAlert } from '../core/monitor.js'
import { sessionIdFromVikingUri, toVikingUri, type VikingBridge } from '../core/viking-bridge.js'
import { toLocalDate } from '../utils/time.js'

export const getContextTool = {
  name: 'get_context',
  description: '为当前工作目录自动提取相关的历史会话上下文。在开始新任务时调用，获取该项目的历史记录。',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: '当前工作目录（绝对路径）' },
      task: { type: 'string', description: '当前任务描述（可选，用于语义搜索）' },
      max_tokens: { type: 'number', description: 'token 预算，默认 4000（约 16000 字符）' },
      detail: { type: 'string', enum: ['abstract', 'overview', 'full'], description: '详情级别 (需要 OpenViking): abstract (~100 tokens), overview (~2K tokens), full' },
      sort_by: { type: 'string', enum: ['recency', 'score'], description: '排序方式: recency (默认按时间倒序) 或 score (按质量分数倒序)' },
      include_environment: { type: 'boolean', description: '包含实时环境数据（活跃会话、今日成本、工具使用、告警），默认 true' },
    },
    additionalProperties: false,
  },
}

const CHARS_PER_TOKEN = 4

export interface GetContextDeps {
  vectorStore?: VectorStore
  embed?: (text: string) => Promise<Float32Array | null>
  viking?: VikingBridge | null
  liveMonitor?: { getSessions(): LiveSession[] }
  backgroundMonitor?: { getAlerts(): MonitorAlert[] }
  log?: Logger
}

export async function handleGetContext(
  db: Database,
  params: { cwd: string; task?: string; max_tokens?: number; detail?: 'abstract' | 'overview' | 'full'; sort_by?: 'recency' | 'score'; include_environment?: boolean },
  deps: GetContextDeps = {}
) {
  deps.log?.info('get_context invoked', { cwd: params.cwd, task: params.task?.slice(0, 100), detail: params.detail })

  const maxTokens = params.max_tokens ?? 4000
  const maxChars = maxTokens * CHARS_PER_TOKEN

  const projectName = basename(params.cwd.replace(/\/$/, ''))
  const projectNames = db.resolveProjectAliases([projectName])
  let sessions = db.listSessions({ projects: projectNames, limit: 50 })
  if (sessions.length === 0 && params.cwd) {
    sessions = db.listSessions({ project: params.cwd, limit: 50 })
  }

  // Sort by quality score if requested
  if (params.sort_by === 'score') {
    sessions.sort((a, b) => (b.qualityScore ?? 0) - (a.qualityScore ?? 0))
  }

  // Semantic boost: if task + vector store available, merge vector results
  if (params.task && deps.vectorStore && deps.embed) {
    try {
      const queryVec = await deps.embed(params.task)
      if (queryVec) {
        const vecResults = deps.vectorStore.search(queryVec, 10)
        const vecSessionIds = new Set(vecResults.map(r => r.sessionId))
        const existingIds = new Set(sessions.map(s => s.id))

        for (const vr of vecResults) {
          if (!existingIds.has(vr.sessionId)) {
            const s = db.getSession(vr.sessionId)
            if (s && projectNames.includes(s.project ?? '')) {
              sessions.push(s)
            }
          }
        }

        sessions.sort((a, b) => {
          const aVec = vecSessionIds.has(a.id) ? 0 : 1
          const bVec = vecSessionIds.has(b.id) ? 0 : 1
          if (aVec !== bVec) return aVec - bVec
          return b.startTime.localeCompare(a.startTime)
        })
      }
    } catch { /* vector search failed, fall through */ }
  }

  // Viking-enhanced: use tiered content when available
  if (deps.viking && params.detail && await deps.viking.checkAvailable()) {
    const readFn = params.detail === 'abstract' ? deps.viking.abstract.bind(deps.viking)
      : params.detail === 'full' ? deps.viking.read.bind(deps.viking)
      : deps.viking.overview.bind(deps.viking)

    let targetSessions = sessions.slice(0, 5)
    if (params.task) {
      try {
        const vikingResults = await deps.viking.find(params.task)
        const vikingSessionIds = vikingResults.map(r => sessionIdFromVikingUri(r.uri))
        const vikingSessions = vikingSessionIds
          .map(id => db.getSession(id))
          .filter((s): s is NonNullable<typeof s> => s !== null)
        if (vikingSessions.length > 0) targetSessions = vikingSessions.slice(0, 5)
      } catch { /* fall through to session list */ }
    }

    // Pre-fetch all in parallel, then apply token budget
    const uris = targetSessions.map(s => toVikingUri(s.source, s.project, s.id))
    const fetched = await Promise.allSettled(uris.map(u => readFn(u)))

    const parts: string[] = []
    let totalChars = 0
    const selectedSessions: typeof sessions = []

    if (params.task) {
      const taskLine = `当前任务：${params.task}\n`
      parts.push(taskLine)
      totalChars += taskLine.length
    }

    for (let i = 0; i < targetSessions.length; i++) {
      const result = fetched[i]
      const content = result.status === 'fulfilled' ? result.value : ''
      if (!content) continue
      const session = targetSessions[i]
      const line = `[${session.source}] ${toLocalDate(session.startTime)} — ${content}\n`
      if (totalChars + line.length > maxChars) break
      parts.push(line)
      totalChars += line.length
      selectedSessions.push(session)
    }

    const footer = `\n— ${selectedSessions.length} sessions (${params.detail}), ~${Math.ceil(totalChars / CHARS_PER_TOKEN)} tokens`
    parts.push(footer)

    const envSection = (params.include_environment !== false) ? await gatherEnvironmentData(db, deps) : ''

    return {
      contextText: parts.join('') + envSection,
      sessionCount: selectedSessions.length,
      sessionIds: selectedSessions.map(s => s.id),
    }
  }

  const contextParts: string[] = []
  let totalChars = 0
  const selectedSessions: typeof sessions = []

  if (params.task) {
    const taskLine = `当前任务：${params.task}\n`
    contextParts.push(taskLine)
    totalChars += taskLine.length
  }

  for (const session of sessions) {
    if (!session.summary) continue
    const line = `[${session.source}] ${toLocalDate(session.startTime)} — ${session.summary}\n`
    if (totalChars + line.length > maxChars) break
    contextParts.push(line)
    totalChars += line.length
    selectedSessions.push(session)
  }

  const footer = `\n— ${selectedSessions.length} sessions, ~${Math.ceil(totalChars / CHARS_PER_TOKEN)} tokens`
  contextParts.push(footer)

  const envSection = (params.include_environment !== false) ? await gatherEnvironmentData(db, deps) : ''

  return {
    contextText: contextParts.join('') + envSection,
    sessionCount: selectedSessions.length,
    sessionIds: selectedSessions.map(s => s.id),
  }
}

async function gatherEnvironmentData(db: Database, deps: GetContextDeps): Promise<string> {
  const sections: string[] = []

  // Live sessions
  try {
    if (deps.liveMonitor) {
      const live = deps.liveMonitor.getSessions()
      if (live.length > 0) {
        const lines = live.map(s => `  ${s.source} ${s.project ?? '?'} [${s.activityLevel}]`)
        sections.push(`Live sessions (${live.length}):\n${lines.join('\n')}`)
      }
    }
  } catch (err: unknown) {
    if (!isNoSuchTableError(err)) console.error('[get_context] liveSessions error:', err)
  }

  // Today's cost
  try {
    const today = new Date().toISOString().slice(0, 10)
    const breakdown = db.getCostsSummary({ since: `${today}T00:00:00Z` })
    const totalCost = breakdown.reduce((sum: number, r: any) => sum + (r.costUsd || 0), 0)
    if (totalCost > 0) {
      sections.push(`Cost today: $${(Math.round(totalCost * 100) / 100).toFixed(2)}`)
    }
  } catch (err: unknown) {
    if (!isNoSuchTableError(err)) console.error('[get_context] costToday error:', err)
  }

  // Recent tool usage (last 7 days, top 10)
  try {
    const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
    const tools = db.getToolAnalytics({ since, groupBy: 'tool' })
    if (tools.length > 0) {
      const top10 = tools.slice(0, 10)
      const lines = top10.map((t: any) => `  ${t.key}: ${t.callCount} calls`)
      sections.push(`Top tools (7d):\n${lines.join('\n')}`)
    }
  } catch (err: unknown) {
    if (!isNoSuchTableError(err)) console.error('[get_context] recentTools error:', err)
  }

  // Active alerts
  try {
    if (deps.backgroundMonitor) {
      const alerts = deps.backgroundMonitor.getAlerts().filter(a => !a.dismissed)
      if (alerts.length > 0) {
        const lines = alerts.map(a => `  [${a.severity}] ${a.title}`)
        sections.push(`Alerts (${alerts.length}):\n${lines.join('\n')}`)
      }
    }
  } catch (err: unknown) {
    if (!isNoSuchTableError(err)) console.error('[get_context] alerts error:', err)
  }

  // Infrastructure health checks (if cwd is available in params scope)
  try {
    const { runHealthChecks } = await import('./lint_config.js')
    const cwd = process.cwd()
    const healthIssues = runHealthChecks(cwd)
    if (healthIssues.length > 0) {
      const lines = healthIssues.map(h => `  [${h.severity}] ${h.message}`)
      sections.push(`Health (${healthIssues.length}):\n${lines.join('\n')}`)
    }
  } catch { /* health checks are best-effort */ }

  if (sections.length === 0) return ''
  return `\n\n## Environment\n${sections.join('\n')}`
}

function isNoSuchTableError(err: unknown): boolean {
  return err instanceof Error && err.message.includes('no such table')
}
