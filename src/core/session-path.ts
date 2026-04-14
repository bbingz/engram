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
  for (const value of values) {
    if (isReadableSessionPath(value)) return value;
  }
  return '';
}
