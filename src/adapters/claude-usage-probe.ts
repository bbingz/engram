// src/adapters/claude-usage-probe.ts

import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { UsageProbe, UsageSnapshot } from '../core/usage-probe.js';

/**
 * Claude Code usage probe — extracts API usage/quota info.
 * Primary: parses ~/.claude/usage.json if it exists.
 * Fallback: tmux headless session running `claude /usage`.
 */
export class ClaudeUsageProbe implements UsageProbe {
  source = 'claude-code';
  interval = 300_000; // 5 min

  async probe(): Promise<UsageSnapshot[]> {
    // Check if claude CLI is installed
    try {
      execSync('which claude', { stdio: 'pipe' });
    } catch {
      return [];
    }

    // Try parsing usage file first (fastest)
    const usageFile = join(homedir(), '.claude', 'usage.json');
    if (existsSync(usageFile)) {
      try {
        return this.parseUsageFile(usageFile);
      } catch {
        // Fall through to tmux
      }
    }

    // Fallback: tmux probe
    try {
      return await this.tmuxProbe();
    } catch (err) {
      console.warn('[claude-probe] tmux probe failed:', err);
      return [];
    }
  }

  private parseUsageFile(path: string): UsageSnapshot[] {
    const raw = readFileSync(path, 'utf-8');
    const data = JSON.parse(raw);
    const now = new Date().toISOString();
    const snapshots: UsageSnapshot[] = [];

    // Usage file format varies; extract what we can
    if (data && typeof data === 'object') {
      for (const [key, value] of Object.entries(data)) {
        if (typeof value === 'number') {
          snapshots.push({
            source: this.source,
            metric: key,
            value: Math.min(100, Math.max(0, value)),
            collectedAt: now,
          });
        } else if (
          value &&
          typeof value === 'object' &&
          'percent' in (value as Record<string, unknown>)
        ) {
          const v = value as { percent: number; resetAt?: string };
          snapshots.push({
            source: this.source,
            metric: key,
            value: Math.min(100, Math.max(0, v.percent)),
            resetAt: v.resetAt,
            collectedAt: now,
          });
        }
      }
    }

    return snapshots;
  }

  private async tmuxProbe(): Promise<UsageSnapshot[]> {
    const sessionName = 'engram-claude-probe';
    const probeDir = join(homedir(), '.engram', 'probes', 'claude');

    try {
      // Ensure probe directory exists
      execSync(`mkdir -p ${probeDir}`, { stdio: 'pipe' });

      // Kill any existing probe session
      try {
        execSync(`tmux kill-session -t ${sessionName}`, { stdio: 'pipe' });
      } catch {
        /* ok */
      }

      // Run claude /usage in headless tmux, capture output
      const outFile = join(probeDir, 'usage-output.txt');
      execSync(
        `tmux new-session -d -s ${sessionName} "claude /usage > ${outFile} 2>&1; sleep 2"`,
        { stdio: 'pipe', timeout: 15_000 },
      );

      // Wait for output (max 10s)
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
        return this.parseTmuxOutput(output);
      }
    } catch {
      // Cleanup on failure
      try {
        execSync(`tmux kill-session -t ${sessionName}`, { stdio: 'pipe' });
      } catch {
        /* ok */
      }
    }

    return [];
  }

  private parseTmuxOutput(output: string): UsageSnapshot[] {
    const now = new Date().toISOString();
    const snapshots: UsageSnapshot[] = [];
    const lines = output.split('\n');

    for (const line of lines) {
      // Try to match patterns like "Opus (5h): 45%" or "sonnet_5h: 30%"
      const percentMatch = line.match(
        /(\w[\w\s]*?)\s*[:=]\s*(\d+(?:\.\d+)?)\s*%/,
      );
      if (percentMatch) {
        const metric = percentMatch[1]
          .trim()
          .toLowerCase()
          .replace(/\s+/g, '_')
          .replace(/[()]/g, '');
        const value = parseFloat(percentMatch[2]);
        snapshots.push({
          source: this.source,
          metric,
          value: Math.min(100, value),
          collectedAt: now,
        });
      }
    }

    return snapshots;
  }
}
