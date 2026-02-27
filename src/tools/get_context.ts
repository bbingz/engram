// src/tools/get_context.ts
import { basename } from 'path'
import type { Database } from '../core/db.js'

export const getContextTool = {
  name: 'get_context',
  description: '为当前工作目录自动提取相关的历史会话上下文。在开始新任务时调用，获取该项目的历史记录。',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: '当前工作目录（绝对路径）' },
      task: { type: 'string', description: '当前任务描述（可选）' },
      max_tokens: { type: 'number', description: 'token 预算，默认 4000（约 16000 字符）' },
    },
    additionalProperties: false,
  },
}

const CHARS_PER_TOKEN = 4

export async function handleGetContext(
  db: Database,
  params: { cwd: string; task?: string; max_tokens?: number }
) {
  const maxTokens = params.max_tokens ?? 4000
  const maxChars = maxTokens * CHARS_PER_TOKEN

  // 先用目录名匹配项目名，找不到再用路径片段
  const projectName = basename(params.cwd.replace(/\/$/, ''))
  let sessions = db.listSessions({ project: projectName, limit: 50 })
  if (sessions.length === 0 && params.cwd) {
    sessions = db.listSessions({ project: params.cwd, limit: 50 })
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
    const line = `[${session.source}] ${session.startTime.slice(0, 10)} — ${session.summary}\n`
    if (totalChars + line.length > maxChars) break
    contextParts.push(line)
    totalChars += line.length
    selectedSessions.push(session)
  }

  return {
    cwd: params.cwd,
    sessions: selectedSessions,
    contextText: contextParts.join(''),
    sessionCount: selectedSessions.length,
    estimatedTokens: Math.ceil(totalChars / CHARS_PER_TOKEN),
  }
}
