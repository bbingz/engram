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

      let since = this.db.getSyncTime(peer.name) ?? '1970-01-01T00:00:00Z'
      const PAGE_LIMIT = 100

      // Paginate: keep pulling until we get fewer than PAGE_LIMIT sessions
      while (true) {
        const sessionsRes = await this.fetchFn(
          `${peer.url}/api/sync/sessions?since=${encodeURIComponent(since)}&limit=${PAGE_LIMIT}`,
          { signal: AbortSignal.timeout(30000) }
        )
        if (!sessionsRes.ok) {
          result.error = `Failed to fetch sessions: ${sessionsRes.status}`
          return result
        }

        const { sessions } = await sessionsRes.json() as { sessions: SessionInfo[] }

        let maxIndexedAt = since
        for (const session of sessions) {
          const existing = this.db.getSession(session.id)
          if (existing && existing.messageCount >= session.messageCount) {
            result.skipped++
          } else {
            this.db.upsertSession({
              ...session,
              origin: peer.name,
              filePath: existing ? existing.filePath : `sync://${peer.name}/${session.filePath}`,
            })
            result.pulled++
          }
          // Track the max indexed_at to use as the next cursor
          if (session.startTime > maxIndexedAt) maxIndexedAt = session.startTime
        }

        // Advance cursor to the latest timestamp we saw (not local now())
        if (sessions.length > 0) {
          this.db.setSyncTime(peer.name, maxIndexedAt)
          since = maxIndexedAt
        }

        // If we got fewer than the limit, we've fetched everything
        if (sessions.length < PAGE_LIMIT) break
      }
    } catch (err) {
      result.error = String(err)
    }

    return result
  }

  async syncAllPeers(peers: SyncPeer[]): Promise<SyncResult[]> {
    const settled = await Promise.allSettled(peers.map(p => this.pullFromPeer(p)))
    return settled.map((s, i) =>
      s.status === 'fulfilled'
        ? s.value
        : { peer: peers[i].name, pulled: 0, skipped: 0, error: String(s.reason) }
    )
  }
}
