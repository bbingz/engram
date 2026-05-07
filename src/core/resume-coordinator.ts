// src/core/resume-coordinator.ts
import { execFileSync } from 'node:child_process';

interface ResumeCommand {
  tool: string;
  command: string;
  args: string[];
  cwd: string;
}

interface ResumeError {
  error: string;
  hint: string;
}

type ResumeResult = ResumeCommand | ResumeError;

export interface ResumeInspection {
  capability: 'supported' | 'legacy' | 'fallback' | 'unsupported';
  tool?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  evidence:
    | 'official_doc'
    | 'local_help'
    | 'observed_jsonl'
    | 'heuristic'
    | 'fallback';
  warning?: string;
}

function which(cmd: string): string | null {
  try {
    return execFileSync('which', [cmd], {
      encoding: 'utf-8',
      timeout: 5000,
    }).trim();
  } catch {
    return null;
  }
}

function detectTool(source: string): { path: string; name: string } | null {
  const toolMap: Record<string, string> = {
    'claude-code': 'claude',
    codex: 'codex',
    'gemini-cli': 'gemini',
  };
  const cmd = toolMap[source];
  if (!cmd) return null;
  const path = which(cmd);
  if (!path) return null;
  return { path, name: cmd };
}

function codexArgs(sessionId: string): string[] {
  return ['resume', sessionId];
}

export function buildResumeCommand(
  source: string,
  sessionId: string,
  cwd: string,
): ResumeResult {
  switch (source) {
    case 'claude-code': {
      const tool = detectTool(source);
      if (!tool)
        return {
          error: 'Claude CLI not found',
          hint: 'Install: npm install -g @anthropic-ai/claude-code',
        };
      return {
        tool: 'claude',
        command: tool.path,
        args: ['--resume', sessionId],
        cwd,
      };
    }
    case 'codex': {
      const tool = detectTool(source);
      if (!tool)
        return {
          error: 'Codex CLI not found',
          hint: 'Install: npm install -g @openai/codex',
        };
      return {
        tool: 'codex',
        command: tool.path,
        args: codexArgs(sessionId),
        cwd,
      };
    }
    case 'gemini-cli': {
      const tool = detectTool(source);
      if (!tool)
        return {
          error: 'Gemini CLI not found',
          hint: 'Install: npm install -g @google/gemini-cli',
        };
      return {
        tool: 'gemini',
        command: tool.path,
        args: ['--resume', sessionId],
        cwd,
      };
    }
    case 'cursor':
      return {
        tool: 'cursor',
        command: 'open',
        args: ['-a', 'Cursor', cwd],
        cwd,
      };
    default:
      return { tool: source, command: 'open', args: [cwd], cwd };
  }
}

interface SourceMapping {
  tool: string;
  cmd: string;
  args: (id: string) => string[];
}

const RESUME_SOURCES: Record<string, SourceMapping> = {
  'claude-code': {
    tool: 'claude',
    cmd: 'claude',
    args: (id) => ['--resume', id],
  },
  codex: {
    tool: 'codex',
    cmd: 'codex',
    args: codexArgs,
  },
  'gemini-cli': {
    tool: 'gemini',
    cmd: 'gemini',
    args: (id) => ['--resume', id],
  },
};

/**
 * Pure resume command inspector. Does not invoke external CLIs.
 *
 * If the caller does not pass `resolveCommand`, no PATH lookup is performed:
 * a known CLI source (codex/claude-code/gemini-cli) returns
 * `capability: 'unsupported'` with `tool`, `cwd`, `evidence: 'fallback'`,
 * and a warning explaining that command resolution was skipped — but no
 * `command` or `args`. Pass `resolveCommand` (e.g. `which`) only when the
 * caller is willing to invoke a subprocess.
 */
export function buildResumeInspection(
  source: string,
  sessionId: string,
  cwd: string,
  opts?: { resolveCommand?: (cmd: string) => string | null },
): ResumeInspection {
  const mapping = RESUME_SOURCES[source];
  if (mapping) {
    if (!opts?.resolveCommand) {
      return {
        capability: 'unsupported',
        tool: mapping.tool,
        cwd,
        evidence: 'fallback',
        warning: `${mapping.cmd} command path not resolved (no resolver provided)`,
      };
    }
    const command = opts.resolveCommand(mapping.cmd);
    if (command) {
      return {
        capability: 'supported',
        tool: mapping.tool,
        command,
        args: mapping.args(sessionId),
        cwd,
        evidence: 'local_help',
      };
    }
    return {
      capability: 'unsupported',
      tool: mapping.tool,
      cwd,
      evidence: 'fallback',
      warning: `${mapping.cmd} CLI not found in PATH`,
    };
  }
  if (source === 'cursor') {
    return {
      capability: 'fallback',
      tool: 'cursor',
      command: 'open',
      args: ['-a', 'Cursor', cwd],
      cwd,
      evidence: 'fallback',
    };
  }
  return {
    capability: 'fallback',
    tool: source,
    command: 'open',
    args: [cwd],
    cwd,
    evidence: 'fallback',
  };
}
