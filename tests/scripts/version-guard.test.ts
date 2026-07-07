import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');

function packageVersion(): string {
  const pkg = JSON.parse(
    readFileSync(resolve(repoRoot, 'package.json'), 'utf8'),
  ) as { version?: unknown };
  if (typeof pkg.version !== 'string') {
    throw new Error('package.json version must be a string');
  }
  return pkg.version;
}

function marketingVersion(): string {
  const project = readFileSync(resolve(repoRoot, 'macos/project.yml'), 'utf8');
  const match = project.match(/^\s*MARKETING_VERSION:\s*"?([^"\n#]+)"?\s*$/m);
  if (!match) {
    throw new Error('macos/project.yml MARKETING_VERSION not found');
  }
  return match[1].trim();
}

describe('product version guard', () => {
  it('keeps package.json version aligned with macos/project.yml MARKETING_VERSION', () => {
    expect(packageVersion()).toBe(marketingVersion());
  });
});
