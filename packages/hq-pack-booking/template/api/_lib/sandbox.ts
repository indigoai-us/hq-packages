// SANDBOX providers. Nothing here leaves the app database: calendars are the
// sandbox_events table, video links point at sandbox.hq-booking.invalid (a
// reserved name that never resolves), email goes to outbox_emails and HQ DMs
// go to notifications. Every record they make is marked sandbox.
//
// Each host's sandbox calendar is seeded, the first time a day is read, with
// a few busy blocks derived from the host id and the date, so the same host
// always shows the same plausible week.

import { ConflictError, ProviderError } from "./errors.ts";
import { wallParts, wallToInstant } from "./engine.ts";
import type {
  BusyBlock,
  CalendarEventInput,
  CalendarHost,
  CalendarProvider,
  Conference,
  DirectMessage,
  EmailMessage,
  Mailer,
  MeetingInput,
  Notifier,
  Providers,
  VideoProvider,
} from "./providers.ts";
import type { Store, Tx } from "./store.ts";
import type { SandboxEventRow } from "./tables.ts";
import { DAY, hash32, sha256Hex } from "./util.ts";

export const SANDBOX_MEET_HOST = "sandbox.hq-booking.invalid";
const MAX_SEED_DAYS = 120;

function addDay(date: string, n: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + n * DAY).toISOString().slice(0, 10);
}

/** The deterministic busy blocks for one host on one local date. */
export function sandboxBusyFor(hostId: string, day: string, timeZone: string): BusyBlock[] {
  const weekday = new Date(`${day}T12:00:00Z`).getUTCDay();
  if (weekday === 0 || weekday === 6) return [];
  const seed = hash32(`${hostId}|${day}`);
  const count = seed % 4;
  const blocks: BusyBlock[] = [];
  for (let i = 0; i < count; i++) {
    const h = hash32(`${hostId}|${day}|${i}`);
    const startMin = 9 * 60 + (h % 16) * 30;
    const length = [30, 60, 90][(h >>> 8) % 3] as number;
    const endMin = Math.min(startMin + length, 18 * 60);
    const start = wallToInstant(day, startMin, timeZone);
    const end = wallToInstant(day, endMin, timeZone);
    if (start !== null && end !== null && end > start) blocks.push({ start, end });
  }
  return blocks.sort((a, b) => a.start - b.start);
}

export function sandboxConference(kind: string, bookingId: string): Conference {
  const h = sha256Hex(`${kind}|${bookingId}`);
  const code = `${h.slice(0, 3)}-${h.slice(3, 7)}-${h.slice(7, 10)}`;
  return { provider: `${kind} (sandbox)`, joinUrl: `https://${SANDBOX_MEET_HOST}/${kind}/${code}`, sandbox: true };
}

async function insertIgnoringDuplicate(fn: () => Promise<void>): Promise<boolean> {
  try {
    await fn();
    return true;
  } catch (err) {
    if (err instanceof ConflictError) return false;
    throw err;
  }
}

export class SandboxCalendar implements CalendarProvider {
  readonly name = "sandbox" as const;
  private readonly store: Store;
  private readonly now: () => number;

  constructor(store: Store, now: () => number) {
    this.store = store;
    this.now = now;
  }

  private async ensureSeeded(host: CalendarHost, from: number, to: number): Promise<void> {
    const first = wallParts(from, host.timezone).date;
    const last = wallParts(to, host.timezone).date;
    const days: string[] = [];
    for (let d = first; d <= last && days.length < MAX_SEED_DAYS; d = addDay(d, 1)) days.push(d);
    const seeded = await this.store.find("sandbox_seeds", { host_id: host.id, day: { gte: first, lte: last } });
    const have = new Set(seeded.map((s) => s.day));
    const missing = days.filter((d) => !have.has(d));
    if (missing.length === 0) return;
    const now = this.now();
    await this.store.transaction(async (tx) => {
      for (const day of missing) {
        if (!(await insertIgnoringDuplicate(() => tx.insert("sandbox_seeds", { host_id: host.id, day, created_at: now })))) continue;
        let i = 0;
        for (const b of sandboxBusyFor(host.id, day, host.timezone)) {
          await insertIgnoringDuplicate(() =>
            tx.insert("sandbox_events", {
              id: `sbx_${host.id}_${day}_${i++}`,
              host_id: host.id,
              start_at: b.start,
              end_at: b.end,
              kind: "busy",
              title: "Busy (sandbox)",
              booking_id: null,
              conference: null,
              attendees: [],
              status: "confirmed",
              created_at: now,
              updated_at: now,
            }),
          );
        }
      }
    });
  }

  async freeBusy(hosts: CalendarHost[], range: { from: number; to: number }, options: { ignoreEventIds?: string[] } = {}): Promise<Record<string, BusyBlock[]>> {
    const ignore = new Set(options.ignoreEventIds ?? []);
    const out: Record<string, BusyBlock[]> = {};
    for (const host of hosts) {
      await this.ensureSeeded(host, range.from - DAY, range.to + DAY);
      const events = await this.store.find("sandbox_events", { host_id: host.id, status: "confirmed", start_at: { lt: range.to }, end_at: { gt: range.from } });
      out[host.id] = events
        .filter((e) => !ignore.has(e.id))
        .map((e) => ({ start: e.start_at, end: e.end_at }))
        .sort((a, b) => a.start - b.start);
    }
    return out;
  }

  /** Owner view of a host's sandbox calendar (titles are sandbox-made, never real). */
  async events(hostId: string, from: number, to: number): Promise<SandboxEventRow[]> {
    const rows = await this.store.find("sandbox_events", { host_id: hostId, start_at: { lt: to }, end_at: { gt: from } }, { orderBy: "start_at" });
    return rows;
  }

  async seed(host: CalendarHost, from: number, to: number): Promise<void> {
    await this.ensureSeeded(host, from, to);
  }

  static eventId(idempotencyKey: string): string {
    return `sev_${sha256Hex(idempotencyKey).slice(0, 24)}`;
  }

  async createEvent(input: CalendarEventInput): Promise<{ eventId: string; conference?: Conference }> {
    const eventId = SandboxCalendar.eventId(input.idempotencyKey);
    const conference = input.conference ? sandboxConference(input.conference, input.bookingId) : undefined;
    const now = this.now();
    await insertIgnoringDuplicate(() =>
      this.store.insert("sandbox_events", {
        id: eventId,
        host_id: input.host.id,
        start_at: input.start,
        end_at: input.end,
        kind: "booking",
        title: input.summary,
        booking_id: input.bookingId,
        conference: conference ?? null,
        attendees: input.attendees.map((a) => a.email),
        status: "confirmed",
        created_at: now,
        updated_at: now,
      }),
    );
    return { eventId, ...(conference ? { conference } : {}) };
  }

  private async appEvent(tx: Tx, eventId: string, hostId: string): Promise<SandboxEventRow> {
    const ev = await tx.get("sandbox_events", { id: eventId });
    if (!ev || ev.kind !== "booking" || ev.host_id !== hostId) {
      throw new ProviderError("not-app-event", "That calendar event was not created by this booking app.", 404);
    }
    return ev;
  }

  async updateEvent(eventId: string, input: CalendarEventInput): Promise<void> {
    await this.store.transaction(async (tx) => {
      await this.appEvent(tx, eventId, input.host.id);
      await tx.update("sandbox_events", { id: eventId }, {
        start_at: input.start,
        end_at: input.end,
        title: input.summary,
        attendees: input.attendees.map((a) => a.email),
        status: "confirmed",
        updated_at: this.now(),
      });
    });
  }

  async cancelEvent(eventId: string, host: CalendarHost): Promise<void> {
    await this.store.transaction(async (tx) => {
      await this.appEvent(tx, eventId, host.id);
      await tx.update("sandbox_events", { id: eventId }, { status: "canceled", updated_at: this.now() });
    });
  }
}

export class SandboxVideo implements VideoProvider {
  readonly name = "sandbox";
  async createMeeting(input: MeetingInput): Promise<Conference> {
    return sandboxConference(input.kind, input.bookingId);
  }
}

export class SandboxMailer implements Mailer {
  readonly name = "sandbox";
  private readonly store: Store;
  private readonly now: () => number;
  constructor(store: Store, now: () => number) {
    this.store = store;
    this.now = now;
  }
  send(m: EmailMessage): Promise<boolean> {
    return insertIgnoringDuplicate(() =>
      this.store.insert("outbox_emails", {
        id: m.id,
        booking_id: m.bookingId ?? null,
        kind: m.kind,
        to_addrs: m.to,
        subject: m.subject,
        html: m.html,
        text_body: m.text,
        sandbox: true,
        created_at: this.now(),
      }),
    );
  }
}

export class SandboxNotifier implements Notifier {
  readonly name = "sandbox";
  private readonly store: Store;
  private readonly now: () => number;
  constructor(store: Store, now: () => number) {
    this.store = store;
    this.now = now;
  }
  send(m: DirectMessage): Promise<boolean> {
    return insertIgnoringDuplicate(() =>
      this.store.insert("notifications", {
        id: m.id,
        recipient_type: m.recipient.type,
        recipient_id: m.recipient.id,
        kind: m.kind,
        title: m.title,
        body: m.body,
        data: m.data ?? null,
        booking_id: m.bookingId ?? null,
        approval_id: m.approvalId ?? null,
        sandbox: true,
        created_at: this.now(),
      }),
    );
  }
}

export function sandboxProviders(store: Store, now: () => number): Providers & { calendar: SandboxCalendar } {
  return {
    calendar: new SandboxCalendar(store, now),
    video: new SandboxVideo(),
    mailer: new SandboxMailer(store, now),
    notifier: new SandboxNotifier(store, now),
  };
}
