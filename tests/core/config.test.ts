// tests/core/config.test.ts
import { describe, it, expect } from 'vitest';

// Dynamic import to match the project's ES module setup
const {
  migrateSettings,
  resolveSummaryConfig,
  getBaseURL,
} = await import('../../src/core/config.js');

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
    expect(getBaseURL({ aiProtocol: 'anthropic' })).toBe('https://api.anthropic.com');
  });

  it('returns gemini default URL', () => {
    expect(getBaseURL({ aiProtocol: 'gemini' })).toBe('https://generativelanguage.googleapis.com');
  });

  it('returns custom URL when aiBaseURL is set', () => {
    expect(getBaseURL({
      aiProtocol: 'openai',
      aiBaseURL: 'http://localhost:11434',
    })).toBe('http://localhost:11434');
  });

  it('returns undefined when no protocol and no base URL', () => {
    expect(getBaseURL({})).toBeUndefined();
  });

  it('returns undefined for ollama (no default URL mapping)', () => {
    expect(getBaseURL({ aiProtocol: 'ollama' })).toBeUndefined();
  });
});
