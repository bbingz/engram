import { basename } from 'path'
import type { Database } from '../core/db.js'
import type { VectorStore } from '../core/vector-store.js'
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
    },
    additionalProperties: false,
  },
}

const CHARS_PER_TOKEN = 4

export interface GetContextDeps {
  vectorStore?: VectorStore
  embed?: (text: string) => Promise<Float32Array | null>
}

export async function handleGetContext(
  db: Database,
  params: { cwd: string; task?: string; max_tokens?: number },
  deps: GetContextDeps = {}
) {
  const maxTokens = params.max_tokens ?? 4000
  const maxChars = maxTokens * CHARS_PER_TOKEN

  const projectName = basename(params.cwd.replace(/\/$/, ''))
  const projectNames = db.resolveProjectAliases([projectName])
  let sessions = db.listSessions({ projects: projectNames, limit: 50 })
  if (sessions.length === 0 && params.cwd) {
    sessions = db.listSessions({ project: params.cwd, limit: 50 })
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

  return {
    contextText: contextParts.join(''),
    sessionCount: selectedSessions.length,
    sessionIds: selectedSessions.map(s => s.id),
  }
}
