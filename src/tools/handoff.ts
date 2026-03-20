import { basename } from 'path'
import type { Database } from '../core/db.js'

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
  summary?: string
  model?: string
  messageCount: number
  project?: string
  costUsd?: number
}

export async function handleHandoff(
  db: Database,
  params: HandoffParams
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
    // Fallback: try cwd-based search if project name yields nothing
    if (raw.length === 0) {
      const fallback = db.listSessions({ project: params.cwd, limit: 10 })
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

  if (format === 'markdown') {
    const lines: string[] = []
    lines.push(`## Handoff — ${projectName}`)
    lines.push(`**Last active**: ${relativeTime} via ${mostRecent.source} (${mostRecent.model || 'unknown'})`)
    lines.push(`**Recent sessions** (${sessions.length}):`)
    for (let i = 0; i < sessions.length; i++) {
      const s = sessions[i]
      const cost = s.costUsd != null ? `, $${s.costUsd.toFixed(2)}` : ''
      lines.push(`${i + 1}. [${s.source}] ${s.summary || 'No summary'} — ${s.messageCount} msgs${cost}`)
    }
    lines.push('')
    if (mostRecent.summary) {
      lines.push(`**Last task**: ${mostRecent.summary.slice(0, 200)}`)
      const shortSummary = mostRecent.summary.slice(0, 60)
      lines.push(`**Suggested prompt**: "继续 ${shortSummary}"`)
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
    lines.push(`  ${i + 1}. [${s.source}] ${s.summary || 'No summary'} — ${s.messageCount} msgs${cost}`)
  }
  if (mostRecent.summary) {
    lines.push(`Last task: ${mostRecent.summary.slice(0, 200)}`)
  }
  return { brief: lines.join('\n'), sessionCount: sessions.length }
}

function mapSession(s: { id: string; source: string; startTime: string; summary?: string; model?: string; messageCount: number; project?: string }): SessionWithCost {
  return { id: s.id, source: s.source, startTime: s.startTime, summary: s.summary, model: s.model, messageCount: s.messageCount, project: s.project }
}

function formatRelativeTime(isoTime: string): string {
  const diffMs = Date.now() - new Date(isoTime).getTime()
  const minutes = Math.floor(diffMs / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}
