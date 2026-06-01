import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const indexSource = readFileSync(
  fileURLToPath(new URL('../../src/index.ts', import.meta.url)),
  'utf8',
);

function toolBlock(toolName: string): string {
  const marker = `toolRegistry.set('${toolName}'`;
  const start = indexSource.indexOf(marker);
  if (start < 0) throw new Error(`Missing tool registry block: ${toolName}`);
  const next = indexSource.indexOf(
    '\ntoolRegistry.set(',
    start + marker.length,
  );
  return indexSource.slice(start, next < 0 ? undefined : next);
}

describe('MCP write fallback wiring', () => {
  it('routes project migration mutators through their fail-closed policy names', () => {
    for (const tool of [
      'project_move',
      'project_archive',
      'project_undo',
      'project_move_batch',
    ]) {
      expect(toolBlock(tool)).toMatch(
        new RegExp(`shouldFallbackToDirectForTool\\(\\s*'${tool}'`),
      );
    }
  });

  it('keeps non-project write fallback on the normal strict-mode policy', () => {
    for (const tool of ['manage_project_alias', 'save_insight']) {
      const block = toolBlock(tool);
      expect(block).toContain(
        'shouldFallbackToDirect(err, strictSingleWriter)',
      );
      expect(block).not.toContain('shouldFallbackToDirectForTool(');
    }
  });
});
