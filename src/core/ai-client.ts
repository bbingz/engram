// src/core/ai-client.ts
import type { AiProtocol, FileSettings } from './config.js';
import { resolveSummaryConfig, getBaseURL } from './config.js';

// ── Types ────────────────────────────────────────────────────────────

export interface ConversationMessage {
  role: string;
  content: string;
}

// ── Default prompt template ──────────────────────────────────────────

const DEFAULT_PROMPT_TEMPLATE = `请用不超过 {{maxSentences}} 句话，以 {{language}} 总结以下 AI 编程对话的核心内容。
总结应包括：1) 主要讨论的问题或任务 2) 达成的结论、解决方案或关键成果
{{style}}
保持简洁。`;

// ── renderPromptTemplate ─────────────────────────────────────────────

export function renderPromptTemplate(settings: FileSettings): string {
  const template = settings.summaryPrompt || DEFAULT_PROMPT_TEMPLATE;
  const language = settings.summaryLanguage || '中文';
  const maxSentences = String(settings.summaryMaxSentences ?? 3);
  const styleRaw = settings.summaryStyle || '';
  const style = styleRaw ? `风格要求：${styleRaw}` : '';

  const rendered = template
    .replace(/\{\{language\}\}/g, language)
    .replace(/\{\{maxSentences\}\}/g, maxSentences)
    .replace(/\{\{style\}\}/g, style);

  // Remove lines that are blank after substitution
  return rendered
    .split('\n')
    .filter(line => line.trim() !== '')
    .join('\n');
}

// ── sampleMessages ───────────────────────────────────────────────────

export function sampleMessages(
  messages: ConversationMessage[],
  sampleFirst: number,
  sampleLast: number,
  truncateChars: number,
): ConversationMessage[] {
  const total = sampleFirst + sampleLast;
  const selected = messages.length <= total
    ? messages
    : [...messages.slice(0, sampleFirst), ...messages.slice(-sampleLast)];

  return selected.map(m => ({
    role: m.role,
    content: m.content.length > truncateChars
      ? m.content.slice(0, truncateChars) + '...'
      : m.content,
  }));
}

// ── buildRequestBody ─────────────────────────────────────────────────

export function buildRequestBody(
  protocol: AiProtocol,
  systemPrompt: string,
  conversationText: string,
  opts: { model: string; maxTokens: number; temperature: number },
): object {
  const userContent = `请总结以下对话：\n\n${conversationText}`;

  switch (protocol) {
    case 'openai':
      return {
        model: opts.model,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userContent },
        ],
        max_tokens: opts.maxTokens,
        temperature: opts.temperature,
      };
    case 'anthropic':
      return {
        model: opts.model,
        system: systemPrompt,
        messages: [
          { role: 'user', content: userContent },
        ],
        max_tokens: opts.maxTokens,
        temperature: opts.temperature,
      };
    case 'gemini':
      return {
        systemInstruction: { parts: [{ text: systemPrompt }] },
        contents: [
          { role: 'user', parts: [{ text: userContent }] },
        ],
        generationConfig: {
          maxOutputTokens: opts.maxTokens,
          temperature: opts.temperature,
        },
      };
    default:
      throw new Error(`Unsupported protocol: ${protocol as string}`);
  }
}

// ── summarizeConversation ────────────────────────────────────────────

export async function summarizeConversation(
  messages: ConversationMessage[],
  settings: FileSettings,
): Promise<string> {
  const protocol = settings.aiProtocol || 'openai';
  const apiKey = settings.aiApiKey || '';
  const model = settings.aiModel || 'gpt-4o-mini';

  const baseURL = getBaseURL(settings);
  if (!baseURL) {
    throw new Error(`No base URL configured for protocol: ${protocol}`);
  }

  const summaryConfig = resolveSummaryConfig(settings);
  const systemPrompt = renderPromptTemplate(settings);

  // Sample and format messages
  const sampled = sampleMessages(
    messages,
    summaryConfig.sampleFirst,
    summaryConfig.sampleLast,
    summaryConfig.truncateChars,
  );
  const conversationText = sampled
    .map(m => `[${m.role}] ${m.content}`)
    .join('\n\n');

  // Build URL
  let url: string;
  switch (protocol) {
    case 'openai':
      url = `${baseURL}/v1/chat/completions`;
      break;
    case 'anthropic':
      url = `${baseURL}/v1/messages`;
      break;
    case 'gemini':
      url = `${baseURL}/v1beta/models/${model}:generateContent?key=${apiKey}`;
      break;
    default:
      throw new Error(`Unsupported protocol: ${protocol as string}`);
  }

  // Build headers
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  switch (protocol) {
    case 'openai':
      headers['Authorization'] = `Bearer ${apiKey}`;
      break;
    case 'anthropic':
      headers['x-api-key'] = apiKey;
      headers['anthropic-version'] = '2023-06-01';
      break;
    // gemini: key is in URL, no auth header
  }

  // Build body
  const body = buildRequestBody(protocol, systemPrompt, conversationText, {
    model,
    maxTokens: summaryConfig.maxTokens,
    temperature: summaryConfig.temperature,
  });

  // Make request
  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`AI request failed (${response.status}): ${text}`);
  }

  const data = await response.json();

  // Extract response text
  switch (protocol) {
    case 'openai':
      return (data.choices?.[0]?.message?.content ?? '').trim();
    case 'anthropic':
      return (data.content?.[0]?.text ?? '').trim();
    case 'gemini':
      return (data.candidates?.[0]?.content?.parts?.[0]?.text ?? '').trim();
    default:
      throw new Error(`Unsupported protocol: ${protocol as string}`);
  }
}
