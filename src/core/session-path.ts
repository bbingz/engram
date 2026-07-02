import { existsSync } from 'node:fs';

export function isReadableSessionPath(
  value: string | null | undefined,
): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    !value.startsWith('sync://')
  );
}

export function pickReadableSessionPath(
  ...values: Array<string | null | undefined>
): string {
  const readable = values.filter(isReadableSessionPath);
  for (const value of readable) {
    if (existsSync(value)) return value;
  }
  return readable[0] ?? '';
}
