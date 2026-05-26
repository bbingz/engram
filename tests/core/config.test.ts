// tests/core/config.test.ts
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

// Dynamic import to match the project's ES module setup
const {
  migrateSettings,
  resolveSummaryConfig,
  getBaseURL,
  readFileSettings,
  writeFileSettings,
} = await import('../../src/core/config.js');

afterEach(() => {
  vi.unstubAllEnvs();
});

// ── migrateSettings ──────────────────────────────────────────────────

describe('migrateSettings', () => {
  it('migrates openai provider to unified fields', () => {
    const result = migrateSettings({
      aiProvider: 'openai',
      openaiApiKey: 'sk-test-key',
      openaiModel: 'gpt-4o',
    });

    expect(result.aiProtocol).toBe('openai');
    expect(result.aiApiKey).toBe('sk-test-key');
    expect(result.aiModel).toBe('gpt-4o');
    expect(result.aiProvider).toBeUndefined();
    // Legacy per-provider keys are preserved for embeddings
    expect(result.openaiApiKey).toBe('sk-test-key');
    expect(result.openaiModel).toBe('gpt-4o');
  });

  it('migrates anthropic provider to unified fields', () => {
    const result = migrateSettings({
      aiProvider: 'anthropic',
      anthropicApiKey: 'sk-ant-key',
      anthropicModel: 'claude-sonnet-4-20250514',
    });

    expect(result.aiProtocol).toBe('anthropic');
    expect(result.aiApiKey).toBe('sk-ant-key');
    expect(result.aiModel).toBe('claude-sonnet-4-20250514');
    expect(result.aiProvider).toBeUndefined();
    // Legacy keys preserved
    expect(result.anthropicApiKey).toBe('sk-ant-key');
    expect(result.anthropicModel).toBe('claude-sonnet-4-20250514');
  });

  it('skips migration when aiProtocol already set', () => {
    const input = {
      aiProtocol: 'openai' as const,
      aiApiKey: 'existing-key',
      aiProvider: 'anthropic' as const, // stale leftover — not touched
    };
    const result = migrateSettings(input);

    expect(result.aiProtocol).toBe('openai');
    expect(result.aiApiKey).toBe('existing-key');
    // aiProvider left as-is (no-op)
    expect(result.aiProvider).toBe('anthropic');
  });

  it('returns empty settings unchanged', () => {
    const result = migrateSettings({});
    expect(result).toEqual({});
  });

  it('handles provider set but no key/model present', () => {
    const result = migrateSettings({ aiProvider: 'openai' });
    expect(result.aiProtocol).toBe('openai');
    expect(result.aiApiKey).toBeUndefined();
    expect(result.aiModel).toBeUndefined();
    expect(result.aiProvider).toBeUndefined();
  });
});

// ── resolveSummaryConfig ─────────────────────────────────────────────

describe('resolveSummaryConfig', () => {
  it('returns standard defaults when no preset specified', () => {
    const config = resolveSummaryConfig({});
    expect(config).toEqual({
      maxTokens: 200,
      temperature: 0.3,
      sampleFirst: 20,
      sampleLast: 30,
      truncateChars: 500,
    });
  });

  it('returns concise preset values', () => {
    const config = resolveSummaryConfig({ summaryPreset: 'concise' });
    expect(config).toEqual({
      maxTokens: 100,
      temperature: 0.2,
      sampleFirst: 10,
      sampleLast: 15,
      truncateChars: 300,
    });
  });

  it('returns detailed preset values', () => {
    const config = resolveSummaryConfig({ summaryPreset: 'detailed' });
    expect(config).toEqual({
      maxTokens: 400,
      temperature: 0.4,
      sampleFirst: 30,
      sampleLast: 50,
      truncateChars: 800,
    });
  });

  it('overlays custom fields on top of preset', () => {
    const config = resolveSummaryConfig({
      summaryPreset: 'concise',
      summaryMaxTokens: 150,
      summaryTemperature: 0.5,
    });
    expect(config.maxTokens).toBe(150);
    expect(config.temperature).toBe(0.5);
    // Non-overridden fields keep concise defaults
    expect(config.sampleFirst).toBe(10);
    expect(config.sampleLast).toBe(15);
    expect(config.truncateChars).toBe(300);
  });

  it('allows overriding all advanced fields', () => {
    const config = resolveSummaryConfig({
      summaryPreset: 'standard',
      summarySampleFirst: 5,
      summarySampleLast: 10,
      summaryTruncateChars: 999,
    });
    expect(config.sampleFirst).toBe(5);
    expect(config.sampleLast).toBe(10);
    expect(config.truncateChars).toBe(999);
    // Non-overridden standard defaults
    expect(config.maxTokens).toBe(200);
    expect(config.temperature).toBe(0.3);
  });
});

// ── getBaseURL ───────────────────────────────────────────────────────

describe('getBaseURL', () => {
  it('returns openai default URL', () => {
    expect(getBaseURL({ aiProtocol: 'openai' })).toBe('https://api.openai.com');
  });

  it('returns anthropic default URL', () => {
    expect(getBaseURL({ aiProtocol: 'anthropic' })).toBe(
      'https://api.anthropic.com',
    );
  });

  it('returns gemini default URL', () => {
    expect(getBaseURL({ aiProtocol: 'gemini' })).toBe(
      'https://generativelanguage.googleapis.com',
    );
  });

  it('returns custom URL when aiBaseURL is set', () => {
    expect(
      getBaseURL({
        aiProtocol: 'openai',
        aiBaseURL: 'http://localhost:11434',
      }),
    ).toBe('http://localhost:11434');
  });

  it('returns undefined when no protocol and no base URL', () => {
    expect(getBaseURL({})).toBeUndefined();
  });

  it('custom base URL overrides protocol default (e.g. Ollama via OpenAI)', () => {
    expect(
      getBaseURL({ aiProtocol: 'openai', aiBaseURL: 'http://localhost:11434' }),
    ).toBe('http://localhost:11434');
  });
});

// ── observability config ──────────────────────────────────────────────

describe('observability config', () => {
  it('observability block parsed correctly via migrateSettings passthrough', () => {
    const input = {
      observability: {
        logLevel: 'debug' as const,
        logRetentionDays: 14,
      },
    };
    // migrateSettings should pass through observability untouched (no aiProvider → no-op)
    const result = migrateSettings(input);
    expect(result.observability).toEqual({
      logLevel: 'debug',
      logRetentionDays: 14,
    });
  });

  it('monitor config block preserved through migration', () => {
    const input = {
      monitor: {
        enabled: true,
        dailyCostBudget: 25,
        longSessionMinutes: 120,
        notifyOnCostThreshold: true,
        notifyOnLongSession: false,
      },
    };
    const result = migrateSettings(input);
    expect(result.monitor).toEqual({
      enabled: true,
      dailyCostBudget: 25,
      longSessionMinutes: 120,
      notifyOnCostThreshold: true,
      notifyOnLongSession: false,
    });
  });
});

// ── secure settings file permissions ─────────────────────────────────

describe('settings file permissions', () => {
  it('creates the settings directory as 0700 and settings file as 0600', () => {
    const home = mkdtempSync(join(tmpdir(), 'engram-config-'));
    vi.stubEnv('HOME', home);
    try {
      writeFileSettings({ aiProtocol: 'openai', aiApiKey: 'secret' });

      const dir = join(home, '.engram');
      const file = join(dir, 'settings.json');
      expect(statSync(dir).mode & 0o777).toBe(0o700);
      expect(statSync(file).mode & 0o777).toBe(0o600);
      expect(JSON.parse(readFileSync(file, 'utf-8')).aiApiKey).toBe('secret');
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it('repairs loose permissions on an existing settings file before writing', () => {
    const home = mkdtempSync(join(tmpdir(), 'engram-config-'));
    vi.stubEnv('HOME', home);
    try {
      const dir = join(home, '.engram');
      const file = join(dir, 'settings.json');
      mkdirSync(dir, { recursive: true, mode: 0o755 });
      writeFileSync(file, JSON.stringify({ aiProtocol: 'openai' }), {
        mode: 0o644,
      });
      chmodSync(dir, 0o755);
      chmodSync(file, 0o644);

      writeFileSettings({ aiModel: 'gpt-4o' });

      expect(statSync(dir).mode & 0o777).toBe(0o700);
      expect(statSync(file).mode & 0o777).toBe(0o600);
      expect(JSON.parse(readFileSync(file, 'utf-8')).aiModel).toBe('gpt-4o');
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it('uses secure permissions when persisting migrated settings', () => {
    const home = mkdtempSync(join(tmpdir(), 'engram-config-'));
    vi.stubEnv('HOME', home);
    try {
      const dir = join(home, '.engram');
      const file = join(dir, 'settings.json');
      mkdirSync(dir, { recursive: true, mode: 0o755 });
      writeFileSync(
        file,
        JSON.stringify({ aiProvider: 'openai', openaiApiKey: 'secret' }),
        { mode: 0o644 },
      );
      chmodSync(dir, 0o755);
      chmodSync(file, 0o644);

      const settings = readFileSettings();

      expect(settings.aiProtocol).toBe('openai');
      expect(statSync(dir).mode & 0o777).toBe(0o700);
      expect(statSync(file).mode & 0o777).toBe(0o600);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it('repairs loose permissions when reading existing settings', () => {
    const home = mkdtempSync(join(tmpdir(), 'engram-config-'));
    vi.stubEnv('HOME', home);
    try {
      const dir = join(home, '.engram');
      const file = join(dir, 'settings.json');
      mkdirSync(dir, { recursive: true, mode: 0o755 });
      writeFileSync(file, JSON.stringify({ aiProtocol: 'openai' }), {
        mode: 0o644,
      });
      chmodSync(dir, 0o755);
      chmodSync(file, 0o644);

      const settings = readFileSettings();

      expect(settings.aiProtocol).toBe('openai');
      expect(statSync(dir).mode & 0o777).toBe(0o700);
      expect(statSync(file).mode & 0o777).toBe(0o600);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it('reads legacy Swift titleBaseURL setting as titleBaseUrl', () => {
    const home = mkdtempSync(join(tmpdir(), 'engram-config-'));
    vi.stubEnv('HOME', home);
    try {
      const dir = join(home, '.engram');
      const file = join(dir, 'settings.json');
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      writeFileSync(
        file,
        JSON.stringify({
          titleProvider: 'custom',
          titleBaseURL: 'https://token-plan-sgp.xiaomimimo.com',
          titleModel: 'mimo-2.5-pro',
        }),
        { mode: 0o600 },
      );

      const settings = readFileSettings();

      expect(settings.titleBaseUrl).toBe(
        'https://token-plan-sgp.xiaomimimo.com',
      );
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});
