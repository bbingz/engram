import { describe, expect, it } from 'vitest';
import {
  archiveSuggestionOptions,
  formatMoveDryRunPlan,
  formatProjectCliError,
  normalizeProjectPath,
  parseProjectFlags,
} from '../../src/cli/project.js';

describe('project cli helpers', () => {
  it('parses move flags without touching the database', () => {
    const flags = parseProjectFlags([
      '/old',
      '/new',
      '--dry-run',
      '--force',
      '--note',
      'audit note',
      '-y',
    ]);

    expect(flags).toMatchObject({
      positional: ['/old', '/new'],
      dryRun: true,
      force: true,
      note: 'audit note',
      yes: true,
    });
  });

  it('passes archive category flags through to archive suggestion options', () => {
    const flags = parseProjectFlags([
      '~/old-script',
      '--to',
      'historical-scripts',
    ]);

    expect(archiveSuggestionOptions(flags)).toEqual({
      forceCategory: 'historical-scripts',
    });
  });

  it('formats move dry-run output with source roles, skips, issues, and git state', () => {
    const lines = formatMoveDryRunPlan('/old', '/new', {
      totalFilesPatched: 3,
      totalOccurrences: 5,
      perSource: [
        { id: 'claude-code', filesPatched: 2, occurrences: 4, issues: [] },
        {
          id: 'codex',
          filesPatched: 1,
          occurrences: 1,
          issues: [{ reason: 'too_large', path: '/old/huge.jsonl' }],
        },
      ],
      renamedDirs: [{ sourceId: 'claude-code' }],
      skippedDirs: [{ sourceId: 'iflow', reason: 'noop' }],
      git: { dirty: true, untrackedOnly: false },
    });

    const text = lines.join('\n');
    expect(text).toContain('mv  /old → /new');
    expect(text).toContain('claude-code: rename+patch');
    expect(text).toContain('codex: content patch');
    expect(text).toContain('iflow: encoded name unchanged');
    expect(text).toContain('[too_large] /old/huge.jsonl');
    expect(text).toContain('git: /old has uncommitted changes');
  });

  it('normalizes user paths consistently with CLI path resolution', () => {
    const home = '/Users/tester';
    expect(normalizeProjectPath('~/repo', home)).toBe('/Users/tester/repo');
    expect(normalizeProjectPath('relative/repo', home, '/work')).toBe(
      '/work/relative/repo',
    );
  });

  it('formats batch load errors without leaking a stack trace by default', async () => {
    const error = Object.assign(new Error('invalid batch file'), {
      name: 'YamlParseError',
      stack: 'YamlParseError: invalid batch file\n    at parser',
    });

    const message = await formatProjectCliError(error, {});

    expect(message).toContain('invalid batch file');
    expect(message).not.toContain('at parser');
  });
});
