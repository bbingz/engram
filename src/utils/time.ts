// src/utils/time.ts
// UTC ISO 字符串 → 本地时区显示，DB 内仍存 UTC，仅在输出层转换

const TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;

export interface LocalTimeRange {
  startUtcIso: string;
  endUtcIso: string;
  monthStartUtcIso: string;
  nextMonthStartUtcIso: string;
  localDate: string;
  localMonth: string;
}

function toShiftedDate(value: Date, timeZoneOffsetMinutes: number): Date {
  return new Date(value.getTime() - timeZoneOffsetMinutes * 60_000);
}

function toUtcIso(ms: number): string {
  return new Date(ms).toISOString();
}

export function getLocalTimeRange(
  now: Date = new Date(),
  timeZoneOffsetMinutes: number = now.getTimezoneOffset(),
): LocalTimeRange {
  const shifted = toShiftedDate(now, timeZoneOffsetMinutes);
  const localDate = shifted.toISOString().slice(0, 10);
  const localMonth = localDate.slice(0, 7);

  const startShiftedMs = Date.UTC(
    shifted.getUTCFullYear(),
    shifted.getUTCMonth(),
    shifted.getUTCDate(),
  );
  const monthStartShiftedMs = Date.UTC(
    shifted.getUTCFullYear(),
    shifted.getUTCMonth(),
    1,
  );
  const nextMonthStartShiftedMs = Date.UTC(
    shifted.getUTCFullYear(),
    shifted.getUTCMonth() + 1,
    1,
  );

  const startUtcMs = startShiftedMs + timeZoneOffsetMinutes * 60_000;
  const monthStartUtcMs = monthStartShiftedMs + timeZoneOffsetMinutes * 60_000;
  const nextMonthStartUtcMs =
    nextMonthStartShiftedMs + timeZoneOffsetMinutes * 60_000;

  return {
    startUtcIso: toUtcIso(startUtcMs),
    endUtcIso: toUtcIso(startUtcMs + 24 * 60 * 60 * 1000),
    monthStartUtcIso: toUtcIso(monthStartUtcMs),
    nextMonthStartUtcIso: toUtcIso(nextMonthStartUtcMs),
    localDate,
    localMonth,
  };
}

/**
 * UTC ISO → 本地日期时间字符串 "YYYY-MM-DD HH:mm:ss"
 */
export function toLocalDateTime(utcString: string | undefined): string {
  if (!utcString) return '';
  try {
    return new Date(utcString)
      .toLocaleString('sv', { timeZone: TZ })
      .replace('T', ' ');
  } catch {
    return utcString;
  }
}

/**
 * UTC ISO → 本地日期字符串 "YYYY-MM-DD"
 */
export function toLocalDate(utcString: string | undefined): string {
  if (!utcString) return '';
  try {
    return new Date(utcString).toLocaleDateString('sv', { timeZone: TZ });
  } catch {
    return utcString.slice(0, 10);
  }
}

/**
 * UTC ISO → 本地所在周的周日（YYYY-MM-DD），用于 stats week 分组
 */
// biome-ignore lint/correctness/noUnusedVariables: kept for potential future use
function toLocalWeekStart(utcString: string): string {
  try {
    const localDate = new Date(utcString).toLocaleDateString('sv', {
      timeZone: TZ,
    });
    const [y, m, d] = localDate.split('-').map(Number);
    const date = new Date(y, m - 1, d);
    date.setDate(d - date.getDay());
    const wy = date.getFullYear();
    const wm = String(date.getMonth() + 1).padStart(2, '0');
    const wd = String(date.getDate()).padStart(2, '0');
    return `${wy}-${wm}-${wd}`;
  } catch {
    const d = new Date(utcString);
    d.setDate(d.getDate() - d.getDay());
    return d.toISOString().slice(0, 10);
  }
}
