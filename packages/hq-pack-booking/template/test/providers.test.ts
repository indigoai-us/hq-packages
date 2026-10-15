import { test } from "node:test";
import assert from "node:assert/strict";
import { buildServices, createBookingApp, startupFailure } from "../api/_lib/app.ts";
import { ProviderError } from "../api/_lib/errors.ts";
import { bookingKeyAuth, HqProCalendar, HqProClient, HqProMailer, HqProNotifier, HqProVideo, type FetchLike } from "../api/_lib/hqpro.ts";
import { MemoryStore } from "../api/_lib/memory-store.ts";
import { SandboxCalendar, sandboxBusyFor, sandboxConference, sandboxProviders, SANDBOX_MEET_HOST } from "../api/_lib/sandbox.ts";
import { harness, MONDAY, testConfig } from "./harness.ts";

const host = { id: "ana", email: "ana@acme.example", timezone: "UTC" };

test("sandbox busy blocks are deterministic, on weekdays, inside 09:00-18:00", () => {
  const a = sandboxBusyFor("ana", "2026-11-03", "America/New_York");
  assert.deepEqual(sandboxBusyFor("ana", "2026-11-03", "America/New_York"), a);
  assert.deepEqual(sandboxBusyFor("ana", "2026-11-07", "UTC"), [], "Saturday");
  assert.deepEqual(sandboxBusyFor("ana", "2026-11-08", "UTC"), [], "Sunday");
  let total = 0;
  for (let d = 2; d <= 27; d++) {
    const day = `2026-11-${String(d).padStart(2, "0")}`;
    for (const b of sandboxBusyFor("ben", day, "UTC")) {
      total++;
      const h = new Date(b.start).getUTCHours();
      assert.ok(h >= 9 && h < 18 && b.end > b.start);
    }
  }
  assert.ok(total > 10, "a month has a plausible number of busy blocks");
});

test("sandbox calendar seeds once, ignores given events and only changes its own events", async () => {
  const store = new MemoryStore();
  const cal = new SandboxCalendar(store, () => MONDAY);
  const range = { from: Date.parse("2026-11-02T00:00:00Z"), to: Date.parse("2026-11-07T00:00:00Z") };
  const first = await cal.freeBusy([host], range);
  const seeded = await store.count("sandbox_events");
  await cal.freeBusy([host], range);
  assert.equal(await store.count("sandbox_events"), seeded, "seeding is idempotent");
  const made = await cal.createEvent({ host, bookingId: "bk_1", start: Date.parse("2026-11-03T07:00:00Z"), end: Date.parse("2026-11-03T07:30:00Z"), summary: "Intro", description: "", attendees: [{ email: "i@x.example" }], conference: "meet", idempotencyKey: "bk_1:ana" });
  assert.match(made.conference?.joinUrl ?? "", new RegExp(SANDBOX_MEET_HOST));
  assert.deepEqual(await cal.createEvent({ host, bookingId: "bk_1", start: 0, end: 1, summary: "", description: "", attendees: [], idempotencyKey: "bk_1:ana" }), { eventId: made.eventId }, "same idempotency key, same event");
  const withEvent = await cal.freeBusy([host], range);
  assert.equal(withEvent.ana?.length, (first.ana?.length ?? 0) + 1);
  assert.equal((await cal.freeBusy([host], range, { ignoreEventIds: [made.eventId] })).ana?.length, first.ana?.length);
  const busyId = (await store.find("sandbox_events", { kind: "busy" }))[0]?.id;
  if (busyId) {
    await assert.rejects(cal.cancelEvent(busyId, host), (e: unknown) => e instanceof ProviderError && e.status === 404);
  }
  await assert.rejects(cal.updateEvent(made.eventId, { host: { ...host, id: "ben" }, bookingId: "bk_1", start: 0, end: 1, summary: "", description: "", attendees: [], idempotencyKey: "x" }), ProviderError);
  await cal.cancelEvent(made.eventId, host);
  assert.equal((await store.get("sandbox_events", { id: made.eventId }))?.status, "canceled");
  await cal.seed(host, range.from, range.to);
  assert.deepEqual(sandboxConference("zoom", "bk_1"), sandboxConference("zoom", "bk_1"));
});

test("sandbox mailer and notifier store each id once", async () => {
  const store = new MemoryStore();
  const p = sandboxProviders(store, () => 1);
  const msg = { id: "m1", kind: "confirmation", to: ["a@b.example"], subject: "s", html: "<p>h</p>", text: "t" };
  assert.equal(await p.mailer.send(msg), true);
  assert.equal(await p.mailer.send(msg), false);
  assert.equal(await p.notifier.send({ id: "n1", recipient: { type: "host", id: "ana" }, kind: "k", title: "t", body: "b" }), true);
  assert.equal(await p.notifier.send({ id: "n1", recipient: { type: "host", id: "ana" }, kind: "k", title: "t", body: "b" }), false);
  assert.equal((await store.get("outbox_emails", { id: "m1" }))?.sandbox, true);
});

interface Seen {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: any;
}

function fakeHqPro(reply: (s: Seen) => { status: number; body: unknown } | "throw"): { fetch: FetchLike; seen: Seen[] } {
  const seen: Seen[] = [];
  const fetch: FetchLike = async (url, init) => {
    const s = { url, method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined };
    seen.push(s);
    const r = reply(s);
    if (r === "throw") throw new Error("ECONNRESET");
    return { ok: r.status < 300, status: r.status, text: async () => (typeof r.body === "string" ? r.body : JSON.stringify(r.body)) };
  };
  return { fetch, seen };
}

test("hq-pro calendar client follows the contract", async () => {
  const { fetch, seen } = fakeHqPro((s) => {
    if (s.url.endsWith("/freebusy")) return { status: 200, body: { hosts: { ana: { busy: [{ start: "2026-11-03T15:00:00Z", end: "2026-11-03T14:00:00Z" }, { start: "2026-11-03T10:00:00Z", end: "2026-11-03T11:00:00Z" }] } } } };
    if (s.method === "POST" && s.url.endsWith("/events")) return { status: 201, body: { eventId: "gcal_1", conference: { provider: "meet", joinUrl: "https://meet.google.com/abc" } } };
    return { status: 200, body: {} };
  });
  const client = new HqProClient({ baseUrl: "https://api.example/v1/booking/", authorize: bookingKeyAuth("hqbk_key"), appId: "app_1", fetch });
  const cal = new HqProCalendar(client);
  const busy = await cal.freeBusy([host], { from: 0, to: 1 }, { ignoreEventIds: ["gcal_0"] });
  assert.deepEqual(busy, { ana: [{ start: Date.parse("2026-11-03T10:00:00Z"), end: Date.parse("2026-11-03T11:00:00Z") }] });
  assert.equal(seen[0]?.url, "https://api.example/v1/booking/freebusy");
  assert.equal(seen[0]?.headers.authorization, "Bearer hqbk_key");
  assert.equal(seen[0]?.headers["x-hq-app-id"], "app_1");
  assert.deepEqual(seen[0]?.body, { hosts: [{ hostId: "ana", email: "ana@acme.example", timezone: "UTC" }], from: "1970-01-01T00:00:00.000Z", to: "1970-01-01T00:00:00.001Z", ignoreEventIds: ["gcal_0"] });
  const input = { host, bookingId: "bk_1", start: 0, end: 60_000, summary: "Intro", description: "d", attendees: [{ email: "i@x.example" }], conference: "meet" as const, idempotencyKey: "bk_1:ana" };
  const ev = await cal.createEvent(input);
  assert.deepEqual(ev, { eventId: "gcal_1", conference: { provider: "meet", joinUrl: "https://meet.google.com/abc", sandbox: false } });
  assert.equal(seen[1]?.headers["idempotency-key"], "bk_1:ana");
  assert.equal(seen[1]?.body.conference, "meet");
  await cal.updateEvent("gcal/1", input);
  assert.equal(seen[2]?.method, "PATCH");
  assert.equal(seen[2]?.url, "https://api.example/v1/booking/events/gcal%2F1");
  await cal.cancelEvent("gcal_1", host);
  assert.equal(seen[3]?.method, "DELETE");
  assert.equal(seen[3]?.url, "https://api.example/v1/booking/events/gcal_1?hostId=ana");
});

test("hq-pro errors become plain provider errors", async () => {
  const cases: [ReturnType<Parameters<typeof fakeHqPro>[0]>, RegExp, number][] = [
    [{ status: 403, body: { error: { code: "HOST_NOT_IN_COMPANY", message: "That host is not in this company." } } }, /not in this company/, 502],
    [{ status: 404, body: { error: { code: "NOT_APP_EVENT", message: "Not created by this app." } } }, /Not created/, 404],
    [{ status: 500, body: "<html>oops</html>" }, /refused the request/, 502],
    [{ status: 200, body: "not json" }, /could not read/, 502],
    ["throw", /did not answer/, 502],
  ];
  for (const [reply, message, status] of cases) {
    const { fetch } = fakeHqPro(() => reply);
    const cal = new HqProCalendar(new HqProClient({ baseUrl: "https://api.example", authorize: async () => ({}), appId: "a", fetch }));
    await assert.rejects(cal.cancelEvent("e", host), (e: unknown) => e instanceof ProviderError && message.test(e.message) && e.status === status);
  }
  const { fetch } = fakeHqPro(() => ({ status: 200, body: {} }));
  const cal = new HqProCalendar(new HqProClient({ baseUrl: "https://api.example", authorize: () => ({}), appId: "a", fetch }));
  await assert.rejects(cal.freeBusy([host], { from: 0, to: 1 }), /no busy times/);
  await assert.rejects(cal.createEvent({ host, bookingId: "b", start: 0, end: 1, summary: "", description: "", attendees: [], idempotencyKey: "k" }), /event id/);
});

test("hq-pro mail, DM and meeting clients", async () => {
  const { fetch, seen } = fakeHqPro((s) => {
    if (s.url.endsWith("/meetings")) return { status: 200, body: s.body.kind === "zoom" ? { provider: "zoom", joinUrl: "https://zoom.us/j/1" } : { joinUrl: "http://insecure" } };
    if (s.url.endsWith("/notify/email")) return { status: 200, body: { sent: false } };
    return { status: 200, body: {} };
  });
  const client = new HqProClient({ baseUrl: "https://api.example/v1/booking", authorize: bookingKeyAuth("k"), appId: "a", fetch });
  const video = new HqProVideo(client);
  assert.deepEqual(await video.createMeeting({ kind: "zoom", bookingId: "b", host, start: 0, end: 1, title: "t" }), { provider: "zoom", joinUrl: "https://zoom.us/j/1", sandbox: false });
  await assert.rejects(video.createMeeting({ kind: "teams", bookingId: "b", host, start: 0, end: 1, title: "t" }), /join link/);
  assert.equal(await new HqProMailer(client).send({ id: "m", kind: "k", to: ["a@b.example"], subject: "s", html: "h", text: "t" }), false);
  assert.equal(await new HqProNotifier(client).send({ id: "n", recipient: { type: "member", id: "zoe" }, kind: "k", title: "t", body: "b" }), true);
  assert.equal(seen.find((s) => s.url.endsWith("/notify/email"))?.headers["idempotency-key"], "m");
});

test("provider choice: sandbox by default, hq-pro only with its URL and key", async () => {
  const store = new MemoryStore();
  const cfg = testConfig({ prototype: { provider: "hqpro" } });
  assert.throws(() => buildServices({ config: cfg, store }), /HQ_BOOKING_API_URL/);
  try {
    buildServices({ config: cfg, store });
  } catch (err) {
    const r = startupFailure(err);
    assert.equal(r.status, 503);
  }
  const r500 = startupFailure(new Error("boom"));
  assert.equal(r500.status, 503);
  assert.match(await r500.text(), /could not start/);
  const { fetch } = fakeHqPro(() => ({ status: 200, body: { hosts: { ana: { busy: [] } } } }));
  const s = buildServices({ config: cfg, store, env: { HQ_BOOKING_API_URL: "https://api.example/v1/booking", PUBLIC_BASE_URL: "https://book.acme.example" }, secrets: { HQ_BOOKING_KEY: "k", BOOKING_TOKEN_KEY: "fixed" }, fetch, appId: "app" });
  assert.equal(s.providers.calendar.name, "hqpro");
  assert.equal(s.providers.video.name, "sandbox");
  assert.equal(s.sandbox, undefined);
  assert.equal(s.tokenKey, "fixed");
  assert.equal(s.publicBaseUrl, "https://book.acme.example");
  const app = createBookingApp(s);
  const cal = await app.handle(new Request("https://x.example/api/owner/sandbox/calendar?host=ana", { headers: { authorization: "Bearer nope-nope-nope" } }));
  assert.equal(cal.status, 503, "owner key is not set in this config");
  const sb = buildServices({ config: testConfig(), store });
  assert.equal(sb.providers.calendar.name, "sandbox");
  assert.ok(sb.sandbox);
  assert.equal(buildServices({ config: testConfig(), store }).tokenKey, sb.tokenKey, "token key is stable for one config");
  const h = harness();
  assert.ok(h.app.services.sandbox);
});
