// src/core/preamble-detector.ts

const PREAMBLE_MARKERS = [
  'CLAUDE.md', 'AGENTS.md', 'GEMINI.md', '.cursorrules',
  'environment_context', 'system-reminder',
  '<instructions>', '</instructions>',
  '# agents.md instructions',
]

const SYSTEM_ROLE_PATTERNS = [
  /^you are an expert/i,
  /^your role is/i,
  /^system:/i,
  /^# System Instructions/i,
]

export function isPreambleContent(text: string): boolean {
  const prefix = text.slice(0, 2000)
  if (PREAMBLE_MARKERS.some(m => prefix.includes(m))) return true
  if (SYSTEM_ROLE_PATTERNS.some(p => p.test(prefix))) return true
  const lines = prefix.split('\n').slice(0, 20)
  if (lines.length >= 6) {
    const structuredLines = lines.filter(l => /^[#\-\*\d]/.test(l.trim()))
    if (structuredLines.length >= 4) return true
  }
  return false
}

export function isPreambleOnly(messages: string[]): boolean {
  if (messages.length === 0) return true
  return messages.every(m => isPreambleContent(m))
}
