// src/cli/resume.ts

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

interface SessionInfo {
  id: string;
  source: string;
  displayTitle: string;
  messageCount: number;
  startTime: string;
  cwd?: string;
  project?: string;
}

interface ResumeResult {
  tool?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  error?: string;
  hint?: string;
}

type FetchLike = (
  input: string,
  init?: { method?: string },
) => Promise<{ json(): Promise<unknown> }>;

type SpawnSyncLike = (
  command: string,
  args?: readonly string[],
  options?: { cwd?: string; stdio?: 'inherit' },
) => unknown;

interface RunResumeOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv | Record<string, string | undefined>;
  fetch?: FetchLike;
  input?: (question: string) => Promise<string>;
  output?: (line: string) => void;
  error?: (line: string) => void;
  spawnSync?: SpawnSyncLike;
}

interface LaunchCommand {
  command: 'claude' | 'codex' | 'gemini' | 'open';
  args: string[];
  cwd: string;
}

function getPort(
  env: NodeJS.ProcessEnv | Record<string, string | undefined>,
): number {
  try {
    const settingsPath = join(env.HOME || '', '.engram', 'settings.json');
    const settings = JSON.parse(readFileSync(settingsPath, 'utf-8'));
    return settings.httpPort || 3457;
  } catch {
    return 3457;
  }
}

export function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

async function prompt(question: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return await new Promise<string>((resolve) => {
      rl.question(question, resolve);
    });
  } finally {
    rl.close();
  }
}

function sessionList(value: unknown): SessionInfo[] {
  const object =
    value && typeof value === 'object'
      ? (value as Record<string, unknown>)
      : {};
  const rawSessions = Array.isArray(object.sessions) ? object.sessions : [];
  return rawSessions.map((raw) => {
    const s =
      raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
    return {
      id: String(s.id ?? ''),
      source: String(s.source ?? ''),
      displayTitle: String(
        s.custom_name ??
          s.generated_title ??
          s.summary ??
          String(s.id ?? '').slice(-8),
      ),
      messageCount: typeof s.message_count === 'number' ? s.message_count : 0,
      startTime: typeof s.start_time === 'string' ? s.start_time : '',
      cwd: typeof s.cwd === 'string' ? s.cwd : undefined,
      project: typeof s.project === 'string' ? s.project : undefined,
    };
  });
}

function buildLaunchCommand(
  session: SessionInfo,
  resume: ResumeResult,
  fallbackCwd: string,
): LaunchCommand {
  const cwd = resume.cwd || fallbackCwd;
  switch (session.source) {
    case 'claude-code':
      return { command: 'claude', args: ['--resume', session.id], cwd };
    case 'codex':
      return { command: 'codex', args: ['--resume', session.id], cwd };
    case 'gemini-cli':
      return { command: 'gemini', args: ['--resume', session.id], cwd };
    case 'cursor':
      return { command: 'open', args: ['-a', 'Cursor', cwd], cwd };
    default:
      return { command: 'open', args: [cwd], cwd };
  }
}

export async function runResume(
  options: RunResumeOptions = {},
): Promise<number> {
  const cwd = options.cwd ?? process.cwd();
  const env = options.env ?? process.env;
  const fetchImpl = options.fetch ?? fetch;
  const write = options.output ?? console.log;
  const writeError = options.error ?? console.error;
  const port = getPort(env);
  const baseUrl = `http://127.0.0.1:${port}`;

  // Get project name from cwd
  const project = cwd.split('/').pop() || '';

  write(`Scanning sessions for ${cwd}...`);

  // Fetch recent sessions
  let sessions: SessionInfo[] = [];
  try {
    const url = `${baseUrl}/api/sessions?limit=10`;
    const res = await fetchImpl(url);
    const json = await res.json();
    // Filter sessions matching current directory
    sessions = sessionList(json)
      .filter((s) => s.cwd === cwd || s.project === project)
      .slice(0, 10)
      .map((s) => ({
        id: s.id,
        source: s.source,
        displayTitle: s.displayTitle,
        messageCount: s.messageCount,
        startTime: s.startTime,
      }));
  } catch (_err) {
    writeError('Error: Could not connect to Engram daemon. Is it running?');
    return 1;
  }

  if (sessions.length === 0) {
    write('No sessions found for this project.');
    return 0;
  }

  // Display session list
  write(`\nRecent sessions in this project:\n`);
  sessions.forEach((s, i) => {
    const time = s.startTime ? relativeTime(s.startTime) : '';
    write(
      `  ${i + 1}. ${s.source} · ${s.displayTitle} · ${time} · ${s.messageCount} msgs`,
    );
  });

  // Prompt user to select
  const answer = await (options.input ?? prompt)(
    `\nSelect session (1-${sessions.length}) or q to quit: `,
  );

  if (answer.toLowerCase() === 'q' || answer.trim() === '') {
    return 0;
  }

  const idx = parseInt(answer, 10) - 1;
  if (Number.isNaN(idx) || idx < 0 || idx >= sessions.length) {
    writeError('Invalid selection.');
    return 1;
  }

  const selected = sessions[idx];

  // Get resume command
  try {
    const res = await fetchImpl(
      `${baseUrl}/api/session/${selected.id}/resume`,
      {
        method: 'POST',
      },
    );
    const result = (await res.json()) as ResumeResult;

    if (result.error) {
      writeError(`Error: ${result.error}`);
      if (result.hint) writeError(`Hint: ${result.hint}`);
      return 1;
    }

    if (result.command && result.args) {
      const launch = buildLaunchCommand(selected, result, cwd);
      const fullCmd = [launch.command, ...launch.args].join(' ');
      write(`\nLaunching: ${fullCmd}`);
      write(`Working directory: ${launch.cwd}\n`);

      const spawnSync =
        options.spawnSync ?? (await import('node:child_process')).spawnSync;
      switch (launch.command) {
        case 'claude':
          spawnSync('claude', launch.args, {
            cwd: launch.cwd,
            stdio: 'inherit',
          });
          break;
        case 'codex':
          spawnSync('codex', launch.args, {
            cwd: launch.cwd,
            stdio: 'inherit',
          });
          break;
        case 'gemini':
          spawnSync('gemini', launch.args, {
            cwd: launch.cwd,
            stdio: 'inherit',
          });
          break;
        case 'open':
          spawnSync('open', launch.args, {
            cwd: launch.cwd,
            stdio: 'inherit',
          });
          break;
      }
    }
    return 0;
  } catch (_err) {
    writeError('Error: Could not connect to Engram daemon.');
    return 1;
  }
}

async function main(): Promise<void> {
  const code = await runResume();
  process.exit(code);
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((err) => {
    console.error('Fatal error:', err);
    process.exit(1);
  });
}
