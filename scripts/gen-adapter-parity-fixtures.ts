import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import Database from 'better-sqlite3';
import { AntigravityAdapter } from '../src/adapters/antigravity.js';
import { ClaudeCodeAdapter } from '../src/adapters/claude-code.js';
import { ClineAdapter } from '../src/adapters/cline.js';
import { CodexAdapter } from '../src/adapters/codex.js';
import { CopilotAdapter } from '../src/adapters/copilot.js';
import { CursorAdapter } from '../src/adapters/cursor.js';
import { GeminiCliAdapter } from '../src/adapters/gemini-cli.js';
import { IflowAdapter } from '../src/adapters/iflow.js';
import { KimiAdapter } from '../src/adapters/kimi.js';
import { OpenCodeAdapter } from '../src/adapters/opencode.js';
import { QwenAdapter } from '../src/adapters/qwen.js';
import type {
  Message,
  SessionAdapter,
  SourceName,
  ToolCall,
} from '../src/adapters/types.js';
import { VsCodeAdapter } from '../src/adapters/vscode.js';
import { WindsurfAdapter } from '../src/adapters/windsurf.js';

type SupportedFixtureSource = Exclude<SourceName, 'lobsterai' | 'minimax'>;

interface AdapterFixture {
  schemaVersion: 1;
  source: SupportedFixtureSource;
  inputPath: string;
  locator: string;
  sessionInfo: unknown;
  messages: Message[];
  toolCalls: ToolCall[];
  usageTotals: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens: number;
    cacheCreationTokens: number;
  };
  fileToolCounts: Record<string, Record<string, number>>;
  projectFields: Record<string, unknown>;
  insightFields: Record<string, unknown>;
  searchIndexFields: Record<string, unknown>;
  statsFields: Record<string, unknown>;
  failure: null;
  nodeVersion: string;
  generatedAtCommit: string;
}

const repoRoot = resolve(import.meta.dirname, '..');
const sourceFixtureRoot = join(repoRoot, 'tests/fixtures');
const supportedSources = [
  'antigravity',
  'claude-code',
  'cline',
  'codex',
  'copilot',
  'cursor',
  'gemini-cli',
  'iflow',
  'kimi',
  'opencode',
  'qwen',
  'vscode',
  'windsurf',
] as const satisfies readonly SupportedFixtureSource[];

const malformedCategories = [
  'invalidUtf8',
  'truncatedJSON',
  'truncatedJSONL',
  'malformedJSON',
  'malformedToolCall',
  'deeplyNestedRecord',
  'fileTooLarge',
  'messageLimitExceeded',
  'fileModifiedDuringParse',
] as const;

function parseArgs(argv = process.argv.slice(2)): { out: string } {
  const outIndex = argv.indexOf('--out');
  return {
    out:
      outIndex >= 0
        ? resolve(argv[outIndex + 1])
        : join(repoRoot, 'tests/fixtures/adapter-parity'),
  };
}

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson);
  if (!value || typeof value !== 'object') return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value).sort()) {
    out[key] = sortJson((value as Record<string, unknown>)[key]);
  }
  return out;
}

function stableJson(value: unknown): string {
  return `${JSON.stringify(sortJson(value), null, 2)}\n`;
}

function normalizeFixturePaths(value: unknown, root: string): unknown {
  if (typeof value === 'string') return value.split(root).join('<fixtureRoot>');
  if (Array.isArray(value)) {
    return value.map((item) => normalizeFixturePaths(item, root));
  }
  if (!value || typeof value !== 'object') return value;
  const out: Record<string, unknown> = {};
  for (const [key, nested] of Object.entries(value)) {
    out[key] = normalizeFixturePaths(nested, root);
  }
  return out;
}

function gitCommit(): string {
  try {
    return execFileSync('git', ['rev-parse', '--short', 'HEAD'], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return 'unknown';
  }
}

function copyFileFixture(from: string, to: string): string {
  mkdirSync(dirname(to), { recursive: true });
  cpSync(from, to);
  return to;
}

function copyDirFixture(from: string, to: string): string {
  mkdirSync(dirname(to), { recursive: true });
  cpSync(from, to, { recursive: true });
  return to;
}

function makeOpenCodeDb(dbPath: string): void {
  mkdirSync(dirname(dbPath), { recursive: true });
  rmSync(dbPath, { force: true });
  const db = new Database(dbPath);
  try {
    db.exec(`
      CREATE TABLE session (
        id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT,
        slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL,
        version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER,
        summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT,
        revert TEXT, permission TEXT,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
        time_compacting INTEGER, time_archived INTEGER
      );
      CREATE TABLE message (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
        data TEXT NOT NULL
      );
      CREATE TABLE part (
        id TEXT PRIMARY KEY, message_id TEXT NOT NULL,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
        data TEXT NOT NULL
      );
      INSERT INTO session VALUES (
        'ses_test001', 'proj_001', NULL, 'test-session', '/Users/test/my-project',
        '实现用户登录功能', '0.0.1', NULL, 3, 10, 2, NULL, NULL, NULL,
        1770000000000, 1770000060000, NULL, NULL
      );
      INSERT INTO message VALUES (
        'msg_001', 'ses_test001', 1770000001000, 1770000001000,
        '{"role":"user","time":{"created":1770000001000}}'
      );
      INSERT INTO part VALUES (
        'part_001', 'msg_001', 1770000001000, 1770000001000,
        '{"type":"text","text":"帮我实现登录功能"}'
      );
      INSERT INTO message VALUES (
        'msg_002', 'ses_test001', 1770000010000, 1770000010000,
        '{"role":"assistant","time":{"created":1770000010000,"completed":1770000015000}}'
      );
      INSERT INTO part VALUES (
        'part_002', 'msg_002', 1770000010000, 1770000010000,
        '{"type":"text","text":"好的，我来实现登录功能。"}'
      );
    `);
  } finally {
    db.close();
  }
}

function makeAdapter(source: SupportedFixtureSource, root: string) {
  const inputRoot = join(root, source, 'input');
  switch (source) {
    case 'codex': {
      copyFileFixture(
        join(sourceFixtureRoot, 'codex/sample.jsonl'),
        join(inputRoot, '2026/01/15/rollout-sample.jsonl'),
      );
      return { adapter: new CodexAdapter(inputRoot), inputRoot };
    }
    case 'claude-code': {
      copyFileFixture(
        join(sourceFixtureRoot, 'claude-code/sample.jsonl'),
        join(inputRoot, '-Users-test-my-project/sample.jsonl'),
      );
      return { adapter: new ClaudeCodeAdapter(inputRoot), inputRoot };
    }
    case 'gemini-cli': {
      copyFileFixture(
        join(sourceFixtureRoot, 'gemini/session-sample.json'),
        join(inputRoot, 'tmp/my-project/chats/session-sample.json'),
      );
      copyFileFixture(
        join(sourceFixtureRoot, 'gemini/projects.json'),
        join(inputRoot, 'projects.json'),
      );
      return {
        adapter: new GeminiCliAdapter(
          join(inputRoot, 'tmp'),
          join(inputRoot, 'projects.json'),
        ),
        inputRoot,
      };
    }
    case 'opencode': {
      const dbPath = join(inputRoot, 'sample.db');
      makeOpenCodeDb(dbPath);
      return { adapter: new OpenCodeAdapter(dbPath), inputRoot };
    }
    case 'iflow': {
      copyFileFixture(
        join(sourceFixtureRoot, 'iflow/sample.jsonl'),
        join(inputRoot, '-Users-test-my-project/session-sample.jsonl'),
      );
      return { adapter: new IflowAdapter(inputRoot), inputRoot };
    }
    case 'qwen': {
      copyFileFixture(
        join(sourceFixtureRoot, 'qwen/sample.jsonl'),
        join(inputRoot, '-Users-test-my-project/chats/sample.jsonl'),
      );
      return { adapter: new QwenAdapter(inputRoot), inputRoot };
    }
    case 'kimi': {
      copyDirFixture(join(sourceFixtureRoot, 'kimi'), inputRoot);
      return {
        adapter: new KimiAdapter(
          join(inputRoot, 'sessions'),
          join(inputRoot, 'kimi.json'),
        ),
        inputRoot,
      };
    }
    case 'cline': {
      copyDirFixture(
        join(sourceFixtureRoot, 'cline/tasks'),
        join(inputRoot, 'tasks'),
      );
      return { adapter: new ClineAdapter(join(inputRoot, 'tasks')), inputRoot };
    }
    case 'cursor': {
      const dbPath = copyFileFixture(
        join(sourceFixtureRoot, 'cursor/state.vscdb'),
        join(inputRoot, 'state.vscdb'),
      );
      return { adapter: new CursorAdapter(dbPath), inputRoot };
    }
    case 'vscode': {
      copyDirFixture(join(sourceFixtureRoot, 'vscode'), inputRoot);
      return { adapter: new VsCodeAdapter(inputRoot), inputRoot };
    }
    case 'windsurf': {
      copyDirFixture(
        join(sourceFixtureRoot, 'windsurf/cache'),
        join(inputRoot, 'cache'),
      );
      return {
        adapter: new WindsurfAdapter(
          join(inputRoot, 'missing-daemon'),
          join(inputRoot, 'cache'),
          join(inputRoot, 'missing-conversations'),
        ),
        inputRoot,
      };
    }
    case 'antigravity': {
      copyDirFixture(
        join(sourceFixtureRoot, 'antigravity/cache'),
        join(inputRoot, 'cache'),
      );
      return {
        adapter: new AntigravityAdapter(
          join(inputRoot, 'missing-daemon'),
          join(inputRoot, 'cache'),
          join(inputRoot, 'missing-conversations'),
        ),
        inputRoot,
      };
    }
    case 'copilot': {
      copyDirFixture(join(sourceFixtureRoot, 'copilot'), inputRoot);
      return { adapter: new CopilotAdapter(inputRoot), inputRoot };
    }
  }
}

async function firstLocator(adapter: SessionAdapter): Promise<string> {
  for await (const locator of adapter.listSessionFiles()) {
    return locator;
  }
  throw new Error(`no fixture locator listed for ${adapter.name}`);
}

function relativeLocator(root: string, locator: string): string {
  if (locator.startsWith(root)) return relative(root, locator);
  const [pathPart, query] = locator.split('?');
  if (pathPart.startsWith(root)) {
    return `${relative(root, pathPart)}${query ? `?${query}` : ''}`;
  }
  return locator;
}

async function collectMessages(
  adapter: SessionAdapter,
  locator: string,
): Promise<Message[]> {
  const messages: Message[] = [];
  for await (const msg of adapter.streamMessages(locator)) messages.push(msg);
  return messages;
}

function usageTotals(messages: Message[]): AdapterFixture['usageTotals'] {
  return messages.reduce(
    (acc, msg) => {
      acc.inputTokens += msg.usage?.inputTokens ?? 0;
      acc.outputTokens += msg.usage?.outputTokens ?? 0;
      acc.cacheReadTokens += msg.usage?.cacheReadTokens ?? 0;
      acc.cacheCreationTokens += msg.usage?.cacheCreationTokens ?? 0;
      return acc;
    },
    {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    },
  );
}

function flattenToolCalls(messages: Message[]): ToolCall[] {
  return messages.flatMap((msg) => msg.toolCalls ?? []);
}

function fileToolCounts(
  toolCalls: ToolCall[],
): Record<string, Record<string, number>> {
  const fileTools: Record<string, string> = {
    Edit: 'edit',
    Read: 'read',
    Write: 'write',
    edit_file: 'edit',
    read_file: 'read',
    write_file: 'write',
  };
  const counts: Record<string, Record<string, number>> = {};
  for (const call of toolCalls) {
    const action = fileTools[call.name];
    if (!action || !call.input) continue;
    try {
      const parsed = JSON.parse(call.input) as { file_path?: unknown };
      if (typeof parsed.file_path !== 'string') continue;
      if (!parsed.file_path.startsWith('/')) continue;
      counts[parsed.file_path] ??= {};
      counts[parsed.file_path][action] =
        (counts[parsed.file_path][action] ?? 0) + 1;
    } catch {
      // Malformed tool-call JSON is intentionally ignored by the Node indexer.
    }
  }
  return counts;
}

function derivedFields(
  source: SupportedFixtureSource,
  sessionInfo: Record<string, unknown>,
  messages: Message[],
  tools: ToolCall[],
) {
  const messageText = messages
    .map((msg) => msg.content)
    .filter(Boolean)
    .join('\n');
  return {
    projectFields: {
      cwd: sessionInfo.cwd ?? '',
      project: sessionInfo.project ?? null,
      source,
    },
    insightFields: {
      firstUserSummary: sessionInfo.summary ?? null,
      messageCount: messages.length,
      toolCallCount: tools.length,
    },
    searchIndexFields: {
      contentPreview: messageText.slice(0, 500),
      contentSha256InputBytes: Buffer.byteLength(messageText),
      roles: messages.map((msg) => msg.role),
    },
    statsFields: {
      assistantMessageCount: sessionInfo.assistantMessageCount ?? 0,
      messageCount: sessionInfo.messageCount ?? 0,
      systemMessageCount: sessionInfo.systemMessageCount ?? 0,
      toolMessageCount: sessionInfo.toolMessageCount ?? 0,
      userMessageCount: sessionInfo.userMessageCount ?? 0,
    },
  };
}

function batchSizes(): Record<string, unknown> {
  return {
    schemaVersion: 1,
    watchWriteStabilityMs: 2000,
    watchWriteStabilityPollMs: 500,
    startupParentBackfillLimit: 500,
    sourceFiles: ['src/core/watcher.ts', 'src/core/db/maintenance.ts'],
    generatedAtCommit: gitCommit(),
  };
}

function writeMalformedManifest(out: string): void {
  const malformedRoot = resolve(out, '..', 'adapter-malformed');
  rmSync(malformedRoot, { recursive: true, force: true });
  mkdirSync(malformedRoot, { recursive: true });
  const manifest = {
    schemaVersion: 1,
    categories: Object.fromEntries(
      malformedCategories.map((category) => [
        category,
        {
          committedInput: false,
          generatedInTests:
            category === 'fileTooLarge' || category === 'messageLimitExceeded',
          expectedFailure: category,
        },
      ]),
    ),
    generatedAtCommit: gitCommit(),
  };
  writeFileSync(join(malformedRoot, 'manifest.json'), stableJson(manifest));
}

export async function generateAdapterParityFixtures(
  out: string,
): Promise<void> {
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  const commit = gitCommit();

  for (const source of supportedSources) {
    const { adapter } = makeAdapter(source, out);
    if (!(await adapter.detect())) {
      throw new Error(`fixture adapter did not detect input root: ${source}`);
    }
    const locator = await firstLocator(adapter);
    const sessionInfo = await adapter.parseSessionInfo(locator);
    if (!sessionInfo) throw new Error(`failed to parse fixture: ${source}`);
    const messages = await collectMessages(adapter, locator);
    const tools = flattenToolCalls(messages);
    const derived = derivedFields(
      source,
      sessionInfo as Record<string, unknown>,
      messages,
      tools,
    );
    const fixture: AdapterFixture = {
      schemaVersion: 1,
      source,
      inputPath: relativeLocator(out, locator),
      locator: relativeLocator(out, locator),
      sessionInfo,
      messages,
      toolCalls: tools,
      usageTotals: usageTotals(messages),
      fileToolCounts: fileToolCounts(tools),
      ...derived,
      failure: null,
      nodeVersion: process.version,
      generatedAtCommit: commit,
    };
    writeFileSync(
      join(out, source, 'success.expected.json'),
      stableJson(normalizeFixturePaths(fixture, out)),
    );
  }

  writeFileSync(join(out, 'batch-sizes.json'), stableJson(batchSizes()));
  writeMalformedManifest(out);

  for (const file of [
    join(out, 'opencode/input/sample.db'),
    join(out, 'cursor/input/state.vscdb'),
  ]) {
    if (statSync(file).size > 5 * 1024 * 1024) {
      throw new Error(`generated fixture exceeds 5 MB: ${file}`);
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { out } = parseArgs();
  await generateAdapterParityFixtures(out);
  console.log(`adapter parity fixtures generated: ${relative(repoRoot, out)}`);
}
