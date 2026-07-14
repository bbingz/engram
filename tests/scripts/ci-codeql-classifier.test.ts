import { spawnSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const classifier = resolve(repoRoot, 'scripts/ci/classify-codeql-changes.sh');
const repositories: string[] = [];

function run(cwd: string, command: string, args: string[]): string {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(' ')} failed: ${result.stderr || result.stdout}`,
    );
  }
  return result.stdout.trim();
}

function classify(path: string): Record<string, string> {
  const cwd = mkdtempSync(resolve(tmpdir(), 'engram-codeql-classifier-'));
  repositories.push(cwd);
  run(cwd, 'git', ['init', '-q']);
  run(cwd, 'git', ['config', 'user.email', 'ci@example.invalid']);
  run(cwd, 'git', ['config', 'user.name', 'CI Test']);
  writeFileSync(resolve(cwd, 'README.md'), 'base\n');
  run(cwd, 'git', ['add', 'README.md']);
  run(cwd, 'git', ['commit', '-qm', 'base']);
  const base = run(cwd, 'git', ['rev-parse', 'HEAD']);

  const target = resolve(cwd, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, 'changed\n');
  run(cwd, 'git', ['add', path]);
  run(cwd, 'git', ['commit', '-qm', 'change']);
  const head = run(cwd, 'git', ['rev-parse', 'HEAD']);
  const output = resolve(cwd, 'outputs.txt');
  run(cwd, 'bash', [classifier, base, head, output]);

  return Object.fromEntries(
    readFileSync(output, 'utf8')
      .trim()
      .split('\n')
      .map((line) => line.split('=', 2)),
  );
}

afterEach(() => {
  for (const repository of repositories.splice(0)) {
    rmSync(repository, { recursive: true, force: true });
  }
});

describe('CodeQL path classifier', () => {
  it.each([
    ['docs/guide.md', false, false, false],
    ['src/index.ts', true, false, false],
    ['macos/Engram/App.swift', false, true, false],
    ['macos/EngramRemoteServer/Core/ArchiveRoutes.swift', false, false, true],
    ['macos/Shared/EngramCore/ArchiveV2/ArchiveHash.swift', false, true, true],
    ['macos/project.yml', false, true, true],
    ['.github/workflows/codeql.yml', true, true, true],
  ])('classifies %s', (path, typescript, swiftProduct, swiftRemoteServer) => {
    expect(classify(path)).toEqual({
      typescript: String(typescript),
      swift_product: String(swiftProduct),
      swift_remote_server: String(swiftRemoteServer),
    });
  });
});
