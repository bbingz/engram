type DaemonEvent = Record<string, unknown>;

interface InitialScanDeps {
  emit: (event: DaemonEvent) => void;
  log: {
    warn: (
      message: string,
      meta?: Record<string, unknown>,
      err?: unknown,
    ) => void;
    info?: (message: string, data?: Record<string, unknown>) => void;
  };
  usageCollector: {
    start: () => void;
  };
  indexer: {
    indexAll: () => Promise<number>;
    backfillCounts: () => Promise<number>;
    backfillCosts: () => Promise<number>;
  };
  indexJobRunner: {
    runRecoverableJobs: () => Promise<{
      completed: number;
      notApplicable: number;
    }>;
    backfillInsightEmbeddings: () => Promise<number>;
  };
  db: {
    countSessions: () => number;
    countTodayParentSessions: () => number;
    backfillScores: () => number;
    deduplicateFilePaths: () => number;
    optimizeFts: () => void;
    vacuumIfNeeded: (fragmentationPercent: number) => boolean;
    reconcileInsights: (log?: {
      info: (message: string, data?: Record<string, unknown>) => void;
    }) => {
      resetEmbedding: number;
      orphanedVector: number;
    };
    backfillFilePaths: () => number;
    downgradeSubagentTiers: () => number;
    backfillParentLinks: () => {
      linked: number;
    };
    resetStaleDetections: () => number;
    backfillCodexOriginator: () => number;
    backfillSuggestedParents: () => {
      checked: number;
      suggested: number;
    };
    cleanupStaleMigrations: () => number;
    detectOrphans: (
      adapters: ReadonlyArray<{
        name: string;
        isAccessible(locator: string): Promise<boolean>;
      }>,
      opts?: { gracePeriodDays?: number },
    ) => Promise<{
      scanned: number;
      newlyFlagged: number;
      confirmed: number;
      recovered: number;
      skipped: number;
    }>;
  };
  adapters: ReadonlyArray<{
    name: string;
    isAccessible(locator: string): Promise<boolean>;
  }>;
}

export async function runInitialScan({
  emit,
  log,
  usageCollector,
  indexer,
  indexJobRunner,
  db,
  adapters,
}: InitialScanDeps): Promise<void> {
  const indexed = await indexer.indexAll();

  // Backfill assistant/system counts for sessions indexed before this feature
  try {
    const backfilled = await indexer.backfillCounts();
    if (backfilled > 0) {
      emit({ event: 'backfill_counts', backfilled });
    }
  } catch (err) {
    log.warn('backfill counts failed', {}, err);
  }

  // Backfill costs and tool analytics for sessions without cost data
  try {
    const costBackfilled = await indexer.backfillCosts();
    if (costBackfilled > 0) {
      emit({ event: 'backfill', type: 'costs', count: costBackfilled });
    }
  } catch (err) {
    log.warn('backfill costs failed', {}, err);
  }

  // Backfill quality scores for sessions without scores
  try {
    const scoreBackfilled = db.backfillScores();
    if (scoreBackfilled > 0) {
      emit({ event: 'backfill', type: 'scores', count: scoreBackfilled });
    }
  } catch (err) {
    log.warn('backfill scores failed', {}, err);
  }

  // DB maintenance: dedup, optimize FTS, VACUUM if fragmented, reconcile insights
  try {
    const deduped = db.deduplicateFilePaths();
    if (deduped > 0) {
      emit({ event: 'db_maintenance', action: 'dedup', removed: deduped });
    }
    db.optimizeFts();
    const vacuumed = db.vacuumIfNeeded(15);
    if (vacuumed) {
      emit({ event: 'db_maintenance', action: 'vacuum' });
    }
    const reconciled = db.reconcileInsights(
      log.info ? { info: log.info } : undefined,
    );
    if (reconciled.resetEmbedding > 0 || reconciled.orphanedVector > 0) {
      emit({
        event: 'db_maintenance',
        action: 'reconcile_insights',
        ...reconciled,
      });
    }
  } catch (err) {
    log.warn('db maintenance failed', {}, err);
  }

  // Backfill file_path from source_locator (fixes session parsing in Swift app)
  try {
    const pathsFixed = db.backfillFilePaths();
    if (pathsFixed > 0) {
      emit({ event: 'backfill', type: 'file_paths', count: pathsFixed });
    }
  } catch (err) {
    emit({ event: 'error', message: `backfillFilePaths: ${err}` });
  }

  // Backfill parent session links before publishing the initial todayParents count
  try {
    const downgraded = db.downgradeSubagentTiers();
    if (downgraded > 0) {
      emit({
        event: 'backfill',
        type: 'subagent_tier_downgrade',
        count: downgraded,
      });
    }
    const parentLinks = db.backfillParentLinks();
    if (parentLinks.linked > 0) {
      emit({
        event: 'backfill',
        type: 'parent_links',
        linked: parentLinks.linked,
      });
    }
    const detectionReset = db.resetStaleDetections();
    if (detectionReset > 0) {
      emit({
        event: 'backfill',
        type: 'detection_reset',
        count: detectionReset,
      });
    }
    const originatorUpdated = db.backfillCodexOriginator();
    if (originatorUpdated > 0) {
      emit({
        event: 'backfill',
        type: 'codex_originator',
        updated: originatorUpdated,
      });
    }
    const suggestions = db.backfillSuggestedParents();
    if (suggestions.suggested > 0) {
      emit({
        event: 'backfill',
        type: 'suggested_parents',
        checked: suggestions.checked,
        suggested: suggestions.suggested,
      });
    }
  } catch (err) {
    log.warn('parent link backfill failed', {}, err);
  }

  // Clean up stale project-move migrations (crashed mid-way)
  try {
    const stale = db.cleanupStaleMigrations();
    if (stale > 0) {
      emit({ event: 'migration_cleanup', stale });
    }
  } catch (err) {
    log.warn('migration cleanup failed', {}, err);
  }

  emit({
    event: 'ready',
    indexed,
    total: db.countSessions(),
    todayParents: db.countTodayParentSessions(),
  });

  // Background orphan scan — runs after ready so the menu-bar badge is not delayed.
  setImmediate(() => {
    db.detectOrphans(adapters)
      .then((r) => {
        if (r.newlyFlagged > 0 || r.confirmed > 0 || r.recovered > 0) {
          emit({
            event: 'orphan_scan',
            scanned: r.scanned,
            newly_flagged: r.newlyFlagged,
            confirmed: r.confirmed,
            recovered: r.recovered,
            skipped: r.skipped,
          });
        }
      })
      .catch((err) => log.warn('orphan scan failed', {}, err));
  });

  try {
    const jobSummary = await indexJobRunner.runRecoverableJobs();
    if (jobSummary.completed > 0 || jobSummary.notApplicable > 0) {
      emit({ event: 'index_jobs_recovered', ...jobSummary });
    }
    const promoted = await indexJobRunner.backfillInsightEmbeddings();
    if (promoted > 0) {
      emit({ event: 'insights_promoted', count: promoted });
    }
  } catch (err) {
    log.warn('index job recovery failed', {}, err);
  }

  usageCollector.start();
}
