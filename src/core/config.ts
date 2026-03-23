// src/core/config.ts
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { execFileSync } from 'child_process';
import { join } from 'path';
import { homedir } from 'os';
import type { SyncPeer } from './sync.js';

// ── Keychain integration (macOS) ─────────────────────────────────────

function readKeychainValue(key: string): string | undefined {
  if (process.platform !== 'darwin') return undefined;
  try {
    const result = execFileSync('security', [
      'find-generic-password', '-s', 'com.engram.app', '-a', key, '-w',
    ], { encoding: 'utf-8', timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] });
    return result.trim() || undefined;
  } catch {
    return undefined;  // key not in Keychain
  }
}

// ── Types ────────────────────────────────────────────────────────────

export type AiProtocol = 'openai' | 'anthropic' | 'gemini';

export type SummaryPreset = 'concise' | 'standard' | 'detailed';

export interface SummaryConfig {
  maxTokens: number;
  temperature: number;
  sampleFirst: number;
  sampleLast: number;
  truncateChars: number;
}

export interface VikingSettings {
  url?: string;
  apiKey?: string;
  enabled?: boolean;
}

export interface MonitorConfig {
  enabled: boolean
  dailyCostBudget?: number        // USD, default 20
  monthlyCostBudget?: number      // USD, no default (disabled if unset)
  longSessionMinutes?: number     // default 180
  notifyOnCostThreshold?: boolean // default true
  notifyOnLongSession?: boolean   // default true
}

export interface FileSettings {
  // ── Unified AI provider ───────────────────────────────────────────
  aiProtocol?: AiProtocol;
  aiBaseURL?: string;
  aiApiKey?: string;
  aiModel?: string;

  // ── Summary prompt ────────────────────────────────────────────────
  summaryPrompt?: string;
  summaryLanguage?: string;
  summaryMaxSentences?: number;
  summaryStyle?: string;

  // ── Summary generation config ─────────────────────────────────────
  summaryPreset?: SummaryPreset;
  summaryMaxTokens?: number;
  summaryTemperature?: number;
  summarySampleFirst?: number;
  summarySampleLast?: number;
  summaryTruncateChars?: number;

  // ── Auto-summary ──────────────────────────────────────────────────
  autoSummary?: boolean;
  autoSummaryCooldown?: number;
  autoSummaryMinMessages?: number;
  autoSummaryRefresh?: boolean;
  autoSummaryRefreshThreshold?: number;

  // ── Legacy per-provider keys (kept for embeddings) ────────────────
  /** @deprecated Use aiProtocol instead */
  aiProvider?: 'openai' | 'anthropic';
  openaiApiKey?: string;
  openaiModel?: string;
  anthropicApiKey?: string;
  anthropicModel?: string;
  ollamaUrl?: string;
  ollamaModel?: string;
  embeddingDimension?: number;

  // ── Infrastructure ────────────────────────────────────────────────
  nodejsPath?: string;
  httpPort?: number;
  httpHost?: string;        // '127.0.0.1' (default) | '0.0.0.0' | specific IP
  httpAllowCIDR?: string[]; // e.g. ['10.0.0.0/8', '192.168.1.0/24']
  httpBearerToken?: string; // auto-generated bearer token for write API auth
  syncNodeName?: string;
  syncPeers?: SyncPeer[];
  syncIntervalMinutes?: number;
  syncEnabled?: boolean;

  // ── Noise filtering ──────────────────────────────────────────────
  noiseFilter?: 'all' | 'hide-skip' | 'hide-noise';
  hideUsageSessions?: boolean;    // hide /usage check sessions (default: true)
  hideEmptySessions?: boolean;    // hide summary < 10 chars && <= 3 messages (default: true)
  hideAutoSummary?: boolean;      // hide auto-summary prompt leaks (default: true)

  // ── OpenViking ──────────────────────────────────────────────────
  viking?: VikingSettings;

  // ── Cost budget alerts ───────────────────────────────────────────
  costAlerts?: { dailyBudget?: number; monthlyBudget?: number };

  // ── Background monitor ────────────────────────────────────────────
  monitor?: MonitorConfig;

  // ── Observability ──────────────────────────────────────────────────
  observability?: {
    logLevel?: 'debug' | 'info' | 'warn' | 'error'
    logRetentionDays?: number
  }

  // ── Dev mode ──────────────────────────────────────────────────────
  devMode?: boolean;

  // ── Title generation ─────────────────────────────────────────────
  titleProvider?: 'ollama' | 'openai' | 'dashscope' | 'custom';
  titleBaseUrl?: string;
  titleModel?: string;
  titleApiKey?: string;
  titleAutoGenerate?: boolean;
}

// ── Preset defaults ──────────────────────────────────────────────────

const PRESETS: Record<SummaryPreset, SummaryConfig> = {
  concise:  { maxTokens: 100, temperature: 0.2, sampleFirst: 10, sampleLast: 15, truncateChars: 300 },
  standard: { maxTokens: 200, temperature: 0.3, sampleFirst: 20, sampleLast: 30, truncateChars: 500 },
  detailed: { maxTokens: 400, temperature: 0.4, sampleFirst: 30, sampleLast: 50, truncateChars: 800 },
};

// ── Protocol → default base URL ──────────────────────────────────────

const DEFAULT_BASE_URLS: Record<string, string> = {
  openai:    'https://api.openai.com',
  anthropic: 'https://api.anthropic.com',
  gemini:    'https://generativelanguage.googleapis.com',
};

// ── Paths ────────────────────────────────────────────────────────────

const CONFIG_DIR = join(homedir(), '.engram');
const CONFIG_FILE = join(CONFIG_DIR, 'settings.json');

// ── Migration ────────────────────────────────────────────────────────

/**
 * Migrate legacy `aiProvider` field to the unified `aiProtocol` field.
 *
 * - If `aiProtocol` already exists → no-op (already migrated).
 * - If `aiProvider` doesn't exist → no-op (nothing to migrate).
 * - Otherwise: copies the active provider's key/model to `aiApiKey`/`aiModel`,
 *   sets `aiProtocol`, and deletes only `aiProvider`.
 *   Per-provider keys are kept for embeddings.
 */
export function migrateSettings(settings: FileSettings): FileSettings {
  // Nothing to migrate
  if (settings.aiProtocol !== undefined || settings.aiProvider === undefined) {
    return settings;
  }

  const migrated: FileSettings = { ...settings };
  const provider = settings.aiProvider;

  migrated.aiProtocol = provider;

  if (provider === 'openai') {
    if (settings.openaiApiKey) migrated.aiApiKey = settings.openaiApiKey;
    if (settings.openaiModel) migrated.aiModel = settings.openaiModel;
  } else if (provider === 'anthropic') {
    if (settings.anthropicApiKey) migrated.aiApiKey = settings.anthropicApiKey;
    if (settings.anthropicModel) migrated.aiModel = settings.anthropicModel;
  }

  delete migrated.aiProvider;
  return migrated;
}

// ── Summary config resolution ────────────────────────────────────────

/**
 * Resolve effective summary generation config.
 *
 * 1. Start from preset defaults (default: 'standard').
 * 2. Overlay any non-null custom fields from settings.
 */
export function resolveSummaryConfig(settings: FileSettings): SummaryConfig {
  const preset = settings.summaryPreset ?? 'standard';
  const base = { ...PRESETS[preset] };

  if (settings.summaryMaxTokens != null) base.maxTokens = settings.summaryMaxTokens;
  if (settings.summaryTemperature != null) base.temperature = settings.summaryTemperature;
  if (settings.summarySampleFirst != null) base.sampleFirst = settings.summarySampleFirst;
  if (settings.summarySampleLast != null) base.sampleLast = settings.summarySampleLast;
  if (settings.summaryTruncateChars != null) base.truncateChars = settings.summaryTruncateChars;

  return base;
}

// ── Base URL resolution ──────────────────────────────────────────────

/**
 * Return the AI base URL: custom `aiBaseURL` if set, otherwise the
 * protocol-specific default. Returns `undefined` if neither is available.
 */
export function getBaseURL(settings: FileSettings): string | undefined {
  if (settings.aiBaseURL) return settings.aiBaseURL;
  if (settings.aiProtocol) return DEFAULT_BASE_URLS[settings.aiProtocol];
  return undefined;
}

// ── Read / write ─────────────────────────────────────────────────────

export function readFileSettings(): FileSettings {
  try {
    const content = readFileSync(CONFIG_FILE, 'utf-8');
    const parsed = JSON.parse(content) as FileSettings;
    const migrated = migrateSettings(parsed);
    // Persist migration if settings changed (one-time write-back)
    if (migrated !== parsed) {
      try {
        mkdirSync(CONFIG_DIR, { recursive: true });
        writeFileSync(CONFIG_FILE, JSON.stringify(migrated, null, 2), 'utf-8');
      } catch { /* best-effort */ }
    }
    // Migrate legacy noise toggles → unified noiseFilter
    if (migrated.noiseFilter === undefined) {
      const hasExplicitFalse = migrated.hideUsageSessions === false || migrated.hideEmptySessions === false || migrated.hideAutoSummary === false
      migrated.noiseFilter = hasExplicitFalse ? 'all' : 'hide-skip'
    }
    // Overlay Keychain values — only when "@keychain" sentinel is explicitly set in JSON
    if (migrated.aiApiKey === '@keychain') {
      const kc = readKeychainValue('aiApiKey');
      if (!kc) process.stderr.write('[engram] WARNING: aiApiKey set to @keychain but Keychain entry missing\n');
      migrated.aiApiKey = kc ?? '';
    }
    if (migrated.titleApiKey === '@keychain') {
      const kc = readKeychainValue('titleApiKey');
      if (!kc) process.stderr.write('[engram] WARNING: titleApiKey set to @keychain but Keychain entry missing\n');
      migrated.titleApiKey = kc ?? '';
    }
    if (migrated.viking?.apiKey === '@keychain') {
      const kc = readKeychainValue('vikingApiKey');
      if (kc) {
        migrated.viking!.apiKey = kc;
      } else {
        process.stderr.write('[engram] WARNING: viking.apiKey set to @keychain but Keychain entry missing — Viking will not authenticate\n');
        migrated.viking!.apiKey = '';
      }
    }
    return migrated;
  } catch {
    return {};
  }
}

export function writeFileSettings(settings: FileSettings): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  const current = readFileSettings();
  const merged = { ...current, ...settings };
  writeFileSync(CONFIG_FILE, JSON.stringify(merged, null, 2), 'utf-8');
}
