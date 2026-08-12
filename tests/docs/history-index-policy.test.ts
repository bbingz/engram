import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const archiveIndexPath = resolve(repoRoot, 'docs/archive/README.md');
const reviewIndexPath = resolve(repoRoot, 'docs/reviews/README.md');

describe('historical documentation policy', () => {
  it('indexes archive and review evidence with explicit retention rules_repro', () => {
    const missingIndexes = [archiveIndexPath, reviewIndexPath].filter(
      (path) => !existsSync(path),
    );

    expect(missingIndexes, 'archive and review indexes must exist').toEqual([]);

    const archiveIndex = readFileSync(archiveIndexPath, 'utf8');
    const reviewIndex = readFileSync(reviewIndexPath, 'utf8');

    expect(archiveIndex).toContain('[plans/](plans/)');
    expect(archiveIndex).toContain('[reviews/](reviews/)');
    expect(archiveIndex).toContain('[superpowers/](superpowers/)');
    expect(reviewIndex).toContain(
      '[stewardship queue](2026-08-12-stewardship-queue.md)',
    );

    for (const index of [archiveIndex, reviewIndex]) {
      expect(index).toContain('## Authority');
      expect(index).toContain('## Retention');
      expect(index).toContain('No automatic age-based deletion');
      expect(index).toContain('docs/roadmap.md');
      expect(index).toContain('docs/TODO.md');
      expect(index).toContain('docs/followups.md');
    }
  });
});
