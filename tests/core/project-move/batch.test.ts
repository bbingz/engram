import { describe, expect, it } from 'vitest';
import { normalizeBatchDocument } from '../../../src/core/project-move/batch.js';

describe('batch normalize', () => {
  it('accepts minimal valid doc', () => {
    const doc = normalizeBatchDocument({
      version: 1,
      operations: [{ src: '/a', dst: '/b' }],
    });
    expect(doc.version).toBe(1);
    expect(doc.operations).toEqual([
      {
        src: '/a',
        dst: '/b',
        archive: undefined,
        archiveTo: undefined,
        note: undefined,
      },
    ]);
    expect(doc.defaults?.stopOnError).toBe(true); // default
    expect(doc.defaults?.dryRun).toBe(false);
  });

  it('rejects unknown version', () => {
    expect(() =>
      normalizeBatchDocument({ version: 2, operations: [] }),
    ).toThrow(/version/);
  });

  it('rejects missing src', () => {
    expect(() =>
      normalizeBatchDocument({ version: 1, operations: [{ dst: '/b' }] }),
    ).toThrow(/src is required/);
  });

  it('rejects operation with both dst and archive', () => {
    expect(() =>
      normalizeBatchDocument({
        version: 1,
        operations: [{ src: '/a', dst: '/b', archive: true }],
      }),
    ).toThrow(/exactly one of/);
  });

  it('rejects operation with neither dst nor archive', () => {
    expect(() =>
      normalizeBatchDocument({
        version: 1,
        operations: [{ src: '/a' }],
      }),
    ).toThrow(/exactly one of/);
  });

  it('throws on continue_from (reserved but not implemented)', () => {
    // Codex 4a + Gemini 4: must not silently ignore control-flow directive
    expect(() =>
      normalizeBatchDocument({
        version: 1,
        operations: [{ src: '/a', dst: '/b' }],
        continue_from: 'some-uuid',
      }),
    ).toThrow(/not yet executable|continue_from/);
  });

  it('parses archive_to correctly (snake_case and camelCase)', () => {
    const snake = normalizeBatchDocument({
      version: 1,
      operations: [{ src: '/a', archive: true, archive_to: '历史脚本' }],
    });
    expect(snake.operations[0].archiveTo).toBe('历史脚本');

    const camel = normalizeBatchDocument({
      version: 1,
      operations: [{ src: '/a', archive: true, archiveTo: '空项目' }],
    });
    expect(camel.operations[0].archiveTo).toBe('空项目');
  });

  it('respects stop_on_error defaults', () => {
    const doc = normalizeBatchDocument({
      version: 1,
      defaults: { stop_on_error: false, dry_run: true },
      operations: [{ src: '/a', dst: '/b' }],
    });
    expect(doc.defaults?.stopOnError).toBe(false);
    expect(doc.defaults?.dryRun).toBe(true);
  });
});
