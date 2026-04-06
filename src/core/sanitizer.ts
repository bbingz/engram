export const PII_PATTERNS: Array<{ name: string; regex: RegExp; replacement: string }> = [
  { name: 'anthropic_key', regex: /sk-ant-[a-zA-Z0-9-]{20,}/g,        replacement: 'sk-ant-***' },
  { name: 'openai_key',    regex: /sk-[a-zA-Z0-9_-]{20,}/g,            replacement: 'sk-***' },
  { name: 'bearer_token',  regex: /Bearer\s+[a-zA-Z0-9._\-]{10,}/gi,  replacement: 'Bearer ***' },
  { name: 'hex_secret',    regex: /((?:key|token|secret|password|apikey)[:=]\s*)[a-f0-9]{32,128}/gi, replacement: '$1***' },
  { name: 'email',         regex: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, replacement: '***@***.***' },
  { name: 'url_api_key',   regex: /([?&](?:key|apiKey|api_key))=[^&\s]+/gi,          replacement: '$1=***' },
]

export function sanitize(obj: Record<string, unknown>): Record<string, unknown> {
  return sanitizeValue(obj) as Record<string, unknown>
}

function sanitizeValue(value: unknown): unknown {
  if (typeof value === 'string') return applyPatterns(value)
  if (Array.isArray(value)) return value.map(sanitizeValue)
  if (value && typeof value === 'object') {
    const result: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value)) {
      result[k] = sanitizeValue(v)
    }
    return result
  }
  return value
}

export function applyPatterns(str: string): string {
  let result = str
  for (const { regex, replacement } of PII_PATTERNS) {
    regex.lastIndex = 0
    result = result.replace(regex, replacement)
  }
  return result
}
