// Unit tests for src/core/project-move/gemini-projects-json.ts — the
// subsystem that keeps ~/.gemini/projects.json in sync during a project
// move. Addresses Codex MAJOR #1: Gemini's adapter reverse-resolves a
// session's cwd via this file; if we rename the tmp dir without updating
// the JSON, sessions detach from their project.

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  applyGeminiProjectsJsonUpdate,
  collectOtherGeminiCwdsSharingBasename,
  planGeminiProjectsJsonUpdate,
  reverseGeminiProjectsJsonUpdate,
} from '../../../src/core/project-move/gemini-projects-json.js';

describe('gemini-projects-json', () => {
  let tmp: string;
  let file: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-gemini-'));
    file = join(tmp, 'projects.json');
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  describe('planGeminiProjectsJsonUpdate', () => {
    it('captures old entry + snapshot when file exists with matching cwd', async () => {
      writeFileSync(
        file,
        JSON.stringify({
          projects: {
            '/a/proj': 'proj',
            '/b/other': 'other',
          },
        }),
      );
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      expect(plan.oldEntry).toEqual({ cwd: '/a/proj', name: 'proj' });
      expect(plan.newEntry).toEqual({ cwd: '/a/proj-v2', name: 'proj-v2' });
      expect(plan.originalText).not.toBeNull();
    });

    it('handles missing file — no oldEntry, null snapshot', async () => {
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      expect(plan.oldEntry).toBeNull();
      expect(plan.newEntry.name).toBe('proj-v2');
      expect(plan.originalText).toBeNull();
    });

    it('handles legacy flat layout (no `projects` wrapper)', async () => {
      writeFileSync(
        file,
        JSON.stringify({ '/a/proj': 'proj', '/b/other': 'other' }),
      );
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      expect(plan.oldEntry).toEqual({ cwd: '/a/proj', name: 'proj' });
    });

    it('returns null oldEntry when cwd is not in the map', async () => {
      writeFileSync(
        file,
        JSON.stringify({ projects: { '/b/other': 'other' } }),
      );
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      expect(plan.oldEntry).toBeNull();
      expect(plan.newEntry).toEqual({ cwd: '/a/proj-v2', name: 'proj-v2' });
    });

    it('throws on invalid JSON (refuses to silently clobber)', async () => {
      writeFileSync(file, '{invalid');
      await expect(
        planGeminiProjectsJsonUpdate(file, '/a/proj', '/a/proj-v2'),
      ).rejects.toThrow(/not valid JSON/);
    });
  });

  describe('applyGeminiProjectsJsonUpdate', () => {
    it('replaces the matching entry atomically', async () => {
      writeFileSync(
        file,
        JSON.stringify({
          projects: { '/a/proj': 'proj', '/b/other': 'other' },
        }),
      );
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      await applyGeminiProjectsJsonUpdate(plan);
      const after = JSON.parse(readFileSync(file, 'utf8')) as {
        projects: Record<string, string>;
      };
      expect(after.projects['/a/proj']).toBeUndefined();
      expect(after.projects['/a/proj-v2']).toBe('proj-v2');
      expect(after.projects['/b/other']).toBe('other');
    });

    it('preserves legacy layout when applying', async () => {
      writeFileSync(file, JSON.stringify({ '/a/proj': 'proj' }));
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      await applyGeminiProjectsJsonUpdate(plan);
      const after = JSON.parse(readFileSync(file, 'utf8')) as Record<
        string,
        string
      >;
      // legacy flat layout — no `projects` wrapper
      expect(after['/a/proj-v2']).toBe('proj-v2');
      expect(after['/a/proj']).toBeUndefined();
    });

    it('creates file when missing — writes new entry only', async () => {
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      await applyGeminiProjectsJsonUpdate(plan);
      const after = JSON.parse(readFileSync(file, 'utf8')) as {
        projects: Record<string, string>;
      };
      expect(after.projects['/a/proj-v2']).toBe('proj-v2');
    });
  });

  describe('reverseGeminiProjectsJsonUpdate', () => {
    it('restores full snapshot byte-for-byte when originalText is captured', async () => {
      const originalJson = JSON.stringify(
        { projects: { '/a/proj': 'proj', '/b/other': 'other' } },
        null,
        2,
      );
      writeFileSync(file, originalJson);
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      await applyGeminiProjectsJsonUpdate(plan);
      // file changed
      expect(readFileSync(file, 'utf8')).not.toBe(originalJson);

      await reverseGeminiProjectsJsonUpdate(plan);
      // Reverse restores EXACTLY the captured snapshot — no added newline,
      // no reformatting. User's original file layout preserved.
      expect(readFileSync(file, 'utf8')).toBe(originalJson);
    });

    it('removes the added entry when original file did not exist', async () => {
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      await applyGeminiProjectsJsonUpdate(plan);
      await reverseGeminiProjectsJsonUpdate(plan);
      // Round 4 (Gemini Minor): when engram created the file AND the
      // reversed map is empty, compensation unlinks the file entirely
      // to restore the exact pre-migration state. Either an absent
      // file or a file with no matching entry is acceptable.
      const fsSync = await import('node:fs');
      if (fsSync.existsSync(file)) {
        const after = JSON.parse(readFileSync(file, 'utf8')) as {
          projects: Record<string, string>;
        };
        expect(after.projects['/a/proj-v2']).toBeUndefined();
      }
      // else: file was unlinked — ideal state, pre-migration restored.
    });

    it('unlinks the file entirely when engram created it and map ends up empty', async () => {
      const plan = await planGeminiProjectsJsonUpdate(
        file,
        '/a/proj',
        '/a/proj-v2',
      );
      await applyGeminiProjectsJsonUpdate(plan);
      await reverseGeminiProjectsJsonUpdate(plan);
      const fsSync = await import('node:fs');
      expect(fsSync.existsSync(file)).toBe(false);
    });
  });

  describe('collectOtherGeminiCwdsSharingBasename', () => {
    it('flags OTHER cwds sharing the target basename', async () => {
      writeFileSync(
        file,
        JSON.stringify({
          projects: {
            '/a/proj': 'proj',
            '/b/proj': 'proj', // shares basename with src's new name
            '/c/unrelated': 'unrelated',
          },
        }),
      );
      // src is moving to something that would be called 'proj' — check
      // if any OTHER cwd already claims that name.
      const conflicts = await collectOtherGeminiCwdsSharingBasename(
        file,
        'proj',
        '/a/proj',
      );
      expect(conflicts).toEqual(['/b/proj']);
    });

    it('returns empty when no other cwd shares the basename', async () => {
      writeFileSync(
        file,
        JSON.stringify({
          projects: { '/a/proj': 'proj', '/b/other': 'other' },
        }),
      );
      const conflicts = await collectOtherGeminiCwdsSharingBasename(
        file,
        'proj',
        '/a/proj',
      );
      expect(conflicts).toEqual([]);
    });

    it('treats missing file as empty (no conflicts)', async () => {
      const conflicts = await collectOtherGeminiCwdsSharingBasename(
        file,
        'proj',
        '/a/proj',
      );
      expect(conflicts).toEqual([]);
    });
  });
});
