import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const pluginRoot = resolve(repoRoot, 'integrations/claude-code/engram');

function read(rel: string): string {
  return readFileSync(resolve(pluginRoot, rel), 'utf8');
}

function listFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listFiles(full));
    else out.push(full);
  }
  return out;
}

describe('Claude Code plugin MVP contracts', () => {
  it('ships required plugin layout', () => {
    for (const rel of [
      '.claude-plugin/plugin.json',
      '.mcp.json',
      'hooks/hooks.json',
      'scripts/resolve-engram-helper',
      'scripts/engram-mcp',
      'scripts/session-start-context',
      'skills/catch-up/SKILL.md',
      'skills/remember/SKILL.md',
      'skills/handoff/SKILL.md',
    ]) {
      expect(existsSync(join(pluginRoot, rel)), rel).toBe(true);
    }
  });

  it('plugin.json and mcp/hooks manifests are valid JSON with expected names', () => {
    const plugin = JSON.parse(read('.claude-plugin/plugin.json')) as {
      name: string;
      hooks?: string;
      mcpServers: string;
    };
    expect(plugin.name).toBe('engram');
    // Claude Code automatically loads the standard hooks/hooks.json path.
    // Re-declaring that file in the manifest is a duplicate-hook load error.
    expect(plugin.hooks).toBeUndefined();
    expect(plugin.mcpServers).toBe('./.mcp.json');

    const mcp = JSON.parse(read('.mcp.json')) as {
      mcpServers: { engram: { command: string; args: string[] } };
    };
    const pluginRootVariable = '$' + '{CLAUDE_PLUGIN_ROOT}';
    expect(mcp.mcpServers.engram.command).toContain(
      `${pluginRootVariable}/scripts/engram-mcp`,
    );
    expect(mcp.mcpServers.engram.args).toEqual([]);

    const hooks = JSON.parse(read('hooks/hooks.json')) as {
      hooks: {
        SessionStart: Array<{
          matcher?: string;
          hooks: Array<{ type: string; command: string }>;
        }>;
        SessionEnd?: unknown;
        Stop?: unknown;
      };
    };
    const sessionStart = hooks.hooks.SessionStart;
    expect(sessionStart.length).toBeGreaterThan(0);
    const matcher = sessionStart[0]?.matcher ?? '';
    for (const source of ['startup', 'resume', 'clear', 'compact']) {
      expect(matcher.includes(source), source).toBe(true);
    }
    const handlers = sessionStart.flatMap((group) => group.hooks);
    expect(handlers.every((h) => h.type === 'command')).toBe(true);
    expect(
      handlers.some((h) => h.command.includes('session-start-context')),
    ).toBe(true);
    expect(handlers.some((h) => h.type === 'mcp_tool')).toBe(false);
    expect(hooks.hooks.SessionEnd).toBeUndefined();
    expect(hooks.hooks.Stop).toBeUndefined();
    expect(JSON.stringify(handlers)).not.toContain('save_insight');
  });

  it('wrappers are executable, fail-open for SessionStart, and avoid user-home paths', () => {
    for (const rel of [
      'scripts/resolve-engram-helper',
      'scripts/engram-mcp',
      'scripts/session-start-context',
    ]) {
      const mode = statSync(join(pluginRoot, rel)).mode;
      expect((mode & 0o111) !== 0, `${rel} should be executable`).toBe(true);
      const syntax = spawnSync('bash', ['-n', join(pluginRoot, rel)], {
        encoding: 'utf8',
      });
      expect(syntax.status, `${rel} bash -n: ${syntax.stderr}`).toBe(0);
    }

    const allText = listFiles(pluginRoot)
      .filter((p) => !p.endsWith('.png'))
      .map((p) => readFileSync(p, 'utf8'))
      .join('\n');
    expect(allText).not.toMatch(/\/Users\/[^/\s]+/);
    expect(allText).toContain('ENGRAM_CLI_PATH');
    expect(allText).toContain('ENGRAM_MCP_PATH');
    expect(allText).toContain('/Applications/Engram.app/Contents/Helpers');

    const sessionStart = read('scripts/session-start-context');
    expect(sessionStart).toContain('exit 0');
    expect(sessionStart).toContain('context');
    expect(sessionStart).toContain('8192');
    expect(sessionStart).not.toContain('save_insight');

    // Thin wrappers must not embed a second Swift binary.
    expect(existsSync(join(pluginRoot, 'bin'))).toBe(false);
    for (const file of listFiles(pluginRoot)) {
      expect(file.endsWith('.swift')).toBe(false);
      expect(file).not.toMatch(/EngramMCP$/);
      expect(file).not.toMatch(/EngramCLI$/);
    }
  });

  it('skills keep remember as the only save_insight path', () => {
    const catchUp = read('skills/catch-up/SKILL.md');
    const remember = read('skills/remember/SKILL.md');
    const handoff = read('skills/handoff/SKILL.md');

    expect(catchUp).toContain('get_context');
    expect(catchUp).toMatch(/do \*\*not\*\* call `save_insight`/i);
    expect(handoff).toMatch(/handoff|get_context/i);
    expect(handoff).toMatch(/do \*\*not\*\* call `save_insight`/i);
    expect(remember).toContain('save_insight');
    expect(remember).toMatch(/only/i);
    for (const skill of [catchUp, remember, handoff]) {
      expect(skill).toContain('disable-model-invocation: true');
    }

    // Automatic surfaces must never invoke save_insight (skills may mention it to forbid it).
    const autoSurfaces = `${read('hooks/hooks.json')}\n${read('scripts/session-start-context')}\n${read('scripts/engram-mcp')}`;
    expect(autoSurfaces).not.toContain('save_insight');
  });

  it('resolve-engram-helper honors env overrides and unicode/spaces cwd path through session-start', () => {
    const resolveHelper = join(pluginRoot, 'scripts/resolve-engram-helper');
    const missing = spawnSync('bash', [resolveHelper, 'cli'], {
      encoding: 'utf8',
      env: {
        ...process.env,
        ENGRAM_CLI_PATH: '/tmp/definitely-missing-engram-cli',
        PATH: '/usr/bin:/bin',
      },
    });
    // missing path should fail resolution (non-zero) without crashing bash
    expect(missing.status).not.toBe(0);

    const temporaryRoot = mkdtempSync(
      join(tmpdir(), 'engram-plugin path-with-spaces-'),
    );
    const unicodeCwd = join(temporaryRoot, '项目-engram-test');
    mkdirSync(unicodeCwd, { recursive: true });
    try {
      const sessionStart = join(pluginRoot, 'scripts/session-start-context');
      const failOpen = spawnSync('bash', [sessionStart], {
        encoding: 'utf8',
        cwd: unicodeCwd,
        env: {
          ...process.env,
          ENGRAM_CLI_PATH: '/tmp/definitely-missing-engram-cli',
          CLAUDE_PROJECT_DIR: unicodeCwd,
          PATH: '/usr/bin:/bin',
        },
        input: JSON.stringify({
          hook_event_name: 'SessionStart',
          source: 'startup',
          session_id: 'test',
        }),
      });
      expect(failOpen.error).toBeUndefined();
      expect(failOpen.status).toBe(0);
      expect(failOpen.stdout.trim()).toBe('');
    } finally {
      rmSync(temporaryRoot, { recursive: true, force: true });
    }
  });

  it('optionally validates with claude plugin validate when installed', () => {
    const which = spawnSync('bash', ['-lc', 'command -v claude'], {
      encoding: 'utf8',
    });
    if (which.status !== 0 || !which.stdout.trim()) {
      // Not a hard failure for CI hosts without Claude Code CLI.
      expect(true).toBe(true);
      return;
    }
    const result = spawnSync(
      which.stdout.trim(),
      ['plugin', 'validate', pluginRoot],
      { encoding: 'utf8' },
    );
    expect(result.status, `${result.stdout}\n${result.stderr}`).toBe(0);
  });

  it('EngramCLI context command source remains the production get_context bridge', () => {
    const cli = readFileSync(
      resolve(repoRoot, 'macos/Shared/Service/EngramCLIContextCommand.swift'),
      'utf8',
    );
    expect(cli).toContain('get_context');
    expect(cli).toContain('additionalContext');
    expect(cli).toContain('8_192');
    expect(cli).toContain('timeout');
    expect(cli).not.toContain('save_insight');
    expect(cli).not.toMatch(/INSERT INTO/i);

    const main = readFileSync(
      resolve(repoRoot, 'macos/EngramCLI/main.swift'),
      'utf8',
    );
    expect(main).toContain('runContextCommandIfRequested');
  });
});
