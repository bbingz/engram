import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = resolve(repoRoot, 'scripts/check-swift-conventions.sh');
const rgPath = `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH ?? ''}`;
const hasRg = (() => {
  try {
    execFileSync('bash', ['-c', 'command -v rg'], {
      env: { ...process.env, PATH: rgPath },
      stdio: 'ignore',
    });
    return true;
  } catch {
    return false;
  }
})();

function runScript(args: string[] = [], cwd = repoRoot): string {
  return execFileSync('bash', [script, ...args], {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, PATH: rgPath },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function writeSwift(root: string, relativePath: string, source: string): void {
  const path = resolve(root, relativePath);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, source);
}

describe.skipIf(!hasRg)('Swift conventions gate script', () => {
  it('passes for the repo Swift sources', () => {
    expect(runScript()).toContain('swift conventions ok');
  });

  it('rejects NSHomeDirectory in Swift test sources', () => {
    const root = mkdtempSync(resolve(tmpdir(), 'engram-swift-conventions-'));
    writeSwift(
      root,
      'macos/EngramCoreTests/HomeIsolationTests.swift',
      [
        'import XCTest',
        'final class HomeIsolationTests: XCTestCase {',
        '  func testHome() { _ = NSHomeDirectory() }',
        '}',
      ].join('\n'),
    );

    expect(() => runScript([root])).toThrow(
      /R1 test-home-isolation: macos\/EngramCoreTests\/HomeIsolationTests\.swift:3:.*NSHomeDirectory\(\)/,
    );
  });

  it('rejects hashValue in product Swift sources', () => {
    const root = mkdtempSync(resolve(tmpdir(), 'engram-swift-conventions-'));
    writeSwift(
      root,
      'macos/Engram/CacheKey.swift',
      [
        'import Foundation',
        'struct CacheKey {',
        '  let value = "session".hashValue',
        '}',
      ].join('\n'),
    );

    expect(() => runScript([root])).toThrow(
      /R2 no-hashvalue-keys: macos\/Engram\/CacheKey\.swift:3:.*\.hashValue/,
    );
  });

  it('rejects Node runtime literals in product Swift sources', () => {
    const root = mkdtempSync(resolve(tmpdir(), 'engram-swift-conventions-'));
    writeSwift(
      root,
      'macos/EngramService/Runtime.swift',
      [
        'import Foundation',
        'struct Runtime {',
        '  let forbidden = "node_modules"',
        '}',
      ].join('\n'),
    );

    expect(() => runScript([root])).toThrow(
      /R3 no-node-runtime: macos\/EngramService\/Runtime\.swift:3:.*node_modules/,
    );
  });
});
