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

  it('reports the removed TypeScript resume entrypoint without importing it', async () => {
    const imported: string[] = [];

    await expect(
      dispatchCli(['--resume', 'abc123'], async (specifier) => {
        imported.push(specifier);
        return {};
      }),
    ).rejects.toThrow('The TypeScript MCP entrypoint was removed');

    expect(imported).toEqual([]);
  });

  it('reports the removed TypeScript MCP entrypoint by default', async () => {
    await expect(dispatchCli([], async () => ({}))).rejects.toThrow(
      'The TypeScript MCP entrypoint was removed',
    );
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
