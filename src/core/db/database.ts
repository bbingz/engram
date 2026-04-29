// src/core/db/database.ts — Database facade class
import BetterSqlite3 from 'better-sqlite3';
import type { SessionInfo } from '../../adapters/types.js';
import type { MetricsCollector } from '../metrics.js';
import type {
  AuthoritativeSessionSnapshot,
  IndexJobKind,
  PersistedIndexJob,
  SessionLocalState,
  SyncCursor,
} from '../session-snapshot.js';
import * as aliases from './alias-repo.js';
import * as fts from './fts-repo.js';
import * as jobs from './index-job-repo.js';
import type { InsightRow } from './insight-repo.js';
import * as insights from './insight-repo.js';
import * as maint from './maintenance.js';
import * as metricsRepo from './metrics-repo.js';
import { runMigrations } from './migration.js';
import type { MigrationLogRow } from './migration-log-repo.js';
import * as migrationLog from './migration-log-repo.js';
import * as parentLinks from './parent-link-repo.js';
import * as sessions from './session-repo.js';
import * as sync from './sync-repo.js';
import type {
  CostSummaryRow,
  FileActivityRow,
  ListSessionsOptions,
  NoiseFilter,
  SearchFilters,
  StatsGroup,
  ToolAnalyticsRow,
} from './types.js';

export class Database {
  private db: BetterSqlite3.Database;
  noiseFilter: NoiseFilter = 'hide-skip';
  private metrics?: MetricsCollector;

  /** Expose underlying better-sqlite3 instance for observability writers */
  get raw(): BetterSqlite3.Database {
    return this.db;
  }

  constructor(dbPath: string) {
    this.db = new BetterSqlite3(dbPath);
    this.db.pragma('journal_mode = WAL');
    // 30s busy_timeout: watcher batch transactions + concurrent MCP writers
    // regularly exceed the old 5s under load (see PROGRESS.md Phase A).
    this.db.pragma('busy_timeout = 30000');
    this.db.pragma('foreign_keys = ON');
    runMigrations(
      this.db,
      (k) => this.getMetadata(k),
      (k, v) => this.setMetadata(k, v),
    );
    maint.runPostMigrationBackfill(this.db);
    maint.backfillTiers(this.db);
    maint.backfillScores(this.db);
  }

  setMetrics(metrics: MetricsCollector): void {
    this.metrics = metrics;

    const originalPrepare = this.db.prepare.bind(this.db);
    this.db.prepare = ((sql: string) => {
      const stmt = originalPrepare(sql);
      return this.wrapStatement(stmt);
    }) as typeof this.db.prepare;
  }

  private wrapStatement(
    stmt: BetterSqlite3.Statement,
  ): BetterSqlite3.Statement {
    if (!this.metrics) return stmt;
    const metrics = this.metrics;
    return new Proxy(stmt, {
      get(target, prop) {
        if (prop === 'run' || prop === 'get' || prop === 'all') {
          // biome-ignore lint/suspicious/noExplicitAny: Proxy handler forwarding arbitrary statement arguments
          return (...args: any[]) => {
            const start = performance.now();
            // biome-ignore lint/suspicious/noExplicitAny: dynamic property access on Proxy target
            const result = (target as any)[prop].apply(target, args);
            metrics.histogram('db.query_ms', performance.now() - start, {
              method: prop as string,
            });
            return result;
          };
        }
        // biome-ignore lint/suspicious/noExplicitAny: dynamic property access on Proxy target
        const val = (target as any)[prop];
        return typeof val === 'function' ? val.bind(target) : val;
      },
    }) as BetterSqlite3.Statement;
  }

  getRawDb(): BetterSqlite3.Database {
    return this.db;
  }

  getMetadata(key: string): string | null {
    const row = this.db
      .prepare('SELECT value FROM metadata WHERE key = ?')
      .get(key) as { value: string } | undefined;
    return row?.value ?? null;
  }

  setMetadata(key: string, value: string): void {
    this.db
      .prepare(
        'INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      )
      .run(key, value);
  }

  close(): void {
    this.db.close();
  }

  // --- Session repo ---
  upsertSession(session: SessionInfo): void {
    sessions.upsertSession(this.db, session);
  }
  applyParentLink(session: SessionInfo): void {
    sessions.applyParentLink(this.db, session);
  }
  getSessionByFilePath(filePath: string): SessionInfo | null {
    return sessions.getSessionByFilePath(this.db, filePath);
  }
  getSession(id: string): SessionInfo | null {
    return sessions.getSession(this.db, id);
  }
  listSessions(opts: ListSessionsOptions = {}): SessionInfo[] {
    return sessions.listSessions(this.db, opts, this.noiseFilter, (p) =>
      this.resolveProjectAliases(p),
    );
  }
  listSessionsSince(since: string, limit = 100): SessionInfo[] {
    return sessions.listSessionsSince(this.db, since, limit);
  }
  listSessionsAfterCursor(
    cursor: SyncCursor | null,
    limit = 100,
  ): AuthoritativeSessionSnapshot[] {
    return sessions.listSessionsAfterCursor(this.db, cursor, limit);
  }
  deleteSession(id: string): void {
    sessions.deleteSession(this.db, id);
  }
  isIndexed(filePath: string, sizeBytes: number): boolean {
    return sessions.isIndexed(this.db, filePath, sizeBytes);
  }
  countSessions(
    opts: Pick<
      ListSessionsOptions,
      | 'source'
      | 'sources'
      | 'project'
      | 'projects'
      | 'origin'
      | 'origins'
      | 'agents'
    > = {},
  ): number {
    return sessions.countSessions(this.db, opts, this.noiseFilter, (p) =>
      this.resolveProjectAliases(p),
    );
  }
  countTodayParentSessions(now?: Date, timeZone?: string): number {
    return sessions.countTodayParentSessions(
      this.db,
      this.noiseFilter,
      now,
      timeZone,
    );
  }
  listSources(): string[] {
    return sessions.listSources(this.db);
  }
  listOrigins(): string[] {
    return sessions.listOrigins(this.db);
  }
  getSourceStats(): {
    source: string;
    sessionCount: number;
    latestIndexed: string;
    dailyCounts: number[];
  }[] {
    return sessions.getSourceStats(this.db);
  }
  listProjects(): string[] {
    return sessions.listProjects(this.db);
  }
  updateSessionSummary(
    id: string,
    summary: string,
    messageCount?: number,
  ): void {
    sessions.updateSessionSummary(this.db, id, summary, messageCount);
  }
  getFtsContent(sessionId: string): string[] {
    return fts.getFtsContent(this.db, sessionId);
  }
  getAuthoritativeSnapshot(id: string): AuthoritativeSessionSnapshot | null {
    return sessions.getAuthoritativeSnapshot(this.db, id);
  }
  upsertAuthoritativeSnapshot(snapshot: AuthoritativeSessionSnapshot): void {
    sessions.upsertAuthoritativeSnapshot(this.db, snapshot, (sid) =>
      this.getLocalState(sid),
    );
  }

  // --- FTS repo ---
  indexSessionContent(
    sessionId: string,
    messages: { role: string; content: string }[],
    summary?: string,
  ): void {
    fts.indexSessionContent(this.db, sessionId, messages, summary);
  }
  searchSessions(
    query: string,
    limit = 20,
    filters?: SearchFilters,
  ): { sessionId: string; snippet: string; rank: number }[] {
    return fts.searchSessions(this.db, query, limit, filters, (p) =>
      this.resolveProjectAliases(p),
    );
  }
  replaceFtsContent(sessionId: string, contents: string[]): void {
    fts.replaceFtsContent(this.db, sessionId, contents);
  }

  // --- Metrics repo ---
  statsGroupBy(
    groupBy: string,
    since?: string,
    until?: string,
    opts?: { excludeNoise?: boolean },
  ): StatsGroup[] {
    return metricsRepo.statsGroupBy(
      this.db,
      groupBy,
      since,
      until,
      opts,
      this.noiseFilter,
    );
  }
  needsCountBackfill(): string[] {
    return metricsRepo.needsCountBackfill(this.db);
  }
  upsertSessionCost(
    sessionId: string,
    model: string,
    inputTokens: number,
    outputTokens: number,
    cacheReadTokens: number,
    cacheCreationTokens: number,
    costUsd: number,
  ): void {
    metricsRepo.upsertSessionCost(
      this.db,
      sessionId,
      model,
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheCreationTokens,
      costUsd,
    );
  }
  getCostsSummary(params: {
    groupBy?: string;
    since?: string;
    until?: string;
  }): CostSummaryRow[] {
    return metricsRepo.getCostsSummary(this.db, params);
  }
  sessionsWithoutCosts(limit = 100): string[] {
    return metricsRepo.sessionsWithoutCosts(this.db, limit);
  }
  upsertSessionFiles(
    sessionId: string,
    files: Map<string, { action: string; count: number }>,
  ): void {
    metricsRepo.upsertSessionFiles(this.db, sessionId, files);
  }
  getFileActivity(params: {
    project?: string;
    since?: string;
    limit?: number;
  }): FileActivityRow[] {
    return metricsRepo.getFileActivity(this.db, params);
  }
  upsertSessionTools(sessionId: string, tools: Map<string, number>): void {
    metricsRepo.upsertSessionTools(this.db, sessionId, tools);
  }
  getToolAnalytics(params: {
    project?: string;
    since?: string;
    groupBy?: string;
  }): ToolAnalyticsRow[] {
    return metricsRepo.getToolAnalytics(this.db, params);
  }

  // --- Index job repo ---
  insertIndexJobs(
    sessionId: string,
    targetSyncVersion: number,
    jobKinds: IndexJobKind[],
  ): void {
    jobs.insertIndexJobs(this.db, sessionId, targetSyncVersion, jobKinds);
  }
  takeRecoverableIndexJobs(limit: number): PersistedIndexJob[] {
    return jobs.takeRecoverableIndexJobs(this.db, limit);
  }
  listIndexJobs(sessionId: string): PersistedIndexJob[] {
    return jobs.listIndexJobs(this.db, sessionId);
  }
  markIndexJobCompleted(id: string): void {
    jobs.markIndexJobCompleted(this.db, id);
  }
  markIndexJobNotApplicable(id: string): void {
    jobs.markIndexJobNotApplicable(this.db, id);
  }
  markIndexJobRetryableFailure(id: string, error: string): void {
    jobs.markIndexJobRetryableFailure(this.db, id, error);
  }

  // --- Sync repo ---
  getSyncTime(peerName: string): string | null {
    return sync.getSyncTime(this.db, peerName);
  }
  setSyncTime(peerName: string, time: string): void {
    sync.setSyncTime(this.db, peerName, time);
  }
  getSyncCursor(peerName: string): SyncCursor | null {
    return sync.getSyncCursor(this.db, peerName);
  }
  setSyncCursor(peerName: string, cursor: SyncCursor): void {
    sync.setSyncCursor(this.db, peerName, cursor);
  }
  getLocalState(sessionId: string): SessionLocalState | null {
    return sync.getLocalState(this.db, sessionId);
  }
  setLocalReadablePath(
    sessionId: string,
    localReadablePath: string | null,
  ): void {
    sync.setLocalReadablePath(this.db, sessionId, localReadablePath);
  }

  // --- Maintenance ---
  runPostMigrationBackfill(): void {
    maint.runPostMigrationBackfill(this.db);
  }
  backfillTiers(): void {
    maint.backfillTiers(this.db);
  }
  backfillScores(): number {
    return maint.backfillScores(this.db);
  }
  optimizeFts(): void {
    maint.optimizeFts(this.db);
  }
  checkpointWal(
    mode: maint.WalCheckpointMode = 'TRUNCATE',
  ): maint.WalCheckpointResult {
    return maint.checkpointWal(this.db, mode);
  }
  vacuumIfNeeded(thresholdPct: number): boolean {
    return maint.vacuumIfNeeded(this.db, thresholdPct);
  }
  deduplicateFilePaths(): number {
    return maint.deduplicateFilePaths(this.db);
  }
  reconcileInsights(log?: {
    info: (message: string, data?: Record<string, unknown>) => void;
  }): { resetEmbedding: number; orphanedVector: number } {
    return maint.reconcileInsights(this.db, log);
  }

  // --- Parent link repo ---
  validateParentLink(sessionId: string, parentId: string) {
    return parentLinks.validateParentLink(this.db, sessionId, parentId);
  }
  setParentSession(
    sessionId: string,
    parentId: string,
    linkSource: 'path' | 'manual',
  ) {
    parentLinks.setParentSession(this.db, sessionId, parentId, linkSource);
  }
  clearParentSession(sessionId: string) {
    parentLinks.clearParentSession(this.db, sessionId);
  }
  confirmSuggestion(sessionId: string) {
    return parentLinks.confirmSuggestion(this.db, sessionId);
  }
  setSuggestedParent(sessionId: string, suggestedParentId: string) {
    parentLinks.setSuggestedParent(this.db, sessionId, suggestedParentId);
  }
  clearSuggestedParent(sessionId: string, expectedParentId: string) {
    return parentLinks.clearSuggestedParent(
      this.db,
      sessionId,
      expectedParentId,
    );
  }
  childSessions(parentId: string, limit = 20, offset = 0) {
    return parentLinks.childSessions(this.db, parentId, limit, offset);
  }
  childCount(parentIds: string[]) {
    return parentLinks.childCount(this.db, parentIds);
  }
  suggestedChildSessions(parentId: string) {
    return parentLinks.suggestedChildSessions(this.db, parentId);
  }
  suggestedChildCount(parentIds: string[]) {
    return parentLinks.suggestedChildCount(this.db, parentIds);
  }
  backfillParentLinks() {
    return maint.backfillParentLinks(this.db);
  }
  downgradeSubagentTiers() {
    return maint.downgradeSubagentTiers(this.db);
  }
  backfillFilePaths() {
    return maint.backfillFilePaths(this.db);
  }
  backfillCodexOriginator() {
    return maint.backfillCodexOriginator(this.db);
  }
  resetStaleDetections() {
    return maint.resetStaleDetections(this.db);
  }
  backfillSuggestedParents() {
    return maint.backfillSuggestedParents(this.db);
  }
  detectOrphans(
    adapters: readonly maint.OrphanScanAdapter[],
    opts?: { gracePeriodDays?: number },
  ) {
    return maint.detectOrphans(this.db, adapters, opts);
  }
  markSessionOrphan(
    sessionId: string,
    reason: 'cleaned_by_source' | 'file_deleted' | 'path_unreachable',
  ) {
    return maint.markSessionOrphan(this.db, sessionId, reason);
  }
  markOrphanByPath(
    filePath: string,
    reason: 'cleaned_by_source' | 'file_deleted' = 'cleaned_by_source',
  ) {
    return maint.markOrphanByPath(this.db, filePath, reason);
  }

  // --- migration_log (project move lifecycle) ---
  startMigration(input: migrationLog.StartMigrationInput): void {
    migrationLog.startMigration(this.db, input);
  }
  markMigrationFsDone(input: migrationLog.FsDoneInput): void {
    migrationLog.markFsDone(this.db, input);
  }
  finishMigration(input: migrationLog.FinishMigrationInput): void {
    migrationLog.finishMigration(this.db, input);
  }
  failMigration(id: string, error: string): void {
    migrationLog.failMigration(this.db, id, error);
  }
  findMigration(id: string): MigrationLogRow | null {
    return migrationLog.findMigration(this.db, id);
  }
  listMigrations(opts?: migrationLog.ListMigrationsOptions): MigrationLogRow[] {
    return migrationLog.listMigrations(this.db, opts);
  }
  hasPendingMigrationFor(filePath: string): boolean {
    return migrationLog.hasPendingMigrationFor(this.db, filePath);
  }
  cleanupStaleMigrations(): number {
    return migrationLog.cleanupStaleMigrations(this.db);
  }
  applyMigrationDb(
    input: maint.ApplyMigrationInput,
  ): maint.ApplyMigrationResult {
    return maint.applyMigrationDb(this.db, input);
  }

  // --- Insight repo ---
  saveInsightText(
    id: string,
    content: string,
    wing?: string,
    room?: string,
    importance?: number,
    sourceSessionId?: string,
  ): void {
    insights.saveInsightText(
      this.db,
      id,
      content,
      wing,
      room,
      importance,
      sourceSessionId,
    );
  }
  searchInsightsFts(query: string, limit = 10): InsightRow[] {
    return insights.searchInsightsFts(this.db, query, limit);
  }
  listInsightsByWing(wing: string | undefined, limit = 10): InsightRow[] {
    return insights.listInsightsByWing(this.db, wing, limit);
  }
  markInsightEmbedded(id: string): void {
    insights.markInsightEmbedded(this.db, id);
  }
  findDuplicateInsight(content: string, wing?: string): InsightRow | null {
    return insights.findDuplicateInsight(this.db, content, wing);
  }
  listUnembeddedInsights(limit = 20): InsightRow[] {
    return insights.listUnembeddedInsights(this.db, limit);
  }
  deleteInsightText(id: string): boolean {
    return insights.deleteInsightText(this.db, id);
  }

  // --- Alias repo ---
  resolveProjectAliases(projects: string[]): string[] {
    return aliases.resolveProjectAliases(this.db, projects);
  }
  addProjectAlias(alias: string, canonical: string): void {
    aliases.addProjectAlias(this.db, alias, canonical);
  }
  removeProjectAlias(alias: string, canonical: string): void {
    aliases.removeProjectAlias(this.db, alias, canonical);
  }
  listProjectAliases(): { alias: string; canonical: string }[] {
    return aliases.listProjectAliases(this.db);
  }
}
