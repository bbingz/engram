import { basename } from 'path'
import type { Database } from '../core/db.js'
import type { SessionAdapter } from '../adapters/types.js'

export const handoffTool = {
  name: 'handoff',
  description: 'Generate a handoff brief for a project — summarizes recent sessions to help resume work.',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: 'Project directory (absolute path)' },
      sessionId: { type: 'string', description: 'Specific session to handoff (optional)' },
      format: { type: 'string', enum: ['markdown', 'plain'], description: 'Output format (default: markdown)' },
    },
    additionalProperties: false,
  },
}

export interface HandoffParams {
  cwd: string
  sessionId?: string
  format?: 'markdown' | 'plain'
}

interface SessionWithCost {
  id: string
  source: string
  startTime: string
  endTime?: string
  filePath: string
  summary?: string
  model?: string
  messageCount: number
  project?: string
  costUsd?: number
}

export async function handleHandoff(
  db: Database,
  params: HandoffParams,
  adapters?: SessionAdapter[]
): Promise<{ brief: string; sessionCount: number }> {
  const format = params.format ?? 'markdown'

  // 1. Resolve project name from cwd (same pattern as get_context.ts)
  const projectName = basename(params.cwd.replace(/\/$/, ''))
  const projectNames = db.resolveProjectAliases([projectName])

  // 2. Query recent sessions
  let sessions: SessionWithCost[]
  if (params.sessionId) {
    const s = db.getSession(params.sessionId)
    sessions = s ? [mapSession(s)] : []
  } else {
    const raw = db.listSessions({ projects: projectNames, limit: 10 })
    // Fallback: try basename-based search if alias resolution yields nothing
    if (raw.length === 0) {
      const fallback = db.listSessions({ project: projectName, limit: 10 })
      sessions = fallback.map(mapSession)
    } else {
      sessions = raw.map(mapSession)
    }
  }

  // 3. Join cost data for each session
  for (const s of sessions) {
    try {
      const costRow = db.getRawDb().prepare(
        'SELECT cost_usd FROM session_costs WHERE session_id = ?'
      ).get(s.id) as { cost_usd: number } | undefined
      if (costRow) s.costUsd = costRow.cost_usd
    } catch { /* no cost data */ }
  }

  // 4. Format brief
  if (sessions.length === 0) {
    return {
      brief: format === 'markdown'
        ? `## Handoff — ${projectName}\n\nNo recent sessions found for this project.`
        : `Handoff — ${projectName}\n\nNo recent sessions found for this project.`,
      sessionCount: 0,
    }
  }

  const mostRecent = sessions[0]
  const relativeTime = formatRelativeTime(mostRecent.startTime)

  // I-1: Read last user message from the most recent session via adapter
  const lastUserMessage = await getLastUserMessage(mostRecent, adapters)
  const lastTask = lastUserMessage ?? mostRecent.summary

  if (format === 'markdown') {
    const lines: string[] = []
    lines.push(`## Handoff — ${projectName}`)
    lines.push(`**Last active**: ${relativeTime} via ${mostRecent.source} (${mostRecent.model || 'unknown'})`)
    lines.push(`**Recent sessions** (${sessions.length}):`)
    for (let i = 0; i < sessions.length; i++) {
      const s = sessions[i]
      const cost = s.costUsd != null ? `, $${s.costUsd.toFixed(2)}` : ''
      const duration = formatDuration(s.startTime, s.endTime)
      const durationStr = duration ? `, ${duration}` : ''
      lines.push(`${i + 1}. [${s.source}] ${s.summary || 'No summary'} — ${s.messageCount} msgs${durationStr}${cost}`)
    }
    lines.push('')
    if (lastTask) {
      lines.push(`**Last task**: ${lastTask.slice(0, 200)}`)
      const shortText = lastTask.slice(0, 60)
      lines.push(`**Suggested prompt**: "Continue: ${shortText}"`)
    }
    return { brief: lines.join('\n'), sessionCount: sessions.length }
  }

  // Plain format
  const lines: string[] = []
  lines.push(`Handoff — ${projectName}`)
  lines.push(`Last active: ${relativeTime} via ${mostRecent.source} (${mostRecent.model || 'unknown'})`)
  lines.push(`Recent sessions (${sessions.length}):`)
  for (let i = 0; i < sessions.length; i++) {
    const s = sessions[i]
    const cost = s.costUsd != null ? `, $${s.costUsd.toFixed(2)}` : ''
    const duration = formatDuration(s.startTime, s.endTime)
    const durationStr = duration ? `, ${duration}` : ''
    lines.push(`  ${i + 1}. [${s.source}] ${s.summary || 'No summary'} — ${s.messageCount} msgs${durationStr}${cost}`)
  }
  if (lastTask) {
    lines.push(`Last task: ${lastTask.slice(0, 200)}`)
  }
  return { brief: lines.join('\n'), sessionCount: sessions.length }
}

function mapSession(s: { id: string; source: string; startTime: string; endTime?: string; filePath: string; summary?: string; model?: string; messageCount: number; project?: string }): SessionWithCost {
  return { id: s.id, source: s.source, startTime: s.startTime, endTime: s.endTime, filePath: s.filePath, summary: s.summary, model: s.model, messageCount: s.messageCount, project: s.project }
}

/** Read the last user message from a session via its adapter. Falls back to null. */
async function getLastUserMessage(
  session: SessionWithCost,
  adapters?: SessionAdapter[]
): Promise<string | null> {
  if (!adapters?.length) return null
  const adapter = adapters.find(a => a.name === session.source)
  if (!adapter) return null
  try {
    let lastUserContent: string | null = null
    for await (const msg of adapter.streamMessages(session.filePath)) {
      if (msg.role === 'user' && msg.content.trim()) {
        lastUserContent = msg.content
      }
    }
    return lastUserContent
  } catch {
    return null
  }
}

/** Format duration between two ISO timestamps as human-readable (e.g., "2h 15m", "45m", "5m") */
export function formatDuration(startTime: string, endTime?: string): string | null {
  if (!endTime) return null
  const diffMs = new Date(endTime).getTime() - new Date(startTime).getTime()
  if (diffMs <= 0) return null
  const totalMinutes = Math.floor(diffMs / 60_000)
  if (totalMinutes < 1) return '< 1m'
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  if (hours === 0) return `${minutes}m`
  if (minutes === 0) return `${hours}h`
  return `${hours}h ${minutes}m`
}

export function formatRelativeTime(isoTime: string): string {
  const diffMs = Date.now() - new Date(isoTime).getTime()
  if (diffMs < 0) return 'just now'
  const minutes = Math.floor(diffMs / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}
