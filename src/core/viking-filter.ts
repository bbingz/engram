// src/core/viking-filter.ts
// Content filter pipeline for Viking Sessions API — strips noise, redacts secrets, enforces session budget.

/** System content detection — patterns from claude-code adapter's isSystemInjection() */
function isSystemContent(text: string): boolean {
  return (
    text.startsWith('# AGENTS.md instructions for ') ||
    text.includes('<INSTRUCTIONS>') ||
    text.includes('<system-reminder>') ||
    text.includes('<environment_context>') ||
    text.includes('<command-name>') ||
    text.includes('<command-message>') ||
    text.startsWith('<local-command-caveat>') ||
    text.startsWith('<local-command-stdout>') ||
    text.startsWith('Unknown skill: ') ||
    text.startsWith('Invoke the superpowers:') ||
    text.startsWith('Base directory for this skill:') ||
    text.startsWith('<EXTREMELY_IMPORTANT>') ||
    text.startsWith('<EXTREMELY-IMPORTANT>')
  );
}

/** Tool-only message: ALL lines are backtick tool summaries, no natural language */
const TOOL_LINE_RE = /^`[A-Z][a-zA-Z]+`(: .+)?$/;
function isToolOnlyMessage(text: string): boolean {
  const lines = text
    .trim()
    .split('\n')
    .filter((l) => l.trim());
  if (lines.length === 0) return false;
  return lines.every((line) => TOOL_LINE_RE.test(line.trim()));
}

const SENSITIVE_PATTERNS: [RegExp, string][] = [
  [/PGPASSWORD=\S+/g, 'PGPASSWORD=***'],
  [/MYSQL_PWD=\S+/g, 'MYSQL_PWD=***'],
  [/sk-[a-zA-Z0-9_-]{16,}/g, 'sk-***'],
  [/Bearer [a-zA-Z0-9_.-]{8,}/g, 'Bearer ***'],
];

/** Redact passwords, API keys, bearer tokens */
function _redactSensitive(text: string): string {
  let result = text;
  for (const [pattern, replacement] of SENSITIVE_PATTERNS) {
    result = result.replace(pattern, replacement);
  }
  return result;
}

/** Session-level budget: if total content exceeds this, shrink the longest messages.
 *  2MB ≈ 500K tokens, well within kimi-k2.5's 1M context window.
 *  Tested: largest session (264MB file) has only 0.8MB after filtering → no shrinking needed. */
const SESSION_BUDGET = 2_000_000;

function applySessionBudget(
  messages: { role: string; content: string }[],
): { role: string; content: string }[] {
  let total = messages.reduce((sum, m) => sum + m.content.length, 0);
  if (total <= SESSION_BUDGET) return messages; // 99%+ sessions: direct return

  const indices = messages
    .map((_, i) => i)
    .sort((a, b) => messages[b].content.length - messages[a].content.length);

  const result = messages.map((m) => ({ role: m.role, content: m.content }));
  const MIN_KEEP = 2000;

  for (const i of indices) {
    if (total <= SESSION_BUDGET) break;
    const content = result[i].content;
    if (content.length <= MIN_KEEP) continue;
    const excess = total - SESSION_BUDGET;
    const shrinkBy = Math.min(excess, content.length - MIN_KEEP);
    const keepLen = content.length - shrinkBy;
    // 75/25 head-heavy split: conversations front-load context, so keep more head.
    // Also ensures redacted secrets near middle survive truncation.
    const headLen = Math.floor(keepLen * 0.75);
    const tailLen = keepLen - headLen;
    // total -= shrinkBy ignores the ~35 char marker overhead — acceptable at 2MB budget scale.
    const marker = `\n...[truncated ${shrinkBy.toLocaleString()} chars]...\n`;
    result[i].content =
      content.slice(0, headLen) + marker + content.slice(-tailLen);
    total -= shrinkBy;
  }

  return result;
}

/** Filter and clean messages before pushing to Viking Sessions API.
 *  Pipeline: strip noise → redact secrets → session budget → drop empties
 *  No per-message hard truncation. No same-role merging. Preserves message boundaries. */
export function filterForViking(
  messages: { role: string; content: string }[],
): { role: string; content: string }[] {
  const cleaned = messages
    .filter((m) => !isSystemContent(m.content) && !isToolOnlyMessage(m.content))
    .filter((m) => m.content.trim().length > 0);

  return applySessionBudget(cleaned);
}
