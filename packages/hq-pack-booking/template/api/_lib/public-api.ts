// Public routes: what the booking pages call. No host calendar details ever
// appear in a response: slots carry times only, and round-robin slots do not
// say which host is free.

import {
  checkInvitee,
  checkLocation,
  checkManageToken,
  checkUtm,
  cancelBooking,
  createBooking,
  createHold,
  defaultZone,
  loadBooking,
  publicBookingView,
  releaseHold,
  rescheduleBooking,
  usableLink,
} from "./bookings.ts";
import { badRequest, HttpError, notFound } from "./errors.ts";
import type { EventType, Location, Question } from "./engine.ts";
import { isValidTimeZone, wallParts } from "./engine.ts";
import { rateLimit } from "./guards.ts";
import type { Router } from "./http.ts";
import { buildIcs } from "./ics.ts";
import { locationText } from "./notify.ts";
import { evaluateRouting } from "./routing.ts";
import { findEventType, findHost, isSandbox, type Services } from "./services.ts";
import { openSlots, reclaimExpired } from "./slots.ts";
import { DAY, instant, iso, MINUTE, optionalInstant, optionalInteger, text } from "./util.ts";

export const PUBLIC_LIMITS = {
  holds: { limit: 20, windowMs: 10 * MINUTE },
  bookings: { limit: 10, windowMs: 10 * MINUTE },
  changes: { limit: 20, windowMs: 10 * MINUTE },
  routing: { limit: 60, windowMs: 10 * MINUTE },
};
const MAX_RANGE_DAYS = 62;
const TOO_MANY = "Too many requests from your network. Wait a few minutes and try again.";

function publicLocationOption(l: Location): Record<string, unknown> {
  switch (l.type) {
    case "custom":
      return { type: "custom", label: l.label ?? "Video link from the host" };
    case "phone":
      return { type: "phone", caller: l.caller };
    case "in-person":
      return { type: "in-person", address: l.address };
    default:
      return { type: l.type };
  }
}

function questionView(q: Question): Record<string, unknown> {
  return { id: q.id, label: q.label, type: q.type, required: q.required === true, ...(q.options ? { options: q.options } : {}), ...(q.maxLength ? { maxLength: q.maxLength } : {}) };
}

export function eventTypeView(s: Services, ev: EventType): Record<string, unknown> {
  return {
    id: ev.id,
    title: ev.title,
    description: ev.description ?? null,
    kind: ev.kind,
    durations: ev.durations,
    defaultDuration: ev.defaultDuration ?? ev.durations[0],
    startIncrement: ev.startIncrement ?? 15,
    minimumNotice: ev.minimumNotice ?? 0,
    bookingWindow: ev.bookingWindow ?? 60,
    seats: ev.seats ?? null,
    guestsMax: ev.guests?.max ?? 0,
    secret: ev.secret === true,
    locations: ev.locations.map(publicLocationOption),
    questions: (ev.questions ?? []).map(questionView),
    hosts: ev.kind === "round-robin" ? [] : ev.hosts.map((id) => ({ name: findHost(s, id).name })),
    teamSize: ev.hosts.length,
    policy: {
      cancelCutoffHours: ev.policy?.cancelCutoffHours ?? null,
      rescheduleCutoffHours: ev.policy?.rescheduleCutoffHours ?? null,
      requireCancelReason: ev.policy?.requireCancelReason === true,
    },
    confirmation: ev.confirmation ?? null,
    timezone: defaultZone(s, ev),
  };
}

export function publicConfig(s: Services): Record<string, unknown> {
  const c = s.config;
  return {
    company: c.company,
    timezone: c.timezone ?? null,
    theme: c.theme ?? {},
    embed: { modes: c.embed?.modes ?? ["inline"], allowedOrigins: c.embed?.allowedOrigins ?? [] },
    eventTypes: c.eventTypes.filter((e) => !e.secret).map((e) => eventTypeView(s, e)),
    routingForms: (c.routing?.forms ?? []).map((f) => ({ id: f.id, title: f.title, questions: f.questions.map(questionView) })),
    provider: s.providers.calendar.name,
    sandbox: isSandbox(s),
  };
}

function durationFor(ev: EventType, raw: unknown): number {
  const d = optionalInteger(raw, "duration", 5, 720) ?? ev.defaultDuration ?? (ev.durations[0] as number);
  if (!ev.durations.includes(d)) throw badRequest("bad-duration", `This event type offers ${ev.durations.join(", ")} minute meetings.`);
  return d;
}

function hostList(raw: unknown): string[] | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  const list = Array.isArray(raw) ? raw : String(raw).split(",");
  if (list.length > 20 || !list.every((h) => typeof h === "string" && /^[a-z0-9][a-z0-9-]{0,62}$/.test(h.trim()))) throw badRequest("bad-hosts", "hosts must be host ids.");
  return list.map((h) => (h as string).trim());
}

function zoneParam(raw: string | null, fallback: string): string {
  if (!raw) return fallback;
  if (raw.length > 64 || !isValidTimeZone(raw)) throw badRequest("bad-timezone", "tz must be a time zone such as America/New_York.");
  return raw;
}

export function slotList(slots: { start: number; end: number; seatsLeft?: number }[], tz: string) {
  return slots.map((x) => {
    const w = wallParts(x.start, tz);
    return {
      start: iso(x.start),
      end: iso(x.end),
      date: w.date,
      time: `${String(Math.floor(w.minutes / 60)).padStart(2, "0")}:${String(w.minutes % 60).padStart(2, "0")}`,
      ...(x.seatsLeft !== undefined ? { seatsLeft: x.seatsLeft } : {}),
    };
  });
}

export function rangeParams(s: Services, q: URLSearchParams, defaultDays: number): { from: number; to: number } {
  const now = s.now();
  const from = optionalInstant(q.get("from"), "from") ?? now;
  const to = optionalInstant(q.get("to"), "to") ?? from + defaultDays * DAY;
  if (to <= from) throw badRequest("bad-range", "to must be after from.");
  if (to - from > MAX_RANGE_DAYS * DAY) throw badRequest("bad-range", `Ask for at most ${MAX_RANGE_DAYS} days at a time.`);
  return { from, to };
}

export function registerPublicRoutes(r: Router<Services>): void {
  r.get("/api/config/public", ({ services }) => publicConfig(services));

  r.get("/api/event-types/:id", ({ services, params }) => ({ eventType: eventTypeView(services, findEventType(services, params.id as string)) }));

  r.get("/api/links/:token", async ({ services, params }) => {
    const link = await usableLink(services, params.token as string);
    return {
      eventType: eventTypeView(services, findEventType(services, link.event_type_id)),
      singleUse: link.single_use,
      expiresAt: link.expires_at === null ? null : iso(link.expires_at),
    };
  });

  r.get("/api/slots", async ({ services: s, query }) => {
    const id = text(query.get("eventType"), "eventType", { max: 63 }) as string;
    const ev = findEventType(s, id);
    const duration = durationFor(ev, query.get("duration"));
    const { from, to } = rangeParams(s, query, 7);
    const tz = zoneParam(query.get("tz"), defaultZone(s, ev));
    await reclaimExpired(s);
    const slots = await openSlots(s, ev, duration, from, to, { hostIds: hostList(query.get("hosts")) });
    return { eventType: ev.id, duration, timezone: tz, from: iso(from), to: iso(to), slots: slotList(slots, tz) };
  });

  r.post("/api/routing/:formId/evaluate", async ({ services: s, params, body, ip }) => {
    await rateLimit(s, `routing:${ip}`, PUBLIC_LIMITS.routing.limit, PUBLIC_LIMITS.routing.windowMs, TOO_MANY);
    const form = (s.config.routing?.forms ?? []).find((f) => f.id === params.formId);
    if (!form) throw notFound("There is no routing form with that id.");
    const { target, rule } = evaluateRouting(form, (await body()).answers);
    return { target: target.url ? { url: target.url } : { eventType: target.eventType, ...(target.hosts ? { hosts: target.hosts } : {}) }, matchedRule: rule };
  });

  r.post("/api/holds", async ({ services: s, body, ip }) => {
    await rateLimit(s, `holds:${ip}`, PUBLIC_LIMITS.holds.limit, PUBLIC_LIMITS.holds.windowMs, TOO_MANY);
    const b = await body();
    const ev = findEventType(s, text(b.eventType, "eventType", { max: 63 }) as string);
    const duration = durationFor(ev, b.duration);
    const start = instant(b.start, "start");
    const linkToken = text(b.link, "link", { max: 200, optional: true });
    await reclaimExpired(s);
    const hold = await createHold(s, { ev, duration, start, linkToken, hostIds: hostList(b.hosts) });
    return new Response(
      JSON.stringify({ holdId: hold.id, eventType: ev.id, duration, start: iso(hold.start_at), end: iso(hold.end_at), expiresAt: iso(hold.expires_at) }),
      { status: 201, headers: { "content-type": "application/json; charset=utf-8" } },
    );
  });

  r.delete("/api/holds/:id", async ({ services: s, params }) => ({ released: await releaseHold(s, params.id as string) }));

  r.post("/api/bookings", async ({ services: s, body, ip, url }) => {
    await rateLimit(s, `bookings:${ip}`, PUBLIC_LIMITS.bookings.limit, PUBLIC_LIMITS.bookings.windowMs, TOO_MANY);
    const b = await body();
    const holdId = text(b.holdId, "holdId", { max: 80 }) as string;
    await reclaimExpired(s);
    const hold = await s.store.get("holds", { id: holdId });
    if (!hold || hold.expires_at <= s.now()) throw new HttpError(410, "hold-expired", "Your hold on that time ran out. Pick the time again.");
    const ev = findEventType(s, hold.event_type_id);
    const invitee = checkInvitee(ev, b, defaultZone(s, ev));
    const location = checkLocation(ev, b.location);
    const utm = checkUtm(b.utm);
    let linkToken = text(b.link, "link", { max: 200, optional: true });
    if (hold.link_id && !linkToken) throw badRequest("link-required", "This time was held through a booking link; send the same link.");
    if (!hold.link_id) linkToken = undefined;
    const created = await createBooking(s, {
      ev,
      duration: hold.duration,
      start: hold.start_at,
      end: hold.end_at,
      hostIds: hold.host_ids,
      source: { type: "hold", hold },
      invitee,
      location,
      utm,
      linkToken,
      createdBy: "invitee",
      actor: "invitee",
      origin: url.origin,
    });
    return new Response(
      JSON.stringify({
        booking: publicBookingView(s, created.booking, created.attendee),
        manageToken: created.token,
        manageUrl: `/manage/${created.booking.id}?token=${encodeURIComponent(created.token)}`,
        icsUrl: `/api/bookings/${created.booking.id}/ics?token=${encodeURIComponent(created.token)}`,
        redirectUrl: ev.confirmation?.redirectUrl ?? null,
      }),
      { status: 201, headers: { "content-type": "application/json; charset=utf-8" } },
    );
  });

  r.get("/api/bookings/:id", async ({ services: s, params, query }) => {
    const { booking, attendee } = await loadBooking(s, params.id as string);
    checkManageToken(booking, query.get("token"));
    return { booking: publicBookingView(s, booking, attendee) };
  });

  r.post("/api/bookings/:id/cancel", async ({ services: s, params, body, ip, url }) => {
    await rateLimit(s, `changes:${ip}`, PUBLIC_LIMITS.changes.limit, PUBLIC_LIMITS.changes.windowMs, TOO_MANY);
    const b = await body();
    const { booking } = await loadBooking(s, params.id as string);
    checkManageToken(booking, b.token);
    const updated = await cancelBooking(s, booking, { actor: "invitee", enforcePolicy: true, reason: b.reason as string | undefined, origin: url.origin });
    return { booking: publicBookingView(s, updated, await s.store.get("attendees", { booking_id: updated.id })) };
  });

  r.post("/api/bookings/:id/reschedule", async ({ services: s, params, body, ip, url }) => {
    await rateLimit(s, `changes:${ip}`, PUBLIC_LIMITS.changes.limit, PUBLIC_LIMITS.changes.windowMs, TOO_MANY);
    const b = await body();
    const { booking } = await loadBooking(s, params.id as string);
    checkManageToken(booking, b.token);
    await reclaimExpired(s);
    const moved = await rescheduleBooking(s, booking, {
      actor: "invitee",
      enforcePolicy: true,
      start: instant(b.start, "start"),
      holdId: text(b.holdId, "holdId", { max: 80, optional: true }),
      reason: b.reason as string | undefined,
      origin: url.origin,
    });
    return { booking: publicBookingView(s, moved, await s.store.get("attendees", { booking_id: moved.id })) };
  });

  r.get("/api/bookings/:id/ics", async ({ services: s, params, query }) => {
    const { booking, attendee } = await loadBooking(s, params.id as string);
    checkManageToken(booking, query.get("token"));
    const ev = findEventType(s, booking.event_type_id);
    const first = findHost(s, booking.host_ids[0] as string);
    const loc = booking.location as { joinUrl?: string; url?: string } | null;
    const body = buildIcs({
      uid: `${booking.id}@hq-booking`,
      sequence: booking.reschedule_count,
      start: booking.start_at,
      end: booking.end_at,
      stamp: booking.updated_at,
      summary: `${ev.title} with ${booking.host_ids.map((h) => findHost(s, h).name).join(", ")}`,
      description: `${ev.title}${attendee && attendee.redacted_at === null ? ` for ${attendee.name}` : ""}. Booked through HQ Booking.`,
      location: locationText(booking),
      url: loc?.joinUrl ?? loc?.url ?? undefined,
      canceled: booking.status === "canceled",
      organizer: { name: first.name, email: first.email },
    });
    return new Response(body, {
      status: 200,
      headers: { "content-type": "text/calendar; charset=utf-8", "content-disposition": `attachment; filename="${booking.id}.ics"` },
    });
  });
}
