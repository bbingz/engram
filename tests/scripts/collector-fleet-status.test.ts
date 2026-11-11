import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { expect, it } from 'vitest';

it('checks the read-only fleet exporter and private atomic snapshot contract', () => {
  const result = spawnSync(
    'python3',
    [
      '-I',
      '-B',
      resolve(import.meta.dirname, 'collector_fleet_status_test.py'),
    ],
    { encoding: 'utf8', timeout: 30_000 },
  );
  expect(result.status, result.stdout + result.stderr).toBe(0);
  expect(result.stderr).toContain('OK');
});
