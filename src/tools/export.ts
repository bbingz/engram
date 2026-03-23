// src/tools/export.ts
import { writeFile, mkdir } from 'fs/promises'
import { homedir } from 'os'
import { join } from 'path'
import type { Database } from '../core/db.js'
import type { Logger } from '../core/logger.js'
import type { SessionAdapter } from '../adapters/types.js'
import { toLocalDate, toLocalDateTime } from '../utils/time.js'

export const exportTool = {
  name: 'export',
  description: '将单个会话导出为 Markdown 或 JSON 文件，保存到 ~/codex-exports/ 目录。',
  inputSchema: {
    type: 'object' as const,
    required: ['id'],
    properties: {
      id: { type: 'string', description: '会话 ID' },
      format: { type: 'string', enum: ['markdown', 'json'], description: '默认 markdown' },
    },
    additionalProperties: false,
  },
}

export async function handleExport(
  db: Database,
  adapter: SessionAdapter,
  params: { id: string; format?: string },
  opts?: { log?: Logger }
) {
  opts?.log?.info('export invoked', { id: params.id, format: params.format })
  const session = db.getSession(params.id)
  if (!session) throw new Error(`Session not found: ${params.id}`)

  const format = params.format ?? 'markdown'
  const messages: { role: string; content: string; timestamp?: string }[] = []
  for await (const msg of adapter.streamMessages(session.filePath)) {
    messages.push({ role: msg.role, content: msg.content, timestamp: msg.timestamp })
  }

  const outputDir = join(homedir(), 'codex-exports')
  await mkdir(outputDir, { recursive: true })

  const safeId = session.id.slice(0, 8)
  const filename = `${session.source}-${safeId}-${toLocalDate(session.startTime)}.${format === 'json' ? 'json' : 'md'}`
  const outputPath = join(outputDir, filename)

  let content: string
  if (format === 'json') {
    content = JSON.stringify({ session, messages }, null, 2)
  } else {
    const lines: string[] = [
      `# Session: ${session.id}`,
      '',
      `**Source:** ${session.source}`,
      `**Date:** ${toLocalDateTime(session.startTime)}`,
      `**Project:** ${session.project ?? session.cwd}`,
      `**Messages:** ${session.messageCount}`,
      '',
      '---',
      '',
    ]
    for (const msg of messages) {
      lines.push(`### ${msg.role === 'user' ? '👤 User' : '🤖 Assistant'}`)
      lines.push('')
      lines.push(msg.content)
      lines.push('')
      lines.push('---')
      lines.push('')
    }
    content = lines.join('\n')
  }

  await writeFile(outputPath, content, 'utf8')

  return { outputPath, format, messageCount: messages.length }
}
