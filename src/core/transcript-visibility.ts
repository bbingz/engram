import type { SourceName } from '../adapters/types.js';

type SystemCategory = 'none' | 'systemPrompt' | 'agentComm';

interface VisibleTranscriptMessageInput {
  role: string;
  content: string;
}

export function classifySystemContent(
  content: string,
  source?: SourceName | string,
): SystemCategory {
  const prefixContent = content.trim();
  const sourceName = String(source ?? '').toLowerCase();
  const isAntigravity =
    sourceName === 'antigravity' || sourceName === 'antigravity-legacy';

  if (prefixContent.startsWith('# AGENTS.md instructions for '))
    return 'systemPrompt';
  if (content.includes('<INSTRUCTIONS>')) return 'systemPrompt';
  if (prefixContent.startsWith('<system-reminder>')) return 'systemPrompt';
  if (prefixContent.startsWith('<environment_context>')) return 'systemPrompt';
  if (prefixContent.startsWith('<EXTREMELY_IMPORTANT>')) return 'systemPrompt';
  if (isAntigravity && isSystemMessageWrapper(prefixContent))
    return 'systemPrompt';
  if (prefixContent.startsWith('You are Qwen Code')) return 'systemPrompt';

  if (prefixContent.startsWith('<subagent_notification>')) return 'agentComm';
  if (content.includes('<command-name>')) return 'agentComm';
  if (content.includes('<command-message>')) return 'agentComm';
  if (prefixContent.startsWith('<local-command-caveat>')) return 'agentComm';
  if (prefixContent.startsWith('<local-command-stdout>')) return 'agentComm';
  if (prefixContent.startsWith('Unknown skill: ')) return 'agentComm';
  if (prefixContent.startsWith('Invoke the superpowers:')) return 'agentComm';
  if (prefixContent.startsWith('Base directory for this skill:'))
    return 'agentComm';

  return 'none';
}

export function isDefaultVisibleTranscriptMessage(
  message: VisibleTranscriptMessageInput,
  source?: SourceName | string,
): boolean {
  if (message.role !== 'user' && message.role !== 'assistant') return false;
  if (!message.content.trim()) return false;
  if (message.role === 'user') {
    return classifySystemContent(message.content, source) === 'none';
  }
  return true;
}

function isSystemMessageWrapper(content: string): boolean {
  return (
    content.startsWith('<SYSTEM_MESSAGE>') ||
    content.startsWith('The following is a <SYSTEM_MESSAGE>')
  );
}
