// Holds, bookings, cancel, reschedule and no-show: the flows shared by the
// public, owner and agent APIs.
//
// Order of work in a booking: re-check the hosts' calendars, make the video
// link, then one transaction that takes the time (claims), writes the
// booking and attendee rows, queues reminders and webhooks and writes the
// audit entry. Calendar events are created after the commit; if that fails
// the booking is undone and the caller gets a plain error. Emails and DMs go
// last and never undo a booking.

import { attendingHosts, slotAt } from "./slots.ts";
import { claimTime, releaseClaims, transferClaims, type ClaimOwner } from "./claims.ts";
import { badRequest, ConflictError, conflict, HttpError, notFound, ProviderError } from "./errors.ts";
import type { EventType, Location, Question } from "./engine.ts";
import { isValidTimeZone } from "./engine.ts";
import { audit } from "./guards.ts";
import { baseUrl, cancelJobs, enqueueWebhook, insertJobs, locationText, notifyHosts, scheduleJobs, sendBookingEmail } from "./notify.ts";
import type { CalendarEventInput } from "./providers.ts";
import { calendarHost, findEventType, findHost, hostZone, isSandbox, type Services } from "./services.ts";
import type { Tx } from "./store.ts";
import type { ApprovalRow, AttendeeRow, BookingRow, HoldRow, LinkRow } from "./tables.ts";
import { clampText, hmacHex, HOUR, iso, isEmail, isRecord, MINUTE, newId, sameHex, sha256Hex, text } from "./util.ts";

export const HOLD_MS = 5 * MINUTE;
export const AGENT_NOTE_MAX = 1000;

// --- tokens and links ---------------------------------------------------------

export function manageToken(s: Services, bookingId: string): string {
  return `mt_${Buffer.from(hmacHex(s.tokenKey, `manage:${bookingId}`), "hex").toString("base64url")}`;
}

export function checkManageToken(b: BookingRow, token: unknown): void {
  if (typeof token !== "string" || !token || !sameHex(sha256Hex(token), b.manage_token_hash)) {
    throw new HttpError(403, "bad-token", "This link is not valid for that booking.");
  }
}

export function manageUrl(s: Services, origin: string | undefined, b: BookingRow): string {
  return `${baseUrl(s, origin)}/manage/${encodeURIComponent(b.id)}?token=${encodeURIComponent(manageToken(s, b.id))}`;
}

/** A single-use or secret link, by its raw token. Throws 404 or 410 when it cannot be used. */
export async function usableLink(s: Services, token: string, tx?: Tx): Promise<LinkRow> {
  const link = await (tx ?? s.store).get("single_use_links", { token_hash: sha256Hex(token) });
  if (!link) throw notFound("This booking link does not exist.");
  const now = s.now();
  if (link.revoked_at !== null || (link.expires_at !== null && link.expires_at <= now) || (link.single_use && link.used_at !== null)) {
    throw new HttpError(410, "link-expired", "This booking link has expired or was already used. Ask for a new one.");
  }
  return link;
}

// --- input checks ---------------------------------------------------------------

export interface InviteeInput {
  name: string;
  email: string;
  answers: Record<string, unknown>;
  guests: string[];
  timezone: string;
}

export interface LocationChoice {
  type: Location["type"];
  phone?: string;
}

const PHONE = /^\+?[0-9 ()-]{6,32}$/;

export function checkAnswers(questions: Question[], raw: unknown): Record<string, unknown> {
  if (raw !== undefined && raw !== null && !isRecord(raw)) throw badRequest("bad-answers", "answers must be an object of question id to answer.");
  const answers = (raw ?? {}) as Record<string, unknown>;
  const byId = new Map(questions.map((q) => [q.id, q]));
  for (const key of Object.keys(answers)) {
    if (!byId.has(key)) throw badRequest("unknown-question", `"${clampText(key, 40)}" is not a question on this form.`, { question: clampText(key, 40) });
  }
  const out: Record<string, unknown> = {};
  for (const q of questions) {
    const v = answers[q.id];
    const empty = v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0);
    if (empty) {
      if (q.required) throw badRequest("answer-required", `Please answer "${q.label}".`, { question: q.id });
      continue;
    }
    const fail = (why: string) => badRequest("bad-answer", `"${q.label}" ${why}`, { question: q.id });
    switch (q.type) {
      case "number": {
        const n = typeof v === "string" ? Number(v) : v;
        if (typeof n !== "number" || !Number.isFinite(n)) throw fail("must be a number.");
        out[q.id] = n;
        break;
      }
      case "checkbox": {
        const list = Array.isArray(v) ? v : [v];
        if (!list.every((x) => typeof x === "string" && (q.options ?? []).includes(x))) throw fail("must use the listed options.");
        out[q.id] = [...new Set(list as string[])];
        break;
      }
      case "select":
      case "radio":
        if (typeof v !== "string" || !(q.options ?? []).includes(v)) throw fail("must be one of the listed options.");
        out[q.id] = v;
        break;
      default: {
        if (typeof v !== "string") throw fail("must be text.");
        const max = q.maxLength ?? (q.type === "textarea" ? 5000 : 500);
        const t = v.trim();
        if (t.length > max) throw fail(`must be at most ${max} characters.`);
        if (q.type === "email" && !isEmail(t)) throw fail("must be an email address.");
        if (q.type === "phone" && !PHONE.test(t)) throw fail("must be a phone number.");
        if (t === "" && q.required) throw badRequest("answer-required", `Please answer "${q.label}".`, { question: q.id });
        out[q.id] = t;
      }
    }
  }
  return out;
}

export function checkInvitee(ev: EventType, body: Record<string, unknown>, fallbackZone: string): InviteeInput {
  const name = text(body.name, "name", { max: 120 }) as string;
  const email = text(body.email, "email", { max: 254 }) as string;
  if (!isEmail(email)) throw badRequest("bad-email", "email must be an email address.", { field: "email" });
  const rawGuests = body.guests ?? [];
  if (!Array.isArray(rawGuests)) throw badRequest("bad-guests", "guests must be a list of email addresses.");
  const max = ev.guests?.max ?? 0;
  if (rawGuests.length > max) throw badRequest("too-many-guests", max === 0 ? "This event type does not take guests." : `You can add up to ${max} guests.`);
  const guests: string[] = [];
  for (const g of rawGuests) {
    if (!isEmail(g)) throw badRequest("bad-guests", "Each guest must be an email address.");
    const lower = g.trim().toLowerCase();
    if (lower !== email.toLowerCase() && !guests.includes(lower)) guests.push(lower);
  }
  const timezone = body.timezone === undefined || body.timezone === null || body.timezone === "" ? fallbackZone : body.timezone;
  if (typeof timezone !== "string" || timezone.length > 64 || !isValidTimeZone(timezone)) throw badRequest("bad-timezone", "timezone must be a time zone such as America/New_York.");
  return { name, email, answers: checkAnswers(ev.questions ?? [], body.answers), guests, timezone };
}

/** A location that needs nothing from the invitee (agent and approval bookings). */
export function defaultLocation(ev: EventType): LocationChoice {
  const loc = ev.locations.find((l) => !(l.type === "phone" && l.caller === "host")) ?? (ev.locations[0] as Location);
  return { type: loc.type };
}

export function checkLocation(ev: EventType, raw: unknown): LocationChoice {
  const offered = ev.locations;
  if (raw === undefined || raw === null) {
    const first = offered[0] as Location;
    if (first.type === "phone" && first.caller === "host") throw badRequest("phone-required", "Give a phone number for the host to call.");
    return { type: first.type };
  }
  const type = isRecord(raw) ? raw.type : raw;
  const loc = offered.find((l) => l.type === type);
  if (!loc) throw badRequest("bad-location", `Choose one of: ${offered.map((l) => l.type).join(", ")}.`);
  if (loc.type === "phone" && loc.caller === "host") {
    const phone = isRecord(raw) ? raw.phone : undefined;
    if (typeof phone !== "string" || !PHONE.test(phone.trim())) throw badRequest("phone-required", "Give a phone number for the host to call.");
    return { type: loc.type, phone: phone.trim() };
  }
  return { type: loc.type };
}

export function checkUtm(raw: unknown): Record<string, string> | null {
  if (raw === undefined || raw === null) return null;
  if (!isRecord(raw)) throw badRequest("bad-utm", "utm must be an object such as {\"utm_source\": \"newsletter\"}.");
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(raw)) {
    if (!/^utm_(source|medium|campaign|term|content)$/.test(k)) throw badRequest("bad-utm", `${clampText(k, 40)} is not a UTM field.`);
    if (typeof v !== "string" || v.length > 200) throw badRequest("bad-utm", `${k} must be text up to 200 characters.`);
    out[k] = v;
  }
  return Object.keys(out).length ? out : null;
}

// --- holds ------------------------------------------------------------------------

export interface HoldRequest {
  ev: EventType;
  duration: number;
  start: number;
  linkToken?: string;
  hostIds?: string[];
  excludeBookingId?: string;
}

export async function createHold(s: Services, r: HoldRequest): Promise<HoldRow> {
  let linkId: string | null = null;
  if (r.linkToken) {
    const link = await usableLink(s, r.linkToken);
    if (link.event_type_id !== r.ev.id) throw badRequest("link-mismatch", "This link is for a different event type.");
    linkId = link.id;
  }
  const slot = await slotAt(s, r.ev, r.duration, r.start, { hostIds: r.hostIds, excludeBookingId: r.excludeBookingId });
  if (!slot) throw conflict("slot-unavailable", "That time is no longer available. Pick another time.");
  const hostIds = await attendingHosts(s, r.ev, slot);
  const now = s.now();
  const hold: HoldRow = {
    id: newId("hold"),
    event_type_id: r.ev.id,
    duration: r.duration,
    start_at: slot.start,
    end_at: slot.end,
    host_ids: hostIds,
    seats: 1,
    link_id: linkId,
    claim_keys: [],
    expires_at: now + HOLD_MS,
    created_at: now,
  };
  try {
    await s.store.transaction(async (tx) => {
      hold.claim_keys = await claimTime(tx, r.ev, hostIds, slot.start, slot.end, { type: "hold", id: hold.id, expiresAt: hold.expires_at }, s.claimMinutes, now);
      await tx.insert("holds", hold);
    });
  } catch (err) {
    if (err instanceof ConflictError) throw conflict("slot-taken", "Someone just took that time. Pick another time.");
    throw err;
  }
  return hold;
}

export async function releaseHold(s: Services, holdId: string): Promise<boolean> {
  return s.store.transaction(async (tx) => {
    const hold = await tx.get("holds", { id: holdId });
    if (!hold) return false;
    await tx.remove("holds", { id: holdId });
    await releaseClaims(tx, hold.claim_keys, hold.id, s.now());
    return true;
  });
}

// --- creating bookings ----------------------------------------------------------------

export type BookingSource = { type: "hold"; hold: HoldRow } | { type: "approval"; approval: ApprovalRow } | { type: "direct" };

export interface BookingDraft {
  ev: EventType;
  duration: number;
  start: number;
  end: number;
  hostIds: string[];
  source: BookingSource;
  invitee: InviteeInput;
  location: LocationChoice;
  utm: Record<string, string> | null;
  linkToken?: string;
  createdBy: BookingRow["created_by"];
  actor: string;
  agentKeyId?: string | null;
  memberId?: string | null;
  agentNote?: string | null;
  origin?: string;
}

async function stillFree(s: Services, ev: EventType, hostIds: string[], start: number, end: number, ignoreEventIds: string[] = []): Promise<boolean> {
  const before = (ev.buffers?.before ?? 0) * MINUTE;
  const after = (ev.buffers?.after ?? 0) * MINUTE;
  const hosts = hostIds.map((id) => calendarHost(s, findHost(s, id)));
  const busy = await s.providers.calendar.freeBusy(hosts, { from: start - before, to: end + after }, { ignoreEventIds });
  return hostIds.every((h) =>
    (busy[h] ?? []).every((b) => b.end <= start - before || b.start >= end + after || (ev.kind === "group" && b.start === start && b.end === end)),
  );
}

async function releaseSource(s: Services, source: BookingSource): Promise<void> {
  if (source.type === "hold") await releaseHold(s, source.hold.id).catch(() => false);
}

function providerFailure(err: unknown, what: string): HttpError {
  const detail = err instanceof ProviderError ? ` ${err.message}` : "";
  return new HttpError(502, "provider-failed", `We could not ${what}, so nothing was booked.${detail} Try again in a minute.`);
}

async function resolveLocation(s: Services, ev: EventType, choice: LocationChoice, bookingId: string, hostIds: string[], start: number, end: number): Promise<Record<string, unknown>> {
  const loc = ev.locations.find((l) => l.type === choice.type) as Location;
  const firstHost = findHost(s, hostIds[0] as string);
  switch (loc.type) {
    case "meet":
    case "zoom":
    case "teams": {
      const c = await s.providers.video.createMeeting({ kind: loc.type, bookingId, host: calendarHost(s, firstHost), start, end, title: ev.title });
      return { type: loc.type, provider: c.provider, joinUrl: c.joinUrl, sandbox: c.sandbox };
    }
    case "custom":
      return { type: "custom", url: loc.url ?? firstHost.links?.custom ?? null, label: loc.label ?? null };
    case "phone":
      return loc.caller === "host" ? { type: "phone", caller: "host", phone: choice.phone } : { type: "phone", caller: "invitee", phone: firstHost.links?.phone ?? null };
    case "in-person":
      return { type: "in-person", address: loc.address };
  }
}

function eventInput(s: Services, b: BookingRow, a: AttendeeRow, hostId: string): CalendarEventInput {
  const ev = findEventType(s, b.event_type_id);
  const host = findHost(s, hostId);
  const others = b.host_ids.filter((h) => h !== hostId).map((h) => findHost(s, h));
  const bookedBy = b.created_by === "agent" ? `\nBooked by ${a.name}'s agent for ${a.name}.` : "";
  return {
    host: calendarHost(s, host),
    bookingId: b.id,
    start: b.start_at,
    end: b.end_at,
    summary: `${ev.title}: ${a.name}`,
    description: `${ev.title} booked through HQ Booking.${bookedBy}`,
    location: locationText(b),
    attendees: [
      ...(a.email ? [{ name: a.name, email: a.email }] : []),
      ...a.guests.map((g) => ({ email: g })),
      ...others.map((o) => ({ name: o.name, email: o.email })),
    ],
    idempotencyKey: `${b.id}:${hostId}`,
  };
}

async function upsertAssignment(tx: Tx, eventTypeId: string, hostId: string, at: number): Promise<void> {
  const row = await tx.get("host_assignments", { event_type_id: eventTypeId, host_id: hostId });
  if (!row) await tx.insert("host_assignments", { event_type_id: eventTypeId, host_id: hostId, bookings: 1, last_booked_at: at });
  else await tx.update("host_assignments", { event_type_id: eventTypeId, host_id: hostId }, { bookings: row.bookings + 1, last_booked_at: Math.max(at, row.last_booked_at ?? 0) });
}

export interface CreatedBooking {
  booking: BookingRow;
  attendee: AttendeeRow;
  token: string;
}

export async function createBooking(s: Services, d: BookingDraft): Promise<CreatedBooking> {
  try {
    if (!(await stillFree(s, d.ev, d.hostIds, d.start, d.end))) {
      await releaseSource(s, d.source);
      throw conflict("slot-taken", "That time just filled up on the host's calendar. Pick another time.");
    }
  } catch (err) {
    if (err instanceof HttpError) throw err;
    await releaseSource(s, d.source);
    throw providerFailure(err, "check the host's calendar");
  }

  const id = newId("bk");
  let location: Record<string, unknown>;
  try {
    location = await resolveLocation(s, d.ev, d.location, id, d.hostIds, d.start, d.end);
  } catch (err) {
    await releaseSource(s, d.source);
    throw providerFailure(err, "create the video link");
  }

  const now = s.now();
  const token = manageToken(s, id);
  const booking: BookingRow = {
    id,
    event_type_id: d.ev.id,
    kind: d.ev.kind,
    host_ids: d.hostIds,
    start_at: d.start,
    end_at: d.end,
    duration: d.duration,
    status: "confirmed",
    location,
    timezone: d.invitee.timezone,
    manage_token_hash: sha256Hex(token),
    created_by: d.createdBy,
    agent_key_id: d.agentKeyId ?? null,
    member_id: d.memberId ?? null,
    agent_note: d.agentNote ?? null,
    utm: d.utm,
    link_id: null,
    claim_keys: [],
    calendar: {},
    calendar_status: "pending",
    cancel_reason: null,
    canceled_at: null,
    canceled_by: null,
    reschedule_count: 0,
    no_show: false,
    created_at: now,
    updated_at: now,
  };
  const attendee: AttendeeRow = {
    booking_id: id,
    name: d.invitee.name,
    email: d.invitee.email,
    email_lower: d.invitee.email.toLowerCase(),
    answers: d.invitee.answers,
    guests: d.invitee.guests,
    redacted_at: null,
  };
  const owner: ClaimOwner = { type: "booking", id, expiresAt: null };

  try {
    await s.store.transaction(async (tx) => {
      const src = d.source;
      if (src.type === "hold") {
        const hold = await tx.get("holds", { id: src.hold.id });
        if (!hold || hold.expires_at <= now) throw new HttpError(410, "hold-expired", "Your hold on that time ran out. Pick the time again.");
        await transferClaims(tx, hold.claim_keys, hold.id, owner);
        await tx.remove("holds", { id: hold.id });
        booking.claim_keys = hold.claim_keys;
      } else if (src.type === "approval") {
        const ok = await tx.update("approvals", { id: src.approval.id }, { status: "approved", decided_at: now, booking_id: id }, { status: "pending", expires_at: { gt: now } });
        if (!ok) throw conflict("approval-closed", "This request was already answered or has expired.");
        await transferClaims(tx, src.approval.claim_keys, src.approval.id, owner);
        booking.claim_keys = src.approval.claim_keys;
      } else {
        booking.claim_keys = await claimTime(tx, d.ev, d.hostIds, d.start, d.end, owner, s.claimMinutes, now);
      }
      if (d.linkToken) {
        const link = await usableLink(s, d.linkToken, tx);
        if (link.event_type_id !== d.ev.id || (src.type === "hold" && src.hold.link_id !== null && src.hold.link_id !== link.id)) {
          throw badRequest("link-mismatch", "This link is not the one this time was held with.");
        }
        if (link.single_use && !(await tx.update("single_use_links", { token_hash: link.token_hash }, { used_at: now, used_by: id }, { used_at: null }))) {
          throw new HttpError(410, "link-expired", "This booking link has expired or was already used. Ask for a new one.");
        }
        booking.link_id = link.id;
      }
      await tx.insert("bookings", booking);
      await tx.insert("attendees", attendee);
      for (const h of d.hostIds) await upsertAssignment(tx, d.ev.id, h, d.start);
      await insertJobs(tx, scheduleJobs(s, booking, now));
      await enqueueWebhook(tx, s, "booked", booking, attendee, now);
      await audit(tx, now, {
        actor: d.actor,
        action: "booking.created",
        bookingId: id,
        hostIds: d.hostIds,
        memberId: d.memberId ?? null,
        detail: { eventType: d.ev.id, start: iso(d.start), via: d.source.type, createdBy: d.createdBy },
      });
    });
  } catch (err) {
    await releaseSource(s, d.source);
    if (err instanceof ConflictError) throw conflict("slot-taken", "Someone just took that time. Pick another time.");
    throw err;
  }

  // Calendar events after the commit; undo the booking if they cannot be made.
  const created: Record<string, string> = {};
  try {
    for (const h of d.hostIds) {
      const r = await s.providers.calendar.createEvent(eventInput(s, booking, attendee, h));
      created[h] = r.eventId;
    }
  } catch (err) {
    for (const [h, eventId] of Object.entries(created)) {
      await s.providers.calendar.cancelEvent(eventId, calendarHost(s, findHost(s, h))).catch(() => undefined);
    }
    await undoBooking(s, booking);
    throw providerFailure(err, "add the meeting to the host's calendar");
  }
  booking.calendar = created;
  booking.calendar_status = "created";
  await s.store.update("bookings", { id }, { calendar: created, calendar_status: "created" });

  await sendBookingEmail(s, booking, attendee, "confirmation", { manageUrl: manageUrl(s, d.origin, booking) }).catch((e) => s.log(`confirmation email failed: ${(e as Error).message}`));
  const who = d.createdBy === "agent" ? `${attendee.name}'s agent for ${attendee.name}` : attendee.name;
  await notifyHosts(s, booking, "booking-created", `New booking: ${d.ev.title}`, `${who} booked ${d.ev.title} for ${iso(d.start)}.`).catch((e) =>
    s.log(`host notice failed: ${(e as Error).message}`),
  );
  return { booking, attendee, token };
}

/** Take back a booking whose calendar events could not be created. */
async function undoBooking(s: Services, b: BookingRow): Promise<void> {
  const now = s.now();
  await s.store.transaction(async (tx) => {
    await tx.update("bookings", { id: b.id }, { status: "canceled", canceled_at: now, canceled_by: "system", cancel_reason: "calendar-failed", calendar_status: "failed", updated_at: now });
    await releaseClaims(tx, b.claim_keys, b.id, now);
    await cancelJobs(tx, b.id, now);
    await tx.removeWhere("webhook_outbox", { idempotency_key: `booked:${b.id}:0:`, status: "pending" });
    await audit(tx, now, { actor: "system", action: "booking.undone", bookingId: b.id, hostIds: b.host_ids, detail: { reason: "calendar-failed" } });
  });
}

// --- cancel, reschedule, no-show ----------------------------------------------------------

export interface ChangeOptions {
  actor: string;
  /** Apply the event type's cutoff and reason rules (invitees and agents). */
  enforcePolicy: boolean;
  reason?: string;
  origin?: string;
}

function assertChangeable(s: Services, b: BookingRow, cutoffHours: number | undefined, what: "cancel" | "reschedule", enforce: boolean): void {
  if (b.status !== "confirmed") throw conflict("already-canceled", "This booking was already canceled.");
  if (!enforce) return;
  const now = s.now();
  if (b.start_at <= now) throw conflict("already-started", "This meeting has already started, so it cannot be changed here. Contact the host.");
  if (cutoffHours !== undefined && now > b.start_at - cutoffHours * HOUR) {
    const verb = what === "cancel" ? "canceled" : "rescheduled";
    throw conflict(`${what}-cutoff`, `Bookings can't be ${verb} less than ${cutoffHours} hours before they start. Contact the host.`);
  }
}

export async function cancelBooking(s: Services, b: BookingRow, o: ChangeOptions): Promise<BookingRow> {
  const ev = findEventType(s, b.event_type_id);
  assertChangeable(s, b, ev.policy?.cancelCutoffHours, "cancel", o.enforcePolicy);
  const reason = text(o.reason, "reason", { max: 500, optional: true }) ?? null;
  if (o.enforcePolicy && ev.policy?.requireCancelReason && !reason) throw badRequest("reason-required", "Please give a reason for canceling.");
  const now = s.now();
  const updated: BookingRow = { ...b, status: "canceled", cancel_reason: reason, canceled_at: now, canceled_by: o.actor, updated_at: now };
  await s.store.transaction(async (tx) => {
    const ok = await tx.update("bookings", { id: b.id }, { status: "canceled", cancel_reason: reason, canceled_at: now, canceled_by: o.actor, updated_at: now }, { status: "confirmed" });
    if (!ok) throw conflict("already-canceled", "This booking was already canceled.");
    await releaseClaims(tx, b.claim_keys, b.id, now);
    await cancelJobs(tx, b.id, now);
    await enqueueWebhook(tx, s, "canceled", updated, await tx.get("attendees", { booking_id: b.id }), now);
    await audit(tx, now, { actor: o.actor, action: "booking.canceled", bookingId: b.id, hostIds: b.host_ids, memberId: b.member_id, detail: { hasReason: !!reason } });
  });
  let calendarStatus = "canceled";
  for (const [h, eventId] of Object.entries(b.calendar)) {
    try {
      await s.providers.calendar.cancelEvent(eventId, calendarHost(s, findHost(s, h)));
    } catch (err) {
      calendarStatus = "cancel-failed";
      s.log(`calendar cancel failed for ${b.id}: ${(err as Error).message}`);
    }
  }
  await s.store.update("bookings", { id: b.id }, { calendar_status: calendarStatus });
  updated.calendar_status = calendarStatus;
  const a = await s.store.get("attendees", { booking_id: b.id });
  await sendBookingEmail(s, updated, a, "cancellation", { reason: reason ?? undefined, idSuffix: String(now) }).catch(() => false);
  await notifyHosts(s, updated, "booking-canceled", `Canceled: ${ev.title}`, `The ${ev.title} at ${iso(b.start_at)} was canceled${reason ? `. Reason: ${reason}` : "."}`).catch(() => undefined);
  return updated;
}

export interface RescheduleRequest extends ChangeOptions {
  start: number;
  holdId?: string;
}

export async function rescheduleBooking(s: Services, b: BookingRow, r: RescheduleRequest): Promise<BookingRow> {
  const ev = findEventType(s, b.event_type_id);
  assertChangeable(s, b, ev.policy?.rescheduleCutoffHours, "reschedule", r.enforcePolicy);
  const reason = text(r.reason, "reason", { max: 500, optional: true }) ?? null;
  const now = s.now();
  let hold: HoldRow | null = null;
  let hostIds: string[];
  let end: number;
  if (r.holdId) {
    hold = await s.store.get("holds", { id: r.holdId });
    if (!hold || hold.expires_at <= now) throw new HttpError(410, "hold-expired", "Your hold on that time ran out. Pick the time again.");
    if (hold.event_type_id !== b.event_type_id || hold.duration !== b.duration || hold.start_at !== r.start) {
      throw badRequest("hold-mismatch", "That hold is for a different time or event type.");
    }
    hostIds = hold.host_ids;
    end = hold.end_at;
  } else {
    const slot = await slotAt(s, ev, b.duration, r.start, { excludeBookingId: b.id });
    if (!slot) throw conflict("slot-unavailable", "That time is not available. Pick another time.");
    hostIds = await attendingHosts(s, ev, slot, b.host_ids);
    end = slot.end;
  }
  try {
    if (!(await stillFree(s, ev, hostIds, r.start, end, Object.values(b.calendar)))) throw conflict("slot-taken", "That time just filled up on the host's calendar. Pick another time.");
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(502, "provider-failed", "We could not check the host's calendar, so nothing changed. Try again in a minute.");
  }
  const moved: BookingRow = { ...b, start_at: r.start, end_at: end, host_ids: hostIds, reschedule_count: b.reschedule_count + 1, updated_at: now };
  const owner: ClaimOwner = { type: "booking", id: b.id, expiresAt: null };
  try {
    await s.store.transaction(async (tx) => {
      const current = await tx.get("bookings", { id: b.id });
      if (!current || current.status !== "confirmed" || current.updated_at !== b.updated_at) throw new ConflictError();
      await releaseClaims(tx, b.claim_keys, b.id, now);
      if (hold) {
        const h = await tx.get("holds", { id: hold.id });
        if (!h || h.expires_at <= now) throw new HttpError(410, "hold-expired", "Your hold on that time ran out. Pick the time again.");
        await transferClaims(tx, h.claim_keys, h.id, owner);
        await tx.remove("holds", { id: h.id });
        moved.claim_keys = h.claim_keys;
      } else {
        moved.claim_keys = await claimTime(tx, ev, hostIds, r.start, end, owner, s.claimMinutes, now);
      }
      await tx.update("bookings", { id: b.id }, {
        start_at: moved.start_at,
        end_at: moved.end_at,
        host_ids: moved.host_ids,
        claim_keys: moved.claim_keys,
        reschedule_count: moved.reschedule_count,
        updated_at: now,
      });
      await cancelJobs(tx, b.id, now);
      await insertJobs(tx, scheduleJobs(s, moved, now));
      await enqueueWebhook(tx, s, "rescheduled", moved, await tx.get("attendees", { booking_id: b.id }), now);
      await audit(tx, now, {
        actor: r.actor,
        action: "booking.rescheduled",
        bookingId: b.id,
        hostIds,
        memberId: b.member_id,
        detail: { from: iso(b.start_at), to: iso(r.start), hasReason: !!reason },
      });
    });
  } catch (err) {
    if (err instanceof ConflictError) throw conflict("slot-taken", "Someone just took that time, or the booking changed. Reload and try again.");
    throw err;
  }

  const a = (await s.store.get("attendees", { booking_id: b.id })) as AttendeeRow;
  const calendar: Record<string, string> = {};
  let calendarStatus = "updated";
  for (const h of new Set([...b.host_ids, ...hostIds])) {
    const host = calendarHost(s, findHost(s, h));
    const existing = b.calendar[h];
    try {
      if (existing && hostIds.includes(h)) {
        await s.providers.calendar.updateEvent(existing, eventInput(s, moved, a, h));
        calendar[h] = existing;
      } else if (existing) {
        await s.providers.calendar.cancelEvent(existing, host);
      } else {
        calendar[h] = (await s.providers.calendar.createEvent({ ...eventInput(s, moved, a, h), idempotencyKey: `${b.id}:${h}:${moved.reschedule_count}` })).eventId;
      }
    } catch (err) {
      calendarStatus = "update-failed";
      if (existing && hostIds.includes(h)) calendar[h] = existing;
      s.log(`calendar update failed for ${b.id}: ${(err as Error).message}`);
    }
  }
  moved.calendar = calendar;
  moved.calendar_status = calendarStatus;
  await s.store.update("bookings", { id: b.id }, { calendar, calendar_status: calendarStatus });
  await sendBookingEmail(s, moved, a, "reschedule", { manageUrl: manageUrl(s, r.origin, moved), reason: reason ?? undefined }).catch(() => false);
  await notifyHosts(s, moved, "booking-rescheduled", `Rescheduled: ${ev.title}`, `The ${ev.title} moved from ${iso(b.start_at)} to ${iso(r.start)}.`).catch(() => undefined);
  return moved;
}

export async function setNoShow(s: Services, b: BookingRow, noShow: boolean, actor: string): Promise<BookingRow> {
  if (b.status !== "confirmed") throw conflict("already-canceled", "A canceled booking cannot be marked as a no-show.");
  if (noShow && b.start_at > s.now()) throw conflict("not-started", "A meeting can be marked as a no-show only after it starts.");
  const now = s.now();
  const updated = { ...b, no_show: noShow, updated_at: now };
  await s.store.transaction(async (tx) => {
    await tx.update("bookings", { id: b.id }, { no_show: noShow, updated_at: now });
    if (noShow) await enqueueWebhook(tx, s, "no-show", updated, await tx.get("attendees", { booking_id: b.id }), now);
    await audit(tx, now, { actor, action: noShow ? "booking.no-show" : "booking.no-show-cleared", bookingId: b.id, hostIds: b.host_ids });
  });
  return updated;
}

// --- views ------------------------------------------------------------------------------------

export function publicLocation(b: BookingRow): Record<string, unknown> {
  return { ...((b.location ?? {}) as Record<string, unknown>), text: locationText(b) };
}

export function publicBookingView(s: Services, b: BookingRow, a: AttendeeRow | null): Record<string, unknown> {
  const ev = s.config.eventTypes.find((e) => e.id === b.event_type_id);
  const now = s.now();
  const policy = ev?.policy ?? {};
  const open = b.status === "confirmed" && b.start_at > now;
  const within = (h: number | undefined) => h === undefined || now <= b.start_at - h * HOUR;
  return {
    id: b.id,
    status: b.status,
    eventType: { id: b.event_type_id, title: ev?.title ?? b.event_type_id, kind: b.kind },
    start: iso(b.start_at),
    end: iso(b.end_at),
    duration: b.duration,
    timezone: b.timezone,
    location: publicLocation(b),
    hosts: b.host_ids.map((id) => ({ name: s.config.hosts.find((h) => h.id === id)?.name ?? id })),
    invitee: a && a.redacted_at === null ? { name: a.name, email: a.email } : null,
    guests: a && a.redacted_at === null ? a.guests : [],
    answers: a && a.redacted_at === null ? a.answers : {},
    bookedBy: b.created_by === "agent" && a ? `${a.name}'s agent for ${a.name}` : null,
    cancelReason: b.cancel_reason,
    rescheduleCount: b.reschedule_count,
    policy: {
      canCancel: open && within(policy.cancelCutoffHours),
      canReschedule: open && within(policy.rescheduleCutoffHours),
      cancelCutoffHours: policy.cancelCutoffHours ?? null,
      rescheduleCutoffHours: policy.rescheduleCutoffHours ?? null,
      requireCancelReason: policy.requireCancelReason === true,
    },
    confirmation: ev?.confirmation ?? null,
    sandbox: isSandbox(s),
  };
}

export function ownerBookingView(s: Services, b: BookingRow, a: AttendeeRow | null): Record<string, unknown> {
  return {
    ...publicBookingView(s, b, a),
    hostIds: b.host_ids,
    hosts: b.host_ids.map((id) => ({ id, name: s.config.hosts.find((h) => h.id === id)?.name ?? id })),
    createdBy: b.created_by,
    agentKeyId: b.agent_key_id,
    memberId: b.member_id,
    agentNote: b.agent_note === null ? null : { text: b.agent_note, untrusted: true },
    utm: b.utm,
    linkId: b.link_id,
    noShow: b.no_show,
    calendarStatus: b.calendar_status,
    canceledBy: b.canceled_by,
    canceledAt: b.canceled_at === null ? null : iso(b.canceled_at),
    createdAt: iso(b.created_at),
    updatedAt: iso(b.updated_at),
    inviteeRedacted: a ? a.redacted_at !== null : true,
  };
}

export async function loadBooking(s: Services, id: string): Promise<{ booking: BookingRow; attendee: AttendeeRow | null }> {
  const booking = await s.store.get("bookings", { id });
  if (!booking) throw notFound("There is no booking with that id.");
  return { booking, attendee: await s.store.get("attendees", { booking_id: id }) };
}

export function defaultZone(s: Services, ev: EventType): string {
  return hostZone(s, findHost(s, ev.hosts[0] as string));
}
