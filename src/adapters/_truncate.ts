// Shared adapter helpers for safely truncating serialized tool payloads.
//
// JSON.stringify(value).slice(0, N) has two foot-guns:
//   1. When value is null/undefined the string becomes "null"/"undefined"
//      which surfaces literally in the transcript.
//   2. slice() cuts UTF-16 code units, which can land in the middle of a
//      surrogate pair and produce an invalid string that downstream JSON
//      encoders (or display layers) reject.
//
// `truncateJSON` returns `undefined` for missing payloads and trims surrogate
// pair fragments so the result stays well-formed.

export function truncateJSON(value: unknown, max: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  let json: string;
  try {
    json = JSON.stringify(value);
  } catch {
    return undefined;
  }
  if (json === undefined) return undefined;
  return truncateString(json, max);
}

export function truncateString(value: string, max: number): string {
  if (value.length <= max) return value;
  const cut = value.slice(0, max);
  const last = cut.charCodeAt(cut.length - 1);
  // A high-surrogate at the very end lost its low half to the cut — drop it.
  if (last >= 0xd800 && last <= 0xdbff) {
    return cut.slice(0, cut.length - 1);
  }
  // A low-surrogate at the end is only valid if the preceding unit is its
  // matching high-surrogate. If the input was malformed (a lone low half),
  // drop it so we never emit an unpaired surrogate.
  if (last >= 0xdc00 && last <= 0xdfff) {
    const prev = cut.length >= 2 ? cut.charCodeAt(cut.length - 2) : 0;
    if (prev < 0xd800 || prev > 0xdbff) {
      return cut.slice(0, cut.length - 1);
    }
  }
  return cut;
}
