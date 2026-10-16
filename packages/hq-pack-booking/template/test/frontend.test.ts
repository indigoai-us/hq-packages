// Unit tests for the pure frontend helpers: the override resolver, time
// formatting, URL params, theme tokens and the embed script's frame URLs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import { pagesModuleSource, resolveSlot, routeFromPageFile, scanOverrides, SLOT_NAMES } from "../build/overrides-core.ts";
import { companyName, kindLabel, locationDetail, locationTitle, nameList } from "../src/lib/labels.ts";
import { answersForApi, carryParams, embedAllowed, parseEmbed, parseGuests, parsePrefill, parseUtm } from "../src/lib/params.ts";
import { assignLanes, auditActionLabel, calendarStatusLabel, fillWeeks, humanizeKey } from "../src/lib/owner-format.ts";
import { contrast, DEFAULT_THEME, ensureContrast, fontStylesheet, mix, onColor, safeAssetUrl, themeVars } from "../src/lib/theme.ts";
import { addDays, addMonths, formatClock, formatCountdown, formatDuration, formatRange, monthGrid, wall, weekStart, zonedInstant, zoneLabel } from "../src/lib/time.ts";
import type { Question } from "../src/lib/types.ts";

const here = dirname(fileURLToPath(import.meta.url));

/* ------------------------------------------------------- override layer */

test("@slots resolve to the override when the file exists, else to the template", () => {
  const exists = (p: string) => p === "/co/overrides/Header.tsx";
  assert.deepEqual(resolveSlot("Header", "/tpl/src/components", "/co/overrides", exists), { path: "/co/overrides/Header.tsx", override: true });
  assert.deepEqual(resolveSlot("Footer", "/tpl/src/components", "/co/overrides", exists), { path: "/tpl/src/components/Footer.tsx", override: false });
  assert.deepEqual(resolveSlot("Header", "/tpl/src/components", undefined, () => true), { path: "/tpl/src/components/Header.tsx", override: false });
  assert.throws(() => resolveSlot("Hedaer", "/tpl", "/co", () => true), /not a component the booking pages have/);
});

test("every slot named in US-005 exists as a template component", () => {
  for (const name of ["Header", "EventList", "DurationPicker", "SlotPicker", "LocationPicker", "IntakeForm", "Confirmation", "RoutingForm", "Footer"]) {
    assert.ok((SLOT_NAMES as readonly string[]).includes(name), name);
    assert.ok(readFileSync(join(here, "..", "src", "components", `${name}.tsx`), "utf8").includes("export default function"), `${name}.tsx exports a default component`);
  }
});

test("override pages become routes; bad names and reserved routes name the file", () => {
  assert.equal(routeFromPageFile("pricing.tsx"), "/pricing");
  assert.equal(routeFromPageFile("team/sales.tsx"), "/team/sales");
  assert.equal(routeFromPageFile("team/index.tsx"), "/team");
  assert.equal(routeFromPageFile("Pricing.tsx"), null);
  assert.equal(routeFromPageFile("notes.md"), null);

  const scan = scanOverrides(["Header.tsx", "helpers.ts", "lib/util.tsx", "Hedaer.tsx", "pages/pricing.tsx", "pages/owner.tsx", "pages/Bad Name.tsx", ".DS_Store"], "/co/overrides");
  assert.deepEqual(scan.slots, ["Header"]);
  assert.deepEqual(scan.pages, [{ route: "/pricing", file: "/co/overrides/pages/pricing.tsx" }]);
  assert.equal(scan.errors.length, 3);
  assert.ok(scan.errors.some((e) => e.startsWith("/co/overrides/Hedaer.tsx:") && /no component called Hedaer/.test(e)));
  assert.ok(scan.errors.some((e) => e.startsWith("/co/overrides/pages/owner.tsx:") && /belongs to the booking pages/.test(e)));
  assert.ok(scan.errors.some((e) => e.startsWith("/co/overrides/pages/Bad Name.tsx:")));
});

test("the pages module imports each override page once", () => {
  const src = pagesModuleSource([{ route: "/pricing", file: "/co/overrides/pages/pricing.tsx" }]);
  assert.match(src, /import Page0 from "\/co\/overrides\/pages\/pricing.tsx";/);
  assert.match(src, /export default \[\{ route: "\/pricing", component: Page0 \}\]/);
  assert.equal(pagesModuleSource([]).trim(), "export default [];");
});

/* ---------------------------------------------------------------- time */

test("clock format in 12 and 24 hours", () => {
  assert.equal(formatClock("15:00", true), "3:00pm");
  assert.equal(formatClock("00:30", true), "12:30am");
  assert.equal(formatClock("12:05", true), "12:05pm");
  assert.equal(formatClock("9:15", false), "09:15");
  assert.equal(formatClock("bad", true), "bad");
});

test("instants shown in the visitor's zone", () => {
  const start = "2026-11-03T15:00:00.000Z";
  assert.deepEqual(wall(start, "Europe/Paris"), { date: "2026-11-03", time: "16:00", weekday: 2 });
  assert.deepEqual(wall(start, "America/Los_Angeles").time, "07:00");
  assert.equal(formatRange(start, "2026-11-03T15:30:00.000Z", "Europe/Paris", true), "4:00pm – 4:30pm, Tuesday, November 3, 2026");
  assert.equal(formatRange(start, "2026-11-03T15:30:00.000Z", "Asia/Tokyo", false), "00:00 – 00:30, Wednesday, November 4, 2026");
  assert.match(zoneLabel("America/New_York", Date.parse(start)), /^New York \(GMT-5\)$/);
});

test("zoned instants survive DST changes", () => {
  // New York leaves DST on 2026-11-01.
  assert.equal(new Date(zonedInstant("2026-10-31", "09:00", "America/New_York")).toISOString(), "2026-10-31T13:00:00.000Z");
  assert.equal(new Date(zonedInstant("2026-11-02", "09:00", "America/New_York")).toISOString(), "2026-11-02T14:00:00.000Z");
  assert.equal(new Date(zonedInstant("2026-11-01", "00:00", "UTC")).toISOString(), "2026-11-01T00:00:00.000Z");
});

test("durations, countdown and month grid", () => {
  assert.equal(formatDuration(30), "30 min");
  assert.equal(formatDuration(60), "1 hr");
  assert.equal(formatDuration(90), "1 hr 30 min");
  assert.equal(formatCountdown(299_100), "5:00");
  assert.equal(formatCountdown(61_000), "1:01");
  assert.equal(formatCountdown(-5), "0:00");
  const nov = monthGrid(2026, 11); // Nov 1 2026 is a Sunday
  assert.equal(nov[0]?.[0]?.date, "2026-11-01");
  assert.ok(nov.every((w) => w.length === 7));
  assert.equal(nov.flat().filter((c) => c.inMonth).length, 30);
  const feb = monthGrid(2027, 2);
  assert.equal(feb[0]?.[0]?.inMonth, false);
  assert.deepEqual(addMonths(2026, 12, 1), { year: 2027, month: 1 });
  assert.deepEqual(addMonths(2026, 1, -1), { year: 2025, month: 12 });
  assert.equal(weekStart("2026-11-05"), "2026-11-02");
  assert.equal(addDays("2026-12-31", 1), "2027-01-01");
});

/* -------------------------------------------------------------- params */

const QUESTIONS: Question[] = [
  { id: "company", label: "Company", type: "text", required: true },
  { id: "size", label: "Size", type: "select", required: false, options: ["1-10", "11-50"] },
  { id: "topics", label: "Topics", type: "checkbox", required: false, options: ["Pricing", "Security", "Support"] },
  { id: "seats", label: "Seats", type: "number", required: false },
];

test("URL prefill keeps known questions and valid options", () => {
  const p = parsePrefill("?name=Iris&email=iris%40client.example&a_company=Client%20Co&a_size=11-50&a_topics=Pricing,Nope,Support&a_unknown=x&a_size2=1", QUESTIONS);
  assert.equal(p.name, "Iris");
  assert.equal(p.email, "iris@client.example");
  assert.deepEqual(p.answers, { company: "Client Co", size: "11-50", topics: ["Pricing", "Support"] });
  assert.deepEqual(parsePrefill("?a_size=999", QUESTIONS).answers, {});
  assert.equal(parsePrefill(`?name=${"x".repeat(300)}`).name.length, 200);
});

test("utm params are picked and clipped", () => {
  assert.deepEqual(parseUtm("?utm_source=news&utm_medium=email&utm_bogus=1&utm_campaign="), { utm_source: "news", utm_medium: "email" });
  assert.equal(parseUtm(`?utm_term=${"y".repeat(300)}`).utm_term?.length, 200);
});

test("embed params and allowed origins", () => {
  assert.deepEqual(parseEmbed("?embed=1&embed_origin=https%3A%2F%2Fwww.acme.example%2Fpath&mode=popup-button"), { embedded: true, origin: "https://www.acme.example", mode: "popup-button" });
  assert.deepEqual(parseEmbed("?embed_origin=javascript:alert(1)&mode=weird"), { embedded: false, origin: null, mode: null });
  assert.equal(embedAllowed("https://www.acme.example", "https://book.example", []), true);
  assert.equal(embedAllowed("https://www.acme.example", "https://book.example", ["https://www.acme.example"]), true);
  assert.equal(embedAllowed("https://evil.example", "https://book.example", ["https://www.acme.example"]), false);
  assert.equal(embedAllowed("https://book.example", "https://book.example", ["https://www.acme.example"]), true);
  assert.equal(embedAllowed(null, "https://book.example", ["https://www.acme.example"]), false);
});

test("carried params keep prefill, utm and embed flags only", () => {
  assert.equal(carryParams("?utm_source=a&name=Iris&token=secret&embed=1&a_company=X", { hosts: "sam" }), "?utm_source=a&name=Iris&embed=1&a_company=X&hosts=sam");
  assert.equal(carryParams("?token=x"), "");
});

test("answers are shaped for the API", () => {
  assert.deepEqual(answersForApi(QUESTIONS, { company: "  Client Co ", size: "", topics: ["Pricing"], seats: "120" }), { company: "Client Co", topics: ["Pricing"], seats: 120 });
  assert.deepEqual(answersForApi(QUESTIONS, { seats: "lots" }), { seats: "lots" });
  assert.deepEqual(parseGuests("a@x.example, b@x.example;  A@x.example\nc@x.example"), ["a@x.example", "b@x.example", "c@x.example"]);
});

/* --------------------------------------------------------------- theme */

test("default theme meets WCAG AA for text, muted text and buttons", () => {
  const v = themeVars({});
  assert.ok(contrast(v["--bk-text"] as string, v["--bk-bg"] as string) >= 7);
  assert.ok(contrast(v["--bk-muted"] as string, v["--bk-bg"] as string) >= 4.5);
  assert.ok(contrast(v["--bk-muted"] as string, v["--bk-surface"] as string) >= 4.5);
  assert.ok(contrast(v["--bk-on-primary"] as string, v["--bk-primary"] as string) >= 4.5);
  assert.ok(contrast(v["--bk-danger"] as string, v["--bk-danger-soft"] as string) >= 4.5);
  assert.ok(contrast(v["--bk-success"] as string, v["--bk-success-soft"] as string) >= 4.5);
  assert.ok(contrast(v["--bk-warning"] as string, v["--bk-warning-soft"] as string) >= 4.5);
  assert.equal(v["--bk-radius"], `${DEFAULT_THEME.radius}px`);
});

test("company theme colors, fonts and radius become variables, fixed up for contrast", () => {
  const v = themeVars({ colors: { primary: "#1f4d3a", background: "#ffffff", text: "#111111", muted: "#bbbbbb" }, fonts: { heading: "Fraunces", body: "Inter" }, radius: 4 });
  assert.equal(v["--bk-primary"], "#1f4d3a");
  assert.equal(v["--bk-on-primary"], "#ffffff");
  assert.ok(contrast(v["--bk-muted"] as string, "#ffffff") >= 4.5, "a too-light muted color is darkened");
  assert.match(v["--bk-font-heading"] as string, /^"Fraunces", /);
  assert.equal(v["--bk-radius"], "4px");
  // A light brand color still gives readable link text.
  const light = themeVars({ colors: { primary: "#f5d04b" } });
  assert.ok(contrast(light["--bk-primary-text"] as string, light["--bk-bg"] as string) >= 4.5);
  assert.equal(onColor("#f5d04b"), "#111111");
  // Dark backgrounds get light text.
  const dark = themeVars({ colors: { background: "#101012" } });
  assert.ok(contrast(dark["--bk-text"] as string, "#101012") >= 7);
  assert.equal(dark["--bk-scheme"], "dark");
  // Bad values fall back.
  assert.equal(themeVars({ colors: { primary: "red; background:url(x)" }, radius: 99 })["--bk-radius"], `${DEFAULT_THEME.radius}px`);
  assert.equal(themeVars({ colors: { primary: "red; background:url(x)" } })["--bk-primary"], DEFAULT_THEME.primary);
  assert.equal(ensureContrast("#777777", "#ffffff", 4.5) !== "#777777", true);
  assert.equal(mix("#000000", "#ffffff", 0.5), "#808080");
});

test("fonts load only for plain family names; asset URLs must be http(s) or same origin", () => {
  assert.equal(fontStylesheet({ fonts: { heading: "Fraunces", body: "Inter" } }), "https://fonts.googleapis.com/css2?family=Fraunces:wght@400;500&family=Inter:wght@400;500&display=swap");
  assert.equal(fontStylesheet({ fonts: { body: "serif" } }), null);
  assert.equal(fontStylesheet({ fonts: { body: "x');}@import url(evil" } }), null);
  assert.equal(fontStylesheet({}), null);
  assert.equal(safeAssetUrl("/logo.svg"), "/logo.svg");
  assert.equal(safeAssetUrl("https://cdn.example/logo.png"), "https://cdn.example/logo.png");
  assert.equal(safeAssetUrl("javascript:alert(1)"), null);
  assert.equal(safeAssetUrl("//evil.example/x.png"), null);
});

/* -------------------------------------------------------------- labels */

test("plain labels", () => {
  assert.equal(locationTitle({ type: "meet" }), "Google Meet");
  assert.equal(locationTitle({ type: "custom", label: "Whereby" }), "Whereby");
  assert.match(locationDetail({ type: "phone", caller: "host" }), /host calls you/);
  assert.equal(kindLabel("round-robin", 3), "With one of 3 team members");
  assert.equal(kindLabel("one-on-one", 1), null);
  assert.equal(nameList(["A", "B", "C"]), "A, B and C");
  assert.equal(companyName("northwind-labs"), "Northwind Labs");
});

/* ---------------------------------------------------------------- embed */

test("embed.js builds frame URLs with prefill, utm passthrough and embed flags", () => {
  const code = readFileSync(join(here, "..", "public", "embed.js"), "utf8");
  const sandbox: Record<string, unknown> = { URLSearchParams, URL };
  sandbox.globalThis = sandbox;
  runInNewContext(code, sandbox);
  const api = sandbox.HQBooking as { _frameUrl: (base: string, id: string, mode: string, opts: Record<string, string>) => string };
  const url = new URL(api._frameUrl("https://book.example", "intro-call", "popup-button", { hostSearch: "?utm_source=site&utm_bogus=1&gclid=x&name=Host%20Param&a_company=Acme", name: "Data Attr", params: "a_role=Admin&duration=15&token=nope", hostOrigin: "https://www.acme.example" }));
  assert.equal(url.origin + url.pathname, "https://book.example/intro-call");
  const q = url.searchParams;
  assert.equal(q.get("utm_source"), "site");
  assert.equal(q.get("utm_bogus"), null);
  assert.equal(q.get("gclid"), null);
  assert.equal(q.get("name"), "Data Attr", "data attributes win over host page params");
  assert.equal(q.get("a_company"), "Acme");
  assert.equal(q.get("a_role"), "Admin");
  assert.equal(q.get("duration"), "15");
  assert.equal(q.get("token"), null);
  assert.equal(q.get("embed"), "1");
  assert.equal(q.get("mode"), "popup-button");
  assert.equal(q.get("embed_origin"), "https://www.acme.example");
  assert.equal(new URL(api._frameUrl("https://book.example", "", "inline", {})).pathname, "/");
});

/* ------------------------------------------------- override build (vite) */

test("a build with overrides uses the override header and adds its pages; a broken override fails naming the file", async () => {
  const { build } = await import("vite");
  const { cpSync, mkdtempSync, readdirSync, rmSync, writeFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const root = join(here, "..");
  // The company folder lives outside the template, so replacing the template (a pack upgrade) leaves it alone.
  const company = mkdtempSync(join(tmpdir(), "hqb-overrides-"));
  const overrides = join(company, "overrides");
  cpSync(join(root, "examples", "overrides"), overrides, { recursive: true });
  const outDir = join(company, "dist");
  const run = () =>
    build({ configFile: join(root, "vite.config.ts"), root, logLevel: "silent", build: { outDir, emptyOutDir: true } });
  const prev = process.env.BOOKING_OVERRIDES_DIR;
  process.env.BOOKING_OVERRIDES_DIR = overrides;
  try {
    await run();
    const js = readdirSync(join(outDir, "assets")).filter((f) => f.endsWith(".js"));
    assert.equal(js.length, 1, "one JS bundle");
    const bundle = readFileSync(join(outDir, "assets", js[0] as string), "utf8");
    assert.ok(bundle.includes("Northwind advisers answer within one business day."), "override header is in the bundle");
    assert.ok(bundle.includes('"/about"'), "override page is a route");

    writeFileSync(join(overrides, "Header.tsx"), "export default function Header() {\n  return <div>oops</span>;\n}\n");
    await assert.rejects(run, (e: Error) => e.message.includes(join(overrides, "Header.tsx")) && /failed to build/.test(e.message));
  } finally {
    if (prev === undefined) delete process.env.BOOKING_OVERRIDES_DIR;
    else process.env.BOOKING_OVERRIDES_DIR = prev;
    rmSync(company, { recursive: true, force: true });
  }
});

/* ------------------------------------------------ owner dashboard helpers */

test("owner labels: internal keys read as plain words", () => {
  assert.equal(humanizeKey("company"), "Company");
  assert.equal(humanizeKey("company_size"), "Company size");
  assert.equal(calendarStatusLabel("updated"), "Updated on the host's calendar");
  assert.equal(calendarStatusLabel("some-new-state"), "Some new state");
  assert.equal(auditActionLabel("booking.created"), "Booked");
  assert.equal(auditActionLabel("booking.rescheduled"), "Rescheduled");
  assert.equal(auditActionLabel("link.created"), "Link created");
});

test("analytics weeks: the whole range shows, empty weeks included", () => {
  const rows = fillWeeks([{ key: "2026-10-12", bookings: 6, canceled: 2, noShows: 0 }], "2026-07-27T00:00:00.000Z", "2026-10-19T00:00:00.000Z");
  assert.equal(rows.length, 12);
  assert.equal(rows[0]?.key, "2026-07-27");
  assert.equal(rows[11]?.key, "2026-10-12");
  assert.equal(rows[11]?.bookings, 6);
  assert.equal(rows[5]?.bookings, 0);
});

test("owner calendar: overlapping blocks get side-by-side lanes, others keep the full width", () => {
  const b = (day: number, top: number, height: number) => ({ day, top, height, lane: 0, lanes: 1 });
  const busy = b(4, 250, 84); // 12:30-2:00
  const inner = b(4, 278, 26); // 1:00-1:30, inside the busy block
  const later = b(4, 400, 50); // after both
  const otherDay = b(0, 250, 84); // same time, other day
  assignLanes([inner, busy, later, otherDay]);
  assert.deepEqual([busy.lane, busy.lanes], [0, 2]);
  assert.deepEqual([inner.lane, inner.lanes], [1, 2]);
  assert.deepEqual([later.lane, later.lanes], [0, 1]);
  assert.deepEqual([otherDay.lane, otherDay.lanes], [0, 1]);
});

test("layout guards: narrow slot pickers stack, table scrollers contain hidden text", () => {
  const css = readFileSync(join(here, "..", "src", "styles.css"), "utf8");
  assert.match(css, /\.bk-stage \{[^}]*container-type: inline-size/);
  assert.match(css, /@container \(max-width: 600px\) \{\s*\.bk-slotpicker \{\s*grid-template-columns: minmax\(0, 1fr\)/);
  assert.match(css, /\.ow-table-wrap \{[^}]*position: relative/);
  const manage = readFileSync(join(here, "..", "src", "pages", "ManagePage.tsx"), "utf8");
  assert.match(manage, /mode === "reschedule"[^\n]*bk-narrow/, "the reschedule view leaves the narrow column");
});
