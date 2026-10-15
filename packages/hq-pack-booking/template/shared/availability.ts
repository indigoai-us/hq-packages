// The availability engine: which start times can be offered for an event type,
// given each host's working hours, date overrides, holidays, busy times and
// existing bookings. Pure functions, no I/O. The same code runs in the booking
// API, the launcher's preview and the tests.

import type { EventType, Host, Kind } from "./config.ts";
import { addDays, DAY, MINUTE, parseRange, wallParts, wallToInstant, weekdayOf } from "./time.ts";

export interface Interval {
  start: number;
  end: number;
}

/** A host as the engine sees them: config plus merged busy times. */
export interface HostInput {
  id: string;
  timezone: string;
  hours: Host["hours"];
  overrides?: Host["overrides"];
  holidays?: string[];
  /** Busy blocks merged from every conflict calendar. Titles never reach here. */
  busy: Interval[];
}

export interface ExistingBooking {
  eventTypeId: string;
  hostIds: string[];
  start: number;
  end: number;
  /** Seats taken by this booking (group events). Defaults to 1. */
  seats?: number;
}

export interface SlotQuery {
  eventType: Pick<EventType, "id" | "kind" | "hosts" | "durations" | "startIncrement" | "buffers" | "minimumNotice" | "bookingWindow" | "dailyLimit" | "seats">;
  duration: number;
  hosts: HostInput[];
  bookings: ExistingBooking[];
  now: number;
  /** Optional narrower range inside the booking window. */
  from?: number;
  to?: number;
}

export interface Slot {
  start: number;
  end: number;
  /** round-robin: hosts free at this time (pick one with assignment.ts). Others: hosts who attend. */
  hostIds: string[];
  /** group events only */
  seatsLeft?: number;
}

const DEFAULT_INCREMENT = 15;
const DEFAULT_WINDOW_DAYS = 60;

export class SlotQueryError extends Error {}

export function computeSlots(q: SlotQuery): Slot[] {
  const ev = q.eventType;
  if (!ev.durations.includes(q.duration)) throw new SlotQueryError(`duration ${q.duration} is not offered by ${ev.id}`);
  const hostById = new Map(q.hosts.map((h) => [h.id, h]));
  const hosts = ev.hosts.map((id) => {
    const h = hostById.get(id);
    if (!h) throw new SlotQueryError(`no availability input for host ${id}`);
    return h;
  });

  const durationMs = q.duration * MINUTE;
  const before = (ev.buffers?.before ?? 0) * MINUTE;
  const after = (ev.buffers?.after ?? 0) * MINUTE;
  const increment = ev.startIncrement ?? DEFAULT_INCREMENT;
  const earliest = Math.max(q.now + (ev.minimumNotice ?? 0) * MINUTE, q.from ?? -Infinity);
  const latest = Math.min(q.now + (ev.bookingWindow ?? DEFAULT_WINDOW_DAYS) * DAY, q.to ?? Infinity);
  if (!(latest > earliest)) return [];

  // Bookings of this group event at the same time share a slot instead of
  // blocking it, so they are taken out of the busy times before checking.
  const sameGroupSlot = (b: ExistingBooking) => ev.kind === "group" && b.eventTypeId === ev.id;

  const perHost = hosts.map((host) => {
    const starts = workingStarts(host, increment, durationMs, earliest, latest);
    const busy = host.busy
      .filter((blk) => !(ev.kind === "group" && q.bookings.some((b) => sameGroupSlot(b) && b.start === blk.start && b.end === blk.end && b.hostIds.includes(host.id))))
      .concat(q.bookings.filter((b) => b.hostIds.includes(host.id) && !sameGroupSlot(b)).map((b) => ({ start: b.start, end: b.end })))
      .sort((a, b) => a.start - b.start);
    const perDay = new Map<string, number>();
    if (ev.dailyLimit !== undefined) {
      for (const b of q.bookings) {
        if (b.eventTypeId !== ev.id || !b.hostIds.includes(host.id)) continue;
        const day = wallParts(b.start, host.timezone).date;
        perDay.set(day, (perDay.get(day) ?? 0) + 1);
      }
    }
    return { host, starts, busy, perDay };
  });

  const allStarts = new Set<number>();
  for (const h of perHost) for (const s of h.starts) allStarts.add(s);
  const ordered = [...allStarts].sort((a, b) => a - b);

  const slots: Slot[] = [];
  for (const start of ordered) {
    const end = start + durationMs;
    const free = perHost.filter((h) => {
      if (!h.starts.has(start)) return false;
      if (overlapsAny(h.busy, start - before, end + after)) return false;
      if (ev.dailyLimit !== undefined) {
        const day = wallParts(start, h.host.timezone).date;
        if ((h.perDay.get(day) ?? 0) >= ev.dailyLimit) return false;
      }
      return true;
    });
    const slot = combine(ev.kind, ev.id, ev.seats, perHost.length, free.map((f) => f.host.id), start, end, q.bookings);
    if (slot) slots.push(slot);
  }
  return slots;
}

function combine(
  kind: Kind,
  eventTypeId: string,
  seats: number | undefined,
  hostCount: number,
  freeIds: string[],
  start: number,
  end: number,
  bookings: ExistingBooking[],
): Slot | null {
  switch (kind) {
    case "one-on-one":
    case "round-robin":
      return freeIds.length > 0 ? { start, end, hostIds: freeIds } : null;
    case "collective":
      return freeIds.length === hostCount ? { start, end, hostIds: freeIds } : null;
    case "group": {
      if (freeIds.length !== hostCount) return null;
      const taken = bookings
        .filter((b) => b.eventTypeId === eventTypeId && b.start === start)
        .reduce((n, b) => n + (b.seats ?? 1), 0);
      const left = (seats ?? 0) - taken;
      return left > 0 ? { start, end, hostIds: freeIds, seatsLeft: left } : null;
    }
  }
}

/** Start instants inside the host's working hours for the window. */
function workingStarts(host: HostInput, increment: number, durationMs: number, earliest: number, latest: number): Set<number> {
  const starts = new Set<number>();
  const holidays = new Set(host.holidays ?? []);
  const overrides = new Map((host.overrides ?? []).map((o) => [o.date, o.hours]));
  const firstDay = addDays(wallParts(earliest, host.timezone).date, -1);
  const lastDay = addDays(wallParts(latest, host.timezone).date, 1);

  for (let date = firstDay; date <= lastDay; date = addDays(date, 1)) {
    if (holidays.has(date)) continue;
    const ranges = overrides.get(date) ?? host.hours[weekdayOf(date)] ?? [];
    for (const range of ranges) {
      const { start: rs, end: re } = parseRange(range);
      const rangeStart = wallToInstant(date, rs, host.timezone) ?? firstInstantAfterGap(date, rs, host.timezone);
      const rangeEnd = wallToInstant(date, re, host.timezone) ?? firstInstantAfterGap(date, re, host.timezone);
      if (rangeStart === null || rangeEnd === null) continue;
      for (let m = rs; m + durationMs / MINUTE <= re + 60; m += increment) {
        const s = wallToInstant(date, m, host.timezone);
        if (s === null) continue; // skipped by a DST change
        const e = s + durationMs;
        if (s < rangeStart || e > rangeEnd) continue;
        if (s < earliest || s >= latest) continue;
        starts.add(s);
      }
    }
  }
  return starts;
}

// When a range boundary falls inside a DST gap, the range starts or ends at
// the first wall minute that exists after it.
function firstInstantAfterGap(date: string, minutes: number, timeZone: string): number | null {
  for (let m = minutes + 1; m <= minutes + 120 && m <= 1440; m++) {
    const t = wallToInstant(date, m, timeZone);
    if (t !== null) return t;
  }
  return null;
}

function overlapsAny(busy: Interval[], start: number, end: number): boolean {
  for (const b of busy) {
    if (b.start >= end) return false;
    if (b.end > start) return true;
  }
  return false;
}
