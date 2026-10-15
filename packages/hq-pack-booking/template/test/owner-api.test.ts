import { test } from "node:test";
import assert from "node:assert/strict";
import { analytics } from "../api/_lib/owner-api.ts";
import { signWebhook, WEBHOOK_BACKOFF_MS } from "../api/_lib/notify.ts";
import { book, harness, OWNER_KEY } from "./harness.ts";
import { booking as bookingRow } from "./store-contract.ts";

const MIN = 60_000;
const HOUR = 60 * MIN;

test("owner routes need the owner key", async () => {
  const h = harness();
  const none = await h.call("GET", "/api/owner/bookings");
  assert.equal(none.status, 401);
  assert.match(none.body.error.message, /Authorization: Bearer/);
  assert.equal((await h.call("GET", "/api/owner/bookings", undefined, { authorization: "Bearer wrong-key-123" })).status, 401);
  assert.equal((await h.call("GET", "/api/owner/bookings", undefined, { authorization: OWNER_KEY })).status, 401);
  const ok = await h.owner("GET", "/api/owner/session");
  const { hosts, eventTypes, ...session } = ok.body;
  assert.deepEqual(session, { ok: true, company: "acme", provider: "sandbox", sandbox: true, store: "memory" });
  assert.ok(hosts.length > 0 && hosts.every((x: { id: string; name: string; timezone: string }) => x.id && x.name && x.timezone));
  assert.ok(eventTypes.some((e: { id: string; secret: boolean }) => e.id === "vip" && e.secret === true), "session lists secret event types for the owner");
  assert.ok(!JSON.stringify(hosts).includes("@"), "session must not list host emails");
  let last;
  for (let i = 0; i < 21; i++) last = await h.call("GET", "/api/owner/session", undefined, { authorization: "Bearer guessing-1234", "x-forwarded-for": "198.51.100.200" });
  assert.equal(last?.status, 429);
});

test("list, filter and read bookings", async () => {
  const h = harness();
  const a = await book(h, "intro");
  const b = await book(h, "demo", { email: "other@client.example" });
  await h.owner("POST", `/api/owner/bookings/${b.res.body.booking.id}/cancel`, {});
  const all = await h.owner("GET", "/api/owner/bookings?order=asc");
  assert.equal(all.body.total, 2);
  assert.equal(all.body.bookings[0].invitee.email, "iris@client.example");
  assert.equal((await h.owner("GET", "/api/owner/bookings?status=canceled")).body.total, 1);
  assert.equal((await h.owner("GET", "/api/owner/bookings?eventType=intro")).body.total, 1);
  assert.equal((await h.owner("GET", "/api/owner/bookings?email=OTHER@client.example")).body.total, 1);
  const host = b.res.body.booking.hosts[0].name === "Ana Diaz" ? "ana" : "ben";
  assert.ok((await h.owner("GET", `/api/owner/bookings?host=${host}`)).body.total >= 1);
  assert.equal((await h.owner("GET", "/api/owner/bookings?from=2030-01-01T00:00:00Z")).body.total, 0);
  assert.equal((await h.owner("GET", "/api/owner/bookings?to=2020-01-01T00:00:00Z&createdBy=invitee")).body.total, 0);
  assert.equal((await h.owner("GET", "/api/owner/bookings?limit=1&offset=1")).body.bookings.length, 1);
  assert.equal((await h.owner("GET", "/api/owner/bookings?status=maybe")).status, 400);
  assert.equal((await h.owner("GET", "/api/owner/bookings?limit=0")).status, 400);
  const detail = await h.owner("GET", `/api/owner/bookings/${a.res.body.booking.id}`);
  assert.equal(detail.body.booking.hostIds[0], "ana");
  assert.equal(detail.body.booking.calendarStatus, "created");
  assert.deepEqual(detail.body.audit.map((x: any) => x.action), ["booking.created"]);
  assert.equal((await h.owner("GET", "/api/owner/bookings/bk_nope")).status, 404);
});

test("owner cancel and reschedule skip invitee cutoffs; no-show after the start", async () => {
  const h = harness();
  const { slot, res } = await book(h, "intro");
  const id = res.body.booking.id;
  h.clock.now = Date.parse(slot.start) - 30 * MIN;
  const early = await h.owner("POST", `/api/owner/bookings/${id}/no-show`, {});
  assert.equal(early.body.error.code, "not-started");
  const target = (await h.call("GET", "/api/slots?eventType=intro&from=2026-11-05T00:00:00Z")).body.slots[0];
  const moved = await h.owner("POST", `/api/owner/bookings/${id}/reschedule`, { start: target.start });
  assert.equal(moved.status, 200, moved.text);
  h.clock.now = Date.parse(target.start) + 10 * MIN;
  const ns = await h.owner("POST", `/api/owner/bookings/${id}/no-show`, { noShow: true });
  assert.equal(ns.body.booking.noShow, true);
  assert.equal((await h.store.find("webhook_outbox", { event: "no-show" })).length, 1);
  assert.equal((await h.owner("POST", `/api/owner/bookings/${id}/no-show`, { noShow: false })).body.booking.noShow, false);
  assert.equal((await h.owner("POST", `/api/owner/bookings/${id}/no-show`, { noShow: "yes" })).status, 400);
  const c = await h.owner("POST", `/api/owner/bookings/${id}/cancel`, {});
  assert.equal(c.body.booking.status, "canceled");
  assert.equal(c.body.booking.canceledBy, "owner");
  assert.equal((await h.owner("POST", `/api/owner/bookings/${id}/no-show`, {})).body.error.code, "already-canceled");
});

test("links: mint, list and revoke", async () => {
  const h = harness();
  const m = await h.owner("POST", "/api/owner/links", { eventType: "vip" });
  assert.equal(m.body.link.singleUse, true);
  assert.equal(m.body.link.expiresAt, null);
  assert.match(m.body.path, /^\/l\/bl_/);
  assert.equal((await h.owner("POST", "/api/owner/links", { eventType: "nope" })).status, 404);
  assert.equal((await h.owner("POST", "/api/owner/links", { eventType: "vip", expiresInHours: 0 })).status, 400);
  const list = await h.owner("GET", "/api/owner/links");
  assert.equal(list.body.links.length, 1);
  assert.equal(list.body.links[0].token, undefined, "tokens are shown once only");
  assert.deepEqual((await h.owner("POST", `/api/owner/links/${m.body.link.id}/revoke`)).body, { revoked: true });
  assert.equal((await h.call("GET", `/api/links/${m.body.token}`)).status, 410);
  assert.equal((await h.owner("POST", "/api/owner/links/link_nope/revoke")).status, 404);
});

test("analytics count bookings, cancels and no-shows by event type, host and week", async () => {
  const rows = [
    bookingRow("a", { event_type_id: "intro", host_ids: ["ana"], start_at: Date.parse("2026-11-03T10:00:00Z") }),
    bookingRow("b", { event_type_id: "intro", host_ids: ["ana"], status: "canceled", start_at: Date.parse("2026-11-04T10:00:00Z") }),
    bookingRow("c", { event_type_id: "panel", host_ids: ["ana", "ben"], no_show: true, start_at: Date.parse("2026-11-10T10:00:00Z") }),
    bookingRow("d", { status: "canceled", canceled_by: "system" }),
  ];
  const a = analytics(rows);
  assert.deepEqual(a.totals, { bookings: 3, canceled: 1, noShows: 1 });
  assert.deepEqual(a.byEventType, [
    { key: "intro", bookings: 2, canceled: 1, noShows: 0 },
    { key: "panel", bookings: 1, canceled: 0, noShows: 1 },
  ]);
  assert.deepEqual(a.byHost.map((x) => [x.key, x.bookings]), [["ana", 3], ["ben", 1]]);
  assert.deepEqual(a.byWeek.map((x) => x.key), ["2026-11-02", "2026-11-09"]);

  const h = harness();
  await book(h, "intro");
  const r = await h.owner("GET", "/api/owner/analytics");
  assert.equal(r.body.totals.bookings, 1);
  assert.equal((await h.owner("GET", "/api/owner/analytics?from=2026-11-01T00:00:00Z&to=2026-12-01T00:00:00Z")).body.totals.bookings, 1);
  assert.equal((await h.owner("GET", "/api/owner/analytics?from=2026-12-01T00:00:00Z&to=2026-11-01T00:00:00Z")).status, 400);
});

test("deleting invitee data by email leaves a placeholder and nothing with the email", async () => {
  const h = harness();
  const { res } = await book(h, "intro", { guests: ["g@client.example"] });
  const id = res.body.booking.id;
  const r = await h.owner("POST", "/api/owner/invitee-data/delete", { email: "Iris@Client.example" });
  assert.deepEqual(r.body, { redacted: 1, bookings: [id] });
  assert.equal((await h.store.find("attendees", { email_lower: "iris@client.example" })).length, 0);
  const a = await h.store.get("attendees", { booking_id: id });
  assert.equal(a?.name, "Deleted invitee");
  assert.equal(a?.email, null);
  assert.deepEqual(a?.guests, []);
  const emails = await h.store.find("outbox_emails", { booking_id: id });
  assert.ok(emails.every((e) => !JSON.stringify(e).includes("iris@client.example")));
  const view = await h.owner("GET", `/api/owner/bookings/${id}`);
  assert.equal(view.body.booking.invitee, null);
  assert.equal(view.body.booking.inviteeRedacted, true);
  assert.equal(view.body.booking.status, "confirmed");
  assert.deepEqual((await h.owner("POST", "/api/owner/invitee-data/delete", { email: "iris@client.example" })).body, { redacted: 0, bookings: [] });
  assert.equal((await h.owner("POST", "/api/owner/invitee-data/delete", { email: "nope" })).status, 400);
  assert.ok((await h.owner("GET", "/api/owner/audit?action=invitee.deleted")).body.entries.length === 1);
});

test("retention purge redacts invitees of old meetings only", async () => {
  const h = harness();
  const old = await book(h, "intro");
  h.clock.now += 40 * 24 * HOUR;
  const fresh = await book(h, "intro");
  const r = await h.owner("POST", "/api/owner/retention/run");
  assert.deepEqual(r.body, { redacted: 1 });
  assert.notEqual((await h.store.get("attendees", { booking_id: old.res.body.booking.id }))?.redacted_at, null);
  assert.equal((await h.store.get("attendees", { booking_id: fresh.res.body.booking.id }))?.redacted_at, null);
  const off = harness({ config: { ...h.app.services.config, dataRetention: {} } });
  assert.match((await off.owner("POST", "/api/owner/retention/run")).body.skipped, /inviteeDataDays/);
});

test("outbox, notifications, deliveries, audit and the sandbox calendar are readable", async () => {
  const h = harness();
  const { res } = await book(h, "intro");
  const id = res.body.booking.id;
  const out = await h.owner("GET", `/api/owner/outbox?bookingId=${id}`);
  assert.equal(out.body.sandbox, true);
  assert.equal(out.body.emails[0].kind, "confirmation");
  assert.match(out.body.emails[0].html, /Iris Invitee/);
  const n = await h.owner("GET", "/api/owner/notifications?recipient=ana&kind=booking-created");
  assert.equal(n.body.notifications.length, 1);
  assert.equal(n.body.notifications[0].recipient.type, "host");
  const d = await h.owner("GET", "/api/owner/webhook-deliveries?status=pending");
  assert.equal(d.body.deliveries[0].event, "booked");
  assert.equal(d.body.deliveries[0].payload.data.id, id);
  const audit = await h.owner("GET", `/api/owner/audit?bookingId=${id}&memberId=x`);
  assert.equal(audit.body.entries.length, 0);
  assert.equal((await h.owner("GET", `/api/owner/audit?bookingId=${id}`)).body.entries.length, 1);
  const cal = await h.owner("GET", "/api/owner/sandbox/calendar?host=ana&from=2026-11-02T00:00:00Z&to=2026-11-09T00:00:00Z");
  assert.equal(cal.status, 200);
  assert.equal(cal.body.sandbox, true);
  assert.ok(cal.body.events.some((e: any) => e.bookingId === id && e.kind === "booking"));
  assert.ok(cal.body.busy.length >= cal.body.events.filter((e: any) => e.status === "confirmed").length - 1);
  assert.equal((await h.owner("GET", "/api/owner/sandbox/calendar?host=zed")).status, 404);
});

test("webhooks: create with a secret shown once, sign deliveries, retry with backoff", async () => {
  const h = harness();
  const bad = await h.owner("POST", "/api/owner/webhooks", { url: "http://hooks.example/x", events: ["booked"] });
  assert.equal(bad.body.error.code, "bad-url");
  for (const url of ["https://127.0.0.1/x", "https://localhost/x", "https://box.internal/x", "not a url"]) {
    assert.equal((await h.owner("POST", "/api/owner/webhooks", { url, events: ["booked"] })).status, 400, url);
  }
  assert.equal((await h.owner("POST", "/api/owner/webhooks", { url: "https://hooks.example/x", events: ["paid"] })).body.error.code, "bad-events");
  const made = await h.owner("POST", "/api/owner/webhooks", { url: "https://hooks.example/x", events: ["booked", "canceled"] });
  assert.equal(made.status, 201);
  const secret = made.body.signingSecret;
  assert.match(secret, /^whsec_/);
  const list = await h.owner("GET", "/api/owner/webhooks");
  assert.equal(list.body.webhooks.length, 1);
  assert.doesNotMatch(list.text, new RegExp(secret));
  assert.deepEqual(list.body.configured[0], { id: "config:0", url: "https://hooks.acme.example/booking", events: ["booked", "canceled", "rescheduled", "no-show"], signingSecret: "BOOKING_WEBHOOK_SECRET", secretBound: true });

  await book(h, "intro");
  // Config endpoint first (200), then the new one fails twice before it succeeds.
  h.webhookStatus.push(200, 500, 500);
  let run = await h.owner("POST", "/api/owner/jobs/run");
  assert.deepEqual(run.body.webhooks, { delivered: 1, retrying: 1, failed: 0 });
  const ours = h.deliveries.find((d) => d.url === "https://hooks.example/x");
  assert.ok(ours);
  const sig = ours.headers["x-hq-booking-signature"] as string;
  const t = Number(/t=(\d+)/.exec(sig)?.[1]);
  assert.equal(sig, signWebhook(secret, ours.body, t));
  const cfgDelivery = h.deliveries.find((d) => d.url === "https://hooks.acme.example/booking");
  assert.ok(cfgDelivery);
  const t2 = Number(/t=(\d+)/.exec(cfgDelivery.headers["x-hq-booking-signature"] as string)?.[1]);
  assert.equal(cfgDelivery.headers["x-hq-booking-signature"], signWebhook("whsec_test", cfgDelivery.body, t2));
  assert.equal(ours.headers["x-hq-booking-event"], "booked");
  assert.match(ours.headers["idempotency-key"] as string, /^booked:bk_/);

  // The failing endpoint: retried after 1 minute, then 5; delivered on the third attempt.
  h.clock.now += WEBHOOK_BACKOFF_MS[0] as number;
  run = await h.owner("POST", "/api/owner/jobs/run");
  assert.deepEqual(run.body.webhooks, { delivered: 0, retrying: 1, failed: 0 });
  h.clock.now += WEBHOOK_BACKOFF_MS[1] as number;
  run = await h.owner("POST", "/api/owner/jobs/run");
  assert.deepEqual(run.body.webhooks, { delivered: 1, retrying: 0, failed: 0 });
  const done = await h.owner("GET", "/api/owner/webhook-deliveries?status=delivered");
  assert.equal(done.body.deliveries.length, 2);
  assert.ok(done.body.deliveries.some((d: any) => d.attempts === 3));
  const keys = h.deliveries.filter((d) => d.url === "https://hooks.example/x").map((d) => d.headers["idempotency-key"]);
  assert.equal(keys.length, 3);
  assert.equal(new Set(keys).size, 1, "one idempotency key for every attempt");

  const patched = await h.owner("PATCH", `/api/owner/webhooks/${made.body.webhook.id}`, { active: false, events: ["canceled"], url: "https://hooks.example/y" });
  assert.deepEqual([patched.body.webhook.active, patched.body.webhook.events, patched.body.webhook.url], [false, ["canceled"], "https://hooks.example/y"]);
  assert.equal((await h.owner("PATCH", "/api/owner/webhooks/wh_nope", {})).status, 404);
  assert.deepEqual((await h.owner("DELETE", `/api/owner/webhooks/${made.body.webhook.id}`)).body, { deleted: true });
  assert.equal((await h.owner("DELETE", `/api/owner/webhooks/${made.body.webhook.id}`)).status, 404);
});

test("webhook deliveries give up after the last backoff and report missing secrets", async () => {
  const h = harness({ secrets: {} });
  await book(h, "intro");
  for (let i = 0; i <= WEBHOOK_BACKOFF_MS.length; i++) {
    await h.owner("POST", "/api/owner/jobs/run");
    h.clock.now += 13 * HOUR;
  }
  const failed = await h.owner("GET", "/api/owner/webhook-deliveries?status=failed");
  assert.equal(failed.body.deliveries.length, 1);
  assert.match(failed.body.deliveries[0].lastError, /BOOKING_WEBHOOK_SECRET is not bound/);
  assert.equal(failed.body.deliveries[0].attempts, WEBHOOK_BACKOFF_MS.length + 1);
  assert.equal(h.deliveries.length, 0);
});

test("unreachable webhook endpoints are retried", async () => {
  const h = harness();
  h.app.services.fetch = async () => {
    throw new Error("ECONNREFUSED");
  };
  await book(h, "intro");
  const run = await h.owner("POST", "/api/owner/jobs/run");
  assert.deepEqual(run.body.webhooks, { delivered: 0, retrying: 1, failed: 0 });
  const d = await h.owner("GET", "/api/owner/webhook-deliveries");
  assert.equal(d.body.deliveries[0].lastError, "The endpoint could not be reached.");
});

test("jobs: one reminder at its time, a host brief before, a follow-up after", async () => {
  const h = harness();
  const { slot, res } = await book(h, "intro", { answers: { company: "Client Co", size: "11+" } });
  const id = res.body.booking.id;
  const start = Date.parse(slot.start);
  await h.owner("POST", "/api/owner/jobs/run");
  assert.equal((await h.store.find("outbox_emails", { booking_id: id, kind: "reminder" })).length, 0);
  h.clock.now = start - 60 * MIN;
  const r1 = await h.owner("POST", "/api/owner/jobs/run");
  assert.equal(r1.body.jobs.done, 1);
  await h.owner("POST", "/api/owner/jobs/run");
  assert.equal((await h.store.find("outbox_emails", { booking_id: id, kind: "reminder" })).length, 1, "exactly one reminder");
  h.clock.now = start - 30 * MIN;
  await h.owner("POST", "/api/owner/jobs/run");
  const briefs = await h.store.find("notifications", { booking_id: id, kind: "host-brief" });
  assert.equal(briefs.length, 1);
  assert.match(briefs[0]?.body ?? "", /Team size: 11\+/);
  assert.match(briefs[0]?.body ?? "", /Invitee: Iris Invitee <iris@client\.example>/);
  h.clock.now = start + 30 * MIN + 30 * MIN;
  await h.owner("POST", "/api/owner/jobs/run");
  const follow = await h.store.find("outbox_emails", { booking_id: id, kind: "follow-up" });
  assert.equal(follow.length, 1);
  assert.deepEqual(follow[0]?.to_addrs, ["iris@client.example"]);
  assert.equal((await h.store.find("notification_jobs", { booking_id: id, status: "pending" })).length, 0);
});

test("jobs for canceled bookings are not sent, failing jobs are retried", async () => {
  const h = harness();
  const a = await book(h, "intro");
  const b = await book(h, "intro");
  await h.owner("POST", `/api/owner/bookings/${a.res.body.booking.id}/cancel`, {});
  const mailer = h.app.services.providers.mailer;
  const send = mailer.send.bind(mailer);
  let fail = true;
  mailer.send = async (m) => {
    if (fail && m.kind === "reminder") throw new Error("smtp down");
    return send(m);
  };
  h.clock.now = Date.parse(b.slot.start) - 60 * MIN;
  const r = await h.owner("POST", "/api/owner/jobs/run");
  assert.equal(r.body.jobs.done, 0);
  const job = (await h.store.find("notification_jobs", { booking_id: b.res.body.booking.id, kind: "reminder" }))[0];
  assert.equal(job?.status, "pending");
  assert.equal(job?.last_error, "smtp down");
  fail = false;
  h.clock.now += 5 * MIN;
  await h.owner("POST", "/api/owner/jobs/run");
  assert.equal((await h.store.find("notification_jobs", { booking_id: b.res.body.booking.id, kind: "reminder" }))[0]?.status, "done");
  assert.equal((await h.store.find("outbox_emails", { booking_id: a.res.body.booking.id, kind: "reminder" })).length, 0);
});

test("agent keys and delegations are managed by the owner", async () => {
  const h = harness();
  const bad = await h.owner("POST", "/api/owner/agent-keys", { memberId: "zoe", memberName: "Zoe", memberEmail: "nope" });
  assert.equal(bad.body.error.code, "bad-email");
  const k = await h.owner("POST", "/api/owner/agent-keys", { memberId: "zoe", memberName: "Zoe Park", memberEmail: "zoe@globex.example", memberCompany: "globex", label: "Zoe's agent" });
  assert.equal(k.status, 201);
  assert.match(k.body.key, /^hqbk_agent_/);
  assert.equal(k.body.agentKey.memberCompany, "globex");
  const list = await h.owner("GET", "/api/owner/agent-keys");
  assert.equal(list.body.agentKeys.length, 1);
  assert.doesNotMatch(list.text, new RegExp(k.body.key));
  assert.deepEqual((await h.owner("POST", `/api/owner/agent-keys/${k.body.agentKey.id}/revoke`)).body, { revoked: true });
  assert.notEqual((await h.owner("GET", "/api/owner/agent-keys")).body.agentKeys[0].revokedAt, null);
  assert.equal((await h.owner("POST", "/api/owner/agent-keys/agk_nope/revoke")).status, 404);

  const put = await h.owner("PUT", "/api/owner/delegations/zoe", {
    enabled: true,
    limits: { eventTypes: ["intro"], maxDuration: 30, maxPerWeek: 3, hours: "09:00-17:00", days: ["mon", "tue"], timezone: "Europe/Berlin", companies: ["acme"] },
  });
  assert.equal(put.status, 200, put.text);
  assert.equal((await h.owner("PUT", "/api/owner/delegations/zoe", { enabled: false })).body.delegation.enabled, false);
  assert.equal((await h.owner("GET", "/api/owner/delegations")).body.delegations[0].enabled, false);
  const badLimits: unknown[] = [
    { enabled: true, limits: { colour: 1 } },
    { enabled: true, limits: { hours: "9-5" } },
    { enabled: true, limits: { hours: "17:00-09:00" } },
    { enabled: true, limits: { days: ["someday"] } },
    { enabled: true, limits: { timezone: "Mars/Base" } },
    { enabled: true, limits: { companies: "acme" } },
    { enabled: true, limits: { eventTypes: "intro" } },
    { enabled: true, limits: "x" },
    { limits: {} },
  ];
  for (const body of badLimits) assert.equal((await h.owner("PUT", "/api/owner/delegations/zoe", body)).status, 400, JSON.stringify(body));
  assert.equal((await h.owner("PUT", "/api/owner/delegations/zoe", { enabled: true, limits: { eventTypes: ["nope"] } })).status, 404);
});
