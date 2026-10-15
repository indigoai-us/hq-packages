import { test } from "node:test";
import assert from "node:assert/strict";
import { createBooking, checkInvitee } from "../api/_lib/bookings.ts";
import { ProviderError } from "../api/_lib/errors.ts";
import { sandboxBusyFor, sandboxProviders } from "../api/_lib/sandbox.ts";
import { findEventType } from "../api/_lib/services.ts";
import { slotAt } from "../api/_lib/slots.ts";
import { book, firstSlot, harness, introAnswers, invitee, MONDAY, testConfig } from "./harness.ts";

const MIN = 60_000;

test("public config lists public event types and forms, never secrets or rules", async () => {
  const h = harness();
  const r = await h.call("GET", "/api/config/public");
  assert.equal(r.status, 200);
  assert.equal(r.body.company, "acme");
  assert.equal(r.body.sandbox, true);
  assert.deepEqual(r.body.eventTypes.map((e: any) => e.id), ["intro", "demo", "panel", "class"]);
  const demo = r.body.eventTypes.find((e: any) => e.id === "demo");
  assert.deepEqual(demo.hosts, [], "round-robin does not say who is on the team");
  assert.equal(demo.teamSize, 2);
  const intro = r.body.eventTypes.find((e: any) => e.id === "intro");
  assert.deepEqual(intro.hosts, [{ name: "Ana Diaz" }]);
  assert.equal(intro.guestsMax, 2);
  assert.deepEqual(intro.locations.map((l: any) => l.type), ["meet", "phone", "in-person", "custom"]);
  assert.equal(intro.locations[3].url, undefined, "custom link stays hidden until booked");
  assert.deepEqual(r.body.routingForms[0].questions.map((q: any) => q.id), ["seats", "region"]);
  assert.equal(r.body.routingForms[0].rules, undefined);
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.doesNotMatch(r.text, /ana@acme|BOOKING_WEBHOOK_SECRET|ownerKey/);
});

test("secret event types are reachable by id only", async () => {
  const h = harness();
  assert.equal((await h.call("GET", "/api/event-types/vip")).body.eventType.secret, true);
  const missing = await h.call("GET", "/api/event-types/nope");
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error.code, "not-found");
});

test("slots: times in the asked zone, no host details, sandbox busy blocks respected", async () => {
  const h = harness();
  const r = await h.call("GET", "/api/slots?eventType=intro&tz=America/New_York&from=2026-11-02T00:00:00Z&to=2026-11-03T00:00:00Z");
  assert.equal(r.status, 200);
  assert.equal(r.body.timezone, "America/New_York");
  assert.ok(r.body.slots.length > 0);
  const s0 = r.body.slots[0];
  assert.deepEqual(Object.keys(s0).sort(), ["date", "end", "start", "time"]);
  assert.equal(Date.parse(s0.end) - Date.parse(s0.start), 30 * MIN);
  const busy = sandboxBusyFor("ana", "2026-11-02", "UTC");
  for (const slot of r.body.slots) {
    const st = Date.parse(slot.start);
    const en = Date.parse(slot.end);
    for (const b of busy) assert.ok(en <= b.start || st >= b.end, `slot ${slot.start} overlaps a busy block`);
  }
  const rr = await h.call("GET", "/api/slots?eventType=demo");
  assert.doesNotMatch(rr.text, /ana|ben/);
});

test("slots reject bad input with plain messages", async () => {
  const h = harness();
  const cases: [string, string][] = [
    ["/api/slots", "missing-field"],
    ["/api/slots?eventType=intro&duration=45", "bad-duration"],
    ["/api/slots?eventType=intro&tz=Mars/Base", "bad-timezone"],
    ["/api/slots?eventType=intro&from=2026-11-02", "bad-time"],
    ["/api/slots?eventType=intro&from=2026-11-05T00:00:00Z&to=2026-11-04T00:00:00Z", "bad-range"],
    ["/api/slots?eventType=intro&from=2026-11-02T00:00:00Z&to=2027-03-01T00:00:00Z", "bad-range"],
    ["/api/slots?eventType=intro&hosts=ana", "hosts-not-allowed"],
    ["/api/slots?eventType=demo&hosts=zed", "unknown-host"],
    ["/api/slots?eventType=demo&hosts=BAD!", "bad-hosts"],
  ];
  for (const [path, code] of cases) {
    const r = await h.call("GET", path);
    assert.equal(r.status, 400, path);
    assert.equal(r.body.error.code, code, path);
    assert.ok(r.body.error.message.length > 5);
  }
  assert.equal((await h.call("GET", "/api/slots?eventType=demo&hosts=ben")).status, 200);
});

test("hold then book: booking, email, host DM, jobs, webhook, audit and calendar event", async () => {
  const h = harness();
  const { slot, res } = await book(h, "intro", { guests: ["Guest@Client.example"], utm: { utm_source: "news" }, location: { type: "meet" } });
  assert.equal(res.status, 201, res.text);
  const b = res.body.booking;
  assert.equal(b.status, "confirmed");
  assert.equal(b.start, slot.start);
  assert.equal(b.timezone, "Europe/Paris");
  assert.deepEqual(b.guests, ["guest@client.example"]);
  assert.equal(b.location.type, "meet");
  assert.match(b.location.joinUrl, /^https:\/\/sandbox\.hq-booking\.invalid\/meet\//);
  assert.equal(b.location.sandbox, true);
  assert.match(res.body.manageUrl, /^\/manage\/bk_[0-9a-f]+\?token=mt_/);
  assert.equal(b.policy.canCancel, true);

  const id = b.id;
  const emails = await h.store.find("outbox_emails", { booking_id: id });
  assert.equal(emails.length, 1);
  assert.equal(emails[0]?.kind, "confirmation");
  assert.deepEqual(emails[0]?.to_addrs, ["iris@client.example", "guest@client.example"]);
  assert.match(emails[0]?.text_body ?? "", /https:\/\/book\.acme\.example\/manage\//);
  assert.equal((await h.store.find("notifications", { booking_id: id, kind: "booking-created" })).length, 1);
  const jobs = await h.store.find("notification_jobs", { booking_id: id });
  assert.deepEqual(jobs.map((j) => j.kind).sort(), ["follow-up", "host-brief", "reminder"]);
  const hooks = await h.store.find("webhook_outbox", { event: "booked" });
  assert.equal(hooks.length, 1);
  assert.equal(JSON.parse(hooks[0]?.payload ?? "{}").data.utm.utm_source, "news");
  assert.equal((await h.store.find("audit_log", { booking_id: id, action: "booking.created" })).length, 1);
  const events = await h.store.find("sandbox_events", { booking_id: id });
  assert.equal(events.length, 1);
  assert.deepEqual(events[0]?.attendees, ["iris@client.example", "guest@client.example"]);
  assert.equal((await h.store.find("holds", {})).length, 0);
  const view = await h.call("GET", `/api/bookings/${id}?token=${encodeURIComponent(res.body.manageToken)}`);
  assert.equal(view.status, 200);
  assert.equal(view.body.booking.invitee.email, "iris@client.example");
  assert.equal((await h.call("GET", `/api/bookings/${id}?token=wrong`)).status, 403);
  assert.equal((await h.call("GET", `/api/bookings/bk_nope?token=x`)).status, 404);
  // The booked time is no longer offered.
  assert.notEqual((await firstSlot(h, "intro")).start, slot.start);
});

test("booking input is validated with plain messages", async () => {
  const h = harness();
  const slot = await firstSlot(h, "intro");
  const hold = (await h.call("POST", "/api/holds", { eventType: "intro", start: slot.start })).body.holdId;
  const cases: [Record<string, unknown>, string][] = [
    [{ name: "" }, "missing-field"],
    [{ email: "nope" }, "bad-email"],
    [{ answers: {} }, "answer-required"],
    [{ answers: { company: "x", size: "huge" } }, "bad-answer"],
    [{ answers: { company: "x", seats: "many" } }, "bad-answer"],
    [{ answers: { company: "x", topics: ["z"] } }, "bad-answer"],
    [{ answers: { company: "x", mail: "nope" } }, "bad-answer"],
    [{ answers: { company: "x", tel: "abc" } }, "bad-answer"],
    [{ answers: { company: "x".repeat(501) } }, "bad-answer"],
    [{ answers: { company: 5 } }, "bad-answer"],
    [{ answers: { company: "   " } }, "answer-required"],
    [{ answers: { company: "x", other: 1 } }, "unknown-question"],
    [{ answers: "x" }, "bad-answers"],
    [{ guests: ["a@b.example", "c@d.example", "e@f.example"] }, "too-many-guests"],
    [{ guests: "a@b.example" }, "bad-guests"],
    [{ guests: ["nope"] }, "bad-guests"],
    [{ location: { type: "zoom" } }, "bad-location"],
    [{ location: { type: "phone" } }, "phone-required"],
    [{ timezone: "Mars/Base" }, "bad-timezone"],
    [{ utm: { utm_source: 5 } }, "bad-utm"],
    [{ utm: { ref: "x" } }, "bad-utm"],
    [{ utm: "x" }, "bad-utm"],
  ];
  let n = 0;
  for (const [over, code] of cases) {
    const r = await h.call("POST", "/api/bookings", { holdId: hold, ...invitee, answers: introAnswers, ...over }, { "x-forwarded-for": `10.9.0.${n++}` });
    assert.equal(r.status, 400, `${JSON.stringify(over)} -> ${r.text}`);
    assert.equal(r.body.error.code, code, JSON.stringify(over));
  }
  const ok = await h.call("POST", "/api/bookings", {
    holdId: hold,
    ...invitee,
    answers: { company: "x", size: "11+", seats: "12", topics: "a", mail: "m@x.example", tel: "+1 555 0000" },
    location: { type: "phone", phone: "+33 1 23 45 67 89" },
    utm: { utm_campaign: "fall" },
  });
  assert.equal(ok.status, 201, ok.text);
  assert.deepEqual(ok.body.booking.answers, { company: "x", size: "11+", seats: 12, topics: ["a"], mail: "m@x.example", tel: "+1 555 0000" });
  assert.equal(ok.body.booking.location.phone, "+33 1 23 45 67 89");
  assert.equal(ok.body.booking.location.caller, "host");

  assert.equal((await h.call("POST", "/api/bookings", "{not json")).body.error.code, "bad-json");
  assert.equal((await h.call("POST", "/api/bookings", "[1]")).body.error.code, "bad-json");
  assert.equal((await h.call("POST", "/api/bookings", { holdId: "x".repeat(70_000) })).status, 413);
  assert.equal((await h.call("POST", "/api/bookings", { holdId: "hold_nope", ...invitee })).status, 410);
});

test("other locations resolve to the host's details", async () => {
  const h = harness();
  const custom = await book(h, "intro", { location: { type: "custom" } });
  assert.equal(custom.res.body.booking.location.url, "https://meet.acme.example/ana");
  const inPerson = await book(h, "intro", { location: "in-person" });
  assert.equal(inPerson.res.body.booking.location.address, "1 Main St");
  const ics = await h.call("GET", `/api/bookings/${inPerson.res.body.booking.id}/ics?token=${encodeURIComponent(inPerson.res.body.manageToken)}`);
  assert.equal(ics.status, 200);
  assert.match(ics.headers.get("content-type") ?? "", /text\/calendar/);
  assert.match(ics.text, /BEGIN:VEVENT/);
  assert.match(ics.text, /LOCATION:1 Main St/);
  assert.match(ics.text, /STATUS:CONFIRMED/);
  assert.equal((await h.call("GET", `/api/bookings/${inPerson.res.body.booking.id}/ics?token=bad`)).status, 403);
});

for (const kind of ["memory", "sql"] as const) {
  test(`${kind}: 20 concurrent holds for one slot give one 201 and nineteen 409s`, async () => {
    const h = harness({ store: kind });
    const slot = await firstSlot(h, "intro");
    const results = await Promise.all(
      Array.from({ length: 20 }, (_, i) => h.call("POST", "/api/holds", { eventType: "intro", start: slot.start }, { "x-forwarded-for": `198.51.100.${i}` })),
    );
    assert.deepEqual(results.map((r) => r.status).sort(), [201, ...Array(19).fill(409)]);
    for (const r of results.filter((x) => x.status === 409)) assert.match(r.body.error.code, /^slot-(taken|unavailable)$/);
  });

  test(`${kind}: 20 concurrent bookings of one slot give exactly one booking`, async () => {
    const h = harness({ store: kind });
    const slot = await firstSlot(h, "intro");
    const s = h.app.services;
    const ev = findEventType(s, "intro");
    const draft = (i: number) => ({
      ev,
      duration: 30,
      start: Date.parse(slot.start),
      end: Date.parse(slot.end),
      hostIds: ["ana"],
      source: { type: "direct" as const },
      invitee: checkInvitee(ev, { ...invitee, answers: introAnswers, email: `p${i}@client.example` }, "UTC"),
      location: { type: "meet" as const },
      utm: null,
      createdBy: "invitee" as const,
      actor: "invitee",
    });
    const results = await Promise.allSettled(Array.from({ length: 20 }, (_, i) => createBooking(s, draft(i))));
    const ok = results.filter((r) => r.status === "fulfilled");
    assert.equal(ok.length, 1);
    for (const r of results.filter((x) => x.status === "rejected")) assert.equal((r as PromiseRejectedResult).reason.status, 409);
    assert.equal((await h.store.find("bookings", { status: "confirmed" })).length, 1);
  });

  test(`${kind}: 20 parallel hold-and-book flows end with one booking, others 409`, async () => {
    const h = harness({ store: kind });
    const slot = await firstSlot(h, "intro");
    const flows = await Promise.all(
      Array.from({ length: 20 }, async (_, i) => {
        const ip = { "x-forwarded-for": `192.0.2.${i}` };
        const hold = await h.call("POST", "/api/holds", { eventType: "intro", start: slot.start }, ip);
        if (hold.status !== 201) return hold.status;
        return (await h.call("POST", "/api/bookings", { holdId: hold.body.holdId, ...invitee, answers: introAnswers }, ip)).status;
      }),
    );
    assert.deepEqual(flows.sort(), [201, ...Array(19).fill(409)]);
    assert.equal((await h.store.find("bookings", {})).length, 1);
  });
}

test("an expired hold cannot be booked and its time is offered again", async () => {
  const h = harness();
  const slot = await firstSlot(h, "intro");
  const hold = await h.call("POST", "/api/holds", { eventType: "intro", start: slot.start });
  assert.equal(hold.status, 201);
  assert.equal(Date.parse(hold.body.expiresAt) - MONDAY, 5 * MIN);
  assert.notEqual((await firstSlot(h, "intro")).start, slot.start, "held time is hidden");
  h.clock.now += 6 * MIN;
  const late = await h.call("POST", "/api/bookings", { holdId: hold.body.holdId, ...invitee, answers: introAnswers });
  assert.equal(late.status, 410);
  assert.equal(late.body.error.code, "hold-expired");
  assert.equal((await firstSlot(h, "intro")).start, slot.start);
  const again = await h.call("POST", "/api/holds", { eventType: "intro", start: slot.start }, { "x-forwarded-for": "198.51.100.9" });
  assert.equal(again.status, 201);
});

test("a hold can be released", async () => {
  const h = harness();
  const slot = await firstSlot(h, "intro");
  const hold = await h.call("POST", "/api/holds", { eventType: "intro", start: slot.start });
  assert.deepEqual((await h.call("DELETE", `/api/holds/${hold.body.holdId}`)).body, { released: true });
  assert.deepEqual((await h.call("DELETE", `/api/holds/${hold.body.holdId}`)).body, { released: false });
  assert.equal((await firstSlot(h, "intro")).start, slot.start);
  assert.equal((await h.call("POST", "/api/holds", { eventType: "intro", start: "2026-11-02T03:00:00Z" })).status, 409);
});

test("cancel: token, cutoff, required reason, then everything is released", async () => {
  const h = harness();
  const { slot, res } = await book(h);
  const id = res.body.booking.id;
  const token = res.body.manageToken;
  assert.equal((await h.call("POST", `/api/bookings/${id}/cancel`, { token: "bad" })).status, 403);
  const noReason = await h.call("POST", `/api/bookings/${id}/cancel`, { token });
  assert.equal(noReason.status, 400);
  assert.equal(noReason.body.error.code, "reason-required");

  const saved = h.clock.now;
  h.clock.now = Date.parse(slot.start) - 60 * MIN;
  const late = await h.call("POST", `/api/bookings/${id}/cancel`, { token, reason: "sick" });
  assert.equal(late.status, 409);
  assert.equal(late.body.error.code, "cancel-cutoff");
  assert.match(late.body.error.message, /less than 2 hours/);
  h.clock.now = saved;

  const ok = await h.call("POST", `/api/bookings/${id}/cancel`, { token, reason: "Something came up" });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.body.booking.status, "canceled");
  assert.equal(ok.body.booking.cancelReason, "Something came up");
  assert.equal((await h.store.find("slot_claims", {})).length, 0);
  assert.equal((await firstSlot(h, "intro")).start, slot.start);
  assert.equal((await h.store.find("sandbox_events", { booking_id: id }))[0]?.status, "canceled");
  assert.equal((await h.store.find("outbox_emails", { booking_id: id, kind: "cancellation" })).length, 1);
  assert.equal((await h.store.find("webhook_outbox", { event: "canceled" })).length, 1);
  assert.equal((await h.store.find("notification_jobs", { booking_id: id, status: "pending" })).length, 0);
  const again = await h.call("POST", `/api/bookings/${id}/cancel`, { token, reason: "x" });
  assert.equal(again.body.error.code, "already-canceled");
  const ics = await h.call("GET", `/api/bookings/${id}/ics?token=${encodeURIComponent(token)}`);
  assert.match(ics.text, /STATUS:CANCELLED/);
});

test("a meeting that already started cannot be changed by the invitee", async () => {
  const h = harness();
  const { slot, res } = await book(h);
  h.clock.now = Date.parse(slot.start) + MIN;
  const r = await h.call("POST", `/api/bookings/${res.body.booking.id}/cancel`, { token: res.body.manageToken, reason: "x" });
  assert.equal(r.body.error.code, "already-started");
  assert.equal(res.body.booking.policy.canReschedule, true);
});

test("reschedule moves the calendar event and replaces jobs, no second event", async () => {
  const h = harness();
  const { slot, res } = await book(h);
  const id = res.body.booking.id;
  const token = res.body.manageToken;
  const before = await h.store.find("sandbox_events", { booking_id: id });
  const slots = (await h.call("GET", "/api/slots?eventType=intro&from=2026-11-03T00:00:00Z")).body.slots;
  const target = slots[2];
  const moved = await h.call("POST", `/api/bookings/${id}/reschedule`, { token, start: target.start });
  assert.equal(moved.status, 200, moved.text);
  assert.equal(moved.body.booking.start, target.start);
  assert.equal(moved.body.booking.rescheduleCount, 1);
  const after = await h.store.find("sandbox_events", { booking_id: id });
  assert.equal(after.length, 1);
  assert.equal(after[0]?.id, before[0]?.id);
  assert.equal(after[0]?.start_at, Date.parse(target.start));
  const pending = await h.store.find("notification_jobs", { booking_id: id, status: "pending" });
  assert.equal(pending.length, 3);
  assert.ok(pending.every((j) => j.id.endsWith(`:${Date.parse(target.start)}`)));
  assert.equal((await h.store.find("webhook_outbox", { event: "rescheduled" })).length, 1);
  assert.equal((await h.store.find("outbox_emails", { booking_id: id, kind: "reschedule" })).length, 1);
  assert.equal((await firstSlot(h, "intro")).start, slot.start, "the old time is free again");

  const taken = await h.call("POST", `/api/bookings/${id}/reschedule`, { token, start: "2026-11-03T03:00:00Z" });
  assert.equal(taken.body.error.code, "slot-unavailable");
  h.clock.now = Date.parse(target.start) - 30 * MIN;
  const late = await h.call("POST", `/api/bookings/${id}/reschedule`, { token, start: slots[5].start });
  assert.equal(late.body.error.code, "reschedule-cutoff");
});

test("reschedule into a held time", async () => {
  const h = harness();
  const { res } = await book(h);
  const id = res.body.booking.id;
  const token = res.body.manageToken;
  const target = (await h.call("GET", "/api/slots?eventType=intro&from=2026-11-04T00:00:00Z")).body.slots[0];
  const hold = await h.call("POST", "/api/holds", { eventType: "intro", start: target.start });
  const wrong = await h.call("POST", `/api/bookings/${id}/reschedule`, { token, start: "2026-11-04T15:00:00Z", holdId: hold.body.holdId });
  assert.equal(wrong.body.error.code, "hold-mismatch");
  const ok = await h.call("POST", `/api/bookings/${id}/reschedule`, { token, start: target.start, holdId: hold.body.holdId });
  assert.equal(ok.status, 200, ok.text);
  assert.equal((await h.store.find("holds", {})).length, 0);
  const gone = await h.call("POST", `/api/bookings/${id}/reschedule`, { token, start: target.start, holdId: hold.body.holdId });
  assert.equal(gone.body.error.code, "hold-expired");
});

test("round-robin spreads bookings across free hosts and hides who until booked", async () => {
  const h = harness();
  const hosts: string[] = [];
  for (let i = 0; i < 4; i++) {
    const { res } = await book(h, "demo", {}, `203.0.113.${i + 20}`);
    assert.equal(res.status, 201, res.text);
    hosts.push(res.body.booking.hosts[0].name);
  }
  assert.ok(hosts.includes("Ana Diaz") && hosts.includes("Ben Okafor"), hosts.join());
  const stats = await h.store.find("host_assignments", { event_type_id: "demo" });
  assert.equal(stats.reduce((n, r) => n + r.bookings, 0), 4);
});

test("collective events put one event on every host's calendar", async () => {
  const h = harness();
  const { slot, res } = await book(h, "panel");
  assert.equal(res.status, 201, res.text);
  const events = await h.store.find("sandbox_events", { booking_id: res.body.booking.id });
  assert.deepEqual(events.map((e) => e.host_id).sort(), ["ana", "ben"]);
  assert.match(res.body.booking.location.joinUrl, /\/teams\//);
  // Ana is now busy then, so a one-on-one with her cannot take that time.
  const s = h.app.services;
  assert.equal(await slotAt(s, findEventType(s, "intro"), 30, Date.parse(slot.start)), null);
});

test("group events count seats and the last seat closes the slot", async () => {
  const h = harness();
  const slot = await firstSlot(h, "class");
  assert.equal(slot.seatsLeft, 3);
  const ids: string[] = [];
  for (let i = 0; i < 3; i++) {
    const hold = await h.call("POST", "/api/holds", { eventType: "class", start: slot.start }, { "x-forwarded-for": `10.0.0.${i}` });
    assert.equal(hold.status, 201, hold.text);
    const r = await h.call("POST", "/api/bookings", { holdId: hold.body.holdId, ...invitee, email: `s${i}@x.example` }, { "x-forwarded-for": `10.0.0.${i}` });
    assert.equal(r.status, 201, r.text);
    ids.push(r.body.booking.id);
    const left = (await h.call("GET", `/api/slots?eventType=class&from=${slot.start}&to=${slot.end}`)).body.slots[0];
    if (i < 2) assert.equal(left?.seatsLeft, 2 - i);
    else assert.equal(left, undefined);
  }
  const full = await h.call("POST", "/api/holds", { eventType: "class", start: slot.start }, { "x-forwarded-for": "10.0.0.9" });
  assert.equal(full.status, 409);
  const first = await h.owner("POST", `/api/owner/bookings/${ids[0]}/cancel`, { reason: "moved" });
  assert.equal(first.status, 200);
  assert.equal((await h.call("GET", `/api/slots?eventType=class&from=${slot.start}&to=${slot.end}`)).body.slots[0].seatsLeft, 1);
  const cells = await h.store.find("slot_claims", { owner_type: "group" });
  assert.ok(cells.length > 0, "host cells stay while seats remain");
  for (const id of ids.slice(1)) await h.owner("POST", `/api/owner/bookings/${id}/cancel`, {});
  assert.equal((await h.store.find("slot_claims", {})).length, 0, "the last seat frees the host");
});

test("routing forms send people to the right place", async () => {
  const h = harness();
  const ev = (answers: unknown) => h.call("POST", "/api/routing/sales/evaluate", { answers });
  assert.deepEqual((await ev({ seats: 150 })).body, { target: { eventType: "panel" }, matchedRule: 0 });
  assert.deepEqual((await ev({ seats: 5, region: "EU" })).body, { target: { eventType: "demo", hosts: ["ben"] }, matchedRule: 1 });
  assert.deepEqual((await ev({ seats: 5, region: "US" })).body, { target: { url: "https://acme.example/us" }, matchedRule: 2 });
  assert.deepEqual((await ev({ seats: "7" })).body, { target: { eventType: "demo" }, matchedRule: null });
  assert.equal((await ev({})).body.error.code, "answer-required");
  assert.equal((await h.call("POST", "/api/routing/nope/evaluate", { answers: {} })).status, 404);
});

test("single-use links work once, then show as expired", async () => {
  const h = harness();
  const minted = await h.owner("POST", "/api/owner/links", { eventType: "vip", singleUse: true, expiresInHours: 48 });
  assert.equal(minted.status, 201);
  const token = minted.body.token;
  const info = await h.call("GET", `/api/links/${token}`);
  assert.equal(info.status, 200);
  assert.equal(info.body.eventType.id, "vip");
  const slot = await firstSlot(h, "vip");
  assert.equal((await h.call("POST", "/api/holds", { eventType: "intro", start: slot.start, link: token })).body.error.code, "link-mismatch");
  const hold = await h.call("POST", "/api/holds", { eventType: "vip", start: slot.start, link: token });
  assert.equal(hold.status, 201);
  assert.equal((await h.call("POST", "/api/bookings", { holdId: hold.body.holdId, ...invitee })).body.error.code, "link-required");
  const hold2 = await h.call("POST", "/api/holds", { eventType: "vip", start: slot.start, link: token });
  assert.equal(hold2.status, 409, "the first hold still has the time");
  const r = await h.call("POST", "/api/bookings", { holdId: hold.body.holdId, ...invitee, link: token });
  assert.equal(r.status, 201, r.text);
  const used = await h.call("GET", `/api/links/${token}`);
  assert.equal(used.status, 410);
  assert.equal(used.body.error.code, "link-expired");
  const next = (await h.call("GET", "/api/slots?eventType=vip")).body.slots[1];
  assert.equal((await h.call("POST", "/api/holds", { eventType: "vip", start: next.start, link: token })).status, 410);
  assert.equal((await h.call("GET", "/api/links/bl_unknown")).status, 404);
  h.clock.now += 49 * 3600_000;
  const reusable = await h.owner("POST", "/api/owner/links", { eventType: "vip", singleUse: false, expiresInHours: 1 });
  assert.equal((await h.call("GET", `/api/links/${reusable.body.token}`)).status, 200);
  h.clock.now += 2 * 3600_000;
  assert.equal((await h.call("GET", `/api/links/${reusable.body.token}`)).status, 410);
});

test("public writes are rate limited per IP", async () => {
  const h = harness();
  let last;
  for (let i = 0; i < 21; i++) last = await h.call("POST", "/api/holds", { eventType: "intro", start: "2026-11-02T03:00:00Z" }, { "x-forwarded-for": "203.0.113.99" });
  assert.equal(last?.status, 429);
  assert.equal(last?.body.error.code, "rate-limited");
  assert.ok(Number(last?.headers.get("retry-after")) > 0);
  assert.equal((await h.call("POST", "/api/holds", { eventType: "intro", start: "2026-11-02T03:00:00Z" }, { "x-forwarded-for": "203.0.113.98" })).status, 409);
});

test("a calendar failure undoes the booking and frees the time", async () => {
  const h = harness({
    providers: (store, now) => {
      const p = sandboxProviders(store, now);
      p.calendar.createEvent = async () => {
        throw new ProviderError("calendar-down", "Google did not answer.");
      };
      return p;
    },
  });
  const { slot, res } = await book(h);
  assert.equal(res.status, 502);
  assert.equal(res.body.error.code, "provider-failed");
  assert.match(res.body.error.message, /nothing was booked/);
  assert.equal((await h.store.find("bookings", { status: "confirmed" })).length, 0);
  assert.equal((await h.store.find("webhook_outbox", { status: "pending" })).length, 0);
  assert.equal((await firstSlot(h, "intro")).start, slot.start);
});

test("a busy calendar at booking time releases the hold", async () => {
  const h = harness();
  const slot = await firstSlot(h, "intro");
  const hold = await h.call("POST", "/api/holds", { eventType: "intro", start: slot.start });
  await h.store.insert("sandbox_events", {
    id: "outside", host_id: "ana", start_at: Date.parse(slot.start), end_at: Date.parse(slot.end), kind: "busy", title: "x",
    booking_id: null, conference: null, attendees: [], status: "confirmed", created_at: 0, updated_at: 0,
  });
  const r = await h.call("POST", "/api/bookings", { holdId: hold.body.holdId, ...invitee, answers: introAnswers });
  assert.equal(r.status, 409);
  assert.equal((await h.store.find("holds", {})).length, 0);
});

test("CORS for allowed embed origins only, never on owner routes", async () => {
  const h = harness();
  const ok = await h.call("GET", "/api/config/public", undefined, { origin: "https://www.acme.example" });
  assert.equal(ok.headers.get("access-control-allow-origin"), "https://www.acme.example");
  const other = await h.call("GET", "/api/config/public", undefined, { origin: "https://evil.example" });
  assert.equal(other.headers.get("access-control-allow-origin"), null);
  const pre = await h.call("OPTIONS", "/api/holds", undefined, { origin: "https://www.acme.example" });
  assert.equal(pre.status, 204);
  assert.match(pre.headers.get("access-control-allow-methods") ?? "", /POST/);
  const owner = await h.call("GET", "/api/owner/session", undefined, { origin: "https://www.acme.example" });
  assert.equal(owner.headers.get("access-control-allow-origin"), null);
});

test("unknown routes, wrong methods and internal errors answer plainly", async () => {
  const h = harness();
  assert.equal((await h.call("GET", "/api/nope")).status, 404);
  const wrong = await h.call("PUT", "/api/holds");
  assert.equal(wrong.status, 405);
  assert.equal(wrong.headers.get("allow"), "POST");
  assert.equal((await h.call("GET", "/api/event-types/%E0%A4%A")).status, 404);
  assert.equal((await h.call("HEAD", "/api/config/public")).status, 200);
  h.app.services.store.find = async () => {
    throw new Error("secret internals at /var/task");
  };
  const boom = await h.call("GET", "/api/slots?eventType=intro");
  assert.equal(boom.status, 500);
  assert.deepEqual(boom.body, { error: { code: "internal", message: "Something went wrong on our side. Try again in a minute." } });
  assert.ok(h.logs.some((l) => l.includes("secret internals")));
});

test("config without guests or owner settings behaves safely", async () => {
  const cfg = testConfig({ prototype: undefined, notifications: { confirmation: false } });
  const h = harness({ config: cfg });
  const r = await book(h, "demo", { guests: ["x@y.example"] });
  assert.equal(r.res.body.error.code, "too-many-guests");
  const ok = await book(h, "demo");
  assert.equal(ok.res.status, 201);
  assert.equal((await h.store.find("outbox_emails", {})).length, 0, "confirmation emails are off");
  assert.equal((await h.store.find("notification_jobs", {})).length, 0);
  assert.equal((await h.owner("GET", "/api/owner/session")).status, 503);
});
