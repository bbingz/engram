// tests/adapters/schema-drift.test.ts
// Tests that adapters gracefully handle unknown/future fields in session files.
// Each fixture contains extra fields, new content block types, and unexpected
// nested structures that a future version of the AI tool might introduce.

import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js';
import { CodexAdapter } from '../../src/adapters/codex.js';
import { IflowAdapter } from '../../src/adapters/iflow.js';
import { KimiAdapter } from '../../src/adapters/kimi.js';
import { QwenAdapter } from '../../src/adapters/qwen.js';
import type { SessionAdapter } from '../../src/adapters/types.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixtureDir = join(__dirname, '../fixtures');

interface DriftTestCase {
  name: string;
  adapter: SessionAdapter;
  fixtureDir: string;
  expectedMinMessages: number;
}

const testCases: DriftTestCase[] = [
  {
    name: 'claude-code',
    adapter: new ClaudeCodeAdapter(),
    fixtureDir: 'claude-code',
    expectedMinMessages: 2,
  },
  {
    name: 'codex',
    adapter: new CodexAdapter(),
    fixtureDir: 'codex',
    expectedMinMessages: 2,
  },
  {
    name: 'iflow',
    adapter: new IflowAdapter(),
    fixtureDir: 'iflow',
    expectedMinMessages: 2,
  },
  {
    name: 'kimi',
    adapter: new KimiAdapter(),
    fixtureDir: 'kimi',
    expectedMinMessages: 2,
  },
  {
    name: 'qwen',
    adapter: new QwenAdapter(),
    fixtureDir: 'qwen',
    expectedMinMessages: 2,
  },
];

// Meta-test: ensure all JSONL adapters have schema_drift fixtures
describe('schema drift fixture coverage', () => {
  it('all JSONL adapters have schema_drift fixtures', () => {
    for (const tc of testCases) {
      const path = join(fixtureDir, tc.fixtureDir, 'schema_drift.jsonl');
      expect(
        existsSync(path),
        `Missing fixture: ${tc.name}/schema_drift.jsonl`,
      ).toBe(true);
    }
  });
});

describe('schema drift: forward compatibility', () => {
  for (const tc of testCases) {
    const fixturePath = join(fixtureDir, tc.fixtureDir, 'schema_drift.jsonl');

    describe(tc.name, () => {
      it('parseSessionInfo does not throw on unknown fields', async () => {
        const info = await tc.adapter.parseSessionInfo(fixturePath);
        // May return null if the adapter can't parse (e.g. missing required fields)
        // but must NOT throw
        if (info) {
          expect(info.source).toBeTruthy();
        }
      });

      it('streamMessages yields messages despite unknown fields', async () => {
        const messages = [];
        for await (const msg of tc.adapter.streamMessages(fixturePath)) {
          messages.push(msg);
        }
        expect(messages.length).toBeGreaterThanOrEqual(tc.expectedMinMessages);
        // All messages should have valid role and non-empty content
        for (const msg of messages) {
          expect(['user', 'assistant', 'system', 'tool']).toContain(msg.role);
          expect(msg.content).toBeTruthy();
        }
      });

      it('unknown content block types are gracefully skipped', async () => {
        const messages = [];
        for await (const msg of tc.adapter.streamMessages(fixturePath)) {
          messages.push(msg);
        }
        // Verify no message content contains "[object Object]" (sign of unhandled type)
        for (const msg of messages) {
          expect(msg.content).not.toContain('[object Object]');
        }
      });
    });
  }
});
