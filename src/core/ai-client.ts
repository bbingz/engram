// src/core/ai-client.ts
import OpenAI from 'openai';
import Anthropic from '@anthropic-ai/sdk';

export interface SummarizeOptions {
  provider: 'openai' | 'anthropic';
  apiKey: string;
  model: string;
  maxTokens?: number;
}

export interface ConversationMessage {
  role: string;
  content: string;
}

const SUMMARY_PROMPT = `请用 2-3 句话总结以下 AI 编程对话的核心内容。总结应包括：
1) 主要讨论的问题或任务
2) 达成的结论、解决方案或关键成果

保持简洁，使用中文回复。`;

export async function summarizeConversation(
  messages: ConversationMessage[],
  options: SummarizeOptions
): Promise<string> {
  // Limit messages to control token usage
  // Take first 20 and last 30 messages to capture beginning and end
  const limitedMessages = messages.length <= 50
    ? messages
    : [...messages.slice(0, 20), ...messages.slice(-30)];

  const conversationText = limitedMessages
    .map(m => `[${m.role}] ${m.content.slice(0, 500)}${m.content.length > 500 ? '...' : ''}`)
    .join('\n\n');

  if (options.provider === 'openai') {
    return summarizeWithOpenAI(conversationText, options);
  } else {
    return summarizeWithAnthropic(conversationText, options);
  }
}

async function summarizeWithOpenAI(
  conversationText: string,
  options: SummarizeOptions
): Promise<string> {
  const client = new OpenAI({ apiKey: options.apiKey });

  const response = await client.chat.completions.create({
    model: options.model || 'gpt-4o-mini',
    messages: [
      { role: 'system', content: SUMMARY_PROMPT },
      { role: 'user', content: `请总结以下对话：\n\n${conversationText}` }
    ],
    max_tokens: options.maxTokens || 200,
    temperature: 0.3,
  });

  return response.choices[0]?.message?.content?.trim() || '';
}

async function summarizeWithAnthropic(
  conversationText: string,
  options: SummarizeOptions
): Promise<string> {
  const client = new Anthropic({ apiKey: options.apiKey });

  const response = await client.messages.create({
    model: options.model || 'claude-3-haiku-20240307',
    max_tokens: options.maxTokens || 200,
    temperature: 0.3,
    system: SUMMARY_PROMPT,
    messages: [
      { role: 'user', content: `请总结以下对话：\n\n${conversationText}` }
    ],
  });

  const content = response.content[0];
  if (content.type === 'text') {
    return content.text.trim();
  }
  return '';
}
