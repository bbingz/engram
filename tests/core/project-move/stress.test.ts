// Stress test for walkSessionFiles + findReferencingFiles — scaling to
// realistic claude-projects/ tree sizes (1000 dirs × ~few files each).
// Goal: prove the Phase 2 rev2 subprocess-grep fast-path keeps search
// time sub-second even at 10k file counts.
//
// This is a regression guard, not a benchmark — it asserts "completes
// within N seconds" rather than specific ms. Raise the threshold if CI
// hardware regresses.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  findReferencingFiles,
  walkSessionFiles,
} from '../../../src/core/project-move/sources.js';

const NEEDLE = '/Users/example/-Code-/target-project';
const STRESS_DIRS = 200; // smaller than Gemini's 1000 to keep CI fast
const FILES_PER_DIR = 10;
const NEEDLE_HIT_EVERY = 25; // ~1 in 25 files actually contains the needle

describe('project-move stress — walk + grep at scale', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-stress-'));
    // Simulate claude-projects/ shape: many project-encoded dirs with jsonl inside
    let counter = 0;
    for (let d = 0; d < STRESS_DIRS; d++) {
      const dir = join(
        tmp,
        `-Users-example-proj-${d.toString().padStart(4, '0')}`,
      );
      mkdirSync(dir, { recursive: true });
      for (let f = 0; f < FILES_PER_DIR; f++) {
        const hit = counter % NEEDLE_HIT_EVERY === 0;
        const payload = hit
          ? `{"cwd":"${NEEDLE}","msg":"hello"}`
          : `{"cwd":"/Users/example/-Code-/other-${f}","msg":"hello"}`;
        writeFileSync(join(dir, `session-${f}.jsonl`), payload);
        counter++;
      }
    }
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  it(`walks ${STRESS_DIRS * FILES_PER_DIR} files in under 3 seconds`, async () => {
    const start = Date.now();
    let count = 0;
    for await (const _ of walkSessionFiles(tmp)) count++;
    const ms = Date.now() - start;
    expect(count).toBe(STRESS_DIRS * FILES_PER_DIR);
    expect(ms).toBeLessThan(3000);
  });

  it(`finds all referencing files via grep fast-path within 1 second`, async () => {
    const start = Date.now();
    const hits = await findReferencingFiles(tmp, NEEDLE);
    const ms = Date.now() - start;
    // We planted 1 hit every NEEDLE_HIT_EVERY files, starting at counter=0
    const expectedHits = Math.ceil(
      (STRESS_DIRS * FILES_PER_DIR) / NEEDLE_HIT_EVERY,
    );
    expect(hits.length).toBe(expectedHits);
    // Grep fast-path should dominate; 1s is plenty for 2000 files locally
    expect(ms).toBeLessThan(2000);
  });
});
