import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { checkBookingYaml, checkConfig, schema } from "./config.ts";
import { SchemaChecker } from "./schema-check.ts";

const here = dirname(fileURLToPath(import.meta.url));
const examplesDir = join(here, "..", "..", "knowledge", "booking", "examples");

function minimal(): Record<string, any> {
  return {
    version: 1,
    company: "acme",
    timezone: "America/New_York",
    hosts: [{ id: "ana", name: "Ana", email: "ana@acme.example", hours: { mon: ["09:00-17:00"] } }],
    eventTypes: [{ id: "intro", title: "Intro", kind: "one-on-one", hosts: ["ana"], durations: [30], locations: [{ type: "meet" }] }],
  };
}

function codes(value: unknown): string[] {
  return checkConfig(value).errors.map((e) => `${e.path} ${e.code}`);
}

test("each example config validates", () => {
  const files = readdirSync(examplesDir).filter((f) => f.endsWith(".yaml"));
  assert.equal(files.length, 3);
  for (const f of files) {
    const result = checkBookingYaml(readFileSync(join(examplesDir, f), "utf8"));
    assert.deepEqual(result.errors, [], f);
    assert.equal(result.ok, true, f);
  }
});

test("minimal config is valid", () => {
  assert.equal(checkConfig(minimal()).ok, true);
});

test("collective event with seats is rejected naming the field", () => {
  const cfg = minimal();
  cfg.hosts.push({ id: "ben", name: "Ben", email: "ben@acme.example", hours: { mon: ["09:00-17:00"] } });
  cfg.eventTypes[0] = { ...cfg.eventTypes[0], kind: "collective", hosts: ["ana", "ben"], seats: 5 };
  const result = checkConfig(cfg);
  assert.equal(result.ok, false);
  assert.deepEqual(result.errors.map((e) => [e.path, e.code]), [["eventTypes[0].seats", "seats-not-allowed"]]);
  assert.match(result.errors[0]!.message, /Only group events have seats/);
});

test("round-robin with one host is rejected", () => {
  const cfg = minimal();
  cfg.eventTypes[0].kind = "round-robin";
  assert.deepEqual(codes(cfg), ["eventTypes[0].hosts round-robin-needs-two-hosts"]);
});

test("kind and host count rules", () => {
  const cfg = minimal();
  cfg.hosts.push({ id: "ben", name: "Ben", email: "ben@acme.example", hours: {} });
  cfg.eventTypes[0].hosts = ["ana", "ben"];
  assert.deepEqual(codes(cfg), ["eventTypes[0].hosts one-on-one-needs-one-host"]);

  cfg.eventTypes[0] = { ...cfg.eventTypes[0], kind: "collective", hosts: ["ana"] };
  assert.deepEqual(codes(cfg), ["eventTypes[0].hosts collective-needs-two-hosts"]);

  cfg.eventTypes[0] = { ...cfg.eventTypes[0], kind: "group", hosts: ["ana"] };
  assert.deepEqual(codes(cfg), ["eventTypes[0].seats group-needs-seats"]);
});

test("unknown keys are rejected at every level", () => {
  const cfg = minimal();
  cfg.colour = "red";
  cfg.hosts[0].nickname = "A";
  cfg.eventTypes[0].locations[0].room = "1";
  assert.deepEqual(codes(cfg).sort(), [
    "colour unknown-key",
    "eventTypes[0].locations[0].room unknown-key",
    "hosts[0].nickname unknown-key",
  ]);
});

test("structural errors carry plain messages", () => {
  const cfg = minimal();
  cfg.version = 2;
  cfg.company = "Acme Inc";
  cfg.hosts[0].hours.mon = ["9-5"];
  cfg.eventTypes[0].durations = [3];
  cfg.eventTypes[0].kind = "webinar";
  cfg.eventTypes[0].title = "";
  cfg.eventTypes[0].minimumNotice = 999999;
  cfg.eventTypes[0].secret = "yes";
  const result = checkConfig(cfg);
  const byPath = new Map(result.errors.map((e) => [e.path, e]));
  assert.equal(byPath.get("version")?.code, "wrong-value");
  assert.equal(byPath.get("company")?.code, "bad-format");
  assert.equal(byPath.get("hosts[0].hours.mon[0]")?.code, "bad-format");
  assert.equal(byPath.get("eventTypes[0].durations[0]")?.code, "too-small");
  assert.equal(byPath.get("eventTypes[0].kind")?.code, "not-allowed");
  assert.equal(byPath.get("eventTypes[0].title")?.code, "too-short");
  assert.equal(byPath.get("eventTypes[0].minimumNotice")?.code, "too-large");
  assert.equal(byPath.get("eventTypes[0].secret")?.code, "wrong-type");
  assert.match(byPath.get("eventTypes[0].secret")!.message, /true or false, not text/);
  for (const e of result.errors) assert.ok(e.message.length > 10);
});

test("missing required fields and empty lists", () => {
  assert.deepEqual(codes({ version: 1 }).sort(), ["company missing", "eventTypes missing", "hosts missing"]);
  const cfg = minimal();
  cfg.hosts = [];
  cfg.eventTypes[0].locations = [];
  const c = codes(cfg);
  assert.ok(c.includes("hosts too-few"));
  assert.ok(c.includes("eventTypes[0].locations too-few"));
  assert.ok(c.includes("eventTypes[0].hosts[0] unknown-host"));
  assert.deepEqual(codes("hello"), [" wrong-type"]);
  assert.deepEqual(codes([]), [" wrong-type"]);
});

test("lists: too many, duplicates", () => {
  const cfg = minimal();
  cfg.eventTypes[0].durations = [15, 30, 45, 60, 75, 90, 120];
  cfg.hosts[0].holidays = ["2026-12-25", "2026-12-25"];
  const c = codes(cfg);
  assert.ok(c.includes("eventTypes[0].durations too-many"));
  assert.ok(c.includes("hosts[0].holidays[1] duplicate"));
});

test("ids must be unique", () => {
  const cfg = minimal();
  cfg.hosts.push({ ...cfg.hosts[0] });
  cfg.eventTypes.push({ ...cfg.eventTypes[0] });
  cfg.eventTypes[0].questions = [
    { id: "q", label: "Q", type: "text" },
    { id: "q", label: "Q2", type: "text" },
  ];
  assert.deepEqual(codes(cfg).sort(), [
    "eventTypes[0].questions[1].id duplicate-id",
    "eventTypes[1].id duplicate-id",
    "hosts[1].id duplicate-id",
  ]);
});

test("time zones", () => {
  const cfg = minimal();
  delete cfg.timezone;
  assert.deepEqual(codes(cfg), ["hosts[0].timezone missing-timezone"]);
  cfg.hosts[0].timezone = "Mars/Olympus";
  assert.deepEqual(codes(cfg), ["hosts[0].timezone unknown-timezone"]);
  delete cfg.hosts[0].timezone;
  cfg.timezone = "Nowhere/Land";
  assert.deepEqual(codes(cfg), ["timezone unknown-timezone"]);
});

test("hours, overrides and holidays are real", () => {
  const cfg = minimal();
  cfg.hosts[0].hours.tue = ["13:00-12:00"];
  cfg.hosts[0].hours.wed = ["09:00-12:00", "11:00-14:00"];
  cfg.hosts[0].overrides = [
    { date: "2026-02-30", hours: [] },
    { date: "2026-03-02", hours: ["10:00-11:00"] },
    { date: "2026-03-02", hours: [] },
  ];
  cfg.hosts[0].holidays = ["2026-13-01"];
  assert.deepEqual(codes(cfg).sort(), [
    "hosts[0].holidays[0] bad-date",
    "hosts[0].hours.tue[0] bad-range",
    "hosts[0].hours.wed[1] overlapping-hours",
    "hosts[0].overrides[0].date bad-date",
    "hosts[0].overrides[2].date duplicate-date",
  ]);
});

test("24:00 closes the day", () => {
  const cfg = minimal();
  cfg.hosts[0].hours.sat = ["18:00-24:00"];
  assert.equal(checkConfig(cfg).ok, true);
});

test("calendars: book into a checked, writable calendar", () => {
  const cfg = minimal();
  cfg.hosts[0].calendars = {
    conflicts: [{ source: "google", account: "ana@acme.example", calendar: "primary" }],
    bookInto: { source: "google", account: "ana@acme.example", calendar: "team" },
  };
  assert.deepEqual(codes(cfg), ["hosts[0].calendars.bookInto book-into-not-checked"]);
  cfg.hosts[0].calendars.bookInto = { source: "ical", secret: "ANA_ICAL" };
  assert.deepEqual(codes(cfg), ["hosts[0].calendars.bookInto book-into-read-only"]);
  cfg.hosts[0].calendars.bookInto = { source: "google", account: "ana@acme.example", calendar: "primary" };
  assert.equal(checkConfig(cfg).ok, true);
});

test("an iCal link pasted where a secret name belongs is called out", () => {
  const cfg = minimal();
  cfg.hosts[0].calendars = {
    conflicts: [{ source: "ical", secret: "https://p01-caldav.icloud.example/published/2/abc" }],
  };
  const result = checkConfig(cfg);
  assert.deepEqual(result.errors.map((e) => [e.path, e.code]), [["hosts[0].calendars.conflicts[0].secret", "secret-is-url"]]);
  assert.match(result.errors[0]!.message, /hq secrets set/);
  assert.doesNotMatch(result.errors[0]!.message, /icloud/);
});

test("calendar source must be known; branch errors are specific", () => {
  const cfg = minimal();
  cfg.hosts[0].calendars = { conflicts: [{ source: "yahoo", account: "a@b.example", calendar: "x" }] };
  assert.deepEqual(codes(cfg), ["hosts[0].calendars.conflicts[0].source not-allowed"]);
  cfg.hosts[0].calendars = { conflicts: [{ source: "google", account: "not-an-email", calendar: "primary" }] };
  assert.deepEqual(codes(cfg), ["hosts[0].calendars.conflicts[0].account bad-format"]);
  cfg.hosts[0].calendars = { conflicts: ["primary"] };
  assert.deepEqual(codes(cfg), ["hosts[0].calendars.conflicts[0] no-match"]);
});

test("locations need what they depend on", () => {
  const cfg = minimal();
  cfg.eventTypes[0].locations = [{ type: "custom" }, { type: "phone", caller: "invitee" }, { type: "meet" }, { type: "meet" }];
  assert.deepEqual(codes(cfg).sort(), [
    "eventTypes[0].locations[0] custom-link-missing",
    "eventTypes[0].locations[1] phone-number-missing",
    "eventTypes[0].locations[3] duplicate-location",
  ]);
  cfg.hosts[0].links = { custom: "https://whereby.example/ana", phone: "+1 617 555 0100" };
  cfg.eventTypes[0].locations = [{ type: "custom" }, { type: "phone", caller: "invitee" }];
  assert.equal(checkConfig(cfg).ok, true);
  cfg.eventTypes[0].locations = [{ type: "in-person" }];
  assert.deepEqual(codes(cfg), ["eventTypes[0].locations[0].address missing"]);
});

test("default duration must be offered", () => {
  const cfg = minimal();
  cfg.eventTypes[0].defaultDuration = 45;
  assert.deepEqual(codes(cfg), ["eventTypes[0].defaultDuration default-duration-not-offered"]);
});

test("question options follow the question type", () => {
  const cfg = minimal();
  cfg.eventTypes[0].questions = [
    { id: "size", label: "Size", type: "select" },
    { id: "name", label: "Name", type: "text", options: ["a"] },
  ];
  assert.deepEqual(codes(cfg).sort(), [
    "eventTypes[0].questions[0].options options-required",
    "eventTypes[0].questions[1].options options-not-allowed",
  ]);
});

function withRouting(form: Record<string, unknown>): Record<string, any> {
  const cfg = minimal();
  cfg.routing = { forms: [{ id: "f", title: "F", questions: [{ id: "seats", label: "Seats", type: "number" }], rules: [], default: { eventType: "intro" }, ...form }] };
  return cfg;
}

test("routing rules point at real questions and targets", () => {
  assert.equal(checkConfig(withRouting({})).ok, true);
  assert.deepEqual(codes(withRouting({ rules: [{ when: { question: "size", equals: "big" }, to: { eventType: "intro" } }] })), [
    "routing.forms[0].rules[0].when.question unknown-question",
  ]);
  assert.deepEqual(codes(withRouting({ rules: [{ when: { question: "seats" }, to: { eventType: "intro" } }] })), [
    "routing.forms[0].rules[0].when bad-condition",
  ]);
  assert.equal(checkConfig(withRouting({ rules: [{ when: { question: "seats", gte: 1, lte: 9 }, to: { url: "https://acme.example/small" } }] })).ok, true);
  assert.deepEqual(codes(withRouting({ default: { eventType: "intro", url: "https://acme.example" } })), ["routing.forms[0].default bad-target"]);
  assert.deepEqual(codes(withRouting({ default: {} })), ["routing.forms[0].default bad-target"]);
  assert.deepEqual(codes(withRouting({ default: { eventType: "nope" } })), ["routing.forms[0].default.eventType unknown-event-type"]);
  assert.deepEqual(codes(withRouting({ default: { eventType: "intro", hosts: ["zed"] } })), ["routing.forms[0].default.hosts[0] host-not-on-event-type"]);
  assert.deepEqual(codes(withRouting({ default: { url: "https://acme.example", hosts: ["ana"] } })), ["routing.forms[0].default.hosts hosts-need-event-type"]);
  const dup = withRouting({});
  dup.routing.forms.push({ ...dup.routing.forms[0] });
  assert.deepEqual(codes(dup), ["routing.forms[1].id duplicate-id"]);
});

test("webhook signing secrets are names, not values", () => {
  const cfg = minimal();
  cfg.webhooks = [{ url: "https://hooks.acme.example/x", events: ["booked"], signingSecret: "whsec_abc123" }];
  assert.deepEqual(codes(cfg), ["webhooks[0].signingSecret bad-format"]);
  cfg.webhooks[0].url = "http://hooks.acme.example/x";
  cfg.webhooks[0].signingSecret = "HOOK_SECRET";
  assert.deepEqual(codes(cfg), ["webhooks[0].url bad-format"]);
});

test("YAML syntax errors report the line", () => {
  const result = checkBookingYaml("version: 1\ncompany: acme\nhosts: [\n");
  assert.equal(result.ok, false);
  assert.equal(result.errors[0]?.code, "yaml-syntax");
  assert.match(result.errors[0]!.message, /line \d+/);
  const dupKey = checkBookingYaml("version: 1\nversion: 1\n");
  assert.equal(dupKey.errors[0]?.code, "yaml-syntax");
});

test("errors are sorted by path and not repeated", () => {
  const cfg = minimal();
  cfg.zzz = 1;
  cfg.aaa = 1;
  const paths = checkConfig(cfg).errors.map((e) => e.path);
  assert.deepEqual(paths, [...paths].sort());
});

test("the checker refuses schema keywords it does not enforce", () => {
  assert.throws(() => new SchemaChecker({ type: "object", properties: { a: { type: "string", format: "email" } } }), /unsupported keyword format/);
  assert.throws(() => new SchemaChecker({ type: "object", oneOf: [{ patternProperties: {} }] }), /unsupported keyword patternProperties/);
  assert.throws(() => new SchemaChecker({ $ref: "#/$defs/a", $defs: { a: { $ref: "#/$defs/a" } } }).check(1), /circular/);
  assert.throws(() => new SchemaChecker({ $ref: "http://example.com/x" }).check(1), /unsupported \$ref/);
  assert.throws(() => new SchemaChecker({ $ref: "#/$defs/missing" }).check(1), /missing \$defs/);
});

test("checker handles number types and generic oneOf", () => {
  const c = new SchemaChecker({ type: "object", properties: { n: { type: "number" }, o: { oneOf: [{ type: "string" }, { type: "integer" }] } } });
  assert.deepEqual(c.check({ n: 1.5, o: "x" }), []);
  assert.deepEqual(c.check({ n: 2, o: 3 }), []);
  assert.deepEqual(c.check({ n: "x", o: true }).map((i) => i.code), ["wrong-type", "no-match"]);
  assert.deepEqual(c.check({ n: null }).map((i) => i.message), ["n must be a number, not null."]);
  assert.match(c.check({ n: [] })[0]!.message, /not a list/);
  assert.match(c.check({ n: {} })[0]!.message, /not a section/);
  assert.match(new SchemaChecker({ type: "string" }).check(1.5)[0]!.message, /not a number/);
  assert.match(new SchemaChecker({ type: "string" }).check(2)[0]!.message, /not a whole number/);
  const multi = new SchemaChecker({ oneOf: [
    { type: "object", properties: { a: { const: 1 } } },
    { type: "object", properties: { b: { const: 2 } } },
  ] });
  assert.deepEqual(multi.check({ a: 9, b: 9 }).map((i) => i.code), ["no-match"]);
});

test("schema documents every top-level section", () => {
  const props = Object.keys((schema.properties ?? {}) as object).sort();
  assert.deepEqual(props, ["company", "dataRetention", "embed", "eventTypes", "hosts", "notifications", "routing", "theme", "timezone", "version", "webhooks"]);
});
