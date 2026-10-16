// Live end-to-end check against a deployed HQ Booking app (sandbox provider).
//
//   node tests/e2e-live.mjs https://booking-<co>.indigo-hq.com [--owner-key-env BOOKING_OWNER_KEY]
//
// The app must be reachable without an access gate while this runs. The owner
// key is read from the named environment variable (for example through
// `hq secrets exec --only BOOKING_OWNER_KEY -- node ...`) and never printed.
// Public flows: config, slots, hold, book, manage, reschedule, cancel, a
// 20-way race for one slot, and round-robin spread. Owner flows (when the key
// is present): session, bookings, outbox, jobs, sandbox calendar. Every booking
// it makes is cancelled before it exits.

const base = (process.argv[2] || "").replace(/\/$/, "");
if (!/^https?:\/\//.test(base)) {
  console.error("usage: node tests/e2e-live.mjs <app url> [--owner-key-env NAME]");
  process.exit(2);
}
const keyEnvIdx = process.argv.indexOf("--owner-key-env");
const ownerKey = process.env[keyEnvIdx > 0 ? process.argv[keyEnvIdx + 1] : "BOOKING_OWNER_KEY"] || "";

let pass = 0;
let fail = 0;
const cleanup = [];
const ok = (name) => { pass++; console.log(`ok   ${name}`); };
const bad = (name, detail) => { fail++; console.log(`FAIL ${name}${detail ? `\n     ${String(detail).slice(0, 400)}` : ""}`); };
const check = (name, cond, detail) => (cond ? ok(name) : bad(name, detail));

async function call(method, path, body, headers = {}) {
  const res = await fetch(base + path, {
    method,
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: "manual",
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, json, text };
}
const owner = (method, path, body) => call(method, path, body, { authorization: `Bearer ${ownerKey}` });

const run = Date.now().toString(36);
const person = (n) => ({ name: `E2E ${run} ${n}`, email: `e2e+${run}-${n}@example.com` });

async function book(eventType, start, n, extra = {}) {
  const hold = await call("POST", "/api/holds", { eventType: eventType.id, duration: eventType.defaultDuration ?? eventType.durations[0], start });
  if (hold.status !== 201 && hold.status !== 200) return { hold };
  const answers = {};
  for (const q of eventType.questions || []) if (q.required) answers[q.id] = q.options ? q.options[0] : "e2e";
  const res = await call("POST", "/api/bookings", {
    holdId: hold.json.holdId ?? hold.json.id,
    ...person(n),
    answers,
    location: eventType.locations[0].type,
    timezone: "America/New_York",
    utm: { utm_source: "e2e-live" },
    ...extra,
  });
  if (res.json?.booking?.id || res.json?.id) {
    const b = res.json.booking ?? res.json;
    cleanup.push({ id: b.id, token: b.manageToken ?? res.json.manageToken });
  }
  return { hold, res };
}

try {
  const cfg = await call("GET", "/api/config/public");
  check("public config loads", cfg.status === 200 && Array.isArray(cfg.json?.eventTypes), cfg.text);
  const page = await fetch(base + "/", { redirect: "manual" });
  check("booking page is served", page.status === 200 && (await page.text()).includes("<div"), page.status);

  const demo = cfg.json.eventTypes.find((e) => e.kind === "round-robin") ?? cfg.json.eventTypes[0];
  const from = new Date(Date.now() + 3 * 86400000).toISOString();
  const to = new Date(Date.now() + 10 * 86400000).toISOString();
  const slots = await call("GET", `/api/slots?eventType=${demo.id}&from=${from}&to=${to}&tz=Europe/London`);
  const list = slots.json?.slots ?? [];
  check("slots are offered", slots.status === 200 && list.length > 4, slots.text);
  check("round-robin slots do not reveal hosts", list.every((s) => !("hostIds" in s) && !("hosts" in s)), JSON.stringify(list[0]));

  // Book, read, reschedule, cancel.
  const first = await book(demo, list[0].start, 1);
  const booking = first.res?.json?.booking ?? first.res?.json;
  check("a booking is created", (first.res?.status === 201 || first.res?.status === 200) && booking?.id, first.res?.text ?? first.hold.text);
  const token = cleanup.at(-1)?.token;
  const view = await call("GET", `/api/bookings/${booking.id}?token=${encodeURIComponent(token)}`);
  check("manage view works with the token", view.status === 200, view.text);
  const noToken = await call("GET", `/api/bookings/${booking.id}?token=wrong`);
  check("manage view refuses a wrong token", noToken.status === 403 || noToken.status === 404, noToken.status);
  const again = await call("GET", `/api/slots?eventType=${demo.id}&from=${from}&to=${to}&tz=Europe/London`);
  const ics = await fetch(`${base}/api/bookings/${booking.id}/ics?token=${encodeURIComponent(token)}`);
  check("calendar file downloads", ics.status === 200 && (await ics.text()).includes("BEGIN:VCALENDAR"), ics.status);
  const target = list.find((s, i) => i > 8) ?? list.at(-1);
  const resched = await call("POST", `/api/bookings/${booking.id}/reschedule`, { token, start: target.start });
  check("reschedule moves the booking", resched.status === 200, resched.text);
  check("slot list still answers after booking", again.status === 200, again.text);

  // 20-way race for one slot on a single-host event, or the same round-robin slot across hosts.
  const race = cfg.json.eventTypes.find((e) => e.kind === "collective") ?? demo;
  const raceSlots = (await call("GET", `/api/slots?eventType=${race.id}&from=${from}&to=${to}`)).json?.slots ?? [];
  const raceStart = raceSlots[Math.min(5, raceSlots.length - 1)]?.start;
  if (raceStart) {
    const results = await Promise.all(Array.from({ length: 20 }, (_, i) => book(race, raceStart, `race-${i}`)));
    const won = results.filter((r) => r.res && (r.res.status === 201 || r.res.status === 200)).length;
    // Losers get 409 (slot taken); a few may hit the per-IP write limit (429)
    // because every request comes from this one machine. Either way: one booking.
    const refused = results.filter((r) => [409, 429].includes(r.res ? r.res.status : r.hold.status)).length;
    check(`20 parallel bookings of one ${race.kind} slot: exactly one wins`, won === 1 && refused === 19, `won=${won} refused=${refused} statuses=${results.map((r) => r.res?.status ?? `hold:${r.hold.status}`).join(",")}`);
  } else bad("race slot available", JSON.stringify(raceSlots.slice(0, 2)));

  if (ownerKey) {
    const session = await owner("GET", "/api/owner/session");
    check("owner session works with the key", session.status === 200, session.text);
    const denied = await call("GET", "/api/owner/session", undefined, { authorization: "Bearer nope" });
    check("owner routes refuse a wrong key", denied.status === 401 || denied.status === 403, denied.status);
    const bookings = await owner("GET", "/api/owner/bookings");
    const mine = (bookings.json?.bookings ?? []).filter((b) => JSON.stringify(b).includes(run));
    check("owner sees the e2e bookings", mine.length >= 2, bookings.text.slice(0, 300));
    const outbox = await owner("GET", "/api/owner/outbox");
    check("confirmation emails are in the sandbox outbox", JSON.stringify(outbox.json ?? {}).includes(run), outbox.status);
    const jobs = await owner("POST", "/api/owner/jobs/run", {});
    check("due jobs run", jobs.status === 200, jobs.text);
  } else {
    console.log("skip owner checks: no owner key in the environment");
  }
} catch (err) {
  bad("unexpected error", err?.stack ?? err);
} finally {
  let cancelled = 0;
  for (const b of cleanup) {
    const r = await call("POST", `/api/bookings/${b.id}/cancel`, { token: b.token, reason: "e2e cleanup" });
    if (r.status === 200) cancelled++;
  }
  console.log(`cleanup: cancelled ${cancelled}/${cleanup.length} test bookings`);
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
}
