import { describe, expect, it } from 'vitest';
import { parseFlags } from '../../src/cli/project.js';

describe('parseFlags', () => {
  it('parses project CLI flags without consuming positional args', () => {
    expect(
      parseFlags([
        '--yes',
        '--force',
        '--dry-run',
        '--archive',
        '--to',
        'archived-done',
        '--note',
        'cleanup',
        '--format',
        'md',
        '--include-committed',
        '--since',
        '2026-06-01',
        '/old',
        '/new',
      ]),
    ).toEqual({
      positional: ['/old', '/new'],
      yes: true,
      force: true,
      dryRun: true,
      archive: true,
      archiveTo: 'archived-done',
      note: 'cleanup',
      format: 'md',
      includeCommitted: true,
      since: '2026-06-01',
    });
  });
});
