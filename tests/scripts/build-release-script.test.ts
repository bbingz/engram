import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = readFileSync(
  resolve(repoRoot, 'macos/scripts/build-release.sh'),
  'utf8',
);

describe('macOS release build script', () => {
  it('keeps export fallback broad enough for Xcode method errors', () => {
    expect(script).toMatch(
      /grep -Eq 'expected one\( of\)\? \\\{\\\}\|No valid distribution methods were found'/,
    );
  });

  it('verifies the exported app before reporting success', () => {
    const verifyIndex = script.indexOf(
      'codesign --verify --deep --strict "$EXPORT_PATH/Engram.app"',
    );
    const successIndex = script.indexOf('Export created at: $EXPORT_PATH');

    expect(verifyIndex).toBeGreaterThan(-1);
    expect(successIndex).toBeGreaterThan(verifyIndex);
  });
});
