// src/core/resume-coordinator.ts
import { execFileSync } from 'node:child_process';

export interface ResumeCommand {
  tool: string;
  command: string;
  args: string[];
  cwd: string;
}

export interface ResumeError {
  error: string;
  hint: string;
}

export type ResumeResult = ResumeCommand | ResumeError;

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
        args: ['--resume', sessionId],
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
