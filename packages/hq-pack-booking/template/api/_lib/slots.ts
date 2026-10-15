// Open times for an event type: the shared engine fed with provider busy
// times plus this app's own bookings, holds and pending approvals. Also the
// lazy clean-up of expired holds and approvals, which runs before every read
// and write that depends on them (there is no cron on hq-deploy).

import { badRequest } from "./errors.ts";
import { computeSlots, pickHost, SlotQueryError, type EventType, type ExistingBooking, type HostInput, type HostStats, type Slot } from "./engine.ts";
import { releaseClaims } from "./claims.ts";
import { calendarHost, findHost, hostZone, type Services } from "./services.ts";
import { DAY, MINUTE, newId } from "./util.ts";
import { ConflictError } from "./errors.ts";

const RECLAIM_BATCH = 50;

/** Delete expired holds and expire unanswered approvals. Never fails the caller. */
export async function reclaimExpired(s: Services): Promise<{ holds: number; approvals: number }> {
  const now = s.now();
  let holds = 0;
  let approvals = 0;
  try {
    const expired = await s.store.find("holds", { expires_at: { lte: now } }, { limit: RECLAIM_BATCH });
    for (const h of expired) {
      await s.store.transaction(async (tx) => {
        if (!(await tx.remove("holds", { id: h.id }))) return;
        await releaseClaims(tx, h.claim_keys, h.id, now);
        holds++;
      });
    }
    const lapsed = await s.store.find("approvals", { status: "pending", expires_at: { lte: now } }, { limit: RECLAIM_BATCH });
    for (const a of lapsed) {
      const changed = await s.store.transaction(async (tx) => {
        if (!(await tx.update("approvals", { id: a.id }, { status: "expired", decided_at: now }, { status: "pending" }))) return false;
        await releaseClaims(tx, a.claim_keys, a.id, now);
        await tx.insert("audit_log", {
          id: newId("aud"), at: now, actor: "system", action: "approval.expired", booking_id: null, host_ids: a.host_ids, member_id: a.member_id,
          detail: { approvalId: a.id, eventType: a.event_type_id },
        });
        return true;
      });
      if (changed) {
        approvals++;
        await s.providers.notifier.send({
          id: `approval-expired:${a.id}`,
          recipient: { type: "member", id: a.member_id },
          kind: "approval-expired",
          title: "Booking request expired",
          body: `The host did not answer within 24 hours, so the requested time was released. Ask your agent to request another time.`,
          approvalId: a.id,
        });
      }
    }
  } catch (err) {
    // A concurrent request may be cleaning the same rows; that is fine.
    if (!(err instanceof ConflictError)) s.log(`reclaim skipped: ${(err as Error).message}`);
  }
  return { holds, approvals };
}

export interface SlotOptions {
  /** Round-robin only: limit to these hosts (routing forms). */
  hostIds?: string[];
  /** Leave this booking out (rescheduling it). */
  excludeBookingId?: string;
}

/** The event type with its host list narrowed, after checking the narrowing is allowed. */
export function narrowHosts(ev: EventType, hostIds: string[] | undefined): EventType {
  if (!hostIds || hostIds.length === 0) return ev;
  if (ev.kind !== "round-robin") throw badRequest("hosts-not-allowed", "Choosing hosts works only for round-robin event types.");
  for (const h of hostIds) if (!ev.hosts.includes(h)) throw badRequest("unknown-host", `${h} is not a host of this event type.`);
  return { ...ev, hosts: [...new Set(hostIds)] };
}

/** This app's own reservations that overlap a range, as the engine sees them. */
export async function reservations(s: Services, from: number, to: number, excludeBookingId?: string): Promise<ExistingBooking[]> {
  const now = s.now();
  const pad = DAY;
  const [bookings, holds, approvals] = await Promise.all([
    s.store.find("bookings", { status: "confirmed", start_at: { lt: to + pad }, end_at: { gt: from - pad } }),
    s.store.find("holds", { expires_at: { gt: now }, start_at: { lt: to + pad } }),
    s.store.find("approvals", { status: "pending", expires_at: { gt: now }, start_at: { lt: to + pad } }),
  ]);
  return [
    ...bookings.filter((b) => b.id !== excludeBookingId).map((b) => ({ eventTypeId: b.event_type_id, hostIds: b.host_ids, start: b.start_at, end: b.end_at })),
    ...holds.filter((h) => h.end_at > from - pad).map((h) => ({ eventTypeId: h.event_type_id, hostIds: h.host_ids, start: h.start_at, end: h.end_at, seats: h.seats })),
    ...approvals.filter((a) => a.end_at > from - pad).map((a) => ({ eventTypeId: a.event_type_id, hostIds: a.host_ids, start: a.start_at, end: a.end_at })),
  ];
}

export async function hostInputs(s: Services, hostIds: string[], from: number, to: number, ignoreEventIds: string[] = []): Promise<HostInput[]> {
  const hosts = hostIds.map((id) => findHost(s, id));
  const busy = await s.providers.calendar.freeBusy(hosts.map((h) => calendarHost(s, h)), { from, to }, { ignoreEventIds });
  return hosts.map((h) => ({
    id: h.id,
    timezone: hostZone(s, h),
    hours: h.hours,
    overrides: h.overrides,
    holidays: h.holidays,
    busy: busy[h.id] ?? [],
  }));
}

export async function openSlots(s: Services, ev: EventType, duration: number, from: number, to: number, opts: SlotOptions = {}): Promise<Slot[]> {
  const narrowed = narrowHosts(ev, opts.hostIds);
  if (!narrowed.durations.includes(duration)) {
    throw badRequest("bad-duration", `This event type offers ${narrowed.durations.join(", ")} minute meetings.`);
  }
  const now = s.now();
  const windowEnd = now + (narrowed.bookingWindow ?? 60) * DAY;
  const start = Math.max(from, now);
  const end = Math.min(to, windowEnd);
  if (!(end > start)) return [];
  const pad = ((narrowed.buffers?.before ?? 0) + (narrowed.buffers?.after ?? 0) + duration) * MINUTE + DAY;
  let ignore: string[] = [];
  if (opts.excludeBookingId) {
    const b = await s.store.get("bookings", { id: opts.excludeBookingId });
    ignore = Object.values(b?.calendar ?? {});
  }
  const [hosts, bookings] = await Promise.all([
    hostInputs(s, narrowed.hosts, start - pad, end + pad, ignore),
    reservations(s, start, end, opts.excludeBookingId),
  ]);
  try {
    return computeSlots({ eventType: narrowed, duration, hosts, bookings, now, from: start, to: end });
  } catch (err) {
    if (err instanceof SlotQueryError) throw badRequest("bad-query", err.message);
    throw err;
  }
}

/** The slot starting exactly at `start`, or null when it is not open now. */
export async function slotAt(s: Services, ev: EventType, duration: number, start: number, opts: SlotOptions = {}): Promise<Slot | null> {
  const slots = await openSlots(s, ev, duration, start, start + 1, opts);
  return slots.find((x) => x.start === start) ?? null;
}

export async function roundRobinStats(s: Services, ev: EventType): Promise<HostStats[]> {
  const rows = await s.store.find("host_assignments", { event_type_id: ev.id });
  const byHost = new Map(rows.map((r) => [r.host_id, r]));
  return ev.hosts.map((id) => {
    const h = findHost(s, id);
    const r = byHost.get(id);
    return {
      id,
      weight: h.roundRobin?.weight ?? 1,
      priority: h.roundRobin?.priority ?? 0,
      bookings: r?.bookings ?? 0,
      lastBookedAt: r?.last_booked_at ?? null,
    };
  });
}

/** The hosts who attend a slot: one picked host for round-robin, all hosts otherwise. */
export async function attendingHosts(s: Services, ev: EventType, slot: Slot, prefer?: string[]): Promise<string[]> {
  if (ev.kind !== "round-robin") return slot.hostIds;
  const keep = prefer?.find((h) => slot.hostIds.includes(h));
  if (keep) return [keep];
  return [pickHost(slot.hostIds, await roundRobinStats(s, ev))];
}
