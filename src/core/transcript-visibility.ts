import type { SourceName } from '../adapters/types.js';

export type SystemCategory = 'none' | 'systemPrompt' | 'agentComm';

export interface VisibleTranscriptMessageInput {
  role: string;
  content: string;
}

export function classifySystemContent(
  content: string,
  _source?: SourceName | string,
): SystemCategory {
  if (content.startsWith('# AGENTS.md instructions for '))
    return 'systemPrompt';
  if (content.includes('<INSTRUCTIONS>')) return 'systemPrompt';
  if (content.startsWith('<system-reminder>')) return 'systemPrompt';
  if (content.startsWith('<environment_context>')) return 'systemPrompt';
  if (content.startsWith('<EXTREMELY_IMPORTANT>')) return 'systemPrompt';
  if (isSystemMessageWrapper(content)) return 'systemPrompt';
  if (content.startsWith('\nYou are Qwen Code')) return 'systemPrompt';
  if (content.startsWith('You are Qwen Code')) return 'systemPrompt';

  if (content.startsWith('<subagent_notification>')) return 'agentComm';
  if (content.includes('<command-name>')) return 'agentComm';
  if (content.includes('<command-message>')) return 'agentComm';
  if (content.startsWith('<local-command-caveat>')) return 'agentComm';
  if (content.startsWith('<local-command-stdout>')) return 'agentComm';
  if (content.startsWith('Unknown skill: ')) return 'agentComm';
  if (content.startsWith('Invoke the superpowers:')) return 'agentComm';
  if (content.startsWith('Base directory for this skill:')) return 'agentComm';

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
