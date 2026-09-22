import { describe, expect, it } from 'vitest';
import { SOURCE_NAMES } from '../../src/adapters/types.js';
import { getAdapter } from '../../src/core/bootstrap.js';

describe('reference bootstrap adapters', () => {
  it('keeps pi and grok out of the TypeScript adapter entry (repro)', () => {
    expect(SOURCE_NAMES).toEqual(expect.arrayContaining(['pi', 'grok']));
    expect(getAdapter('pi')).toBeUndefined();
    expect(getAdapter('grok')).toBeUndefined();

    const registered = SOURCE_NAMES.filter((name) => getAdapter(name) != null);
    expect(registered).not.toContain('pi');
    expect(registered).not.toContain('grok');
    expect(registered).toHaveLength(15);
  });
});
