import { describe, expect, it } from 'vitest';
import {
  parseOptionalPositiveIntParam,
  parsePaginationParams,
} from '../../src/web.js';

describe('web query parameter parsing', () => {
  it('rejects invalid pagination offset and limit values', () => {
    expect(parsePaginationParams('abc', '20', 20, 100)).toEqual({
      ok: false,
      error: 'offset must be a non-negative integer',
    });
    expect(parsePaginationParams('-1', '20', 20, 100)).toEqual({
      ok: false,
      error: 'offset must be a non-negative integer',
    });
    expect(parsePaginationParams('0', 'nan', 20, 100)).toEqual({
      ok: false,
      error: 'limit must be a positive integer',
    });
    expect(parsePaginationParams('0', '0', 20, 100)).toEqual({
      ok: false,
      error: 'limit must be a positive integer',
    });
  });

  it('defaults and clamps pagination values', () => {
    expect(parsePaginationParams(undefined, undefined, 20, 100)).toEqual({
      ok: true,
      offset: 0,
      limit: 20,
    });
    expect(parsePaginationParams('5', '500', 20, 100)).toEqual({
      ok: true,
      offset: 5,
      limit: 100,
    });
  });

  it('rejects invalid optional positive integer values', () => {
    expect(parseOptionalPositiveIntParam('limit', 'abc', 100)).toEqual({
      ok: false,
      error: 'limit must be a positive integer',
    });
    expect(parseOptionalPositiveIntParam('limit', '-1', 100)).toEqual({
      ok: false,
      error: 'limit must be a positive integer',
    });
    expect(parseOptionalPositiveIntParam('limit', '0', 100)).toEqual({
      ok: false,
      error: 'limit must be a positive integer',
    });
  });

  it('allows absent optional positive integers and clamps large values', () => {
    expect(parseOptionalPositiveIntParam('limit', undefined, 100)).toEqual({
      ok: true,
      value: undefined,
    });
    expect(parseOptionalPositiveIntParam('limit', '250', 100)).toEqual({
      ok: true,
      value: 100,
    });
  });
});
