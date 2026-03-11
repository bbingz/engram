// src/tools/link_sessions.ts
import { basename, join, isAbsolute } from 'path'
import { mkdir, symlink, readlink, lstat, unlink } from 'fs/promises'
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
  truncated?: boolean
}

const QUERY_LIMIT = 10000

export async function handleLinkSessions(
  db: Database,
  params: { targetDir: string }
): Promise<LinkResult> {
  const targetDir = params.targetDir.replace(/\/$/, '')

  if (!isAbsolute(targetDir)) {
    return { created: 0, skipped: 0, errors: ['targetDir must be an absolute path'], targetDir, projectNames: [] }
  }

  const projectName = basename(targetDir)
  const projectNames = db.resolveProjectAliases([projectName])

  const sessions = db.listSessions({ projects: projectNames, limit: QUERY_LIMIT })

  const result: LinkResult = { created: 0, skipped: 0, errors: [], targetDir, projectNames }
  if (sessions.length === QUERY_LIMIT) {
    result.truncated = true
  }

  const createdDirs = new Set<string>()

  for (const session of sessions) {
    const source = session.source
    const fileName = basename(session.filePath)
    const linkDir = join(targetDir, 'conversation_log', source)
    const linkPath = join(linkDir, fileName)

    try {
      // Check if symlink already exists
      try {
        const stat = await lstat(linkPath)
        if (stat.isSymbolicLink()) {
          const existing = await readlink(linkPath)
          if (existing === session.filePath) {
            result.skipped++
            continue
          }
          // Different target — replace the symlink
          await unlink(linkPath)
        }
      } catch {
        // File doesn't exist — proceed to create
      }

      if (!createdDirs.has(linkDir)) {
        await mkdir(linkDir, { recursive: true })
        createdDirs.add(linkDir)
      }
      await symlink(session.filePath, linkPath)
      result.created++
    } catch (err) {
      result.errors.push(`${linkPath}: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  return result
}
