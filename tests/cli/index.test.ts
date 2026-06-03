import { describe, expect, it } from 'vitest';
import { dispatchCli, formatCliError } from '../../src/cli/index.js';

describe('dispatchCli', () => {
  it('routes logs to the logs subcommand main', async () => {
    const calls: unknown[][] = [];
    const imported: string[] = [];

    await dispatchCli(['logs', '--limit', '5'], async (specifier) => {
      imported.push(specifier);
      return {
        main: (...args: unknown[]) => {
          calls.push(args);
        },
      };
    });

    expect(imported).toEqual(['./logs.js']);
    expect(calls).toEqual([[['--limit', '5']]]);
  });

  it('passes health and diagnose mode through to the health module', async () => {
    const calls: unknown[][] = [];

    await dispatchCli(['diagnose', '--since', '1h'], async () => ({
      main: (...args: unknown[]) => {
        calls.push(args);
      },
    }));

    expect(calls).toEqual([['diagnose', ['--since', '1h']]]);
  });

  it('loads resume module without loading the MCP server', async () => {
    const imported: string[] = [];

    await dispatchCli(['--resume', 'abc123'], async (specifier) => {
      imported.push(specifier);
      return {};
    });

    expect(imported).toEqual(['./resume.js']);
  });

  it('loads MCP server by default', async () => {
    const imported: string[] = [];

    await dispatchCli([], async (specifier) => {
      imported.push(specifier);
      return {};
    });

    expect(imported).toEqual(['../index.js']);
  });

  it('propagates dynamic import failures to the top-level catch', async () => {
    await expect(
      dispatchCli(['project'], async () => {
        throw new Error('load failed');
      }),
    ).rejects.toThrow('load failed');
  });
});

describe('formatCliError', () => {
  it('formats Error and non-Error failures', () => {
    expect(formatCliError(new Error('load failed'))).toContain('load failed');
    expect(formatCliError('plain failure')).toBe('plain failure');
  });
});
