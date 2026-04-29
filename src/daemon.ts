// src/daemon.ts
// Stripped-down daemon: indexer + watcher only, no MCP server.
// Outputs JSON lines to stdout for the Swift app to parse.
// Usage: node dist/daemon.js [db-path]

import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { ClaudeUsageProbe } from './adapters/claude-usage-probe.js';
import { CodexUsageProbe } from './adapters/codex-usage-probe.js';
import { summarizeConversation } from './core/ai-client.js';
import { AlertRuleEngine } from './core/alert-rules.js';
import { AutoSummaryManager } from './core/auto-summary.js';
import { createDaemonDeps, createShutdownHandler } from './core/bootstrap.js';
import {
  DEFAULT_AI_AUDIT_CONFIG,
  type FileSettings,
  readFileSettings,
} from './core/config.js';
import { runInitialScan } from './core/daemon-startup.js';
import { startGitProbeLoop } from './core/git-probe.js';
import { LiveSessionMonitor, type WatchDir } from './core/live-sessions.js';
import { populateMockData } from './core/mock-data.js';
import { BackgroundMonitor } from './core/monitor.js';
import { runWithContext } from './core/request-context.js';
import { SyncEngine } from './core/sync.js';
import { UsageCollector } from './core/usage-collector.js';
import {
  getWatchEntries,
  startWatcher,
  WATCHED_SOURCES,
} from './core/watcher.js';
import { createApp } from './web.js';

// Power state detection — one-time check at startup (macOS only)
function isOnACPower(): boolean {
  try {
    const result = execFileSync('pmset', ['-g', 'batt'], {
      encoding: 'utf-8',
      timeout: 3000,
    });
    return result.includes("'AC Power'");
  } catch {
    return true; // intentional: assume AC if pmset detection fails (non-macOS or cmd not found)
  }
}

const onACPower = isOnACPower();
const powerMode = onACPower ? 'ac' : 'battery';
const POWER_MULTIPLIER = onACPower ? 1 : 2;

function emit(obj: object): void {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

const dbPath = process.argv[2] || undefined;
const {
  db,
  adapters,
  settings,
  audit,
  auditQuery,
  tracer,
  indexer,
  indexJobRunner,
  vecDeps,
  log,
  logWriter,
  metrics,
  titleGenerator,
} = createDaemonDeps({ dbPath });

log.info('daemon starting', { powerMode });

// Emit power state
emit({ event: 'power', mode: powerMode });

// Eager WAL checkpoint on startup — clears accumulated frames left by the
// previous process so readers don't pay for a huge -wal file up front.
try {
  const cp = db.checkpointWal('TRUNCATE');
  emit({
    event: 'wal_checkpoint',
    phase: 'startup',
    busy: cp.busy,
    log: cp.log,
    checkpointed: cp.checkpointed,
  });
} catch (err) {
  log.warn('startup wal_checkpoint failed', {}, err);
}

audit.on(
  'entry',
  (entry: {
    id: number;
    caller: string;
    operation: string;
    model?: string;
    durationMs: number;
    promptTokens?: number;
  }) => {
    emit({
      event: 'ai_audit',
      id: entry.id,
      caller: entry.caller,
      operation: entry.operation,
      model: entry.model,
      durationMs: entry.durationMs,
      promptTokens: entry.promptTokens,
    });
  },
);

if (!vecDeps) {
  emit({ event: 'warning', message: 'Vector store unavailable' });
}

// Build watch directories for live session detection (reuse canonical entries from watcher)
const watchDirs: WatchDir[] = getWatchEntries().map(([path, source]) => ({
  path,
  source,
}));

const usageCollector = new UsageCollector(db.getRawDb(), (event, data) =>
  emit({
    event,
    ...(typeof data === 'object' && data !== null ? data : { data }),
  }),
);
usageCollector.register(new ClaudeUsageProbe());
usageCollector.register(new CodexUsageProbe());

// Handle --mock flag for development
if (process.argv.includes('--mock')) {
  populateMockData(db)
    .then((stats) => {
      emit({ event: 'mock_data', ...stats });
    })
    .catch((err) => {
      emit({ event: 'error', message: `Mock data failed: ${String(err)}` });
    });
}

// Initial full scan
runInitialScan({
  emit,
  log,
  usageCollector,
  indexer,
  indexJobRunner,
  db,
  adapters,
}).catch((err) => {
  emit({ event: 'error', message: String(err) });
});

// Auto-summary manager — lazily created when settings enable it
let autoSummary: AutoSummaryManager | undefined;
let cachedAutoSummarySettings: FileSettings | undefined;
let settingsCacheTime = 0;
const SETTINGS_CACHE_TTL = 30_000; // re-read settings at most every 30s

function getCachedSettings(): FileSettings {
  const now = Date.now();
  if (
    !cachedAutoSummarySettings ||
    now - settingsCacheTime > SETTINGS_CACHE_TTL
  ) {
    cachedAutoSummarySettings = readFileSettings();
    settingsCacheTime = now;
  }
  return cachedAutoSummarySettings;
}

function getAutoSummary(): AutoSummaryManager | undefined {
  const current = getCachedSettings();
  if (!current.autoSummary || !current.aiApiKey) {
    if (autoSummary) {
      autoSummary.cleanup();
      autoSummary = undefined;
    }
    return undefined;
  }
  if (!autoSummary) {
    autoSummary = new AutoSummaryManager({
      cooldownMs: (current.autoSummaryCooldown ?? 5) * 60 * 1000,
      minMessages: current.autoSummaryMinMessages ?? 4,
      hasSummary: (id) => {
        const s = db.getSession(id);
        if (!s?.summary) return false;
        const fresh = getCachedSettings();
        if (!fresh.autoSummaryRefresh) return true;
        const threshold = fresh.autoSummaryRefreshThreshold ?? 20;
        const lastCount = s.summaryMessageCount;
        return (
          lastCount !== undefined && s.messageCount - lastCount < threshold
        );
      },
      onTrigger: async (sessionId) => {
        const session = db.getSession(sessionId);
        if (!session) return;
        const adapter = adapters.find((a) => a.name === session.source);
        if (!adapter) return;

        const messages: Array<{ role: string; content: string }> = [];
        for await (const msg of adapter.streamMessages(session.filePath)) {
          messages.push({ role: msg.role, content: msg.content });
        }
        if (messages.length === 0) return;

        try {
          // Fresh read for AI call (need latest API key/model)
          const currentSettings = readFileSettings();
          const summary = await summarizeConversation(
            messages,
            currentSettings,
            { audit, sessionId },
          );
          if (summary) {
            db.updateSessionSummary(sessionId, summary, messages.length);
            emit({
              event: 'summary_generated',
              sessionId,
              summary,
              total: db.countSessions(),
              todayParents: db.countTodayParentSessions(),
            });
          }
        } catch (err) {
          emit({ event: 'summary_error', sessionId, message: String(err) });
        }
      },
    });
  }
  return autoSummary;
}

// File watcher (persistent — keeps process alive)
const watcher = startWatcher(adapters, indexer, {
  // Skip all events (add/change/unlink) for paths covered by an in-flight
  // project move. chokidar fires unlink(old)+add(new) on rename; handling
  // either would corrupt DB (index pre-patch JSONL or orphan soon-to-be-
  // rewritten rows).
  shouldSkip: (filePath) => db.hasPendingMigrationFor(filePath),
  onIndexed: (sessionId, messageCount, tier) => {
    emit({
      event: 'watcher_indexed',
      total: db.countSessions(),
      todayParents: db.countTodayParentSessions(),
    });
    if (tier === 'premium') {
      getAutoSummary()?.onSessionIndexed(sessionId, messageCount);
    }
    indexJobRunner.runRecoverableJobs().catch(() => {}); // intentional: fire-and-forget background job
  },
  onUnlink: (filePath) => {
    const touched = db.markOrphanByPath(filePath, 'cleaned_by_source');
    if (touched > 0) {
      emit({
        event: 'watcher_orphaned',
        path: filePath,
        sessions: touched,
      });
    }
  },
});

// Live session monitor — detects active coding sessions via file mtime
const liveMonitor = new LiveSessionMonitor({ watchDirs });
liveMonitor.start(5000 * POWER_MULTIPLIER);

// Background monitor — periodic health checks + alerts
const monitorConfig = settings.monitor ?? { enabled: true };
// Merge costAlerts into monitor config (costAlerts overrides monitor defaults)
if (settings.costAlerts?.dailyBudget != null) {
  monitorConfig.dailyCostBudget = settings.costAlerts.dailyBudget;
}
if (settings.costAlerts?.monthlyBudget != null) {
  monitorConfig.monthlyCostBudget = settings.costAlerts.monthlyBudget;
}
const backgroundMonitor = new BackgroundMonitor(
  db,
  monitorConfig,
  (alert) => {
    emit({ event: 'alert', alert });
  },
  liveMonitor,
);
if (monitorConfig.enabled) {
  backgroundMonitor.start(600_000 * POWER_MULTIPLIER); // every 10 minutes (20 on battery)
}

const alertEngine = new AlertRuleEngine(db.raw);

const alertCheckTimer = setInterval(() => {
  runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => {
    metrics.flush();
    const alerts = alertEngine.check();
    for (const alert of alerts) {
      emit({ event: 'alert', alert });
    }
  });
}, 600_000 * POWER_MULTIPLIER);

// Periodic re-scan every 10 minutes — only for non-watchable sources
// (SQLite-based: Cursor, OpenCode, VS Code, Windsurf, Copilot)
const RESCAN_INTERVAL = 10 * 60 * 1000 * POWER_MULTIPLIER;
const allSourceNames = new Set(adapters.map((a) => a.name));
const nonWatchable = new Set(
  [...allSourceNames].filter((s) => !WATCHED_SOURCES.has(s)),
);

const rescanTimer = setInterval(async () => {
  await runWithContext(
    { requestId: randomUUID(), source: 'scheduler' },
    async () => {
      try {
        const indexed =
          nonWatchable.size > 0
            ? await indexer.indexAll({ sources: nonWatchable })
            : 0;
        if (indexed > 0) {
          const total = db.countSessions();
          const todayParents = db.countTodayParentSessions();
          emit({ event: 'rescan', indexed, total, todayParents });
          indexJobRunner.runRecoverableJobs().catch(() => {});
        }
      } catch (err) {
        log.warn('periodic rescan failed', {}, err);
      }
    },
  );
}, RESCAN_INTERVAL);

// Sync engine
const syncEngine = new SyncEngine(db);
const syncPeers = settings.syncPeers ?? [];
const syncIntervalMs =
  Math.max(settings.syncIntervalMinutes ?? 30, 1) * 60 * 1000;

async function syncAndEmit(): Promise<void> {
  const results = await syncEngine.syncAllPeers(syncPeers);
  const totalPulled = results.reduce((sum, r) => sum + r.pulled, 0);
  if (totalPulled > 0) {
    emit({
      event: 'sync_complete',
      results,
      totalPulled,
      total: db.countSessions(),
      todayParents: db.countTodayParentSessions(),
    });
    indexJobRunner.runRecoverableJobs().catch(() => {}); // intentional: fire-and-forget background job
  }
}

// Start web server
const port = settings.httpPort ?? 3457;
const host = settings.httpHost ?? '127.0.0.1';

// Safety: non-localhost binding requires CIDR whitelist
if (
  host !== '127.0.0.1' &&
  (!settings.httpAllowCIDR || settings.httpAllowCIDR.length === 0)
) {
  emit({
    event: 'error',
    message: `Refusing to bind to ${host} without httpAllowCIDR. Add allowed CIDRs to settings.json.`,
  });
  process.exit(1);
}

// Auto-generate bearer token for non-localhost binding
if (host !== '127.0.0.1' && !settings.httpBearerToken) {
  const { randomBytes } = await import('node:crypto');
  const token = randomBytes(32).toString('hex');
  const { writeFileSettings } = await import('./core/config.js');
  writeFileSettings({ httpBearerToken: token });
  settings.httpBearerToken = token;
  emit({
    event: 'security',
    message: 'Bearer token auto-generated for non-localhost binding',
  });
}
const app = createApp(db, {
  vectorStore: vecDeps?.vectorStore,
  embeddingClient: vecDeps?.embeddingClient,
  syncEngine,
  syncPeers,
  settings,
  adapters,
  usageCollector,
  titleGenerator,
  liveMonitor,
  backgroundMonitor,
  logWriter,
  metrics,
  tracer,
  audit,
  auditQuery,
});
const { serve } = await import('@hono/node-server');
const webServer = serve({ fetch: app.fetch, port, hostname: host }, (info) => {
  emit({ event: 'web_ready', port: info.port, host });
});

// Initial sync on startup
if (settings.syncEnabled && syncPeers.length > 0) {
  syncAndEmit().catch((err) => {
    log.warn('initial sync failed', {}, err);
  });
}

// Periodic sync timer
const syncTimer =
  settings.syncEnabled && syncPeers.length > 0
    ? setInterval(() => {
        syncAndEmit().catch((err) => {
          log.warn('periodic sync failed', {}, err);
        });
      }, syncIntervalMs)
    : null;

// Git repo probe loop — runs once immediately, then every 5 minutes (10 on battery)
const gitProbeTimer = startGitProbeLoop(
  db.getRawDb(),
  300_000 * POWER_MULTIPLIER,
);

// Observability: log rotation + metrics rollup
const logRotationTimer = setInterval(() => {
  runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => {
    const retentionDays = settings.observability?.logRetentionDays ?? 7;
    logWriter.rotate(retentionDays);
    logWriter.enforceMaxRows(100_000);
    db.raw
      .prepare('DELETE FROM traces WHERE start_ts < ?')
      .run(new Date(Date.now() - retentionDays * 86400000).toISOString());
    db.raw
      .prepare('DELETE FROM metrics WHERE ts < ?')
      .run(new Date(Date.now() - 24 * 3600000).toISOString());
    const auditRetention =
      settings.aiAudit?.retentionDays ?? DEFAULT_AI_AUDIT_CONFIG.retentionDays;
    audit.cleanup(auditRetention);
  });
}, 3600000);

let rollupInterval: ReturnType<typeof setInterval> | null = null;
const metricsRollupTimer = setTimeout(() => {
  rollupInterval = setInterval(() => {
    metrics.rollup();
  }, 3600000);
}, 300000);

// Periodic WAL checkpoint — every 10 minutes (20 on battery).
// Round 1 hotfix: PASSIVE mode (non-blocking) — TRUNCATE on the daemon's
// main connection was blocking the event loop up to 30s (busy_timeout)
// whenever a reader held an old snapshot. PASSIVE moves what frames it
// can without waiting; startup still uses TRUNCATE to clear accumulated
// WAL in one shot when we own the DB exclusively.
const walCheckpointTimer = setInterval(() => {
  runWithContext({ requestId: randomUUID(), source: 'scheduler' }, () => {
    try {
      const cp = db.checkpointWal('PASSIVE');
      if (cp.busy === 1 || cp.checkpointed > 0) {
        emit({
          event: 'wal_checkpoint',
          phase: 'periodic',
          busy: cp.busy,
          log: cp.log,
          checkpointed: cp.checkpointed,
        });
      }
      metrics.gauge('db.wal_frames', cp.log);
    } catch (err) {
      log.warn('periodic wal_checkpoint failed', {}, err);
    }
  });
}, 600_000 * POWER_MULTIPLIER);

// Daemon uptime gauge — report every 60 seconds
const daemonStartTime = Date.now();
const uptimeTimer = setInterval(() => {
  metrics.gauge(
    'daemon.uptime_s',
    Math.floor((Date.now() - daemonStartTime) / 1000),
  );
  // Process health
  const mem = process.memoryUsage();
  metrics.gauge(
    'process.heap_mb',
    Math.round((mem.heapUsed / 1048576) * 10) / 10,
  );
  metrics.gauge('process.rss_mb', Math.round((mem.rss / 1048576) * 10) / 10);
  const cpu = process.cpuUsage();
  metrics.gauge('process.cpu_user_ms', Math.round(cpu.user / 1000));
  metrics.gauge('process.cpu_system_ms', Math.round(cpu.system / 1000));
}, 60000);

// Lifecycle: signal handlers only (no stdin/parent checks — daemon runs standalone)
const shutdown = createShutdownHandler(
  {
    timers: [
      rescanTimer,
      syncTimer,
      gitProbeTimer,
      logRotationTimer,
      metricsRollupTimer,
      rollupInterval,
      uptimeTimer,
      alertCheckTimer,
      walCheckpointTimer,
    ],
    watcher,
    webServer,
    db,
    metrics,
    liveMonitor,
    backgroundMonitor,
    usageCollector,
    autoSummary,
  },
  log,
);

const wrappedShutdown = () => {
  shutdown();
  process.exit(0);
};
process.on('SIGTERM', wrappedShutdown);
process.on('SIGINT', wrappedShutdown);
