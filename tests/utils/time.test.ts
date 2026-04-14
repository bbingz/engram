// tests/utils/time.test.ts

import { describe, expect, it } from 'vitest';
import {
  getLocalTimeRange,
  toLocalDate,
  toLocalDateTime,
} from '../../src/utils/time.js';

describe('toLocalDateTime', () => {
  it('formats a valid UTC ISO string as YYYY-MM-DD HH:mm:ss', () => {
    const result = toLocalDateTime('2025-06-15T14:30:00Z');
    expect(result).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);
  });

  it('returns empty string for undefined', () => {
    expect(toLocalDateTime(undefined)).toBe('');
  });

  it('returns empty string for empty string', () => {
    expect(toLocalDateTime('')).toBe('');
  });
});

describe('toLocalDate', () => {
  it('formats a valid UTC ISO string as YYYY-MM-DD', () => {
    const result = toLocalDate('2025-06-15T14:30:00Z');
    expect(result).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('returns empty string for undefined', () => {
    expect(toLocalDate(undefined)).toBe('');
  });
});

describe('getLocalTimeRange', () => {
  it('computes Shanghai local-day boundaries', () => {
    const range = getLocalTimeRange(
      new Date('2026-04-14T13:56:07.817Z'),
      'Asia/Shanghai',
    );

    expect(range.startUtcIso).toBe('2026-04-13T16:00:00.000Z');
    expect(range.endUtcIso).toBe('2026-04-14T16:00:00.000Z');
    expect(range.localDate).toBe('2026-04-14');
  });

  it('uses actual DST transition boundaries instead of a fixed 24h window', () => {
    const range = getLocalTimeRange(
      new Date('2026-03-08T12:00:00.000Z'),
      'America/New_York',
    );

    expect(range.startUtcIso).toBe('2026-03-08T05:00:00.000Z');
    expect(range.endUtcIso).toBe('2026-03-09T04:00:00.000Z');
  });
});
