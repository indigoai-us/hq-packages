// Time formatting for the booking pages. Pure functions on Intl, no DOM, so
// node --test can run them.

/** "15:00" -> "3:00pm" (12h) or "15:00" (24h). */
export function formatClock(hhmm: string, hour12: boolean): string {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm);
  if (!m) return hhmm;
  const h = Number(m[1]);
  const min = m[2] as string;
  if (!hour12) return `${String(h).padStart(2, "0")}:${min}`;
  const suffix = h < 12 ? "am" : "pm";
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${min}${suffix}`;
}

/** Wall-clock parts of an instant in a zone. */
export function wall(iso: string | number | Date, tz: string): { date: string; time: string; weekday: number } {
  const d = new Date(iso);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    weekday: "short",
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(get("weekday"));
  return { date: `${get("year")}-${get("month")}-${get("day")}`, time: `${get("hour")}:${get("minute")}`, weekday };
}

/** "Tuesday, November 3, 2026" for a YYYY-MM-DD date. */
export function formatDateLong(date: string, locale = "en-US"): string {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  return new Intl.DateTimeFormat(locale, { timeZone: "UTC", weekday: "long", month: "long", day: "numeric", year: "numeric" }).format(Date.UTC(y, m - 1, d));
}

/** "Tue, Nov 3" for a YYYY-MM-DD date. */
export function formatDateShort(date: string, locale = "en-US"): string {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  return new Intl.DateTimeFormat(locale, { timeZone: "UTC", weekday: "short", month: "short", day: "numeric" }).format(Date.UTC(y, m - 1, d));
}

/** "3:00pm – 3:30pm, Tuesday, November 3, 2026" in the zone. */
export function formatRange(start: string, end: string, tz: string, hour12: boolean): string {
  const a = wall(start, tz);
  const b = wall(end, tz);
  return `${formatClock(a.time, hour12)} – ${formatClock(b.time, hour12)}, ${formatDateLong(a.date)}`;
}

/** "Nov 3, 3:00pm" in the zone; for lists. */
export function formatInstant(iso: string, tz: string, hour12: boolean): string {
  const w = wall(iso, tz);
  const [y, m, d] = w.date.split("-").map(Number) as [number, number, number];
  const day = new Intl.DateTimeFormat("en-US", { timeZone: "UTC", month: "short", day: "numeric" }).format(Date.UTC(y, m - 1, d));
  return `${day}, ${formatClock(w.time, hour12)}`;
}

/** 30 -> "30 min", 60 -> "1 hr", 90 -> "1 hr 30 min". */
export function formatDuration(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m ? `${h} hr ${m} min` : `${h} hr`;
}

/** Milliseconds left -> "4:05". Never negative. */
export function formatCountdown(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

/** "in 3 hours", "in 12 minutes", "ended". */
export function formatTimeLeft(ms: number): string {
  if (ms <= 0) return "ended";
  const min = Math.round(ms / 60000);
  if (min < 60) return `${Math.max(1, min)} min left`;
  const h = Math.floor(min / 60);
  return `${h} hr ${min % 60 ? `${min % 60} min ` : ""}left`;
}

/** UTC offset of a zone at an instant, like "GMT-5" or "GMT+5:30". */
export function zoneOffset(tz: string, at: number = Date.now()): string {
  try {
    const part = new Intl.DateTimeFormat("en-US", { timeZone: tz, timeZoneName: "shortOffset" }).formatToParts(at).find((p) => p.type === "timeZoneName");
    return part?.value ?? "";
  } catch {
    return "";
  }
}

/** "America/New_York" -> "New York (GMT-5)". */
export function zoneLabel(tz: string, at?: number): string {
  const city = tz.split("/").pop()?.replace(/_/g, " ") ?? tz;
  const off = zoneOffset(tz, at);
  return off ? `${city} (${off})` : city;
}

export function isValidZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/** Zones for the picker, the given ones first. */
export function zoneList(extra: string[] = []): string[] {
  const intl = Intl as unknown as { supportedValuesOf?: (k: string) => string[] };
  const all = intl.supportedValuesOf ? intl.supportedValuesOf("timeZone") : ["UTC", "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "Europe/London", "Europe/Paris", "Asia/Tokyo", "Australia/Sydney"];
  const set = new Set([...extra.filter(isValidZone), ...all]);
  return [...set];
}

/** Guess 12h vs 24h from a locale. */
export function prefersHour12(locale: string): boolean {
  try {
    const opts = new Intl.DateTimeFormat(locale, { hour: "numeric" }).resolvedOptions() as { hour12?: boolean; hourCycle?: string };
    if (typeof opts.hour12 === "boolean") return opts.hour12;
    return opts.hourCycle === "h12" || opts.hourCycle === "h11";
  } catch {
    return true;
  }
}

export interface MonthCell {
  date: string;
  day: number;
  inMonth: boolean;
}

/** Weeks of a month (Sunday first), padded with days of the next and previous months. */
export function monthGrid(year: number, month: number): MonthCell[][] {
  const first = new Date(Date.UTC(year, month - 1, 1));
  const startOffset = first.getUTCDay();
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const cells: MonthCell[] = [];
  const totalCells = Math.ceil((startOffset + daysInMonth) / 7) * 7;
  for (let i = 0; i < totalCells; i++) {
    const d = new Date(Date.UTC(year, month - 1, 1 - startOffset + i));
    cells.push({ date: d.toISOString().slice(0, 10), day: d.getUTCDate(), inMonth: d.getUTCMonth() === month - 1 });
  }
  const weeks: MonthCell[][] = [];
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
  return weeks;
}

export function monthTitle(year: number, month: number, locale = "en-US"): string {
  return new Intl.DateTimeFormat(locale, { timeZone: "UTC", month: "long", year: "numeric" }).format(Date.UTC(year, month - 1, 1));
}

export function addMonths(year: number, month: number, n: number): { year: number; month: number } {
  const idx = year * 12 + (month - 1) + n;
  return { year: Math.floor(idx / 12), month: (idx % 12) + 1 };
}

/** The instant a wall-clock date and time has in a zone (handles DST by one correction pass). */
export function zonedInstant(date: string, time: string, tz: string): number {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  const [hh, mm] = time.split(":").map(Number) as [number, number];
  const guess = Date.UTC(y, m - 1, d, hh, mm);
  const offsetAt = (t: number) => {
    const w = wall(t, tz);
    const [wy, wm, wd] = w.date.split("-").map(Number) as [number, number, number];
    const [wh, wmin] = w.time.split(":").map(Number) as [number, number];
    return Date.UTC(wy, wm - 1, wd, wh, wmin) - t;
  };
  let t = guess - offsetAt(guess);
  t = guess - offsetAt(t);
  return t;
}

/** Monday (UTC date) of the week containing a date. */
export function weekStart(date: string): string {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  const dt = new Date(Date.UTC(y, m - 1, d));
  const dow = (dt.getUTCDay() + 6) % 7;
  dt.setUTCDate(dt.getUTCDate() - dow);
  return dt.toISOString().slice(0, 10);
}

export function addDays(date: string, n: number): string {
  const [y, m, d] = date.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

/** Minutes since midnight for "HH:MM". */
export function clockMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number) as [number, number];
  return h * 60 + m;
}
