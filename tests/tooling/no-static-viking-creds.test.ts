import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = process.cwd();
const vikingScripts = [
  'scripts/search-audit.sh',
  'scripts/viking-quality-test.sh',
];

describe('historical Viking scripts', () => {
  it('do not retain static endpoint or bearer credentials', () => {
    for (const scriptPath of vikingScripts) {
      const script = readFileSync(join(repoRoot, scriptPath), 'utf8');

      expect(script, scriptPath).not.toContain('10.0.8.9');
      expect(script, scriptPath).not.toContain('engram-viking-2026');
      expect(script, scriptPath).toContain('VIKING_BASE');
      expect(script, scriptPath).toContain('VIKING_TOKEN');
    }
  });
});
