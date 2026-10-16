// Time zone helpers built on Intl, so the engine needs no time library.
// All instants are epoch milliseconds. Wall times are a calendar date plus
// minutes since local midnight in a named IANA zone.

export const MINUTE = 60_000;
export const DAY = 86_400_000;

export const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] as const;
export type Weekday = (typeof WEEKDAYS)[number];

export interface WallParts {
  date: string; // YYYY-MM-DD
  minutes: number; // minutes since local midnight
  weekday: Weekday;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      weekday: "short",
    });
    formatters.set(timeZone, f);
  }
  return f;
}

export function isValidTimeZone(timeZone: string): boolean {
  try {
    formatter(timeZone);
    return true;
  } catch {
    return false;
  }
}

export function wallParts(instant: number, timeZone: string): WallParts {
  const parts: Record<string, string> = {};
  for (const p of formatter(timeZone).formatToParts(new Date(instant))) parts[p.type] = p.value;
  const weekday = (parts.weekday ?? "").toLowerCase().slice(0, 3) as Weekday;
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    minutes: Number(parts.hour) * 60 + Number(parts.minute),
    weekday,
  };
}

/** Offset of the zone from UTC at an instant, in minutes (east positive). */
export function offsetMinutes(instant: number, timeZone: string): number {
  const floored = Math.floor(instant / MINUTE) * MINUTE;
  const w = wallParts(floored, timeZone);
  const [y, m, d] = w.date.split("-").map(Number) as [number, number, number];
  const asUtc = Date.UTC(y, m - 1, d) + w.minutes * MINUTE;
  return Math.round((asUtc - floored) / MINUTE);
}

export function parseDate(date: string): { y: number; m: number; d: number } | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!match) return null;
  const y = Number(match[1]);
  const m = Number(match[2]);
  const d = Number(match[3]);
  const check = new Date(Date.UTC(y, m - 1, d));
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== m - 1 || check.getUTCDate() !== d) return null;
  return { y, m, d };
}

export function addDays(date: string, days: number): string {
  const p = parseDate(date);
  if (!p) throw new Error(`bad date ${date}`);
  const t = new Date(Date.UTC(p.y, p.m - 1, p.d) + days * DAY);
  return t.toISOString().slice(0, 10);
}

export function weekdayOf(date: string): Weekday {
  const p = parseDate(date);
  if (!p) throw new Error(`bad date ${date}`);
  return WEEKDAYS[new Date(Date.UTC(p.y, p.m - 1, p.d)).getUTCDay()] as Weekday;
}

/**
 * The instant at which the wall clock in `timeZone` reads `date` + `minutes`.
 * Returns null when that wall time does not exist (skipped by a DST change).
 * When it occurs twice (clocks fall back) the earlier instant is returned.
 * minutes may be 1440 to mean the following midnight.
 */
export function wallToInstant(date: string, minutes: number, timeZone: string): number | null {
  if (minutes === 1440) return wallToInstant(addDays(date, 1), 0, timeZone);
  const p = parseDate(date);
  if (!p) throw new Error(`bad date ${date}`);
  const naive = Date.UTC(p.y, p.m - 1, p.d) + minutes * MINUTE;
  const candidates = new Set<number>();
  for (const probe of [naive - 12 * 60 * MINUTE, naive, naive + 12 * 60 * MINUTE]) {
    candidates.add(naive - offsetMinutes(probe, timeZone) * MINUTE);
  }
  const valid = [...candidates].filter((t) => {
    const w = wallParts(t, timeZone);
    return w.date === date && w.minutes === minutes;
  });
  if (valid.length === 0) return null;
  return Math.min(...valid);
}

export function parseRange(range: string): { start: number; end: number } {
  const [a, b] = range.split("-") as [string, string];
  const toMin = (s: string) => {
    const [h, m] = s.split(":").map(Number) as [number, number];
    return h * 60 + m;
  };
  return { start: toMin(a), end: toMin(b) };
}
