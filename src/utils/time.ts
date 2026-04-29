// src/utils/time.ts
// UTC ISO 字符串 → 本地时区显示，DB 内仍存 UTC，仅在输出层转换

const TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;

interface LocalTimeRange {
  startUtcIso: string;
  endUtcIso: string;
  monthStartUtcIso: string;
  nextMonthStartUtcIso: string;
  localDate: string;
  localMonth: string;
}

interface LocalDateParts {
  year: number;
  month: number;
  day: number;
}

function toUtcIso(ms: number): string {
  return new Date(ms).toISOString();
}

function getLocalDateParts(value: Date, timeZone: string): LocalDateParts {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(value);
  return {
    year: Number(parts.find((part) => part.type === 'year')?.value),
    month: Number(parts.find((part) => part.type === 'month')?.value),
    day: Number(parts.find((part) => part.type === 'day')?.value),
  };
}

function getOffsetMilliseconds(value: Date, timeZone: string): number {
  const timeZoneName = new Intl.DateTimeFormat('en-US', {
    timeZone,
    timeZoneName: 'longOffset',
    hour: '2-digit',
    minute: '2-digit',
  })
    .formatToParts(value)
    .find((part) => part.type === 'timeZoneName')?.value;
  if (!timeZoneName || timeZoneName === 'GMT') return 0;

  const match = timeZoneName.match(/^GMT([+-])(\d{1,2})(?::(\d{2}))?$/);
  if (!match)
    throw new RangeError(`Unsupported time zone offset: ${timeZoneName}`);

  const [, sign, hours, minutes = '00'] = match;
  const totalMinutes = Number(hours) * 60 + Number(minutes);
  return (sign === '+' ? 1 : -1) * totalMinutes * 60_000;
}

function resolveLocalMidnightUtc(
  year: number,
  month: number,
  day: number,
  timeZone: string,
): number {
  let utcMs = Date.UTC(year, month - 1, day, 0, 0, 0);
  for (let i = 0; i < 3; i++) {
    const offsetMs = getOffsetMilliseconds(new Date(utcMs), timeZone);
    const nextUtcMs = Date.UTC(year, month - 1, day, 0, 0, 0) - offsetMs;
    if (nextUtcMs === utcMs) break;
    utcMs = nextUtcMs;
  }
  return utcMs;
}

function shiftLocalDay(
  { year, month, day }: LocalDateParts,
  deltaDays: number,
): LocalDateParts {
  const shifted = new Date(Date.UTC(year, month - 1, day, 0, 0, 0));
  shifted.setUTCDate(shifted.getUTCDate() + deltaDays);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate(),
  };
}

function startOfNextMonth({ year, month }: LocalDateParts): LocalDateParts {
  const shifted = new Date(Date.UTC(year, month - 1, 1, 0, 0, 0));
  shifted.setUTCMonth(shifted.getUTCMonth() + 1);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: 1,
  };
}

export function getLocalTimeRange(
  now: Date = new Date(),
  timeZone: string = TZ,
): LocalTimeRange {
  const localParts = getLocalDateParts(now, timeZone);
  const nextDayParts = shiftLocalDay(localParts, 1);
  const monthStartParts = { ...localParts, day: 1 };
  const nextMonthParts = startOfNextMonth(monthStartParts);

  const startUtcMs = resolveLocalMidnightUtc(
    localParts.year,
    localParts.month,
    localParts.day,
    timeZone,
  );
  const endUtcMs = resolveLocalMidnightUtc(
    nextDayParts.year,
    nextDayParts.month,
    nextDayParts.day,
    timeZone,
  );
  const monthStartUtcMs = resolveLocalMidnightUtc(
    monthStartParts.year,
    monthStartParts.month,
    monthStartParts.day,
    timeZone,
  );
  const nextMonthStartUtcMs = resolveLocalMidnightUtc(
    nextMonthParts.year,
    nextMonthParts.month,
    nextMonthParts.day,
    timeZone,
  );
  const localDate = `${String(localParts.year).padStart(4, '0')}-${String(localParts.month).padStart(2, '0')}-${String(localParts.day).padStart(2, '0')}`;
  const localMonth = `${String(localParts.year).padStart(4, '0')}-${String(localParts.month).padStart(2, '0')}`;

  return {
    startUtcIso: toUtcIso(startUtcMs),
    endUtcIso: toUtcIso(endUtcMs),
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
