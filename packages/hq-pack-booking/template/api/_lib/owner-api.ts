// Owner routes (/api/owner/*). Every call sends the owner key as
// "Authorization: Bearer <key>"; booking.yaml holds only its SHA-256
// (prototype.ownerKeySha256), compared in constant time.

import { createBooking, cancelBooking, defaultLocation, defaultZone, loadBooking, ownerBookingView, rescheduleBooking, setNoShow } from "./bookings.ts";
import { releaseClaims } from "./claims.ts";
import { badRequest, conflict, HttpError, notFound } from "./errors.ts";
import { isValidTimeZone, WEEKDAYS } from "./engine.ts";
import { audit, purgeCounters, rateLimit } from "./guards.ts";
import type { Handler, RouteCtx, Router } from "./http.ts";
import { deliverWebhooks, runDueJobs, WEBHOOK_EVENTS } from "./notify.ts";
import { rangeParams } from "./public-api.ts";
import { findEventType, findHost, isSandbox, type Services } from "./services.ts";
import { reclaimExpired } from "./slots.ts";
import type { Tx } from "./store.ts";
import type { AgentKeyRow, BookingRow, DelegationLimits, WebhookEndpointRow } from "./tables.ts";
import {
  bool,
  DAY,
  HOUR,
  instant,
  iso,
  isEmail,
  isRecord,
  MINUTE,
  newId,
  newToken,
  optionalInteger,
  parseRangeText,
  sameHex,
  sha256Hex,
  slugValue,
  text,
  weekStart,
} from "./util.ts";

const OWNER_AUTH_FAILS = { limit: 20, windowMs: 10 * MINUTE };

export function bearer(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(\S{8,512})$/i.exec(h.trim());
  return m ? (m[1] as string) : null;
}

export async function requireOwner(c: RouteCtx<Services>): Promise<void> {
  const expected = c.services.config.prototype?.ownerKeySha256;
  if (!expected) throw new HttpError(503, "owner-not-configured", "Owner access is not set up for this booking app. Run the booking setup again to create an owner key.");
  const key = bearer(c.req);
  if (key && sameHex(sha256Hex(key), expected)) return;
  await rateLimit(c.services, `owner-auth:${c.ip}`, OWNER_AUTH_FAILS.limit, OWNER_AUTH_FAILS.windowMs, "Too many failed owner sign-ins. Wait a few minutes.");
  throw new HttpError(401, "unauthorized", "Send the owner key as: Authorization: Bearer <owner key>.");
}

const owner = (h: Handler<Services>): Handler<Services> => async (c) => {
  await requireOwner(c);
  return h(c);
};

export function page(q: URLSearchParams): { limit: number; offset: number } {
  return { limit: optionalInteger(q.get("limit"), "limit", 1, 200) ?? 50, offset: optionalInteger(q.get("offset"), "offset", 0, 100_000) ?? 0 };
}

function created(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 201, headers: { "content-type": "application/json; charset=utf-8" } });
}

// --- invitee data ----------------------------------------------------------------

export async function redactBooking(tx: Tx, bookingId: string, now: number): Promise<boolean> {
  const a = await tx.get("attendees", { booking_id: bookingId });
  if (!a || a.redacted_at !== null) return false;
  await tx.update("attendees", { booking_id: bookingId }, { name: "Deleted invitee", email: null, email_lower: null, answers: {}, guests: [], redacted_at: now });
  for (const m of await tx.find("outbox_emails", { booking_id: bookingId })) {
    await tx.update("outbox_emails", { id: m.id }, { to_addrs: ["[deleted]"], subject: "[deleted]", html: "[deleted]", text_body: "[deleted]" });
  }
  for (const n of await tx.find("notifications", { booking_id: bookingId })) {
    await tx.update("notifications", { id: n.id }, { body: "[deleted]" });
  }
  return true;
}

export async function runRetention(s: Services): Promise<{ redacted: number; skipped?: string }> {
  const days = s.config.dataRetention?.inviteeDataDays;
  if (!days) return { redacted: 0, skipped: "No dataRetention.inviteeDataDays in booking.yaml." };
  const now = s.now();
  const old = await s.store.find("bookings", { end_at: { lt: now - days * DAY } }, { limit: 500 });
  let redacted = 0;
  for (const b of old) {
    const done = await s.store.transaction(async (tx) => {
      const r = await redactBooking(tx, b.id, now);
      if (r) await audit(tx, now, { actor: "system", action: "invitee.retention-purge", bookingId: b.id, hostIds: b.host_ids });
      return r;
    });
    if (done) redacted++;
  }
  return { redacted };
}

// --- analytics -------------------------------------------------------------------

interface Tally {
  key: string;
  bookings: number;
  canceled: number;
  noShows: number;
}

export function analytics(bookings: BookingRow[]): { totals: Omit<Tally, "key">; byEventType: Tally[]; byHost: Tally[]; byWeek: Tally[] } {
  const maps = { ev: new Map<string, Tally>(), host: new Map<string, Tally>(), week: new Map<string, Tally>() };
  const totals = { bookings: 0, canceled: 0, noShows: 0 };
  const bump = (m: Map<string, Tally>, key: string, b: BookingRow) => {
    const t = m.get(key) ?? { key, bookings: 0, canceled: 0, noShows: 0 };
    t.bookings++;
    if (b.status === "canceled") t.canceled++;
    if (b.no_show) t.noShows++;
    m.set(key, t);
  };
  for (const b of bookings) {
    if (b.canceled_by === "system") continue;
    totals.bookings++;
    if (b.status === "canceled") totals.canceled++;
    if (b.no_show) totals.noShows++;
    bump(maps.ev, b.event_type_id, b);
    for (const h of b.host_ids) bump(maps.host, h, b);
    bump(maps.week, iso(weekStart(b.start_at)).slice(0, 10), b);
  }
  const sorted = (m: Map<string, Tally>) => [...m.values()].sort((a, b) => (a.key < b.key ? -1 : 1));
  return { totals, byEventType: sorted(maps.ev), byHost: sorted(maps.host), byWeek: sorted(maps.week) };
}

// --- webhooks, agent keys, delegations ---------------------------------------------

export function checkWebhookUrl(raw: unknown, allowLocal: boolean): string {
  const value = text(raw, "url", { max: 2048 }) as string;
  let u: URL;
  try {
    u = new URL(value);
  } catch {
    throw badRequest("bad-url", "url must be a full https:// address.");
  }
  const host = u.hostname.toLowerCase();
  const local = host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal") || /^[\d.]+$/.test(host) || host.includes(":") || host.startsWith("[");
  if (allowLocal && (u.protocol === "http:" || u.protocol === "https:")) return u.toString();
  if (u.protocol !== "https:") throw badRequest("bad-url", "Webhook URLs must use https://.");
  if (local) throw badRequest("bad-url", "Webhook URLs must use a public host name, not an IP address or a local name.");
  return u.toString();
}

function eventsList(raw: unknown): string[] {
  if (!Array.isArray(raw) || raw.length === 0) throw badRequest("bad-events", `events must list some of: ${WEBHOOK_EVENTS.join(", ")}.`);
  for (const e of raw) if (!(WEBHOOK_EVENTS as readonly string[]).includes(e as string)) throw badRequest("bad-events", `events must list some of: ${WEBHOOK_EVENTS.join(", ")}.`);
  return [...new Set(raw as string[])];
}

function webhookView(w: WebhookEndpointRow) {
  return { id: w.id, url: w.url, events: w.events, active: w.active, createdAt: iso(w.created_at) };
}

function agentKeyView(k: AgentKeyRow) {
  return {
    id: k.id,
    memberId: k.member_id,
    memberName: k.member_name,
    memberEmail: k.member_email,
    memberCompany: k.member_company,
    label: k.label,
    createdAt: iso(k.created_at),
    revokedAt: k.revoked_at === null ? null : iso(k.revoked_at),
  };
}

export function checkLimits(s: Services, raw: unknown): DelegationLimits {
  if (raw === undefined || raw === null) return {};
  if (!isRecord(raw)) throw badRequest("bad-limits", "limits must be an object.");
  const allowed = new Set(["eventTypes", "maxDuration", "maxPerWeek", "hours", "days", "timezone", "companies"]);
  for (const k of Object.keys(raw)) if (!allowed.has(k)) throw badRequest("bad-limits", `limits.${k} is not a known limit.`);
  const out: DelegationLimits = {};
  if (raw.eventTypes !== undefined) {
    if (!Array.isArray(raw.eventTypes)) throw badRequest("bad-limits", "limits.eventTypes must be a list of event type ids.");
    out.eventTypes = raw.eventTypes.map((id) => findEventType(s, String(id)).id);
  }
  const maxDuration = optionalInteger(raw.maxDuration, "limits.maxDuration", 5, 720);
  if (maxDuration !== undefined) out.maxDuration = maxDuration;
  const maxPerWeek = optionalInteger(raw.maxPerWeek, "limits.maxPerWeek", 0, 200);
  if (maxPerWeek !== undefined) out.maxPerWeek = maxPerWeek;
  if (raw.hours !== undefined) out.hours = parseRangeText(raw.hours, "limits.hours");
  if (raw.days !== undefined) {
    if (!Array.isArray(raw.days) || !raw.days.every((d) => (WEEKDAYS as readonly string[]).includes(d as string))) throw badRequest("bad-limits", "limits.days must list days such as mon, tue.");
    out.days = [...new Set(raw.days as string[])];
  }
  if (raw.timezone !== undefined) {
    if (typeof raw.timezone !== "string" || !isValidTimeZone(raw.timezone)) throw badRequest("bad-limits", "limits.timezone must be a time zone such as Europe/Berlin.");
    out.timezone = raw.timezone;
  }
  if (raw.companies !== undefined) {
    if (!Array.isArray(raw.companies)) throw badRequest("bad-limits", "limits.companies must be a list of company slugs.");
    out.companies = raw.companies.map((c, i) => slugValue(c, `limits.companies[${i}]`));
  }
  return out;
}

async function decide(s: Services, approvalId: string, approve: boolean, origin: string, reason?: string) {
  await reclaimExpired(s);
  const approval = await s.store.get("approvals", { id: approvalId });
  if (!approval) throw notFound("There is no approval with that id.");
  if (approval.status !== "pending") throw conflict("approval-closed", `This request was already ${approval.status}.`);
  const ev = findEventType(s, approval.event_type_id);
  if (approve) {
    const delegation = await s.store.get("agent_delegations", { member_id: approval.member_id });
    const result = await createBooking(s, {
      ev,
      duration: approval.duration,
      start: approval.start_at,
      end: approval.end_at,
      hostIds: approval.host_ids,
      source: { type: "approval", approval },
      invitee: { name: approval.member_name, email: approval.member_email, answers: {}, guests: [], timezone: delegation?.limits.timezone ?? defaultZone(s, ev) },
      location: defaultLocation(ev),
      utm: null,
      createdBy: "agent",
      actor: "owner",
      agentKeyId: approval.agent_key_id,
      memberId: approval.member_id,
      agentNote: approval.topic,
      origin,
    });
    await s.providers.notifier.send({
      id: `approval-approved:${approval.id}`,
      recipient: { type: "member", id: approval.member_id },
      kind: "approval-approved",
      title: `Booked: ${ev.title}`,
      body: `The host approved your agent's request. ${ev.title} is booked for ${iso(approval.start_at)}.`,
      approvalId: approval.id,
      bookingId: result.booking.id,
    });
    return { status: "approved", booking: ownerBookingView(s, result.booking, result.attendee) };
  }
  const now = s.now();
  const changed = await s.store.transaction(async (tx) => {
    if (!(await tx.update("approvals", { id: approval.id }, { status: "declined", decided_at: now }, { status: "pending" }))) return false;
    await releaseClaims(tx, approval.claim_keys, approval.id, now);
    await audit(tx, now, { actor: "owner", action: "approval.declined", hostIds: approval.host_ids, memberId: approval.member_id, detail: { approvalId: approval.id } });
    return true;
  });
  if (!changed) throw conflict("approval-closed", "This request was already answered.");
  await s.providers.notifier.send({
    id: `approval-declined:${approval.id}`,
    recipient: { type: "member", id: approval.member_id },
    kind: "approval-declined",
    title: `Declined: ${ev.title}`,
    body: `The host declined your agent's request for ${iso(approval.start_at)}${reason ? `: ${reason}` : "."}`,
    approvalId: approval.id,
  });
  return { status: "declined" };
}

export async function runJobs(s: Services) {
  const reclaimed = await reclaimExpired(s);
  const jobs = await runDueJobs(s);
  const webhooks = await deliverWebhooks(s);
  const retention = s.config.dataRetention?.inviteeDataDays ? await runRetention(s) : { redacted: 0 };
  const counters = await purgeCounters(s);
  return { reclaimed, jobs, webhooks, retention, countersPurged: counters, ranAt: iso(s.now()) };
}

export function registerOwnerRoutes(r: Router<Services>): void {
  r.get("/api/owner/session", owner(({ services: s }) => ({
    ok: true,
    company: s.config.company,
    provider: s.providers.calendar.name,
    sandbox: isSandbox(s),
    store: s.store.kind,
    // The owner pages need host ids (calendar, filters) and every event type, secret ones included (links).
    hosts: s.config.hosts.map((h) => ({ id: h.id, name: h.name, timezone: h.timezone ?? s.config.timezone ?? "UTC" })),
    eventTypes: s.config.eventTypes.map((e) => ({ id: e.id, title: e.title, kind: e.kind, secret: e.secret === true, durations: e.durations })),
  })));

  r.get("/api/owner/bookings", owner(async ({ services: s, query }) => {
    const { limit, offset } = page(query);
    const status = query.get("status");
    if (status && status !== "confirmed" && status !== "canceled") throw badRequest("bad-status", "status must be confirmed or canceled.");
    const from = query.get("from") ? instant(query.get("from"), "from") : undefined;
    const to = query.get("to") ? instant(query.get("to"), "to") : undefined;
    const where: Record<string, unknown> = {};
    if (status) where.status = status;
    if (query.get("eventType")) where.event_type_id = query.get("eventType");
    if (from !== undefined || to !== undefined) where.start_at = { ...(from !== undefined ? { gte: from } : {}), ...(to !== undefined ? { lt: to } : {}) };
    if (query.get("createdBy")) where.created_by = query.get("createdBy");
    let rows = await s.store.find("bookings", where, { orderBy: "start_at", desc: query.get("order") !== "asc" });
    const host = query.get("host");
    if (host) rows = rows.filter((b) => b.host_ids.includes(host));
    const email = query.get("email");
    if (email) {
      const ids = new Set((await s.store.find("attendees", { email_lower: email.trim().toLowerCase() })).map((a) => a.booking_id));
      rows = rows.filter((b) => ids.has(b.id));
    }
    const slice = rows.slice(offset, offset + limit);
    const views = [];
    for (const b of slice) views.push(ownerBookingView(s, b, await s.store.get("attendees", { booking_id: b.id })));
    return { total: rows.length, limit, offset, bookings: views };
  }));

  r.get("/api/owner/bookings/:id", owner(async ({ services: s, params }) => {
    const { booking, attendee } = await loadBooking(s, params.id as string);
    const audits = await s.store.find("audit_log", { booking_id: booking.id }, { orderBy: "at" });
    return { booking: ownerBookingView(s, booking, attendee), audit: audits.map((a) => ({ at: iso(a.at), actor: a.actor, action: a.action, detail: a.detail })) };
  }));

  r.post("/api/owner/bookings/:id/cancel", owner(async ({ services: s, params, body, url }) => {
    const b = await body();
    const { booking } = await loadBooking(s, params.id as string);
    const updated = await cancelBooking(s, booking, { actor: "owner", enforcePolicy: false, reason: b.reason as string | undefined, origin: url.origin });
    return { booking: ownerBookingView(s, updated, await s.store.get("attendees", { booking_id: updated.id })) };
  }));

  r.post("/api/owner/bookings/:id/reschedule", owner(async ({ services: s, params, body, url }) => {
    const b = await body();
    const { booking } = await loadBooking(s, params.id as string);
    await reclaimExpired(s);
    const moved = await rescheduleBooking(s, booking, { actor: "owner", enforcePolicy: false, start: instant(b.start, "start"), reason: b.reason as string | undefined, origin: url.origin });
    return { booking: ownerBookingView(s, moved, await s.store.get("attendees", { booking_id: moved.id })) };
  }));

  r.post("/api/owner/bookings/:id/no-show", owner(async ({ services: s, params, body }) => {
    const b = await body();
    const { booking } = await loadBooking(s, params.id as string);
    const updated = await setNoShow(s, booking, bool(b.noShow, "noShow") ?? true, "owner");
    return { booking: ownerBookingView(s, updated, await s.store.get("attendees", { booking_id: updated.id })) };
  }));

  r.get("/api/owner/links", owner(async ({ services: s }) => {
    const rows = await s.store.find("single_use_links", {}, { orderBy: "created_at", desc: true });
    return {
      links: rows.map((l) => ({
        id: l.id,
        eventType: l.event_type_id,
        singleUse: l.single_use,
        expiresAt: l.expires_at === null ? null : iso(l.expires_at),
        usedAt: l.used_at === null ? null : iso(l.used_at),
        usedBy: l.used_by,
        revokedAt: l.revoked_at === null ? null : iso(l.revoked_at),
        createdAt: iso(l.created_at),
      })),
    };
  }));

  r.post("/api/owner/links", owner(async ({ services: s, body }) => {
    const b = await body();
    const ev = findEventType(s, text(b.eventType, "eventType", { max: 63 }) as string);
    const singleUse = bool(b.singleUse, "singleUse") ?? true;
    const hours = optionalInteger(b.expiresInHours, "expiresInHours", 1, 24 * 365);
    const now = s.now();
    const token = newToken("bl");
    const row = {
      token_hash: sha256Hex(token),
      id: newId("link"),
      event_type_id: ev.id,
      single_use: singleUse,
      expires_at: hours ? now + hours * HOUR : null,
      used_at: null,
      used_by: null,
      revoked_at: null,
      created_at: now,
    };
    await s.store.transaction(async (tx) => {
      await tx.insert("single_use_links", row);
      await audit(tx, now, { actor: "owner", action: "link.created", detail: { linkId: row.id, eventType: ev.id, singleUse } });
    });
    return created({ link: { id: row.id, eventType: ev.id, singleUse, expiresAt: row.expires_at === null ? null : iso(row.expires_at) }, token, path: `/l/${token}` });
  }));

  r.post("/api/owner/links/:id/revoke", owner(async ({ services: s, params }) => {
    const [link] = await s.store.find("single_use_links", { id: params.id as string });
    if (!link) throw notFound("There is no link with that id.");
    await s.store.update("single_use_links", { token_hash: link.token_hash }, { revoked_at: s.now() });
    return { revoked: true };
  }));

  r.get("/api/owner/analytics", owner(async ({ services: s, query }) => {
    const now = s.now();
    const from = query.get("from") ? instant(query.get("from"), "from") : weekStart(now) - 11 * 7 * DAY;
    const to = query.get("to") ? instant(query.get("to"), "to") : weekStart(now) + 7 * DAY;
    if (to <= from) throw badRequest("bad-range", "to must be after from.");
    const rows = await s.store.find("bookings", { start_at: { gte: from, lt: to } });
    return { from: iso(from), to: iso(to), ...analytics(rows) };
  }));

  r.post("/api/owner/invitee-data/delete", owner(async ({ services: s, body }) => {
    const email = text((await body()).email, "email", { max: 254 }) as string;
    if (!isEmail(email)) throw badRequest("bad-email", "email must be an email address.");
    const now = s.now();
    const matches = await s.store.find("attendees", { email_lower: email.toLowerCase() });
    const ids: string[] = [];
    for (const a of matches) {
      const done = await s.store.transaction(async (tx) => {
        const r = await redactBooking(tx, a.booking_id, now);
        if (r) await audit(tx, now, { actor: "owner", action: "invitee.deleted", bookingId: a.booking_id });
        return r;
      });
      if (done) ids.push(a.booking_id);
    }
    return { redacted: ids.length, bookings: ids };
  }));

  r.post("/api/owner/retention/run", owner(async ({ services: s }) => runRetention(s)));

  r.get("/api/owner/outbox", owner(async ({ services: s, query }) => {
    const { limit, offset } = page(query);
    const where = query.get("bookingId") ? { booking_id: query.get("bookingId") } : {};
    const rows = await s.store.find("outbox_emails", where, { orderBy: "created_at", desc: true, limit, offset });
    return { sandbox: s.providers.mailer.name === "sandbox", emails: rows.map((m) => ({ id: m.id, bookingId: m.booking_id, kind: m.kind, to: m.to_addrs, subject: m.subject, html: m.html, text: m.text_body, sandbox: m.sandbox, createdAt: iso(m.created_at) })) };
  }));

  r.get("/api/owner/notifications", owner(async ({ services: s, query }) => {
    const { limit, offset } = page(query);
    const where: Record<string, unknown> = {};
    if (query.get("recipient")) where.recipient_id = query.get("recipient");
    if (query.get("kind")) where.kind = query.get("kind");
    const rows = await s.store.find("notifications", where, { orderBy: "created_at", desc: true, limit, offset });
    return {
      sandbox: s.providers.notifier.name === "sandbox",
      notifications: rows.map((n) => ({ id: n.id, recipient: { type: n.recipient_type, id: n.recipient_id }, kind: n.kind, title: n.title, body: n.body, data: n.data, bookingId: n.booking_id, approvalId: n.approval_id, sandbox: n.sandbox, createdAt: iso(n.created_at) })),
    };
  }));

  r.get("/api/owner/webhook-deliveries", owner(async ({ services: s, query }) => {
    const { limit, offset } = page(query);
    const where = query.get("status") ? { status: query.get("status") } : {};
    const rows = await s.store.find("webhook_outbox", where, { orderBy: "created_at", desc: true, limit, offset });
    return {
      deliveries: rows.map((d) => ({
        id: d.id, endpointId: d.endpoint_id, event: d.event, idempotencyKey: d.idempotency_key, status: d.status, attempts: d.attempts,
        nextAttemptAt: iso(d.next_attempt_at), lastStatus: d.last_status, lastError: d.last_error, createdAt: iso(d.created_at),
        deliveredAt: d.delivered_at === null ? null : iso(d.delivered_at), payload: JSON.parse(d.payload),
      })),
    };
  }));

  r.get("/api/owner/audit", owner(async ({ services: s, query }) => {
    const { limit, offset } = page(query);
    const where: Record<string, unknown> = {};
    if (query.get("bookingId")) where.booking_id = query.get("bookingId");
    if (query.get("memberId")) where.member_id = query.get("memberId");
    if (query.get("action")) where.action = query.get("action");
    const rows = await s.store.find("audit_log", where, { orderBy: "at", desc: true, limit, offset });
    return { entries: rows.map((a) => ({ id: a.id, at: iso(a.at), actor: a.actor, action: a.action, bookingId: a.booking_id, hostIds: a.host_ids, memberId: a.member_id, detail: a.detail })) };
  }));

  r.get("/api/owner/sandbox/calendar", owner(async ({ services: s, query }) => {
    if (!s.sandbox) throw notFound("The sandbox calendar exists only when prototype.provider is sandbox.");
    const host = findHost(s, text(query.get("host"), "host", { max: 63 }) as string);
    const { from, to } = rangeParams(s, query, 7);
    const ch = { id: host.id, email: host.email, timezone: host.timezone ?? s.config.timezone ?? "UTC" };
    const busy = (await s.sandbox.freeBusy([ch], { from, to }))[host.id] ?? [];
    const events = await s.sandbox.events(host.id, from, to);
    return {
      host: { id: host.id, name: host.name, timezone: ch.timezone },
      from: iso(from),
      to: iso(to),
      sandbox: true,
      busy: busy.map((b) => ({ start: iso(b.start), end: iso(b.end) })),
      events: events.map((e) => ({ id: e.id, kind: e.kind, title: e.title, start: iso(e.start_at), end: iso(e.end_at), status: e.status, bookingId: e.booking_id, conference: e.conference, attendees: e.attendees })),
    };
  }));

  r.get("/api/owner/webhooks", owner(async ({ services: s }) => {
    const rows = await s.store.find("webhook_endpoints", {}, { orderBy: "created_at" });
    return {
      configured: (s.config.webhooks ?? []).map((w, i) => ({ id: `config:${i}`, url: w.url, events: w.events, signingSecret: w.signingSecret, secretBound: !!s.secrets[w.signingSecret] })),
      webhooks: rows.map(webhookView),
    };
  }));

  r.post("/api/owner/webhooks", owner(async ({ services: s, body }) => {
    const b = await body();
    const now = s.now();
    const row: WebhookEndpointRow = { id: newId("wh"), url: checkWebhookUrl(b.url, s.allowLocalWebhooks === true), events: eventsList(b.events), secret: newToken("whsec"), active: true, created_at: now };
    await s.store.transaction(async (tx) => {
      await tx.insert("webhook_endpoints", row);
      await audit(tx, now, { actor: "owner", action: "webhook.created", detail: { webhookId: row.id } });
    });
    return created({ webhook: webhookView(row), signingSecret: row.secret });
  }));

  r.patch("/api/owner/webhooks/:id", owner(async ({ services: s, params, body }) => {
    const b = await body();
    const row = await s.store.get("webhook_endpoints", { id: params.id as string });
    if (!row) throw notFound("There is no webhook with that id.");
    const patch: Partial<WebhookEndpointRow> = {};
    if (b.url !== undefined) patch.url = checkWebhookUrl(b.url, s.allowLocalWebhooks === true);
    if (b.events !== undefined) patch.events = eventsList(b.events);
    if (b.active !== undefined) patch.active = bool(b.active, "active") as boolean;
    await s.store.update("webhook_endpoints", { id: row.id }, patch);
    return { webhook: webhookView({ ...row, ...patch }) };
  }));

  r.delete("/api/owner/webhooks/:id", owner(async ({ services: s, params }) => {
    if (!(await s.store.remove("webhook_endpoints", { id: params.id as string }))) throw notFound("There is no webhook with that id.");
    return { deleted: true };
  }));

  r.get("/api/owner/agent-keys", owner(async ({ services: s }) => {
    const rows = await s.store.find("agent_keys", {}, { orderBy: "created_at" });
    return { agentKeys: rows.map(agentKeyView) };
  }));

  r.post("/api/owner/agent-keys", owner(async ({ services: s, body }) => {
    const b = await body();
    const memberEmail = text(b.memberEmail, "memberEmail", { max: 254 }) as string;
    if (!isEmail(memberEmail)) throw badRequest("bad-email", "memberEmail must be an email address.");
    const key = newToken("hqbk_agent");
    const now = s.now();
    const row: AgentKeyRow = {
      key_hash: sha256Hex(key),
      id: newId("agk"),
      member_id: slugValue(b.memberId, "memberId"),
      member_name: text(b.memberName, "memberName", { max: 120 }) as string,
      member_email: memberEmail,
      member_company: b.memberCompany === undefined ? s.config.company : slugValue(b.memberCompany, "memberCompany"),
      label: text(b.label, "label", { max: 80, optional: true }) ?? null,
      created_at: now,
      revoked_at: null,
    };
    await s.store.transaction(async (tx) => {
      await tx.insert("agent_keys", row);
      await audit(tx, now, { actor: "owner", action: "agent-key.created", memberId: row.member_id, detail: { agentKeyId: row.id, company: row.member_company } });
    });
    return created({ agentKey: agentKeyView(row), key });
  }));

  r.post("/api/owner/agent-keys/:id/revoke", owner(async ({ services: s, params }) => {
    const [row] = await s.store.find("agent_keys", { id: params.id as string });
    if (!row) throw notFound("There is no agent key with that id.");
    const now = s.now();
    await s.store.transaction(async (tx) => {
      await tx.update("agent_keys", { key_hash: row.key_hash }, { revoked_at: now });
      await audit(tx, now, { actor: "owner", action: "agent-key.revoked", memberId: row.member_id, detail: { agentKeyId: row.id } });
    });
    return { revoked: true };
  }));

  r.get("/api/owner/delegations", owner(async ({ services: s }) => {
    const rows = await s.store.find("agent_delegations", {});
    return { delegations: rows.map((d) => ({ memberId: d.member_id, enabled: d.enabled, limits: d.limits, updatedAt: iso(d.updated_at) })) };
  }));

  r.put("/api/owner/delegations/:memberId", owner(async ({ services: s, params, body }) => {
    const b = await body();
    const memberId = slugValue(params.memberId, "memberId");
    const enabled = bool(b.enabled, "enabled");
    if (enabled === undefined) throw badRequest("missing-field", "enabled is required.");
    const limits = checkLimits(s, b.limits);
    const now = s.now();
    await s.store.transaction(async (tx) => {
      const row = { member_id: memberId, enabled, limits, updated_at: now };
      if (await tx.get("agent_delegations", { member_id: memberId })) await tx.update("agent_delegations", { member_id: memberId }, row);
      else await tx.insert("agent_delegations", row);
      await audit(tx, now, { actor: "owner", action: enabled ? "delegation.enabled" : "delegation.disabled", memberId, detail: { limits } });
    });
    return { delegation: { memberId, enabled, limits, updatedAt: iso(now) } };
  }));

  r.get("/api/owner/approvals", owner(async ({ services: s, query }) => {
    await reclaimExpired(s);
    const where = query.get("status") ? { status: query.get("status") } : {};
    const rows = await s.store.find("approvals", where as never, { orderBy: "created_at", desc: true });
    return {
      approvals: rows.map((a) => ({
        id: a.id, status: a.status, eventType: a.event_type_id, start: iso(a.start_at), end: iso(a.end_at), duration: a.duration, hostIds: a.host_ids,
        requester: { memberId: a.member_id, name: a.member_name, email: a.member_email, company: a.member_company, agentKeyId: a.agent_key_id },
        topic: a.topic === null ? null : { text: a.topic, untrusted: true },
        expiresAt: iso(a.expires_at), createdAt: iso(a.created_at), decidedAt: a.decided_at === null ? null : iso(a.decided_at), bookingId: a.booking_id,
      })),
    };
  }));

  r.post("/api/owner/approvals/:id/approve", owner(async ({ services: s, params, url }) => decide(s, params.id as string, true, url.origin)));
  r.post("/api/owner/approvals/:id/decline", owner(async ({ services: s, params, body, url }) => {
    const reason = text((await body()).reason, "reason", { max: 300, optional: true });
    return decide(s, params.id as string, false, url.origin, reason);
  }));

  r.post("/api/owner/jobs/run", owner(async ({ services: s }) => runJobs(s)));
}
