// src/cli/resume.ts

import { readFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

interface SessionInfo {
  id: string;
  source: string;
  displayTitle: string;
  messageCount: number;
  startTime: string;
}

interface ResumeResult {
  tool?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  error?: string;
  hint?: string;
}

function getPort(): number {
  try {
    const settingsPath = join(
      process.env.HOME || '',
      '.engram',
      'settings.json',
    );
    const settings = JSON.parse(readFileSync(settingsPath, 'utf-8'));
    return settings.httpPort || 3457;
  } catch {
    return 3457;
  }
}

function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export function selectProjectSessions(
  apiSessions: unknown[],
  cwd: string,
): SessionInfo[] {
  const project = basename(cwd);

  return apiSessions
    .filter(
      (s): s is Record<string, unknown> => typeof s === 'object' && s !== null,
    )
    .filter((s) => s.cwd === cwd || s.project === project)
    .slice(0, 10)
    .map((s) => {
      const id = String(s.id ?? '');
      const displayTitle =
        s.custom_name || s.generated_title || s.summary || id.slice(-8);
      return {
        id,
        source: String(s.source ?? ''),
        displayTitle: String(displayTitle),
        messageCount: typeof s.message_count === 'number' ? s.message_count : 0,
        startTime: typeof s.start_time === 'string' ? s.start_time : '',
      };
    });
}

export function formatResumeCommand(command: string, args: string[]): string {
  return [command, ...args].join(' ');
}

export async function main() {
  const cwd = process.cwd();
  const port = getPort();
  const baseUrl = `http://127.0.0.1:${port}`;

  console.log(`Scanning sessions for ${cwd}...`);

  // Fetch recent sessions
  let sessions: SessionInfo[] = [];
  try {
    const url = `${baseUrl}/api/sessions?limit=10`;
    const res = await fetch(url);
    // biome-ignore lint/suspicious/noExplicitAny: API response shape is loosely typed
    const json = (await res.json()) as any;
    // Filter sessions matching current directory
    sessions = selectProjectSessions(json.sessions || [], cwd);
  } catch (_err) {
    console.error('Error: Could not connect to Engram daemon. Is it running?');
    process.exit(1);
  }

  if (sessions.length === 0) {
    console.log('No sessions found for this project.');
    process.exit(0);
  }

  // Display session list
  console.log(`\nRecent sessions in this project:\n`);
  sessions.forEach((s, i) => {
    const time = s.startTime ? relativeTime(s.startTime) : '';
    console.log(
      `  ${i + 1}. ${s.source} · ${s.displayTitle} · ${time} · ${s.messageCount} msgs`,
    );
  });

  // Prompt user to select
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise<string>((resolve) => {
    rl.question(
      `\nSelect session (1-${sessions.length}) or q to quit: `,
      resolve,
    );
  });
  rl.close();

  if (answer.toLowerCase() === 'q' || answer.trim() === '') {
    process.exit(0);
  }

  const idx = parseInt(answer, 10) - 1;
  if (Number.isNaN(idx) || idx < 0 || idx >= sessions.length) {
    console.error('Invalid selection.');
    process.exit(1);
  }

  const selected = sessions[idx];

  // Get resume command
  try {
    const res = await fetch(`${baseUrl}/api/session/${selected.id}/resume`, {
      method: 'POST',
    });
    const result = (await res.json()) as ResumeResult;

    if (result.error) {
      console.error(`Error: ${result.error}`);
      if (result.hint) console.error(`Hint: ${result.hint}`);
      process.exit(1);
    }

    if (result.command && result.args) {
      const fullCmd = formatResumeCommand(result.command, result.args);
      console.log(`\nLaunching: ${fullCmd}`);
      console.log(`Working directory: ${result.cwd || cwd}\n`);

      // Execute the command, replacing this process
      const { spawnSync } = await import('node:child_process');
      spawnSync(result.command, result.args, {
        cwd: result.cwd || cwd,
        stdio: 'inherit',
      });
    }
  } catch (_err) {
    console.error('Error: Could not connect to Engram daemon.');
    process.exit(1);
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (import.meta.url === invokedPath) {
  main().catch((err) => {
    console.error('Fatal error:', err);
    process.exit(1);
  });
}
