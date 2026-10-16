// Everything a request handler needs, built once per process (app.ts), plus
// lookups into the booking config.

import { notFound } from "./errors.ts";
import type { BookingConfig, EventType, Host } from "./engine.ts";
import type { FetchLike } from "./hqpro.ts";
import type { CalendarHost, Providers } from "./providers.ts";
import type { SandboxCalendar } from "./sandbox.ts";
import type { Store } from "./store.ts";

export interface Services {
  config: BookingConfig;
  store: Store;
  providers: Providers;
  /** Set when the calendar is the sandbox, for the owner's sandbox view. */
  sandbox?: SandboxCalendar;
  now: () => number;
  /** Used for webhook delivery. */
  fetch: FetchLike;
  /** Bound app secrets (ctx.secrets on hq-deploy). Server-side only. */
  secrets: Record<string, string>;
  log: (message: string) => void;
  /** Public origin for links in emails; the request origin when unset. */
  publicBaseUrl?: string;
  /** Size of the time cells used by the double-booking guard. */
  claimMinutes: number;
  /** HMAC key for manage-link tokens (BOOKING_TOKEN_KEY when bound). */
  tokenKey: string;
  /** Local dev only: allow http:// and localhost webhook URLs. */
  allowLocalWebhooks?: boolean;
}

export function findEventType(s: Services, id: string): EventType {
  const ev = s.config.eventTypes.find((e) => e.id === id);
  if (!ev) throw notFound("There is no event type with that id.");
  return ev;
}

export function findHost(s: Services, id: string): Host {
  const h = s.config.hosts.find((x) => x.id === id);
  if (!h) throw notFound("There is no host with that id.");
  return h;
}

export function hostZone(s: Services, h: Host): string {
  return (h.timezone ?? s.config.timezone ?? "UTC") as string;
}

export function calendarHost(s: Services, h: Host): CalendarHost {
  return { id: h.id, email: h.email, timezone: hostZone(s, h), ...(h.calendars ? { calendars: h.calendars } : {}) };
}

export function isSandbox(s: Services): boolean {
  return s.providers.calendar.name === "sandbox";
}

function gcd(a: number, b: number): number {
  return b === 0 ? a : gcd(b, a % b);
}

/**
 * The largest cell size (minutes) that every possible booking boundary falls
 * on: start times sit on range starts plus increments, ends add a duration,
 * and zone offsets are multiples of 15 minutes. Two bookings overlap exactly
 * when they share a cell, so claiming cells catches every overlap.
 */
export function claimMinutesFor(config: BookingConfig): number {
  let g = 15;
  for (const ev of config.eventTypes) {
    g = gcd(g, ev.startIncrement ?? 15);
    for (const d of ev.durations) g = gcd(g, d);
  }
  for (const h of config.hosts) {
    const ranges = [...Object.values(h.hours ?? {}).flat(), ...(h.overrides ?? []).flatMap((o) => o.hours)];
    for (const r of ranges) {
      const [a] = (r as string).split("-") as [string];
      const [hh, mm] = a.split(":").map(Number) as [number, number];
      g = gcd(g, hh * 60 + mm);
    }
  }
  return Math.max(1, g);
}
