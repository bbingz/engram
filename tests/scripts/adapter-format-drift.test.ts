import { describe, expect, it } from 'vitest';
import {
  alignBaselineWithMatrix,
  assertNoUserPathKeys,
  type BaselineFile,
  checkBaselineSchemaVersion,
  compareFingerprints,
  compareVersions,
  evaluateFreshness,
  type FormatMatrixEntry,
  fingerprintRecords,
  PREVALENCE_THRESHOLD,
  toBaselineFile,
} from '../../scripts/check-adapter-format-drift.js';

const baseEntry = (
  over: Partial<FormatMatrixEntry> = {},
): FormatMatrixEntry => ({
  sources: ['claude-code'],
  roots: ['~/.claude/projects'],
  glob: '**/*.jsonl',
  excludeGlobs: ['**/subagents/**'],
  requiredTypes: ['user', 'assistant'],
  versionField: '$.version',
  max_verified_version: '2.1.218',
  last_checked_utc: '2026-07-24T00:00:00Z',
  monitored: true,
  docs: ['docs/session-formats/claude-code.md'],
  ...over,
});

describe('compareVersions', () => {
  it('orders prerelease alphas numerically', () => {
    expect(compareVersions('0.146.0-alpha.10', '0.146.0-alpha.6')).toBe(1);
  });
  it('orders patch versions numerically', () => {
    expect(compareVersions('2.1.9', '2.1.10')).toBe(-1);
  });
  it('orders major.minor.patch', () => {
    expect(compareVersions('2.1.218', '2.1.58')).toBe(1);
    expect(compareVersions('2.2.0', '2.1.218')).toBe(1);
  });
  it('release beats prerelease of same core', () => {
    expect(compareVersions('0.146.0', '0.146.0-alpha.6')).toBe(1);
  });
  it('throws on unparseable', () => {
    expect(() => compareVersions('not-a-version', '1.0.0')).toThrow(
      /unparseable/,
    );
  });
});

describe('compareFingerprints', () => {
  const makeBaseline = (
    keys: Record<string, number>,
    corpusFiles = 200,
  ): BaselineFile => ({
    schemaVersion: 1,
    format: 'claude-code',
    sources: ['claude-code'],
    acceptedAtUtc: '2026-07-24T00:00:00Z',
    acceptedNote: 'test',
    vendorVersions: { min: '2.1.218', max: '2.1.218' },
    corpusFiles,
    corpusNewestMtimeUtc: '2026-07-24T00:00:00Z',
    sampling: { headLines: 200, tailLines: 800, excludeGlobs: [] },
    digest: 'sha256:test',
    buckets: {
      'record:assistant': {
        files: corpusFiles,
        records: corpusFiles,
        keys,
      },
    },
    note: 'test',
  });

  it('flags high-prevalence new keys as DRIFT', () => {
    const baseline = makeBaseline({ type: 200, message: 200 });
    const observed = fingerprintRecords('claude-code', [
      { type: 'assistant', message: {}, attributionPolicy: 1 },
      { type: 'assistant', message: {}, attributionPolicy: 1 },
    ]);
    // Force prevalence: both files would need attributionPolicy on all files.
    // fingerprintRecords treats all records as one file — so prevalence is 1.0.
    const findings = compareFingerprints(observed, baseline);
    expect(
      findings.some(
        (f) => f.kind === 'DRIFT' && f.line.includes('attributionPolicy'),
      ),
    ).toBe(true);
  });

  it('flags new high-prevalence buckets as DRIFT', () => {
    const baseline = makeBaseline({ type: 200 });
    const observed = fingerprintRecords('claude-code', [
      { type: 'pr-comment', foo: 1 },
    ]);
    const findings = compareFingerprints(observed, baseline);
    expect(
      findings.some(
        (f) => f.kind === 'DRIFT' && f.line.includes('record:pr-comment'),
      ),
    ).toBe(true);
  });

  it('reports missing baseline keys only when baseline prevalence >= threshold', () => {
    const rareCount = Math.floor(200 * (PREVALENCE_THRESHOLD - 0.1));
    const baseline = makeBaseline({
      type: 200,
      rareKey: rareCount,
      commonKey: 200,
    });
    const observed = fingerprintRecords('claude-code', [
      { type: 'assistant', typex: 1 },
    ]);
    // observed has no commonKey / rareKey
    observed.buckets['record:assistant'] = {
      files: 30,
      records: 30,
      keys: { type: 30 },
    };
    observed.corpusFiles = 30;
    const findings = compareFingerprints(observed, baseline);
    expect(
      findings.some((f) => f.kind === 'info' && f.line.includes('commonKey')),
    ).toBe(true);
    expect(findings.some((f) => f.line.includes('rareKey'))).toBe(false);
  });

  it('emits exactly one novel-rare note when observed prevalence is below threshold', () => {
    const baseline = makeBaseline({ type: 200, message: 200 });
    // 1/30 files with a new key → prevalence ≈ 0.033 < 0.5
    const observed = fingerprintRecords('claude-code', [
      { type: 'assistant', message: {} },
    ]);
    observed.corpusFiles = 30;
    observed.buckets['record:assistant'] = {
      files: 30,
      records: 30,
      keys: { type: 30, message: 30, rareNovelKey: 1 },
    };
    const findings = compareFingerprints(observed, baseline);
    const novelNotes = findings.filter(
      (f) =>
        f.kind === 'note' &&
        f.line.includes('rareNovelKey') &&
        f.line.includes('novel-rare'),
    );
    expect(novelNotes).toHaveLength(1);
    expect(
      findings.some(
        (f) => f.kind === 'DRIFT' && f.line.includes('rareNovelKey'),
      ),
    ).toBe(false);
  });
});

describe('alignBaselineWithMatrix', () => {
  const entry = baseEntry({ max_verified_version: '2.1.218' });

  it('desync when baseline.max < matrix.max_verified_version', () => {
    const result = alignBaselineWithMatrix(
      {
        format: 'claude-code',
        vendorVersions: { min: '2.1.100', max: '2.1.100' },
      },
      'claude-code',
      entry,
    );
    expect(result.status).toBe('desync');
    if (result.status === 'desync') {
      expect(result.message).toMatch(/baseline\/matrix desync for claude-code/);
      expect(result.message).toMatch(/2\.1\.100.*2\.1\.218/);
    }
  });

  it('stale_baseline when baseline.max > matrix.max_verified_version', () => {
    const result = alignBaselineWithMatrix(
      {
        format: 'claude-code',
        vendorVersions: { min: '2.1.300', max: '2.1.300' },
      },
      'claude-code',
      entry,
    );
    expect(result.status).toBe('stale_baseline');
  });

  it('ok when versions equal', () => {
    const result = alignBaselineWithMatrix(
      {
        format: 'claude-code',
        vendorVersions: { min: '2.1.218', max: '2.1.218' },
      },
      'claude-code',
      entry,
    );
    expect(result.status).toBe('ok');
  });
});

describe('checkBaselineSchemaVersion', () => {
  it('hard-fails unknown schemaVersion', () => {
    const result = checkBaselineSchemaVersion({ schemaVersion: 99 }, 'codex');
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.message).toMatch(/unsupported baseline schemaVersion 99/);
    }
  });

  it('accepts current schemaVersion', () => {
    expect(checkBaselineSchemaVersion({ schemaVersion: 1 }, 'codex').ok).toBe(
      true,
    );
  });
});

describe('assertNoUserPathKeys', () => {
  it('throws on path-shaped keys (accept/write path contract)', () => {
    expect(() => assertNoUserPathKeys(['type', '/Users/me/secret'])).toThrow(
      /user-path-shaped key/,
    );
    expect(() => assertNoUserPathKeys(['type', 'message.md'])).toThrow(
      /user-path-shaped key/,
    );
    expect(() => assertNoUserPathKeys(['type', 'message'])).not.toThrow();
  });
});

describe('evaluateFreshness', () => {
  const entry = baseEntry();

  it('no_local_sample when roots absent', () => {
    const fp = fingerprintRecords('claude-code', []);
    fp.rootsPresent = 0;
    fp.globMatches = 0;
    const state = evaluateFreshness(fp, entry);
    expect(state.state).toBe('no_local_sample');
  });

  it('blocked_required_type_absent when glob matched but nothing selected', () => {
    const fp = fingerprintRecords('claude-code', []);
    fp.rootsPresent = 1;
    fp.globMatches = 30;
    fp.corpusFiles = 0;
    const state = evaluateFreshness(fp, entry);
    expect(state.state).toBe('blocked_required_type_absent');
    if (state.state === 'blocked_required_type_absent') {
      expect(state.reason).toMatch(/under ~\/\.claude\/projects/);
      expect(state.reason).toMatch(/30 files scanned/);
    }
  });

  it('blocked_stale_baseline when corpus version ahead of matrix', () => {
    const fp = fingerprintRecords(
      'claude-code',
      [{ type: 'assistant', version: '2.1.300' }],
      { versionField: '$.version' },
    );
    fp.rootsPresent = 1;
    fp.globMatches = 1;
    fp.corpusFiles = 1;
    fp.corpusNewestMtimeUtc = new Date().toISOString();
    fp.vendorVersions = { min: '2.1.300', max: '2.1.300' };
    const state = evaluateFreshness(fp, entry);
    expect(state.state).toBe('blocked_stale_baseline');
  });

  it('stale_local_toolchain when observed below max_verified', () => {
    const fp = fingerprintRecords(
      'claude-code',
      [{ type: 'assistant', version: '2.1.100' }],
      { versionField: '$.version' },
    );
    fp.rootsPresent = 1;
    fp.globMatches = 1;
    fp.corpusFiles = 1;
    fp.corpusNewestMtimeUtc = new Date().toISOString();
    fp.vendorVersions = { min: '2.1.100', max: '2.1.100' };
    const state = evaluateFreshness(fp, entry);
    expect(state.state).toBe('stale_local_toolchain');
  });

  it('blocked_stale_sample when newest mtime too old', () => {
    const fp = fingerprintRecords('claude-code', [{ type: 'assistant' }]);
    fp.rootsPresent = 1;
    fp.globMatches = 1;
    fp.corpusFiles = 1;
    fp.corpusNewestMtimeUtc = '2026-01-01T00:00:00.000Z';
    fp.vendorVersions = { min: '2.1.218', max: '2.1.218' };
    const state = evaluateFreshness(
      fp,
      entry,
      new Date('2026-07-24T00:00:00Z'),
    );
    expect(state.state).toBe('blocked_stale_sample');
  });
});

describe('toBaselineFile', () => {
  it('embeds schemaVersion and digest', () => {
    const fp = fingerprintRecords('claude-code', [
      { type: 'user', cwd: '/tmp' },
      { type: 'assistant', message: {} },
    ]);
    const baseline = toBaselineFile(fp, baseEntry(), 'seed');
    expect(baseline.schemaVersion).toBe(1);
    expect(baseline.digest.startsWith('sha256:')).toBe(true);
    expect(baseline.acceptedNote).toBe('seed');
  });
});
