// tests/utils/time.test.ts

import { describe, expect, it } from 'vitest';
import { toLocalDate, toLocalDateTime } from '../../src/utils/time.js';

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
