import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { SOURCE_NAMES } from '../../src/adapters/types.js';

describe('MCP tools documentation', () => {
  it('documents the same source enum as the runtime tool schemas', () => {
    const doc = readFileSync(join(process.cwd(), 'docs/mcp-tools.md'), 'utf8');
    const match = doc.match(/Enum: ((?:`[^`]+`(?:, )?)+)/);

    expect(match).not.toBeNull();
    const documented = [...match![1].matchAll(/`([^`]+)`/g)].map((m) => m[1]);

    expect(documented).toEqual([...SOURCE_NAMES]);
  });
});
