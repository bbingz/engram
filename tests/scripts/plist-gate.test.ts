import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const hasPlutil = (() => {
  try {
    execFileSync('bash', ['-c', 'command -v plutil'], {
      stdio: 'ignore',
    });
    return true;
  } catch {
    return false;
  }
})();

function runScript(path: string, args: string[] = [], cwd = repoRoot): string {
  return execFileSync('bash', [path, ...args], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

describe.skipIf(!hasPlutil)('plist gate script', () => {
  it('passes for tracked plist and entitlement files', () => {
    const script = resolve(repoRoot, 'scripts/check-plists.sh');
    expect(runScript(script)).toContain('plists ok');
  });

  it('avoids Bash 4-only builtins for macOS CI compatibility', () => {
    const script = readFileSync(
      resolve(repoRoot, 'scripts/check-plists.sh'),
      'utf8',
    );
    expect(script).not.toContain('mapfile');
  });

  it('passes for tracked files when launched outside the repo root', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-plist-gate-cwd-'));
    const script = resolve(repoRoot, 'scripts/check-plists.sh');
    expect(runScript(script, [], tempDir)).toContain('plists ok');
  });

  it('rejects duplicate keys in the same dict', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-plist-gate-'));
    const duplicatePlist = resolve(tempDir, 'duplicate.plist');
    writeFileSync(
      duplicatePlist,
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Enabled</key>
  <true/>
  <key>Enabled</key>
  <false/>
</dict>
</plist>
`,
    );

    expect(() =>
      runScript(resolve(repoRoot, 'scripts/check-plists.sh'), [duplicatePlist]),
    ).toThrow(/Enabled/);
  });

  it('skips duplicate-key detection for binary plists', () => {
    const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-plist-gate-binary-'));
    const binaryPlist = resolve(tempDir, 'binary.plist');
    writeFileSync(
      binaryPlist,
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Enabled</key>
  <true/>
</dict>
</plist>
`,
    );
    execFileSync('plutil', ['-convert', 'binary1', binaryPlist], {
      stdio: 'ignore',
    });

    const output = runScript(resolve(repoRoot, 'scripts/check-plists.sh'), [
      binaryPlist,
    ]);
    expect(output).toContain('binary plist, duplicate-key check skipped');
    expect(output).toContain('plists ok');
  });
});
