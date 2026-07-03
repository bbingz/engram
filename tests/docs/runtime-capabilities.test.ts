import { describe, expect, it } from 'vitest';
import {
  checkRuntimeCapabilities,
  parseSwiftSourceNames,
} from '../../scripts/check-runtime-capabilities.js';

describe('runtime capability truth', () => {
  it('derives source names from the Swift product enum', () => {
    const sourceNames = parseSwiftSourceNames(`
public enum SourceName: String, CaseIterable, Codable, Sendable {
    case codex
    case claudeCode = "claude-code"
}
`);

    expect(sourceNames).toEqual(['codex', 'claude-code']);
  });

  it('keeps README, MCP docs, and MCP instructions aligned with runtime contracts', () => {
    const result = checkRuntimeCapabilities(process.cwd());

    expect(result.errors).toEqual([]);
    expect(result.capabilities.sourceNames).toHaveLength(23);
    expect(result.capabilities.toolNames).toHaveLength(29);
  });
});
