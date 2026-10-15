import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { cellKeys } from "../api/_lib/claims.ts";
import { renderEmail } from "../api/_lib/emails.ts";
import { HttpError } from "../api/_lib/errors.ts";
import { clientIp, Router } from "../api/_lib/http.ts";
import { buildIcs, escapeIcs } from "../api/_lib/ics.ts";
import { locationText, quoteUntrusted } from "../api/_lib/notify.ts";
import { checkWebhookUrl } from "../api/_lib/owner-api.ts";
import { claimMinutesFor } from "../api/_lib/services.ts";
import { bool, clampText, escapeHtml, instant, integer, isEmail, parseRangeText, sameHex, text, weekStart } from "../api/_lib/util.ts";
import { checkStaged, stage } from "../dev/stage.ts";
import { startDevServer } from "../dev/server.ts";
import { booking } from "./store-contract.ts";
import { OWNER_KEY, testConfig } from "./harness.ts";

const here = dirname(fileURLToPath(import.meta.url));

test("ics files escape text and fold long lines", () => {
  const ics = buildIcs({
    uid: "bk_1@hq-booking",
    sequence: 2,
    start: Date.parse("2026-11-03T10:00:00Z"),
    end: Date.parse("2026-11-03T10:30:00Z"),
    stamp: 0,
    summary: "Intro; with, Ana",
    description: `Line one\nLine two ${"é".repeat(80)}`,
    location: "https://sandbox.hq-booking.invalid/meet/abc",
    url: "https://sandbox.hq-booking.invalid/meet/abc",
    canceled: false,
  });
  assert.match(ics, /DTSTART:20261103T100000Z/);
  assert.match(ics, /SUMMARY:Intro\\; with\\, Ana/);
  assert.match(ics, /SEQUENCE:2/);
  for (const line of ics.split("\r\n")) assert.ok(Buffer.byteLength(line, "utf8") <= 75, line);
  assert.equal(escapeIcs("a\\b"), "a\\\\b");
});

test("emails escape everything the invitee typed and follow the theme", () => {
  const cfg = testConfig();
  const r = renderEmail({
    config: cfg,
    kind: "confirmation",
    eventTitle: "Intro <b>call</b>",
    start: Date.parse("2026-11-03T10:00:00Z"),
    end: Date.parse("2026-11-03T10:30:00Z"),
    timezone: "Europe/Paris",
    attendeeName: `<script>alert("x")</script>`,
    hostNames: ["Ana Diaz"],
    location: "1 Main St",
    manageUrl: "https://book.acme.example/manage/bk_1?token=t",
    reason: "x",
    sandbox: true,
  });
  assert.doesNotMatch(r.html, /<script>/);
  assert.match(r.html, /&lt;script&gt;/);
  assert.match(r.html, /#123456/);
  assert.match(r.text, /Tuesday, November 3, 2026, 11:00 AM to 11:30 AM \(Europe\/Paris\)/);
  assert.match(r.text, /Sandbox: this email was stored/);
  for (const kind of ["cancellation", "reschedule", "reminder", "follow-up"] as const) {
    const e = renderEmail({ config: { ...cfg, theme: undefined }, kind, eventTitle: "T", start: 0, end: 1, timezone: "UTC", attendeeName: "A", hostNames: ["H"], location: "L", sandbox: false });
    assert.ok(e.subject.length > 3);
    assert.doesNotMatch(e.text, /Sandbox/);
  }
});

test("location text covers every location kind", () => {
  const b = (location: unknown) => booking("x", { location });
  assert.equal(locationText(b({ type: "zoom", joinUrl: "https://z" })), "https://z");
  assert.equal(locationText(b({ type: "teams" })), "teams");
  assert.equal(locationText(b({ type: "custom", url: null, label: "Room" })), "Room");
  assert.equal(locationText(b({ type: "custom" })), "Link from the host");
  assert.equal(locationText(b({ type: "phone", caller: "host", phone: "+1" })), "The host will call +1");
  assert.equal(locationText(b({ type: "phone", caller: "invitee", phone: null })), "Call the host");
  assert.equal(locationText(b({ type: "phone", caller: "host" })), "The host will call you");
  assert.equal(locationText(b({ type: "in-person" })), "In person");
  assert.equal(locationText(b(null)), "To be confirmed");
  assert.equal(quoteUntrusted("a\nb"), "> a\n> b");
});

test("claim cells cover every overlap", () => {
  assert.deepEqual(cellKeys("ana", 0, 30 * 60_000, 15), ["cell:ana:0", "cell:ana:900000"]);
  assert.deepEqual(cellKeys("ana", 5 * 60_000, 20 * 60_000, 15), ["cell:ana:0", "cell:ana:900000"]);
  const cfg = testConfig();
  assert.equal(claimMinutesFor(cfg), 15);
  cfg.eventTypes[0] = { ...(cfg.eventTypes[0] as (typeof cfg.eventTypes)[number]), durations: [25] };
  assert.equal(claimMinutesFor(cfg), 5);
  cfg.hosts[0] = { ...(cfg.hosts[0] as (typeof cfg.hosts)[number]), hours: { mon: ["09:07-17:00"] }, overrides: [{ date: "2026-11-03", hours: ["10:00-12:00"] }] };
  assert.equal(claimMinutesFor(cfg), 1);
});

test("input helpers give plain messages", () => {
  assert.throws(() => text(undefined, "name", { max: 5 }), /name is required/);
  assert.equal(text(undefined, "name", { max: 5, optional: true }), undefined);
  assert.throws(() => text(3, "name", { max: 5 }), /must be text/);
  assert.throws(() => text("toolong", "name", { max: 5 }), /at most 5/);
  assert.throws(() => instant("tomorrow", "start"), /date-time such as/);
  assert.throws(() => instant("2026-02-30T10:00:00Z", "start"), /not a real date-time/);
  assert.equal(instant("2026-11-03T10:00:00+01:00", "start"), Date.parse("2026-11-03T09:00:00Z"));
  assert.throws(() => integer("x", "n", 1, 3), /whole number from 1 to 3/);
  assert.equal(integer("2", "n", 1, 3), 2);
  assert.throws(() => bool("yes", "b"), /true or false/);
  assert.equal(isEmail("a@b.co"), true);
  assert.equal(isEmail("a@b"), false);
  assert.equal(sameHex("ab", "abc"), false);
  assert.equal(sameHex("zz", "zz"), false);
  assert.equal(escapeHtml(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  assert.equal(clampText("abcdef", 4), "abc…");
  assert.equal(new Date(weekStart(Date.parse("2026-11-08T23:00:00Z"))).toISOString(), "2026-11-02T00:00:00.000Z");
  assert.equal(parseRangeText("09:00-24:00", "h"), "09:00-24:00");
  assert.throws(() => parseRangeText(5, "h"), /look like/);
});

test("webhook URLs: public https only, local allowed in dev", () => {
  assert.equal(checkWebhookUrl("https://hooks.example/a", false), "https://hooks.example/a");
  assert.throws(() => checkWebhookUrl("https://[::1]/a", false), HttpError);
  assert.throws(() => checkWebhookUrl("https://10.0.0.1/a", false), HttpError);
  assert.equal(checkWebhookUrl("http://localhost:9000/a", true), "http://localhost:9000/a");
  assert.throws(() => checkWebhookUrl("ftp://x.example/a", true), /https/);
});

test("router matches params and reports methods", async () => {
  const r = new Router<null>();
  r.get("/api/x/:id", ({ params }) => ({ id: params.id }));
  r.put("/api/x/:id", () => ({ put: true }));
  r.patch("/api/x/:id", () => new Response("raw", { status: 202 }));
  r.post("/api/y", () => undefined);
  const onError = (e: unknown) => new Response(String(e), { status: 500 });
  const get = await r.handle(new Request("https://h.example/api/x/a%20b"), null, onError);
  assert.deepEqual(await get.json(), { id: "a b" });
  assert.equal((await r.handle(new Request("https://h.example/api/x/1", { method: "PATCH" }), null, onError)).status, 202);
  assert.deepEqual(await (await r.handle(new Request("https://h.example/api/y", { method: "POST" }), null, onError)).json(), { ok: true });
  const wrong = await r.handle(new Request("https://h.example/api/x/1", { method: "DELETE" }), null, onError);
  assert.equal(wrong.status, 405);
  assert.equal(wrong.headers.get("allow"), "GET, PUT, PATCH");
  assert.equal(clientIp(new Request("https://h.example/", { headers: { "x-real-ip": "1.2.3.4" } })), "1.2.3.4");
  assert.equal(clientIp(new Request("https://h.example/")), "unknown");
});

test("stage builds a self-contained hq-deploy upload", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "hqb-stage-"));
  try {
    const out = join(tmp, "out");
    const dist = join(tmp, "dist");
    mkdirSync(dist);
    writeFileSync(join(dist, "index.html"), "<!doctype html><title>Booking</title>");
    const example = join(here, "..", "..", "knowledge", "booking", "examples", "sales-round-robin.yaml");
    const r = stage(example, out, dist);
    assert.deepEqual(r.problems, []);
    assert.equal(r.ok, true);
    assert.ok(r.files < 100);
    const engine = readFileSync(join(out, "api", "_lib", "engine.ts"), "utf8");
    assert.doesNotMatch(engine, /"\.\.\/\.\.\/shared\//);
    assert.equal(JSON.parse(readFileSync(join(out, "api", "_lib", "booking.config.json"), "utf8")).company, "northwind");
    assert.match(readFileSync(join(out, "dist", "index.html"), "utf8"), /Booking/);
    assert.equal(stage(example, out, dist).problems[0], `${out} is not empty.`);

    writeFileSync(join(out, "api", "bad.ts"), 'import { parse } from "yaml";\nimport x from "../../outside.ts";\nimport { y } from "./_lib/missing.ts";\n');
    writeFileSync(join(out, "api", "_lib", "x.test.ts"), "");
    const problems = checkStaged(out);
    assert.ok(problems.some((p) => /package yaml/.test(p)));
    assert.ok(problems.some((p) => /outside api/.test(p)));
    assert.ok(problems.some((p) => /missing/.test(p)));
    assert.ok(problems.some((p) => /test file/.test(p)));
    assert.ok(problems.some((p) => /no default export/.test(p)));

    const badYaml = join(tmp, "bad.yaml");
    writeFileSync(badYaml, "version: 1\ncompany: [\n");
    assert.equal(stage(badYaml, join(tmp, "out2")).ok, false);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("dev server serves the API and static files from one origin", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "hqb-dev-"));
  const server = await startDevServer({ ownerKey: OWNER_KEY, distDir: tmp, jobsEveryMs: 60_000 });
  try {
    const getJson = async (path: string, init?: RequestInit): Promise<any> => (await fetch(`${server.url}${path}`, init)).json();
    const cfg = await getJson("/api/config/public");
    assert.equal(cfg.company, "northwind");
    assert.equal(cfg.sandbox, true);
    const plain = await fetch(`${server.url}/`);
    assert.match(await plain.text(), /API is running/);
    writeFileSync(join(tmp, "index.html"), "<h1>pages</h1>");
    writeFileSync(join(tmp, "app.js"), "1");
    assert.match(await (await fetch(`${server.url}/book/intro-call`)).text(), /pages/, "SPA fallback");
    assert.equal((await fetch(`${server.url}/app.js`)).headers.get("content-type"), "text/javascript; charset=utf-8");
    assert.doesNotMatch(await (await fetch(`${server.url}/%2e%2e/%2e%2e/etc/passwd`)).text(), /root:/);
    assert.equal((await getJson("/api/owner/session", { headers: { authorization: `Bearer ${OWNER_KEY}` } })).store, "memory");
    const slots = await getJson("/api/slots?eventType=intro-call");
    assert.ok(Array.isArray(slots.slots));
    const hold = await fetch(`${server.url}/api/holds`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
    assert.equal(hold.status, 400);
  } finally {
    await server.close();
    rmSync(tmp, { recursive: true, force: true });
  }
  const generated = await startDevServer({ jobsEveryMs: 60_000 });
  assert.match(generated.ownerKey ?? "", /^dev_owner_/);
  await generated.close();
});
