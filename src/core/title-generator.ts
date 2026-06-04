// src/core/title-generator.ts

import type { AiAuditWriter } from './ai-audit.js';
import { joinApiUrl, normalizeOpenAICompatibleModel } from './config.js';

interface TitleGeneratorConfig {
  provider: 'ollama' | 'openai' | 'dashscope' | 'custom';
  baseUrl: string;
  model: string;
  apiKey?: string;
  autoGenerate: boolean;
  audit?: AiAuditWriter;
}

export class TitleGenerator {
  private audit?: AiAuditWriter;

  constructor(private config: TitleGeneratorConfig) {
    this.audit = config.audit;
  }

  async generate(
    messages: { role: string; content: string }[],
  ): Promise<string | null> {
    if (!this.config.autoGenerate) return null;
    if (messages.length === 0) return null;
    const prompt = buildTitlePrompt(messages.slice(0, 6));
    try {
      return await this.callLLM(prompt);
    } catch (err) {
      console.error('[title-gen] Failed:', err); // stderr → os_log in daemon mode
      return null;
    }
  }

  private async callLLM(prompt: string): Promise<string> {
    const isOllama = this.config.provider === 'ollama';
    const url = isOllama
      ? joinApiUrl(this.config.baseUrl, '/api/generate')
      : joinApiUrl(this.config.baseUrl, '/v1/chat/completions');

    const body = isOllama
      ? { model: this.config.model, prompt, stream: false }
      : {
          model: normalizeOpenAICompatibleModel(
            this.config.model,
            this.config.baseUrl,
          ),
          messages: [{ role: 'user', content: prompt }],
          max_tokens: 50,
          temperature: 0.3,
        };

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };
    if (this.config.apiKey)
      headers.Authorization = `Bearer ${this.config.apiKey}`;

    const start = Date.now();
    const timeout = createTimeoutSignal(15000);
    let res: Response | null = null;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: timeout.signal,
      });

      // biome-ignore lint/suspicious/noExplicitAny: LLM API response shape varies by provider (Ollama vs OpenAI)
      const json = (await res.json()) as Record<string, any>;

      const raw = isOllama
        ? (json.response as string)
        : (json.choices?.[0]?.message?.content as string);

      const result = parseTitleResponse(raw || '');

      // Extract token counts — field names differ by provider
      const promptTokens: number | undefined = isOllama
        ? (json.prompt_eval_count ?? undefined)
        : (json.usage?.prompt_tokens ?? undefined);
      const completionTokens: number | undefined = isOllama
        ? (json.eval_count ?? undefined)
        : (json.usage?.completion_tokens ?? undefined);

      this.audit?.record({
        caller: 'title',
        operation: 'generate',
        method: 'POST',
        url,
        statusCode: res.status,
        model: this.config.model,
        provider: this.config.provider,
        promptTokens,
        completionTokens,
        totalTokens: (promptTokens ?? 0) + (completionTokens ?? 0) || undefined,
        durationMs: Date.now() - start,
        requestBody: { prompt },
        responseBody: { text: result },
      });

      return result;
    } catch (err) {
      if (res === null) {
        this.audit?.record({
          caller: 'title',
          operation: 'generate',
          method: 'POST',
          url,
          model: this.config.model,
          provider: this.config.provider,
          durationMs: Date.now() - start,
          requestBody: { prompt },
          error: err instanceof Error ? err.message : String(err),
        });
      }
      throw err;
    } finally {
      timeout.cleanup();
    }
  }
}

function createTimeoutSignal(ms: number): {
  signal: AbortSignal;
  cleanup: () => void;
} {
  const controller = new AbortController();
  const timer = setTimeout(() => {
    controller.abort(new Error(`Timed out after ${ms}ms`));
  }, ms);
  return {
    signal: controller.signal,
    cleanup: () => clearTimeout(timer),
  };
}

export function buildTitlePrompt(
  messages: { role: string; content: string }[],
): string {
  const turns = messages
    .map((m) => `[${m.role}]: ${m.content.slice(0, 200)}`)
    .join('\n');

  return `Generate a concise title (≤30 characters) for this AI coding conversation. Match the conversation's language (Chinese conversation → Chinese title, English → English). Return ONLY the title, no quotes or prefix.\n\n${turns}`;
}

export function parseTitleResponse(raw: string): string {
  let title = raw.trim();
  title = title.replace(/^(Title:|标题[:：])\s*/i, '');
  title = title.replace(/^["'「]|["'」]$/g, '');
  if (title.length > 30) title = title.slice(0, 30);
  return title;
}
