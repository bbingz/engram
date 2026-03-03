import type { Database } from './db.js'
import type { SessionInfo } from '../adapters/types.js'

export interface SyncPeer {
  name: string
  url: string
}

export interface SyncResult {
  peer: string
  pulled: number
  skipped: number
  error?: string
}

export class SyncEngine {
  private lastSyncTimes = new Map<string, string>()

  constructor(
    private db: Database,
    private fetchFn: typeof fetch = fetch
  ) {}

  async pullFromPeer(peer: SyncPeer): Promise<SyncResult> {
    const result: SyncResult = { peer: peer.name, pulled: 0, skipped: 0 }

    try {
      const statusRes = await this.fetchFn(`${peer.url}/api/sync/status`, {
        signal: AbortSignal.timeout(5000),
      })
      if (!statusRes.ok) {
        result.error = `Peer returned ${statusRes.status}`
        return result
      }

      const since = this.lastSyncTimes.get(peer.name) ?? '1970-01-01T00:00:00Z'
      const sessionsRes = await this.fetchFn(
        `${peer.url}/api/sync/sessions?since=${encodeURIComponent(since)}`,
        { signal: AbortSignal.timeout(30000) }
      )
      if (!sessionsRes.ok) {
        result.error = `Failed to fetch sessions: ${sessionsRes.status}`
        return result
      }

      const { sessions } = await sessionsRes.json() as { sessions: SessionInfo[] }

      for (const session of sessions) {
        const existing = this.db.getSession(session.id)
        if (existing) {
          result.skipped++
          continue
        }

        this.db.upsertSession({
          ...session,
          origin: peer.name,
          filePath: `sync://${peer.name}/${session.filePath}`,
        })
        result.pulled++
      }

      this.lastSyncTimes.set(peer.name, new Date().toISOString())
    } catch (err) {
      result.error = String(err)
    }

    return result
  }

  async syncAllPeers(peers: SyncPeer[]): Promise<SyncResult[]> {
    const results: SyncResult[] = []
    for (const peer of peers) {
      results.push(await this.pullFromPeer(peer))
    }
    return results
  }
}
