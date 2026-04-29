// src/adapters/codex-usage-probe.ts

import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { UsageProbe, UsageSnapshot } from '../core/usage-probe.js';

/**
 * Codex usage probe — extracts API usage/quota info from codex CLI.
 * Uses tmux headless session to run `codex /status`.
 */
export class CodexUsageProbe implements UsageProbe {
  source = 'codex';
  interval = 600_000; // 10 min

  async probe(): Promise<UsageSnapshot[]> {
    // Check if codex CLI is installed
    try {
      execSync('which codex', { stdio: 'pipe' });
    } catch {
      return [];
    }

    try {
      return await this.tmuxProbe();
    } catch (err) {
      console.warn('[codex-probe] tmux probe failed:', err);
      return [];
    }
  }

  private async tmuxProbe(): Promise<UsageSnapshot[]> {
    const sessionName = 'engram-codex-probe';
    const probeDir = join(homedir(), '.engram', 'probes', 'codex');
    const outFile = join(probeDir, 'status-output.txt');

    try {
      execSync(`mkdir -p ${probeDir}`, { stdio: 'pipe' });

      // Kill any existing probe session
      try {
        execSync(`tmux kill-session -t ${sessionName}`, { stdio: 'pipe' });
      } catch {
        /* ok */
      }

      // Run codex /status in headless tmux
      execSync(
        `tmux new-session -d -s ${sessionName} "codex /status > ${outFile} 2>&1; sleep 2"`,
        { stdio: 'pipe', timeout: 15_000 },
      );

      // Wait for output
      await new Promise((r) => setTimeout(r, 10_000));

      // Kill session
      try {
        execSync(`tmux kill-session -t ${sessionName}`, { stdio: 'pipe' });
      } catch {
        /* ok */
      }

      // Parse output
      if (existsSync(outFile)) {
        const output = readFileSync(outFile, 'utf-8');
        return this.parseOutput(output);
      }
    } catch {
      try {
        execSync(`tmux kill-session -t ${sessionName}`, { stdio: 'pipe' });
      } catch {
        /* ok */
      }
    }

    return [];
  }

  private parseOutput(output: string): UsageSnapshot[] {
    const now = new Date().toISOString();
    const snapshots: UsageSnapshot[] = [];
    const lines = output.split('\n');

    for (const line of lines) {
      // Match patterns like "Usage: 45%" or "quota: 30/100"
      const percentMatch = line.match(
        /(\w[\w\s]*?)\s*[:=]\s*(\d+(?:\.\d+)?)\s*%/,
      );
      if (percentMatch) {
        const metric = percentMatch[1]
          .trim()
          .toLowerCase()
          .replace(/\s+/g, '_');
        const value = parseFloat(percentMatch[2]);
        snapshots.push({
          source: this.source,
          metric,
          value: Math.min(100, value),
          collectedAt: now,
        });
        continue;
      }

      // Match fraction patterns like "30/100"
      const fractionMatch = line.match(
        /(\w[\w\s]*?)\s*[:=]\s*(\d+)\s*\/\s*(\d+)/,
      );
      if (fractionMatch) {
        const metric = fractionMatch[1]
          .trim()
          .toLowerCase()
          .replace(/\s+/g, '_');
        const numerator = parseInt(fractionMatch[2], 10);
        const denominator = parseInt(fractionMatch[3], 10);
        if (denominator > 0) {
          snapshots.push({
            source: this.source,
            metric,
            value: Math.min(100, (numerator / denominator) * 100),
            collectedAt: now,
          });
        }
      }
    }

    return snapshots;
  }
}
