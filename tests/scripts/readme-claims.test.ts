// Freeze public claims about how indexing stays current.
//
// README.md claimed "之后通过文件监听增量更新" while the service has never had a
// file watcher — indexing is a periodic NSBackgroundActivityScheduler cycle with
// an adaptive 15m..1h interval (IndexingSchedulePolicy). Mirror backlog row 6
// (UX-3) asked to fix the claim *and then freeze it*, so this guard is
// bidirectional: it fails if the README claims watching the service does not do,
// and equally if the service gains a watcher and the README is not updated.

import { readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const readme = readFileSync(resolve(repoRoot, 'README.md'), 'utf8');

/** Swift sources that would host a watcher if one existed. */
const serviceRoots = [
  'macos/EngramService',
  'macos/EngramCoreWrite',
  'macos/Shared',
];

function swiftSources(): string {
  const parts: string[] = [];
  for (const root of serviceRoots) {
    const dir = resolve(repoRoot, root);
    for (const entry of readdirSync(dir, {
      recursive: true,
      withFileTypes: true,
    })) {
      if (!entry.isFile() || !entry.name.endsWith('.swift')) continue;
      parts.push(readFileSync(join(entry.parentPath, entry.name), 'utf8'));
    }
  }
  return parts.join('\n');
}

const WATCHER_API =
  /FSEvent|DispatchSource\.makeFileSystemObjectSource|\bkqueue\b|NSFilePresenter/;
const WATCH_CLAIM = /文件监听|文件系统监听|file[-\s]?watch/i;

describe('README claims match the shipped service', () => {
  it('claims file watching only if the service actually watches files', () => {
    const watcherPresent = WATCHER_API.test(swiftSources());
    const claimsWatching = WATCH_CLAIM.test(readme);

    expect(claimsWatching).toBe(watcherPresent);
  });

  it('describes the periodic scan the service really runs', () => {
    expect(readme).toContain('周期性重扫');
    expect(readme).toContain('15 分钟到 1 小时');
  });

  it('keeps the documented interval bounds equal to the policy', () => {
    const policy = readFileSync(
      resolve(
        repoRoot,
        'macos/EngramService/Core/IndexingSchedulePolicy.swift',
      ),
      'utf8',
    );
    expect(policy).toContain('minInterval: TimeInterval = 15 * 60');
    expect(policy).toContain('maxInterval: TimeInterval = 60 * 60');
  });
});
