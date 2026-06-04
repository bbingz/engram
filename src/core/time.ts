export function durationMinutes(
  startTime?: string | null,
  endTime?: string | null,
): number {
  if (!startTime || !endTime) return 0;
  const start = new Date(startTime).getTime();
  const end = new Date(endTime).getTime();
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 0;
  const duration = (end - start) / 60_000;
  return Number.isFinite(duration) ? duration : 0;
}
