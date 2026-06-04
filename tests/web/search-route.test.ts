import { describe, expect, it } from 'vitest';
import { searchFailureWarning } from '../../src/web/routes/search.js';

describe('searchFailureWarning', () => {
  it('does not expose internal exception messages', () => {
    expect(searchFailureWarning(new Error('SQLITE_CORRUPT: secret path'))).toBe(
      'Search failed. Check server logs for details.',
    );
  });
});
