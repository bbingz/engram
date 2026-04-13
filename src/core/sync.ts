import type { SessionInfo } from '../adapters/types.js';
import type { Database } from './db.js';
import type {
  AuthoritativeSessionSnapshot,
  SyncCursor,
} from './session-snapshot.js';
import { computeTier } from './session-tier.js';
import { SessionSnapshotWriter } from './session-writer.js';

export interface SyncPeer {
  name: string;
  url: string;
}

interface SyncResult {
  peer: string;
  pulled: number;
  skipped: number;
  error?: string;
}

export class SyncEngine {
  constructor(
    private db: Database,
    private fetchFn: typeof fetch = fetch,
    private writer: Pick<
      SessionSnapshotWriter,
      'writeAuthoritativeSnapshot'
    > = new SessionSnapshotWriter(db),
  ) {}

  private normalizeRemoteSnapshot(
    peerName: string,
    raw: SessionInfo | AuthoritativeSessionSnapshot,
  ): AuthoritativeSessionSnapshot {
    const rawFilePath = 'filePath' in raw ? raw.filePath : undefined;
    // Prefer remote's sourceLocator, then raw filePath from sync payload.
    // Do NOT fall back to local existing.filePath — that's a local path and would pollute ownership.
    const sourceLocator =
      ('sourceLocator' in raw && raw.sourceLocator
        ? raw.sourceLocator
        : rawFilePath) ?? '';
    const indexedAt =
      'indexedAt' in raw && raw.indexedAt ? raw.indexedAt : raw.startTime;
    const authoritativeNode =
      'authoritativeNode' in raw && raw.authoritativeNode
        ? raw.authoritativeNode
        : peerName;
    const syncVersion =
      'syncVersion' in raw && typeof raw.syncVersion === 'number'
        ? raw.syncVersion
        : raw.messageCount;
    const snapshotHash =
      'snapshotHash' in raw && raw.snapshotHash
        ? raw.snapshotHash
        : `${raw.id}:${raw.messageCount}:${raw.summary ?? ''}`;

    return {
      id: raw.id,
      source: raw.source,
      authoritativeNode,
      syncVersion,
      snapshotHash,
      indexedAt,
      sourceLocator:
        sourceLocator ?? `sync://${peerName}/${rawFilePath ?? raw.id}`,
      startTime: raw.startTime,
      endTime: raw.endTime,
      cwd: raw.cwd,
      project: raw.project,
      model: raw.model,
      messageCount: raw.messageCount,
      userMessageCount: raw.userMessageCount,
      assistantMessageCount: raw.assistantMessageCount,
      toolMessageCount: raw.toolMessageCount,
      systemMessageCount: raw.systemMessageCount,
      summary: raw.summary,
      summaryMessageCount:
        'summaryMessageCount' in raw ? raw.summaryMessageCount : undefined,
      origin: peerName,
      agentRole: 'agentRole' in raw ? ((raw as any).agentRole ?? null) : null,
    };
  }

  private buildSyncUrl(
    peer: SyncPeer,
    cursor: SyncCursor | null,
    limit: number,
  ): string {
    if (!cursor) return `${peer.url}/api/sync/sessions?limit=${limit}`;
    return `${peer.url}/api/sync/sessions?cursor_indexed_at=${encodeURIComponent(cursor.indexedAt)}&cursor_id=${encodeURIComponent(cursor.sessionId)}&limit=${limit}`;
  }

  async pullFromPeer(peer: SyncPeer): Promise<SyncResult> {
    const result: SyncResult = { peer: peer.name, pulled: 0, skipped: 0 };

    try {
      const statusRes = await this.fetchFn(`${peer.url}/api/sync/status`, {
        signal: AbortSignal.timeout(5000),
      });
      if (!statusRes.ok) {
        result.error = `Peer returned ${statusRes.status}`;
        return result;
      }

      let cursor = this.db.getSyncCursor(peer.name);
      const PAGE_LIMIT = 100;

      // Paginate: keep pulling until we get fewer than PAGE_LIMIT sessions
      while (true) {
        const sessionsRes = await this.fetchFn(
          this.buildSyncUrl(peer, cursor, PAGE_LIMIT),
          { signal: AbortSignal.timeout(30000) },
        );
        if (!sessionsRes.ok) {
          result.error = `Failed to fetch sessions: ${sessionsRes.status}`;
          return result;
        }

        const { sessions } = (await sessionsRes.json()) as {
          sessions: Array<SessionInfo | AuthoritativeSessionSnapshot>;
        };

        let pagePulled = 0;
        let pageSkipped = 0;
        let lastCursor: SyncCursor | null = cursor;
        for (const session of sessions) {
          const snapshot = this.normalizeRemoteSnapshot(peer.name, session);
          snapshot.tier = computeTier({
            messageCount: snapshot.messageCount,
            agentRole: snapshot.agentRole ?? null,
            filePath: snapshot.sourceLocator,
            project: snapshot.project ?? null,
            summary: snapshot.summary ?? null,
            startTime: snapshot.startTime,
            endTime: snapshot.endTime ?? null,
            source: snapshot.source,
          });
          const writeResult = this.writer.writeAuthoritativeSnapshot(snapshot);
          if (writeResult.action === 'noop') {
            pageSkipped++;
          } else {
            pagePulled++;
          }
          lastCursor = {
            indexedAt: snapshot.indexedAt,
            sessionId: snapshot.id,
          };
        }

        if (sessions.length > 0 && lastCursor) {
          this.db.setSyncCursor(peer.name, lastCursor);
          cursor = lastCursor;
          result.pulled += pagePulled;
          result.skipped += pageSkipped;
        }

        // If we got fewer than the limit, we've fetched everything
        if (sessions.length < PAGE_LIMIT) break;
      }
    } catch (err) {
      result.error = err instanceof Error ? err.message : String(err);
    }

    return result;
  }

  async syncAllPeers(peers: SyncPeer[]): Promise<SyncResult[]> {
    const settled = await Promise.allSettled(
      peers.map((p) => this.pullFromPeer(p)),
    );
    return settled.map((s, i) =>
      s.status === 'fulfilled'
        ? s.value
        : {
            peer: peers[i].name,
            pulled: 0,
            skipped: 0,
            error: String(s.reason),
          },
    );
  }
}
