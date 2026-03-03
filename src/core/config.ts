// src/core/config.ts
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

export interface FileSettings {
  aiProvider?: 'openai' | 'anthropic';
  openaiApiKey?: string;
  openaiModel?: string;
  anthropicApiKey?: string;
  anthropicModel?: string;
  nodejsPath?: string;
  httpPort?: number;
  syncNodeName?: string;
  syncPeers?: { name: string; url: string }[];
}

const CONFIG_DIR = join(homedir(), '.engram');
const CONFIG_FILE = join(CONFIG_DIR, 'settings.json');

export function readFileSettings(): FileSettings {
  if (!existsSync(CONFIG_FILE)) {
    return {};
  }
  try {
    const content = readFileSync(CONFIG_FILE, 'utf-8');
    return JSON.parse(content) as FileSettings;
  } catch {
    return {};
  }
}

export function writeFileSettings(settings: FileSettings): void {
  if (!existsSync(CONFIG_DIR)) {
    mkdirSync(CONFIG_DIR, { recursive: true });
  }
  const current = readFileSettings();
  const merged = { ...current, ...settings };
  writeFileSync(CONFIG_FILE, JSON.stringify(merged, null, 2), 'utf-8');
}
