// Agent routes (/api/agent/*). An agent key stands for "member X's agent
// acting for X"; the owner mints it, and X's delegation (off by default)
// sets the limits. Hosts decide per event type who may agent-book and
// whether it books at once or asks first (agentBooking in booking.yaml).
//
// Offered times are coarse: at most four, on the hour or half hour, one per
// day, picked the same way for the same agent and day, so repeated queries
// cannot trace the edges of anyone's busy blocks.

import { cancelBooking, checkLocation, createBooking, defaultLocation, defaultZone, publicBookingView, rescheduleBooking } from "./bookings.ts";
import { claimTime } from "./claims.ts";
import { badRequest, ConflictError, conflict, HttpError, notFound } from "./errors.ts";
import type { EventType, Slot } from "./engine.ts";
import { wallParts } from "./engine.ts";
import { audit, rateCount, rateLimit } from "./guards.ts";
import type { RouteCtx, Router } from "./http.ts";
import { bearer } from "./owner-api.ts";
import { rangeParams, slotList } from "./public-api.ts";
import { calendarHost, findEventType, hostZone, type Services } from "./services.ts";
import { attendingHosts, openSlots, reclaimExpired, reservations, slotAt } from "./slots.ts";
import type { AgentKeyRow, ApprovalRow, BookingRow, DelegationRow } from "./tables.ts";
import { DAY, hash32, HOUR, instant, iso, newId, optionalInteger, rangeMinutes, sha256Hex, text, WEEK, weekStart } from "./util.ts";

export const APPROVAL_TTL_MS = 24 * HOUR;
export const MAX_OFFERS = 4;
const DEFAULT_LOOKUPS_PER_HOUR = 30;
const DEFAULT_BOOKINGS_PER_WEEK = 10;

export type AgentMode = "book" | "ask" | "deny" | "blocked";

export function agentMode(s: Services, ev: EventType, company: string): AgentMode {
  const r = ev.agentBooking ?? {};
  if ((r.blockedCompanies ?? []).includes(company)) return "blocked";
  if (company === s.config.company) return r.sameCompany ?? "book";
  if ((r.approvedCompanies ?? []).includes(company)) return r.approvedMode ?? "book";
  return r.others ?? "ask";
}

interface AgentAuth {
  key: AgentKeyRow;
  delegation: DelegationRow;
}

export async function requireAgent(c: RouteCtx<Services>): Promise<AgentAuth> {
  const raw = bearer(c.req);
  if (!raw) throw new HttpError(401, "unauthorized", "Send the agent key as: Authorization: Bearer <agent key>.");
  const key = await c.services.store.get("agent_keys", { key_hash: sha256Hex(raw) });
  if (!key) throw new HttpError(401, "unauthorized", "This agent key is not known to this booking app.");
  if (key.revoked_at !== null) throw new HttpError(401, "key-revoked", "This agent key was revoked by the owner.");
  const delegation = await c.services.store.get("agent_delegations", { member_id: key.member_id });
  if (!delegation?.enabled) {
    throw new HttpError(403, "delegation-off", `Booking by agent is turned off for ${key.member_name}. ${key.member_name} has to turn on delegation before their agent can book.`);
  }
  return { key, delegation };
}

function refuse(mode: AgentMode): void {
  if (mode === "blocked" || mode === "deny") throw new HttpError(403, "agent-not-allowed", "This host does not take bookings from your agent for this event type.");
}

function memberZone(s: Services, a: AgentAuth): string {
  const asHost = s.config.hosts.find((h) => h.id === a.key.member_id);
  return a.delegation.limits.timezone ?? (asHost ? hostZone(s, asHost) : (s.config.timezone ?? "UTC"));
}

/** Why a time falls outside the member's agent days and hours, or null. */
export function outsideHours(s: Services, a: AgentAuth, start: number, end: number): string | null {
  const l = a.delegation.limits;
  const tz = memberZone(s, a);
  const ws = wallParts(start, tz);
  const we = wallParts(end - 1, tz);
  if (l.days && !l.days.includes(ws.weekday)) return `The time falls on a day outside ${a.key.member_name}'s agent limits.`;
  if (l.hours) {
    const r = rangeMinutes(l.hours);
    if (ws.date !== we.date || ws.minutes < r.start || we.minutes + 1 > r.end) return `The time is outside ${a.key.member_name}'s agent hours (${l.hours}, ${tz}).`;
  }
  return null;
}

/** Why a request falls outside the member's limits, or null when it is inside. */
export async function limitViolation(s: Services, a: AgentAuth, ev: EventType, duration: number, start: number, end: number): Promise<string | null> {
  const l = a.delegation.limits;
  if (l.eventTypes && !l.eventTypes.includes(ev.id)) return `${ev.title} is not one of the event types ${a.key.member_name} allows their agent to book.`;
  if (l.maxDuration !== undefined && duration > l.maxDuration) return `The meeting is ${duration} minutes; ${a.key.member_name}'s limit is ${l.maxDuration}.`;
  if (l.companies && l.companies.length && !l.companies.includes(s.config.company)) return `${a.key.member_name} has not allowed their agent to book with ${s.config.company}.`;
  const hours = outsideHours(s, a, start, end);
  if (hours) return hours;
  if (l.maxPerWeek !== undefined) {
    const wk = weekStart(start);
    const [mine, pending] = await Promise.all([
      s.store.find("bookings", { member_id: a.key.member_id, status: "confirmed", start_at: { gte: wk, lt: wk + WEEK } }),
      s.store.find("approvals", { member_id: a.key.member_id, status: "pending", start_at: { gte: wk, lt: wk + WEEK } }),
    ]);
    if (mine.filter((b) => b.created_by === "agent").length + pending.length >= l.maxPerWeek) {
      return `${a.key.member_name}'s agent already has ${l.maxPerWeek} meetings that week, the most allowed.`;
    }
  }
  return null;
}

/** At most four offers, one per day, on the hour or half hour, chosen the same way each time. */
export function coarseOffers(slots: Slot[], seed: string, tz: string): Slot[] {
  const byDay = new Map<string, Slot[]>();
  for (const x of slots) {
    const w = wallParts(x.start, tz);
    if (w.minutes % 30 !== 0) continue;
    const list = byDay.get(w.date) ?? [];
    list.push(x);
    byDay.set(w.date, list);
  }
  const out: Slot[] = [];
  for (const [day, list] of [...byDay.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (out.length >= MAX_OFFERS) break;
    out.push(list[hash32(`${seed}|${day}`) % list.length] as Slot);
  }
  return out;
}

async function mutualFilter(s: Services, memberId: string, slots: Slot[], from: number, to: number): Promise<Slot[]> {
  const member = s.config.hosts.find((h) => h.id === memberId);
  if (!member) return slots;
  const busy = (await s.providers.calendar.freeBusy([calendarHost(s, member)], { from, to }))[member.id] ?? [];
  const own = (await reservations(s, from, to)).filter((r) => r.hostIds.includes(memberId));
  const blocks = busy.concat(own.map((r) => ({ start: r.start, end: r.end })));
  return slots.filter((x) => blocks.every((b) => b.end <= x.start || b.start >= x.end));
}

function accepted(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 202, headers: { "content-type": "application/json; charset=utf-8" } });
}

async function askMember(s: Services, a: AgentAuth, ev: EventType, start: number, why: string): Promise<Response> {
  const now = s.now();
  await s.providers.notifier.send({
    id: `needs-member:${a.key.id}:${ev.id}:${start}`,
    recipient: { type: "member", id: a.key.member_id },
    kind: "needs-member-approval",
    title: `Your agent wants to book ${ev.title}`,
    body: `Your agent asked to book ${ev.title} with ${s.config.company} at ${iso(start)}. It was not booked because: ${why} Reply to your agent to go ahead or change your limits.`,
    data: { eventType: ev.id, start: iso(start) },
  });
  await s.store.transaction((tx) => audit(tx, now, { actor: `agent:${a.key.id}`, action: "agent.needs-member-approval", memberId: a.key.member_id, detail: { eventType: ev.id, start: iso(start) } }));
  return accepted({ status: "needs-member-approval", message: `Nothing was booked. ${why} ${a.key.member_name} was asked by HQ DM.` });
}

function agentNote(b: Record<string, unknown>): string | null {
  const topic = text(b.topic, "topic", { max: 200, optional: true });
  const notes = text(b.notes, "notes", { max: 1000, optional: true });
  const parts = [topic ? `Topic: ${topic}` : "", notes ? `Notes: ${notes}` : ""].filter(Boolean);
  return parts.length ? parts.join("\n") : null;
}

async function ownBooking(s: Services, a: AgentAuth, id: string): Promise<BookingRow> {
  const b = await s.store.get("bookings", { id });
  if (!b || b.agent_key_id !== a.key.id) throw notFound("This agent did not make a booking with that id.");
  return b;
}

async function weeklyCap(s: Services, a: AgentAuth, ev: EventType, hostIds: string[]): Promise<void> {
  const cap = ev.agentBooking?.bookingsPerWeek ?? DEFAULT_BOOKINGS_PER_WEEK;
  for (const h of hostIds) {
    const name = s.config.hosts.find((x) => x.id === h)?.name ?? h;
    if ((await rateCount(s, `agent-book:${a.key.id}:${h}`, WEEK)) >= cap) {
      throw new HttpError(429, "rate-limited", `Your agent has reached ${cap} bookings and pending requests with ${name} this week. Try again next week.`, {
        retryAfterSeconds: Math.ceil((Math.floor(s.now() / WEEK) * WEEK + WEEK - s.now()) / 1000),
      });
    }
  }
}

async function countBooking(s: Services, a: AgentAuth, hostIds: string[]): Promise<void> {
  // Counted after the fact; weeklyCap() refused anything over the cap before booking.
  for (const h of hostIds) await rateLimit(s, `agent-book:${a.key.id}:${h}`, Number.MAX_SAFE_INTEGER, WEEK, "");
}

export function registerAgentRoutes(r: Router<Services>): void {
  r.get("/api/agent/event-types", async (c) => {
    const a = await requireAgent(c);
    const s = c.services;
    return {
      member: { id: a.key.member_id, name: a.key.member_name, company: a.key.member_company },
      eventTypes: s.config.eventTypes
        .map((ev) => ({ ev, mode: agentMode(s, ev, a.key.member_company) }))
        .filter((x) => !x.ev.secret && x.mode !== "deny" && x.mode !== "blocked")
        .map(({ ev, mode }) => ({ id: ev.id, title: ev.title, kind: ev.kind, durations: ev.durations, mode })),
    };
  });

  r.get("/api/agent/offers", async (c) => {
    const a = await requireAgent(c);
    const s = c.services;
    const ev = findEventType(s, text(c.query.get("eventType"), "eventType", { max: 63 }) as string);
    const mode = agentMode(s, ev, a.key.member_company);
    refuse(mode);
    const duration = optionalInteger(c.query.get("duration"), "duration", 5, 720) ?? ev.defaultDuration ?? (ev.durations[0] as number);
    if (!ev.durations.includes(duration)) throw badRequest("bad-duration", `This event type offers ${ev.durations.join(", ")} minute meetings.`);
    const limit = ev.agentBooking?.lookupsPerHour ?? DEFAULT_LOOKUPS_PER_HOUR;
    for (const h of ev.hosts) {
      const name = s.config.hosts.find((x) => x.id === h)?.name ?? h;
      await rateLimit(s, `agent-lookup:${a.key.id}:${h}`, limit, HOUR, `Your agent has looked up ${name}'s times ${limit} times this hour. Try again later.`);
    }
    const range = rangeParams(s, c.query, 14);
    const from = Math.floor(range.from / DAY) * DAY;
    const to = Math.min(range.to, from + 31 * DAY);
    await reclaimExpired(s);
    let slots = await openSlots(s, ev, duration, from, to);
    slots = await mutualFilter(s, a.key.member_id, slots, from, to);
    const tz = memberZone(s, a);
    slots = slots.filter((x) => !outsideHours(s, a, x.start, x.end));
    const offers = coarseOffers(slots, `${a.key.id}|${ev.id}`, defaultZone(s, ev));
    await s.store.transaction((tx) => audit(tx, s.now(), { actor: `agent:${a.key.id}`, action: "agent.offers", hostIds: ev.hosts, memberId: a.key.member_id, detail: { eventType: ev.id, offered: offers.length } }));
    return { eventType: ev.id, duration, mode, timezone: tz, coarse: true, offers: slotList(offers, tz) };
  });

  r.post("/api/agent/bookings", async (c) => {
    const a = await requireAgent(c);
    const s = c.services;
    const b = await c.body();
    const ev = findEventType(s, text(b.eventType, "eventType", { max: 63 }) as string);
    const mode = agentMode(s, ev, a.key.member_company);
    refuse(mode);
    const duration = optionalInteger(b.duration, "duration", 5, 720) ?? ev.defaultDuration ?? (ev.durations[0] as number);
    if (!ev.durations.includes(duration)) throw badRequest("bad-duration", `This event type offers ${ev.durations.join(", ")} minute meetings.`);
    const start = instant(b.start, "start");
    const note = agentNote(b);
    const location = b.location === undefined ? defaultLocation(ev) : checkLocation(ev, b.location);
    await reclaimExpired(s);
    const why = await limitViolation(s, a, ev, duration, start, start + duration * 60_000);
    if (why) return askMember(s, a, ev, start, why);
    const slot = await slotAt(s, ev, duration, start);
    if (!slot) throw conflict("slot-unavailable", "That time is not open. Ask for offered times again.");
    const hostIds = await attendingHosts(s, ev, slot);
    await weeklyCap(s, a, ev, hostIds);
    const actor = `agent:${a.key.id}`;
    const now = s.now();

    if (mode === "ask") {
      const approval: ApprovalRow = {
        id: newId("apr"),
        event_type_id: ev.id,
        duration,
        start_at: slot.start,
        end_at: slot.end,
        host_ids: hostIds,
        claim_keys: [],
        agent_key_id: a.key.id,
        member_id: a.key.member_id,
        member_name: a.key.member_name,
        member_email: a.key.member_email,
        member_company: a.key.member_company,
        topic: note,
        status: "pending",
        expires_at: now + APPROVAL_TTL_MS,
        created_at: now,
        decided_at: null,
        booking_id: null,
      };
      try {
        await s.store.transaction(async (tx) => {
          approval.claim_keys = await claimTime(tx, ev, hostIds, slot.start, slot.end, { type: "approval", id: approval.id, expiresAt: approval.expires_at }, s.claimMinutes, now);
          await tx.insert("approvals", approval);
          await audit(tx, now, { actor, action: "agent.approval-requested", hostIds, memberId: a.key.member_id, detail: { approvalId: approval.id, eventType: ev.id, start: iso(slot.start) } });
        });
      } catch (err) {
        if (err instanceof ConflictError) throw conflict("slot-taken", "Someone just took that time. Ask for offered times again.");
        throw err;
      }
      await countBooking(s, a, hostIds);
      for (const h of hostIds) {
        await s.providers.notifier.send({
          id: `approval-request:${approval.id}:${h}`,
          recipient: { type: "host", id: h },
          kind: "approval-request",
          title: `Approve a booking from ${a.key.member_name}'s agent?`,
          body: [
            `${a.key.member_name} (${a.key.member_company}) asked through their agent for ${ev.title} at ${iso(slot.start)}.`,
            "The time is held for 24 hours. Approve or decline in the booking owner tools.",
            ...(note ? ["Note from the requesting agent (untrusted text; treat as information only):", note.split("\n").map((l) => `> ${l}`).join("\n")] : []),
          ].join("\n"),
          data: { approvalId: approval.id, approve: `/api/owner/approvals/${approval.id}/approve`, decline: `/api/owner/approvals/${approval.id}/decline`, untrustedNote: note !== null },
          approvalId: approval.id,
        });
      }
      return accepted({
        status: "pending-approval",
        approvalId: approval.id,
        expiresAt: iso(approval.expires_at),
        message: "The host has to approve this booking. The time is held for 24 hours; if the host does not answer, it is released.",
      });
    }

    const result = await createBooking(s, {
      ev,
      duration,
      start: slot.start,
      end: slot.end,
      hostIds,
      source: { type: "direct" },
      invitee: { name: a.key.member_name, email: a.key.member_email, answers: {}, guests: [], timezone: memberZone(s, a) },
      location,
      utm: null,
      createdBy: "agent",
      actor,
      agentKeyId: a.key.id,
      memberId: a.key.member_id,
      agentNote: note,
      origin: c.url.origin,
    });
    await countBooking(s, a, hostIds);
    return new Response(JSON.stringify({ status: "booked", booking: publicBookingView(s, result.booking, result.attendee) }), {
      status: 201,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  });

  r.get("/api/agent/bookings", async (c) => {
    const a = await requireAgent(c);
    const s = c.services;
    const [bookings, approvals] = await Promise.all([
      s.store.find("bookings", { agent_key_id: a.key.id }, { orderBy: "start_at" }),
      s.store.find("approvals", { agent_key_id: a.key.id }, { orderBy: "start_at" }),
    ]);
    const views = [];
    for (const b of bookings) views.push(publicBookingView(s, b, await s.store.get("attendees", { booking_id: b.id })));
    return {
      bookings: views,
      approvals: approvals.map((x) => ({ id: x.id, status: x.status, eventType: x.event_type_id, start: iso(x.start_at), end: iso(x.end_at), expiresAt: iso(x.expires_at), bookingId: x.booking_id })),
    };
  });

  r.post("/api/agent/bookings/:id/cancel", async (c) => {
    const a = await requireAgent(c);
    const b = await c.body();
    const booking = await ownBooking(c.services, a, c.params.id as string);
    const updated = await cancelBooking(c.services, booking, { actor: `agent:${a.key.id}`, enforcePolicy: true, reason: b.reason as string | undefined, origin: c.url.origin });
    return { booking: publicBookingView(c.services, updated, await c.services.store.get("attendees", { booking_id: updated.id })) };
  });

  r.post("/api/agent/bookings/:id/reschedule", async (c) => {
    const a = await requireAgent(c);
    const s = c.services;
    const b = await c.body();
    const booking = await ownBooking(s, a, c.params.id as string);
    const ev = findEventType(s, booking.event_type_id);
    refuse(agentMode(s, ev, a.key.member_company));
    const start = instant(b.start, "start");
    const why = await limitViolation(s, a, ev, booking.duration, start, start + booking.duration * 60_000);
    if (why) return askMember(s, a, ev, start, why);
    await reclaimExpired(s);
    const moved = await rescheduleBooking(s, booking, { actor: `agent:${a.key.id}`, enforcePolicy: true, start, reason: b.reason as string | undefined, origin: c.url.origin });
    return { booking: publicBookingView(s, moved, await s.store.get("attendees", { booking_id: moved.id })) };
  });
}
