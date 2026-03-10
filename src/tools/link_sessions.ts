// src/tools/link_sessions.ts
import { basename, join } from 'path'
import { mkdir, symlink, readlink, lstat } from 'fs/promises'
import type { Database } from '../core/db.js'

export const linkSessionsTool = {
  name: 'link_sessions',
  description: 'Create symlinks to all AI session files for a project in <targetDir>/conversation_log/<source>/',
  inputSchema: {
    type: 'object' as const,
    required: ['targetDir'],
    properties: {
      targetDir: { type: 'string', description: 'Project directory (absolute path). Project name is derived from basename.' },
    },
    additionalProperties: false,
  },
}

export interface LinkResult {
  created: number
  skipped: number
  errors: string[]
  targetDir: string
  projectNames: string[]
}

export async function handleLinkSessions(
  db: Database,
  params: { targetDir: string }
): Promise<LinkResult> {
  const targetDir = params.targetDir.replace(/\/$/, '')
  const projectName = basename(targetDir)
  const projectNames = db.resolveProjectAliases([projectName])

  const sessions = db.listSessions({ projects: projectNames, limit: 10000 })

  const result: LinkResult = { created: 0, skipped: 0, errors: [], targetDir, projectNames }

  for (const session of sessions) {
    const source = session.source
    const fileName = basename(session.filePath)
    const linkDir = join(targetDir, 'conversation_log', source)
    const linkPath = join(linkDir, fileName)

    try {
      // Check if symlink already exists and points to the same target
      try {
        const stat = await lstat(linkPath)
        if (stat.isSymbolicLink()) {
          const existing = await readlink(linkPath)
          if (existing === session.filePath) {
            result.skipped++
            continue
          }
        }
      } catch {
        // File doesn't exist — proceed to create
      }

      await mkdir(linkDir, { recursive: true })
      await symlink(session.filePath, linkPath)
      result.created++
    } catch (err) {
      result.errors.push(`${linkPath}: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  return result
}
