// src/core/migrate.ts
// One-time migration from ~/.coding-memory to ~/.engram
import { existsSync, renameSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'

export function migrateDataDir(): void {
  const home = homedir()
  const oldDir = join(home, '.coding-memory')
  const newDir = join(home, '.engram')

  if (existsSync(oldDir) && !existsSync(newDir)) {
    try {
      renameSync(oldDir, newDir)
      process.stderr.write(`[engram] Migrated data directory: ~/.coding-memory → ~/.engram\n`)
    } catch (err) {
      process.stderr.write(
        `[engram] WARNING: Could not rename ~/.coding-memory → ~/.engram: ${err}\n` +
        `[engram] Your existing data remains at ~/.coding-memory. Please move it manually.\n`
      )
    }
  }
}
