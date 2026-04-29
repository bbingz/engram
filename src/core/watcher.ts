// src/core/watcher.ts

import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';
import chokidar, { type FSWatcher } from 'chokidar';
import type { SessionAdapter, SourceName } from '../adapters/types.js';
import type { Indexer } from './indexer.js';
import { runWithContext } from './request-context.js';
import type { SessionTier } from './session-tier.js';

interface WatcherOptions {
  onIndexed?: (
    sessionId: string,
    messageCount: number,
    tier: SessionTier,
  ) => void;
  /**
   * Called when a watched session file disappears. The caller should mark
   * matching DB rows as orphaned (reason='cleaned_by_source') — not delete them.
   * The path is the absolute filesystem path that chokidar reported as unlinked.
   */
  onUnlink?: (filePath: string) => void;
  /**
   * Return true to skip the event entirely (no indexing, no orphan marking).
   * Used to pause watcher activity during an in-flight `project move`:
   * chokidar sees rename as unlink + add, and we must not index a half-moved
   * JSONL (pre-patch `cwd`), nor mark the old path as orphaned.
   *
   * Called for add / change / unlink events. If omitted, all events proceed.
   */
  shouldSkip?: (filePath: string) => boolean;
}

/** Source names that have file watchers (jsonl-based, filesystem events work) */
export const WATCHED_SOURCES = new Set([
  'codex',
  'claude-code',
  'gemini-cli',
  'antigravity',
  'iflow',
  'qwen',
  'kimi',
  'pi',
  'cline',
  // Derived sources that share claude-code's directory
  'lobsterai',
  'minimax',
]);

/** Canonical mapping of watch directories to source names. Shared by watcher and daemon. */
export function getWatchEntries(home?: string): Array<[string, SourceName]> {
  const h = home ?? homedir();
  return [
    [join(h, '.codex', 'sessions'), 'codex'],
    [join(h, '.codex', 'archived_sessions'), 'codex'],
    [join(h, '.claude', 'projects'), 'claude-code'],
    [join(h, '.gemini', 'tmp'), 'gemini-cli'],
    [join(h, '.gemini', 'antigravity'), 'antigravity'],
    [join(h, '.iflow', 'projects'), 'iflow'],
    [join(h, '.qwen', 'projects'), 'qwen'],
    [join(h, '.kimi', 'sessions'), 'kimi'],
    [join(h, '.pi', 'agent', 'sessions'), 'pi'],
    [join(h, '.cline', 'data', 'tasks'), 'cline'],
  ];
}

export function startWatcher(
  adapters: SessionAdapter[],
  indexer: Indexer,
  opts?: WatcherOptions,
): FSWatcher | null {
  const home = homedir();
  const adaptersByName = new Map(adapters.map((a) => [a.name, a]));
  const watchEntries = getWatchEntries(home);
  const watchMap: Record<string, SessionAdapter> = {};
  for (const [path, name] of watchEntries) {
    const adapter = adaptersByName.get(name);
    if (adapter) watchMap[path] = adapter;
  }

  const watchPaths = Object.keys(watchMap).filter(
    (p) => watchMap[p] !== undefined,
  );
  if (watchPaths.length === 0) return null;

  const watcher = chokidar.watch(watchPaths, {
    persistent: true,
    ignoreInitial: true,
    followSymlinks: false,
    awaitWriteFinish: { stabilityThreshold: 2000, pollInterval: 500 },
    // Skip high-churn noise directories that explode the fd count without
    // ever yielding a session to index. ENFILE on machines with large
    // Gemini tmp trees was the trigger (see e.g. .gemini/tmp/<proj>/
    // tool-outputs/run_shell_command_*.txt — thousands per session).
    // Patterns anchored where possible so we don't accidentally skip a
    // user project that happens to be named "tool-outputs" / etc.
    ignored: [
      /\/\.gemini\/tmp\/[^/]+\/tool-outputs\//,
      /\/\.vite-temp\//,
      /\.engram-tmp-/,
      /\.engram-move-tmp-/,
      /\/node_modules\//,
      /\.DS_Store$/,
    ],
  });

  const handleChange = async (filePath: string) => {
    // Skip if caller (usually project-move in flight) says so.
    // Prevents indexer reading half-moved JSONL before its cwd is patched.
    if (opts?.shouldSkip?.(filePath)) return;
    await runWithContext(
      { requestId: randomUUID(), source: 'watcher' },
      async () => {
        for (const [watchPath, adapter] of Object.entries(watchMap)) {
          if (filePath.startsWith(watchPath)) {
            const result = await indexer.indexFile(adapter, filePath);
            if (result.indexed && result.sessionId) {
              opts?.onIndexed?.(
                result.sessionId,
                result.messageCount ?? 0,
                result.tier ?? 'normal',
              );
            }
            break;
          }
        }
      },
    );
  };

  watcher.on('add', handleChange);
  watcher.on('change', handleChange);

  if (opts?.onUnlink) {
    watcher.on('unlink', (filePath: string) => {
      // shouldSkip also covers unlink — during rename both unlink+add fire
      if (opts.shouldSkip?.(filePath)) return;
      try {
        opts.onUnlink?.(filePath);
      } catch {
        // intentional: unlink hook must not crash the watcher
      }
    });
  }

  return watcher;
}
