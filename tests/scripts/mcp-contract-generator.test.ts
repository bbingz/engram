import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const generatorSource = readFileSync(
  resolve(repoRoot, 'scripts/gen-mcp-contract-fixtures.ts'),
  'utf8',
);

describe('MCP contract fixture generator', () => {
  it('derives MCP tool metadata from the Swift registry instead of the deleted TypeScript entrypoint', () => {
    expect(generatorSource).toContain(
      'macos/EngramMCP/Core/MCPToolRegistry.swift',
    );
    expect(generatorSource).not.toContain("resolve(repoRoot, 'src/index.ts')");
    expect(generatorSource).not.toContain('extractToolNamesFromIndex');
    expect(generatorSource).not.toContain('extractInitializeResultFromIndex');
  });
});
