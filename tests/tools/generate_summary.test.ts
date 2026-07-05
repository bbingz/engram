// tests/tools/generate_summary.test.ts

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Database } from '../../src/core/db.js';
import {
  generateSummaryStatusFromHttpError,
  handleGenerateSummary,
} from '../../src/tools/generate_summary.js';

const { mockGetAdapter, mockReadFileSettings, mockSummarizeConversation } =
  vi.hoisted(() => ({
    mockGetAdapter: vi.fn(),
    mockReadFileSettings: vi.fn(),
    mockSummarizeConversation: vi.fn(),
  }));

vi.mock('../../src/core/bootstrap.js', () => ({
  getAdapter: mockGetAdapter,
}));

vi.mock('../../src/core/config.js', () => ({
  readFileSettings: mockReadFileSettings,
}));

vi.mock('../../src/core/ai-client.js', () => ({
  summarizeConversation: mockSummarizeConversation,
}));

const SESSION_ID = 'summary-session-01';

beforeEach(() => {
  mockGetAdapter.mockReset();
  mockReadFileSettings.mockReset();
  mockSummarizeConversation.mockReset();
});

function dbWithSession(session?: Record<string, unknown>) {
  return {
    getSession: vi.fn().mockReturnValue(session ?? null),
    updateSessionSummary: vi.fn(),
  } as unknown as Database & {
    getSession: ReturnType<typeof vi.fn>;
    updateSessionSummary: ReturnType<typeof vi.fn>;
  };
}

function session(overrides: Record<string, unknown> = {}) {
  return {
    id: SESSION_ID,
    source: 'codex',
    filePath: '/tmp/session.jsonl',
    ...overrides,
  };
}

async function* messages(items: Array<{ role: string; content: string }>) {
  for (const item of items) yield item;
}

async function* throwingMessages() {
  yield* [];
  throw new Error('read failed');
}

async function* throwingSecretPathMessages() {
  yield* [];
  throw new Error('failed to read secret path /Users/bing/.ssh/id_ed25519');
}

describe('handleGenerateSummary status results', () => {
  it('returns a structured not_found status without MCP isError', async () => {
    mockReadFileSettings.mockReturnValue({ aiApiKey: 'sk-test' });
    const db = dbWithSession();

    const result = await handleGenerateSummary(db, { sessionId: SESSION_ID });

    expect(result).not.toHaveProperty('isError');
    expect(result).toMatchObject({
      structuredContent: {
        status: 'not_found',
        sessionId: SESSION_ID,
      },
    });
  });

  it('returns a structured not_configured status without MCP isError', async () => {
    mockReadFileSettings.mockReturnValue({});
    const db = dbWithSession(session());

    const result = await handleGenerateSummary(db, { sessionId: SESSION_ID });

    expect(result).not.toHaveProperty('isError');
    expect(result).toMatchObject({
      structuredContent: {
        status: 'not_configured',
        sessionId: SESSION_ID,
      },
    });
  });

  it('returns a structured unsupported_source status without MCP isError', async () => {
    mockReadFileSettings.mockReturnValue({ aiApiKey: 'sk-test' });
    mockGetAdapter.mockReturnValue(undefined);
    const db = dbWithSession(session({ source: 'unknown-source' }));

    const result = await handleGenerateSummary(db, { sessionId: SESSION_ID });

    expect(result).not.toHaveProperty('isError');
    expect(result).toMatchObject({
      structuredContent: {
        status: 'unsupported_source',
        sessionId: SESSION_ID,
      },
    });
  });

  it('returns a structured empty status without MCP isError', async () => {
    mockReadFileSettings.mockReturnValue({ aiApiKey: 'sk-test' });
    mockGetAdapter.mockReturnValue({
      streamMessages: () => messages([]),
    });
    const db = dbWithSession(session());

    const result = await handleGenerateSummary(db, { sessionId: SESSION_ID });

    expect(result).not.toHaveProperty('isError');
    expect(result).toMatchObject({
      structuredContent: {
        status: 'empty',
        sessionId: SESSION_ID,
      },
    });
  });

  it('returns a structured empty_response status without MCP isError', async () => {
    mockReadFileSettings.mockReturnValue({ aiApiKey: 'sk-test' });
    mockGetAdapter.mockReturnValue({
      streamMessages: () => messages([{ role: 'user', content: 'hello' }]),
    });
    mockSummarizeConversation.mockResolvedValue(null);
    const db = dbWithSession(session());

    const result = await handleGenerateSummary(db, { sessionId: SESSION_ID });

    expect(result).not.toHaveProperty('isError');
    expect(result).toMatchObject({
      structuredContent: {
        status: 'empty_response',
        sessionId: SESSION_ID,
      },
    });
  });

  it('keeps read failures as MCP isError', async () => {
    mockReadFileSettings.mockReturnValue({ aiApiKey: 'sk-test' });
    mockGetAdapter.mockReturnValue({
      streamMessages: throwingMessages,
    });
    const db = dbWithSession(session());

    const result = await handleGenerateSummary(db, { sessionId: SESSION_ID });

    expect(result).toMatchObject({
      isError: true,
      structuredContent: {
        error: { message: expect.stringContaining('Failed to read') },
      },
    });
  });

  it('does not expose adapter read error details in user-visible output', async () => {
    mockReadFileSettings.mockReturnValue({ aiApiKey: 'sk-test' });
    mockGetAdapter.mockReturnValue({
      streamMessages: throwingSecretPathMessages,
    });
    const db = dbWithSession(session());

    const result = await handleGenerateSummary(db, { sessionId: SESSION_ID });
    const rendered = JSON.stringify(result);

    expect(result).toMatchObject({
      isError: true,
      structuredContent: {
        error: { message: 'Failed to read session messages.' },
      },
    });
    expect(rendered).not.toContain('/Users/bing/.ssh');
    expect(rendered).not.toContain('id_ed25519');
  });
});

describe('generateSummaryStatusFromHttpError', () => {
  it('maps daemon business errors to non-error status results', () => {
    expect(
      generateSummaryStatusFromHttpError(
        404,
        { error: `Session not found: ${SESSION_ID}` },
        SESSION_ID,
      )?.structuredContent,
    ).toMatchObject({ status: 'not_found', sessionId: SESSION_ID });

    expect(
      generateSummaryStatusFromHttpError(
        500,
        { error: 'API key not configured. Please set it in Settings.' },
        SESSION_ID,
      )?.structuredContent,
    ).toMatchObject({ status: 'not_configured', sessionId: SESSION_ID });
  });

  it('leaves transport or unknown daemon errors for MCP isError handling', () => {
    expect(
      generateSummaryStatusFromHttpError(
        500,
        { error: 'database locked' },
        SESSION_ID,
      ),
    ).toBeNull();
  });
});
