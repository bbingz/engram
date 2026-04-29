// src/core/usage-probe.ts

export interface UsageSnapshot {
  source: string;
  metric: string; // e.g. "opus_5h", "opus_weekly", "sonnet_5h"
  value: number; // 0-100 percentage
  resetAt?: string; // ISO timestamp
  collectedAt: string; // ISO timestamp
}

export interface UsageProbe {
  source: string;
  interval: number; // ms between probes
  probe(): Promise<UsageSnapshot[]>;
}
