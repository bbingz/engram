import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { documentedToolNames } from '../../scripts/check-runtime-capabilities.js';
import { SOURCE_NAMES } from '../../src/adapters/types.js';

describe('MCP tools documentation', () => {
  it('documents the same source enum as the runtime tool schemas', () => {
    const doc = readFileSync(join(process.cwd(), 'docs/mcp-tools.md'), 'utf8');
    const match = doc.match(/Enum: ((?:`[^`]+`(?:, )?)+)/);

    expect(match).not.toBeNull();
    const documented = [...match![1].matchAll(/`([^`]+)`/g)].map((m) => m[1]);

    expect(documented).toEqual([...SOURCE_NAMES]);
  });

  it('documents every tool in the MCP golden tools contract', () => {
    const doc = readFileSync(join(process.cwd(), 'docs/mcp-tools.md'), 'utf8');
    const toolNames = JSON.parse(
      readFileSync(
        join(process.cwd(), 'tests/fixtures/mcp-golden/tools.json'),
        'utf8',
      ),
    );

    const documented = documentedToolNames(doc);

    expect(new Set(documented)).toEqual(new Set(toolNames));
    expect(documented).toHaveLength(toolNames.length);
  });
});
