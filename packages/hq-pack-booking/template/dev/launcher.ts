// Helpers behind scripts/hq-booking.sh. The shell script resolves the session
// company and refuses other companies' files; this module does the work that
// needs YAML editing, HTTP or JSON. Every command prints one JSON object.
// Exit 0 ok, 1 refused or failed, 2 usage or setup error.
//
//   launcher.ts setup      --file F --company C [--example E] [--company-name N] [--rotate] [--key-in-env]
//   launcher.ts hosts      list|add|remove --file F --company C [...]
//   launcher.ts owner      <sub> --deploy-json J [--url U] ...   (owner key in $BOOKING_OWNER_KEY)
//   launcher.ts agent      <sub> --base URL --key-env NAME ...
//   launcher.ts deploy     --company C --root R --file F --stage S --build-meta M --deploy-json J --scripts D ...
//   launcher.ts dev-serve  --config F [--port N]       (owner key in $BOOKING_OWNER_KEY)
//
// Secrets: the owner key is generated here, piped to `hq secrets set
// --from-stdin` and never printed, logged or written to disk. Only its SHA-256
// goes into booking.yaml. Owner and agent keys are read from the environment
// that `hq secrets exec` sets up.

import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { isMap, isSeq, parseDocument, type Document } from "yaml";
import { checkBookingYaml, type BookingConfig } from "../shared/config.ts";

type Flags = { pos: string[]; f: Map<string, string | true> };
type Json = Record<string, unknown>;

const BOOLEAN_FLAGS = new Set([
  "rotate", "key-in-env", "single-use", "reusable", "undo", "accept-database-billing", "link", "force", "plain", "h12", "h24",
]);

export const OWNER_SECRET = "BOOKING_OWNER_KEY";
export const MAX_FILES = 100;
export const DB_TERMS =
  "Adding a database to this app costs $10 a month. That includes 250,000 compute units and 1 GB of storage. Above that it is $32 per million compute units and $1.32 per GB per month. If the app reaches 4 times the included amounts, the database becomes read-only until the next month.";

class Exit extends Error {
  code: number;
  body: Json;
  constructor(code: number, body: Json) {
    super(String(body.message ?? body.error ?? "exit"));
    this.code = code;
    this.body = body;
  }
}

function fail(code: number, error: string, message: string, extra: Json = {}): never {
  throw new Exit(code, { ok: false, error, message, ...extra });
}

function parse(args: string[]): Flags {
  const pos: string[] = [];
  const f = new Map<string, string | true>();
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string;
    if (a.startsWith("--")) {
      const name = a.slice(2);
      if (BOOLEAN_FLAGS.has(name)) {
        f.set(name, true);
        continue;
      }
      const v = args[i + 1];
      if (v === undefined || v.startsWith("--")) fail(2, "usage", `${a} needs a value.`);
      f.set(name, v);
      i++;
    } else pos.push(a);
  }
  return { pos, f };
}

function str(fl: Flags, name: string): string | undefined {
  const v = fl.f.get(name);
  return typeof v === "string" ? v : undefined;
}

function need(fl: Flags, name: string, hint?: string): string {
  const v = str(fl, name);
  if (!v) fail(2, "usage", hint ?? `--${name} is required.`);
  return v;
}

function num(fl: Flags, name: string, min: number, max: number): number | undefined {
  const v = str(fl, name);
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || n < min || n > max) fail(2, "usage", `--${name} must be a number from ${min} to ${max}.`);
  return n;
}

function list(fl: Flags, name: string): string[] | undefined {
  const v = str(fl, name);
  return v === undefined ? undefined : v.split(",").map((s) => s.trim()).filter(Boolean);
}

export function sha256(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

function slugify(text: string): string {
  const s = text.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 63);
  return /^[a-z0-9]/.test(s) ? s : `m-${s}`.slice(0, 63);
}

const SLUG = /^[a-z0-9][a-z0-9-]{0,62}$/;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// --- booking.yaml editing ----------------------------------------------------

function loadDoc(file: string): Document {
  const doc = parseDocument(readFileSync(file, "utf8"));
  if (doc.errors.length) fail(1, "yaml-syntax", `${file} is not valid YAML. Run validate to see where.`);
  return doc;
}

/** Write the document only when the result still passes the checker. */
function saveChecked(file: string, doc: Document): BookingConfig {
  const text = doc.toString();
  const checked = checkBookingYaml(text);
  if (!checked.ok || !checked.config) {
    fail(1, "invalid-change", "That change would leave booking.yaml with problems, so the file was not changed.", { errors: checked.errors });
  }
  writeFileSync(file, text);
  return checked.config;
}

function hq(args: string[], input?: string): { status: number; stdout: string } {
  const r = spawnSync("hq", args, { input, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
  return { status: r.error ? 127 : (r.status ?? 1), stdout: r.stdout ?? "" };
}

function storeOwnerKey(company: string, key: string): void {
  // The key goes to the vault on stdin; hq's own output is not passed on.
  const r = hq(["secrets", "--company", company, "set", OWNER_SECRET, "--from-stdin"], key);
  if (r.status !== 0) {
    fail(1, "vault-write-failed", `Could not save the owner key in the HQ vault for ${company}. Check that you are signed in (/hq-login) and can write company secrets, then run setup again.`);
  }
}

function cmdSetup(fl: Flags): Json {
  const file = need(fl, "file");
  const company = need(fl, "company");
  const created = !existsSync(file);
  if (created) {
    const example = need(fl, "example", "No booking.yaml yet; pass --from <example>.");
    const doc = parseDocument(readFileSync(example, "utf8"));
    doc.set("company", company);
    writeFileSync(file, doc.toString());
  }
  const doc = loadDoc(file);
  if (doc.get("company") !== company) fail(1, "other-company", `booking.yaml says company "${String(doc.get("company"))}", but this session is bound to ${company}.`);

  const oldHash = doc.getIn(["prototype", "ownerKeySha256"]);
  let key: string | null = null;
  let ownerKey: "created" | "rotated" | "kept" | "rehashed";
  const envKey = process.env[OWNER_SECRET];
  if (fl.f.has("key-in-env") && envKey && !fl.f.has("rotate")) {
    const h = sha256(envKey);
    ownerKey = h === oldHash ? "kept" : "rehashed";
    doc.setIn(["prototype", "ownerKeySha256"], h);
  } else {
    key = randomBytes(32).toString("base64url");
    ownerKey = fl.f.has("rotate") ? "rotated" : "created";
    doc.setIn(["prototype", "ownerKeySha256"], sha256(key));
  }
  doc.setIn(["prototype", "provider"], "sandbox");
  const name = str(fl, "company-name");
  if (name) doc.setIn(["prototype", "companyName"], name);

  const text = doc.toString();
  const checked = checkBookingYaml(text);
  // Save the key in the vault before the file names its hash, so a failed vault
  // write never leaves an app nobody can sign in to.
  if (key) storeOwnerKey(company, key);
  key = null;
  writeFileSync(file, text);
  const cfg = checked.config;
  return {
    ok: true,
    company,
    file,
    created,
    ownerKey,
    ownerKeySecret: `${OWNER_SECRET} in the ${company} vault`,
    provider: "sandbox",
    valid: checked.ok,
    ...(checked.ok ? {} : { errors: checked.errors }),
    hosts: cfg ? cfg.hosts.map((h) => ({ id: h.id, name: h.name, email: h.email })) : [],
    eventTypes: cfg ? cfg.eventTypes.map((e) => ({ id: e.id, title: e.title, kind: e.kind })) : [],
    next: [
      created ? "Replace the example hosts with your team: hosts add --email <member email>." : "Review hosts and event types.",
      "Build the app: hq-booking.sh build",
      "Deploy it: hq-booking.sh deploy (password-protected by default)",
    ],
  };
}

// --- hosts ---------------------------------------------------------------------

type MemberCheck = "member" | "not-member" | "unavailable";

function memberCheck(company: string, email: string): MemberCheck {
  const r = hq(["members", "--company", company, "list"]);
  if (r.status !== 0 || !r.stdout.trim()) return "unavailable";
  const needle = email.toLowerCase();
  return r.stdout.toLowerCase().split(/[\s,;"'<>()[\]{}|]+/).includes(needle) ? "member" : "not-member";
}

function seqItems(doc: Document, path: (string | number)[]): unknown[] {
  const node = doc.getIn(path, true);
  return isSeq(node) ? node.items : [];
}

function hostRows(doc: Document): { id: string; name: string; email: string }[] {
  return seqItems(doc, ["hosts"]).map((n) => {
    const m = isMap(n) ? n : null;
    return { id: String(m?.get("id") ?? ""), name: String(m?.get("name") ?? ""), email: String(m?.get("email") ?? "") };
  });
}

function eventHosts(doc: Document): { id: string; kind: string; hosts: string[] }[] {
  return seqItems(doc, ["eventTypes"]).map((n) => {
    const m = isMap(n) ? n : null;
    const hs = m?.get("hosts", true);
    return { id: String(m?.get("id") ?? ""), kind: String(m?.get("kind") ?? ""), hosts: isSeq(hs) ? hs.items.map((x) => String((x as { value?: unknown }).value ?? x)) : [] };
  });
}

function cmdHosts(fl: Flags): Json {
  const file = need(fl, "file");
  const company = need(fl, "company");
  const sub = fl.pos[0];
  const doc = loadDoc(file);
  if (sub === "list") {
    const events = eventHosts(doc);
    return {
      ok: true,
      company,
      hosts: hostRows(doc).map((h) => ({ ...h, eventTypes: events.filter((e) => e.hosts.includes(h.id)).map((e) => e.id), bookingReady: true, sandbox: true })),
    };
  }
  if (sub === "add") {
    const email = need(fl, "email", "hosts add needs --email <member email>.").trim();
    if (!EMAIL.test(email)) fail(2, "usage", `${email} is not an email address.`);
    if (hostRows(doc).some((h) => h.email.toLowerCase() === email.toLowerCase())) fail(1, "already-host", `${email} is already a host.`);
    const check = memberCheck(company, email);
    if (check === "not-member") {
      fail(1, "not-a-member", `${email} is not a member of ${company}, so they cannot be a host. Invite them first with /new-hire or hq members invite.`);
    }
    const id = str(fl, "id") ?? slugify(email.split("@")[0] as string);
    if (!SLUG.test(id)) fail(2, "usage", `--id ${id} must be lowercase letters, digits and hyphens.`);
    if (hostRows(doc).some((h) => h.id === id)) fail(1, "duplicate-id", `There is already a host with id ${id}. Pass --id to choose another.`);
    const name = str(fl, "name") ?? (email.split("@")[0] as string).replace(/[._-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
    const host: Json = { id, name, email };
    const tz = str(fl, "timezone");
    if (tz) host.timezone = tz;
    else if (!doc.get("timezone")) {
      const first = seqItems(doc, ["hosts"])[0];
      const ftz = isMap(first) ? first.get("timezone") : undefined;
      if (ftz) host.timezone = String(ftz);
    }
    const days = list(fl, "days") ?? ["mon", "tue", "wed", "thu", "fri"];
    const hours = str(fl, "hours") ?? "09:00-17:00";
    host.hours = Object.fromEntries(days.map((d) => [d, [hours]]));
    doc.addIn(["hosts"], doc.createNode(host));
    const events = list(fl, "event-types") ?? [];
    const all = eventHosts(doc);
    for (const ev of events) {
      const i = all.findIndex((e) => e.id === ev);
      if (i < 0) fail(1, "unknown-event-type", `There is no event type ${ev}.`);
      doc.addIn(["eventTypes", i, "hosts"], id);
    }
    saveChecked(file, doc);
    return {
      ok: true,
      company,
      added: { id, name, email, eventTypes: events },
      membership: check === "member" ? "checked" : "unavailable",
      ...(check === "unavailable" ? { membershipNote: `Could not check ${company}'s member list (hq members list is unavailable or returned nothing). Make sure ${email} is a member.` } : {}),
      bookingReady: true,
      sandbox: true,
      realFlow: `In the real version the host must connect a calendar first: HQ sends ${email} a DM with a connect link, and they are left out of open times until they connect. In the sandbox they are booking ready at once and no DM is sent.`,
      next: "Rebuild and redeploy to put the change live.",
    };
  }
  if (sub === "remove") {
    const id = fl.pos[1] ?? str(fl, "id");
    if (!id) fail(2, "usage", "hosts remove needs a host id.");
    const idx = hostRows(doc).findIndex((h) => h.id === id || h.email.toLowerCase() === id.toLowerCase());
    if (idx < 0) fail(1, "unknown-host", `There is no host ${id}.`);
    const hostId = hostRows(doc)[idx]?.id as string;
    const touched: string[] = [];
    eventHosts(doc).forEach((e, i) => {
      const j = e.hosts.indexOf(hostId);
      if (j >= 0) {
        doc.deleteIn(["eventTypes", i, "hosts", j]);
        touched.push(e.id);
      }
    });
    seqItems(doc, ["routing"]).forEach((_, fi) => {
      seqItems(doc, ["routing", fi, "rules"]).forEach((_r, ri) => {
        const hs = seqItems(doc, ["routing", fi, "rules", ri, "target", "hosts"]);
        const j = hs.findIndex((x) => String((x as { value?: unknown }).value ?? x) === hostId);
        if (j >= 0) doc.deleteIn(["routing", fi, "rules", ri, "target", "hosts", j]);
      });
    });
    doc.deleteIn(["hosts", idx]);
    saveChecked(file, doc);
    return {
      ok: true,
      company,
      removed: hostId,
      eventTypes: touched,
      note: "New bookings will not be assigned to this host once you redeploy. Existing bookings stay in place; cancel or reschedule them with owner commands if needed.",
    };
  }
  fail(2, "usage", "Use hosts list, hosts add --email <email>, or hosts remove <id>.");
}

// --- HTTP clients -------------------------------------------------------------

function isLoopback(u: URL): boolean {
  return u.hostname === "127.0.0.1" || u.hostname === "localhost" || u.hostname === "[::1]";
}

/** Base URL for owner calls: --url (loopback, or the deployed app) or deploy.json. */
function ownerBase(fl: Flags): string {
  const dj = need(fl, "deploy-json");
  const given = str(fl, "url");
  const rec = existsSync(dj) ? (JSON.parse(readFileSync(dj, "utf8")) as Json) : null;
  const deployed = typeof rec?.url === "string" ? rec.url : null;
  if (!given) {
    if (!deployed) fail(1, "not-deployed", "This company's booking app is not deployed yet. Deploy it, or pass --url http://127.0.0.1:<port> for a local dev server.");
    return new URL(deployed).origin;
  }
  let u: URL;
  try {
    u = new URL(given);
  } catch {
    fail(2, "usage", `--url ${given} is not a URL.`);
  }
  if (isLoopback(u)) return u.origin;
  if (deployed && new URL(deployed).origin === u.origin) return u.origin;
  fail(1, "other-app", "The owner key only goes to this company's own booking app (the one in deploy.json) or a local dev server. That URL is neither.");
}

function baseOf(fl: Flags): string {
  const b = need(fl, "base");
  const u = new URL(b);
  if (u.protocol !== "https:" && !isLoopback(u)) fail(1, "insecure-url", "Keys are only sent over HTTPS (or to a local dev server).");
  return u.origin;
}

async function call(base: string, key: string | null, method: string, path: string, body?: unknown): Promise<{ status: number; json: Json }> {
  let r: Response;
  try {
    r = await fetch(base + path, {
      method,
      headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), ...(body === undefined ? {} : { "content-type": "application/json" }), accept: "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    fail(1, "unreachable", `Could not reach the booking app at ${base}.`);
  }
  const text = await r.text();
  let json: Json = {};
  try {
    json = text ? (JSON.parse(text) as Json) : {};
  } catch {
    json = {};
  }
  if (r.status >= 400) {
    const e = (json.error ?? {}) as Json;
    fail(1, String(e.code ?? `http-${r.status}`), String(e.message ?? `The booking app answered ${r.status}.`), { status: r.status, ...(e.details ? { details: e.details } : {}) });
  }
  return { status: r.status, json };
}

function qs(params: Record<string, string | number | undefined>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== "") q.set(k, String(v));
  const s = q.toString();
  return s ? `?${s}` : "";
}

function isoArg(fl: Flags, name: string): string | undefined {
  const v = str(fl, name);
  if (v === undefined) return undefined;
  const t = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(v) ? `${v}T00:00:00Z` : v);
  if (Number.isNaN(t)) fail(2, "usage", `--${name} must be a date or ISO date-time, such as 2026-11-02 or 2026-11-02T15:00:00Z.`);
  return new Date(t).toISOString();
}

function dayLabel(iso: string, tz: string): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "long", month: "long", day: "numeric" }).format(new Date(iso));
}

function timeLabel(iso: string, tz: string, h12: boolean): string {
  // ICU puts a narrow no-break space before AM/PM; plain text email wants a space.
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit", hour12: h12 }).format(new Date(iso)).replace(/[  ]/g, " ");
}

function tzName(tz: string): string {
  const part = new Intl.DateTimeFormat("en-US", { timeZone: tz, timeZoneName: "long" }).formatToParts(new Date()).find((p) => p.type === "timeZoneName");
  return part ? `${part.value} (${tz})` : tz;
}

function checkTz(tz: string): string {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
  } catch {
    fail(2, "usage", `--tz ${tz} is not a time zone. Use a name such as Europe/London.`);
  }
  return tz;
}

/** Pick up to n items spread across a day's list. */
function spread<T>(items: T[], n: number): T[] {
  if (items.length <= n) return items;
  if (n === 1) return [items[0] as T];
  return Array.from({ length: n }, (_, i) => items[Math.round((i * (items.length - 1)) / (n - 1))] as T);
}

export function timesSnippet(o: {
  title: string;
  duration: number;
  tz: string;
  slots: { start: string }[];
  days: number;
  maxDays: number;
  perDay: number;
  h12: boolean;
  link: string | null;
}): { text: string; times: { day: string; times: string[]; starts: string[] }[] } {
  const byDay = new Map<string, string[]>();
  for (const s of o.slots) {
    const d = dayLabel(s.start, o.tz);
    const arr = byDay.get(d) ?? [];
    arr.push(s.start);
    byDay.set(d, arr);
  }
  const times = [...byDay.entries()].slice(0, o.maxDays).map(([day, starts]) => {
    const picked = spread(starts, o.perDay);
    return { day, starts: picked, times: picked.map((s) => timeLabel(s, o.tz, o.h12)) };
  });
  const lines: string[] = [];
  if (!times.length) {
    lines.push(`There are no open times for a ${o.duration}-minute ${o.title} in the next ${o.days} days.`);
    if (o.link) lines.push("", `You can check for new times here: ${o.link}`);
  } else {
    lines.push(`Here are some times that work for a ${o.duration}-minute ${o.title} (times are ${tzName(o.tz)}):`, "");
    for (const t of times) lines.push(`- ${t.day}: ${t.times.join(", ")}`);
    lines.push("");
    lines.push(o.link ? `Pick one of these, or any other open time, here: ${o.link}` : "Reply with the time that suits you and I will send an invite.");
  }
  return { text: lines.join("\n"), times };
}

type OwnerBooking = {
  id: string;
  status: string;
  start: string;
  eventType?: { id?: string; title?: string };
  invitee?: { name?: string; email?: string } | null;
  hosts?: { name?: string }[];
  noShow?: boolean;
  bookedBy?: string | null;
  createdBy?: string;
};

function bookingLine(b: OwnerBooking, tz: string): string {
  const who = b.invitee ? `${b.invitee.name ?? "?"} <${b.invitee.email ?? "?"}>` : "Deleted invitee";
  const hosts = (b.hosts ?? []).map((h) => h.name).filter(Boolean).join(", ");
  return [
    `${dayLabel(b.start, tz)} ${timeLabel(b.start, tz, true)}`,
    b.eventType?.title ?? b.eventType?.id ?? "?",
    who,
    hosts ? `with ${hosts}` : "",
    b.status + (b.noShow ? ", no-show" : ""),
    b.bookedBy ? `booked by ${b.bookedBy}` : "",
  ].filter(Boolean).join(" | ");
}

async function cmdOwner(fl: Flags): Promise<Json> {
  const base = ownerBase(fl);
  const key = process.env[OWNER_SECRET];
  if (!key) fail(2, "no-owner-key", "The owner key was not available. Run setup first.");
  const sub = fl.pos[0];
  const id = fl.pos[1];
  const needId = (what: string): string => {
    if (!id) fail(2, "usage", `owner ${sub} needs the ${what} id.`);
    return encodeURIComponent(id);
  };
  const ok = (json: Json): Json => ({ ok: true, base, ...json });
  const go = async (method: string, path: string, body?: unknown) => (await call(base, key, method, path, body)).json;
  switch (sub) {
    case "session":
      return ok(await go("GET", "/api/owner/session"));
    case "bookings": {
      let from = isoArg(fl, "from");
      let to = isoArg(fl, "to");
      const days = num(fl, "days", 1, 366);
      if (days !== undefined && !from) {
        from = new Date().toISOString();
        to = to ?? new Date(Date.now() + days * 86_400_000).toISOString();
      }
      const res = await go("GET", `/api/owner/bookings${qs({ from, to, status: str(fl, "status"), eventType: str(fl, "event"), host: str(fl, "host"), email: str(fl, "email"), createdBy: str(fl, "created-by"), order: "asc", limit: num(fl, "limit", 1, 200) ?? 100 })}`);
      const tz = str(fl, "tz") ? checkTz(str(fl, "tz") as string) : String((await go("GET", "/api/config/public")).timezone ?? "UTC");
      const bookings = (res.bookings ?? []) as OwnerBooking[];
      return ok({ total: res.total, timezone: tz, lines: bookings.map((b) => bookingLine(b, tz)), bookings });
    }
    case "booking":
      return ok(await go("GET", `/api/owner/bookings/${needId("booking")}`));
    case "cancel":
      return ok(await go("POST", `/api/owner/bookings/${needId("booking")}/cancel`, { ...(str(fl, "reason") ? { reason: str(fl, "reason") } : {}) }));
    case "reschedule": {
      const path = `/api/owner/bookings/${needId("booking")}/reschedule`;
      const start = isoArg(fl, "start") ?? fail(2, "usage", "owner reschedule needs --start <ISO time>.");
      return ok(await go("POST", path, { start, ...(str(fl, "reason") ? { reason: str(fl, "reason") } : {}) }));
    }
    case "no-show":
      return ok(await go("POST", `/api/owner/bookings/${needId("booking")}/no-show`, { noShow: !fl.f.has("undo") }));
    case "link": {
      const eventType = need(fl, "event", "owner link needs --event <event type id>.");
      const res = await go("POST", "/api/owner/links", { eventType, singleUse: !fl.f.has("reusable"), ...(num(fl, "expires", 1, 8760) ? { expiresInHours: num(fl, "expires", 1, 8760) } : {}) });
      return ok({ url: `${base}${String(res.path)}`, link: res.link, note: "Share this link once; it is not shown again." });
    }
    case "links":
      return ok(await go("GET", "/api/owner/links"));
    case "times": {
      const eventType = need(fl, "event", "owner times needs --event <event type id>.");
      const ev = (await go("GET", `/api/event-types/${encodeURIComponent(eventType)}`)).eventType as Json;
      const tz = checkTz(str(fl, "tz") ?? String(ev.timezone ?? "UTC"));
      const days = num(fl, "days", 1, 62) ?? 7;
      const duration = num(fl, "duration", 5, 1440) ?? Number(ev.defaultDuration ?? (ev.durations as number[] | undefined)?.[0] ?? 30);
      const from = new Date().toISOString();
      const to = new Date(Date.now() + days * 86_400_000).toISOString();
      const res = await go("GET", `/api/slots${qs({ eventType, duration, from, to, tz })}`);
      let link: string | null = ev.secret ? null : `${base}/${encodeURIComponent(eventType)}`;
      if (fl.f.has("link")) {
        const l = await go("POST", "/api/owner/links", { eventType, singleUse: true, expiresInHours: days * 24 });
        link = `${base}${String(l.path)}`;
      }
      const snip = timesSnippet({ title: String(ev.title ?? eventType), duration, tz, slots: (res.slots ?? []) as { start: string }[], days, maxDays: num(fl, "max-days", 1, 14) ?? 3, perDay: num(fl, "per-day", 1, 12) ?? 4, h12: !fl.f.has("h24"), link });
      return ok({ eventType, duration, timezone: tz, snippet: snip.text, times: snip.times });
    }
    case "analytics":
      return ok(await go("GET", `/api/owner/analytics${qs({ from: isoArg(fl, "from"), to: isoArg(fl, "to") })}`));
    case "outbox": {
      const res = await go("GET", `/api/owner/outbox${qs({ bookingId: str(fl, "booking") })}`);
      const emails = ((res.emails ?? []) as Json[]).map((e) => ({ id: e.id, bookingId: e.bookingId, kind: e.kind, to: e.to, subject: e.subject, createdAt: e.createdAt, ...(fl.f.has("plain") ? { text: e.text } : {}) }));
      return ok({ sandbox: res.sandbox, note: "Sandbox: these emails are stored in the app, not sent.", emails });
    }
    case "notifications":
      return ok(await go("GET", `/api/owner/notifications${qs({ recipient: str(fl, "recipient"), kind: str(fl, "kind") })}`));
    case "approvals":
      return ok(await go("GET", `/api/owner/approvals${qs({ status: str(fl, "status") ?? "pending" })}`));
    case "approve":
      return ok(await go("POST", `/api/owner/approvals/${needId("approval")}/approve`, {}));
    case "decline":
      return ok(await go("POST", `/api/owner/approvals/${needId("approval")}/decline`, { ...(str(fl, "reason") ? { reason: str(fl, "reason") } : {}) }));
    case "agents": {
      const keys = (await go("GET", "/api/owner/agent-keys")).agentKeys as Json[];
      const dels = (await go("GET", "/api/owner/delegations")).delegations as Json[];
      return ok({ agentKeys: keys.map((k) => ({ ...k, delegation: dels.find((d) => d.memberId === k.memberId) ?? null })) });
    }
    case "agent-key": {
      const email = need(fl, "member", "owner agent-key needs --member <email>.");
      if (!EMAIL.test(email)) fail(2, "usage", `${email} is not an email address.`);
      const memberId = str(fl, "member-id") ?? slugify(email.split("@")[0] as string);
      const memberName = str(fl, "name") ?? (email.split("@")[0] as string);
      const limits: Json = {};
      const set = (k: string, v: unknown) => {
        if (v !== undefined) limits[k] = v;
      };
      set("eventTypes", list(fl, "event-types"));
      set("maxDuration", num(fl, "max-duration", 5, 1440));
      set("maxPerWeek", num(fl, "max-per-week", 1, 100));
      set("hours", str(fl, "hours"));
      set("days", list(fl, "days"));
      set("timezone", str(fl, "timezone") ? checkTz(str(fl, "timezone") as string) : undefined);
      set("companies", list(fl, "companies"));
      const created = await go("POST", "/api/owner/agent-keys", { memberId, memberName, memberEmail: email, ...(str(fl, "member-company") ? { memberCompany: str(fl, "member-company") } : {}), ...(str(fl, "label") ? { label: str(fl, "label") } : {}) });
      const delegation = (await go("PUT", `/api/owner/delegations/${encodeURIComponent(memberId)}`, { enabled: true, ...(Object.keys(limits).length ? { limits } : {}) })).delegation;
      return ok({
        agentKey: created.agentKey,
        key: created.key,
        delegation,
        note: `This key is shown once. Give it to ${email} privately; they store it in their own HQ vault (hq secrets set <NAME>). It lets their agent book for them within these limits.`,
      });
    }
    case "revoke-agent":
      return ok(await go("POST", `/api/owner/agent-keys/${needId("agent key")}/revoke`, {}));
    case "delegation": {
      const memberId = needId("member");
      // Keep the member's limits when pausing or resuming.
      const dels = ((await go("GET", "/api/owner/delegations")).delegations ?? []) as Json[];
      const limits = dels.find((d) => d.memberId === id)?.limits;
      return ok(await go("PUT", `/api/owner/delegations/${memberId}`, { enabled: !fl.f.has("undo"), ...(limits ? { limits } : {}) }));
    }
    case "webhooks":
      return ok(await go("GET", "/api/owner/webhooks"));
    case "webhook-deliveries":
      return ok(await go("GET", `/api/owner/webhook-deliveries${qs({ status: str(fl, "status") })}`));
    case "audit":
      return ok(await go("GET", `/api/owner/audit${qs({ bookingId: str(fl, "booking"), memberId: str(fl, "member"), action: str(fl, "action") })}`));
    case "delete-invitee": {
      const email = need(fl, "email", "owner delete-invitee needs --email <invitee email>.");
      return ok(await go("POST", "/api/owner/invitee-data/delete", { email }));
    }
    case "jobs-run":
      return ok(await go("POST", "/api/owner/jobs/run", {}));
    default:
      fail(2, "usage", "Unknown owner command. Use bookings, booking, cancel, reschedule, no-show, link, links, times, analytics, outbox, notifications, approvals, approve, decline, agents, agent-key, revoke-agent, delegation, webhooks, webhook-deliveries, audit, delete-invitee or jobs-run.");
  }
}

async function cmdAgent(fl: Flags): Promise<Json> {
  const base = baseOf(fl);
  const envName = need(fl, "key-env");
  const key = process.env[envName];
  if (!key) fail(2, "no-agent-key", `The agent key ${envName} was not available in this company's vault.`);
  const sub = fl.pos[0];
  const eventType = str(fl, "event");
  const ok = (json: Json): Json => ({ ok: true, base, ...json });
  switch (sub) {
    case "event-types":
      return ok((await call(base, key, "GET", "/api/agent/event-types")).json);
    case "times": {
      if (!eventType) fail(2, "usage", "agent times needs an event type: agent times <company>/<event>.");
      const tz = checkTz(str(fl, "tz") ?? "UTC");
      const res = (await call(base, key, "GET", `/api/agent/offers${qs({ eventType, duration: num(fl, "duration", 5, 1440), from: isoArg(fl, "from"), to: isoArg(fl, "to") })}`)).json;
      const offers = (res.offers ?? []) as { start: string }[];
      const snip = timesSnippet({ title: eventType, duration: Number(res.duration ?? 30), tz, slots: offers, days: 14, maxDays: 14, perDay: 4, h12: !fl.f.has("h24"), link: null });
      return ok({ eventType, mode: res.mode, duration: res.duration, coarse: res.coarse, offers, snippet: snip.text });
    }
    case "book": {
      if (!eventType) fail(2, "usage", "agent book needs an event type: agent book <company>/<event> --start <ISO>.");
      const start = isoArg(fl, "start") ?? fail(2, "usage", "agent book needs --start <ISO time> (one of the offered times).");
      const r = await call(base, key, "POST", "/api/agent/bookings", {
        eventType,
        start,
        ...(num(fl, "duration", 5, 1440) ? { duration: num(fl, "duration", 5, 1440) } : {}),
        ...(str(fl, "topic") ? { topic: str(fl, "topic") } : {}),
        ...(str(fl, "notes") ? { notes: str(fl, "notes") } : {}),
      });
      const status = String(r.json.status ?? "");
      const message =
        status === "booked"
          ? "Booked."
          : status === "pending-approval"
            ? "The host approves agent bookings from outside their company first. The time is held for 24 hours while they decide."
            : status === "needs-member-approval"
              ? "That request is outside the limits your member set, so nothing was booked. They have been asked."
              : String(r.json.message ?? "");
      return ok({ ...r.json, message: r.json.message ?? message });
    }
    case "bookings":
      return ok((await call(base, key, "GET", "/api/agent/bookings")).json);
    case "cancel": {
      const id = fl.pos[1] ?? fail(2, "usage", "agent cancel needs the booking id.");
      return ok((await call(base, key, "POST", `/api/agent/bookings/${encodeURIComponent(id)}/cancel`, { ...(str(fl, "reason") ? { reason: str(fl, "reason") } : {}) })).json);
    }
    case "reschedule": {
      const id = fl.pos[1] ?? fail(2, "usage", "agent reschedule needs the booking id.");
      const start = isoArg(fl, "start") ?? fail(2, "usage", "agent reschedule needs --start <ISO time>.");
      return ok((await call(base, key, "POST", `/api/agent/bookings/${encodeURIComponent(id)}/reschedule`, { start })).json);
    }
    default:
      fail(2, "usage", "Use agent event-types, times, book, bookings, cancel or reschedule.");
  }
}

// --- deploy -------------------------------------------------------------------

type Run = { status: number; stdout: string; stderr: string };

function run(cmd: string, args: string[], opts: { cwd: string; env?: Record<string, string> }): Run {
  const r = spawnSync(cmd, args, { cwd: opts.cwd, encoding: "utf8", env: { ...process.env, ...(opts.env ?? {}) }, maxBuffer: 32 * 1024 * 1024 });
  return { status: r.error ? 127 : (r.status ?? 1), stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function lastJson(text: string): Json | null {
  const line = text.trim().split("\n").reverse().find((l) => l.trim().startsWith("{"));
  if (!line) return null;
  try {
    return JSON.parse(line) as Json;
  } catch {
    return null;
  }
}

async function cmdDeploy(fl: Flags): Promise<Json> {
  const company = need(fl, "company");
  const root = need(fl, "root");
  const file = need(fl, "file");
  const stageDir = need(fl, "stage");
  const metaPath = need(fl, "build-meta");
  const deployJson = need(fl, "deploy-json");
  const scripts = need(fl, "scripts");
  const access = str(fl, "access") ?? "password";
  if (!["password", "company", "public"].includes(access)) fail(2, "usage", "--access must be password, company or public.");
  const givenPw = str(fl, "password");
  if (givenPw !== undefined && access !== "password") fail(2, "usage", "--password only goes with --access password.");
  if (givenPw !== undefined && givenPw.length < 8) fail(2, "usage", "The password must be at least 8 characters.");

  const yamlText = readFileSync(file, "utf8");
  const checked = checkBookingYaml(yamlText);
  if (!checked.ok || !checked.config) fail(1, "invalid-config", "booking.yaml has problems. Run validate and fix them first.", { errors: checked.errors });
  const cfg = checked.config;
  if (!cfg.prototype?.ownerKeySha256) fail(1, "no-owner-key", "booking.yaml has no owner key yet. Run setup first.");
  if (!existsSync(metaPath) || !existsSync(`${stageDir}/api`)) fail(1, "not-built", "There is no build to deploy. Run build first.");
  const meta = JSON.parse(readFileSync(metaPath, "utf8")) as Json;
  if (meta.configSha256 !== sha256(yamlText)) fail(1, "build-stale", "booking.yaml changed after the last build. Run build again, then deploy.");
  if (!existsSync(`${stageDir}/dist/index.html`)) fail(1, "no-pages", "The build has no booking pages (dist/index.html). Run build again.");

  const appName = cfg.prototype.appName ?? `booking-${company}`;
  const tools = ["identity-resolve.sh", "deploy-api-request.sh", "resolve-deploy-api.sh", "guardrails-check.sh", "password-helper.sh"];
  for (const t of tools) if (!existsSync(`${scripts}/${t}`)) fail(2, "deploy-skill-missing", `The /deploy skill's ${t} was not found in ${scripts}. Update HQ (/update-hq) and try again.`);
  const sh = (t: string) => `${scripts}/${t}`;

  const api = run("bash", [sh("resolve-deploy-api.sh")], { cwd: root }).stdout.trim();
  if (!api) fail(2, "no-deploy-api", "Could not work out the hq-deploy address.");
  const ident = lastJson(run("bash", [sh("identity-resolve.sh")], { cwd: root }).stdout);
  if (!ident || ident.status !== "ok" || typeof ident.jwt !== "string") {
    fail(1, "login-required", "Sign in to HQ first (/hq-login), then deploy again.", { reason: ident?.reason ?? ident?.status ?? "unknown" });
  }
  const jwt = ident.jwt as string;
  const idToken = typeof ident.id_token === "string" ? ident.id_token : "";

  const guard = lastJson(run("bash", [sh("guardrails-check.sh"), `${stageDir}/dist`, `${stageDir}/api`], { cwd: stageDir }).stdout);
  if (!guard || guard.pass !== true) fail(1, "guardrails", `The build did not pass the deploy checks (${String(guard?.reason ?? "no answer")}).`, { maxFiles: MAX_FILES });
  const tarball = String(guard.tarball_path);

  const requests: string[] = [];
  const req = (stage: string, method: string, path: string, extra: string[], expect?: string): Json => {
    requests.push(`${method} ${path}`);
    const args = [sh("deploy-api-request.sh"), "--stage", stage, "--org", company, "--scope", "company", "--header", `X-Org-Slug: ${company}`, "--method", method, "--url", `${api}${path}`, ...extra, ...(expect ? ["--expect", expect] : [])];
    const r = run("bash", args, { cwd: root, env: { HQ_DEPLOY_JWT: jwt } });
    if (r.status !== 0) {
      const diag = r.stderr.split("\n").filter((l) => l.startsWith("[deploy]")).pop() ?? "";
      const code = /api_code=(\S+)/.exec(diag)?.[1] ?? "request-failed";
      if (code === "DATABASE_BILLING_ACK_REQUIRED") fail(1, "database-billing-ack-required", `${DB_TERMS} Run deploy again with --accept-database-billing to agree.`);
      fail(1, "deploy-failed", `hq-deploy refused the ${stage} step.`, { diagnostic: diag, requests });
    }
    try {
      return JSON.parse(r.stdout || "{}") as Json;
    } catch {
      return {};
    }
  };
  const json = (body: unknown) => ["--header", "Content-Type: application/json", "--data", JSON.stringify(body)];

  try {
    const apps = (req("app-list", "GET", "/api/apps", [], '.apps | type == "array"').apps ?? []) as Json[];
    let app = apps.find((a) => a.name === appName) ?? null;
    const exempt = (process.env.HQ_DB_BILLING_EXEMPT_ORGS ?? "indigo").split(",").map((s) => s.trim()).includes(company);
    const accepted = fl.f.has("accept-database-billing");
    if (!app && !exempt && !accepted) {
      fail(1, "database-billing-ack-required", `${DB_TERMS} HQ Booking needs the database. Run deploy again with --accept-database-billing to agree.`, { terms: DB_TERMS });
    }
    if (!app) app = req("app-creation", "POST", "/api/apps", json({ name: appName, type: "app" }), '(.id | type == "string" and length > 0)');
    const appId = String(app.id);
    const appJson = req("app-read", "GET", `/api/apps/${encodeURIComponent(appId)}`, [], 'type == "object"');
    const subdomain = String(appJson.subdomain ?? app.subdomain ?? appName);
    const hasDb = appJson.database === true;
    let dbAck = false;
    if (!hasDb) {
      if (!exempt && !accepted) fail(1, "database-billing-ack-required", `${DB_TERMS} Run deploy again with --accept-database-billing to agree.`, { terms: DB_TERMS });
      req("db-enable", "PATCH", `/api/apps/${encodeURIComponent(appId)}`, json({ database: true, databaseBillingAcknowledged: true }));
      dbAck = true;
    }

    // Set the gate before the upload so the pages are never live without it.
    let password: string | null = null;
    const current = String(appJson.accessMode ?? "public");
    if (access === "password") {
      if (givenPw !== undefined || current !== "password") {
        password = givenPw ?? run("bash", [sh("password-helper.sh"), "gen"], { cwd: root }).stdout.trim();
        if (password.length < 8) fail(1, "password-failed", "Could not make a password for the booking app.");
        req("access-mode-password", "POST", `/api/apps/${encodeURIComponent(appId)}/access-mode`, json({ mode: "password", password }));
        run("bash", [sh("password-helper.sh"), "persist", subdomain, password, "hq-booking-sandbox"], { cwd: root });
      }
    } else if (access === "company") {
      const vault = process.env.VAULT_API_URL ?? "https://4nfy67z28h.execute-api.us-east-1.amazonaws.com";
      let companyUid = "";
      try {
        const r = await fetch(`${vault}/entity/by-slug/company/${encodeURIComponent(company)}`, { headers: { authorization: `Bearer ${idToken || jwt}` }, signal: AbortSignal.timeout(15_000) });
        companyUid = r.ok ? String(((await r.json()) as { entity?: { uid?: string } }).entity?.uid ?? "") : "";
      } catch {
        companyUid = "";
      }
      if (!companyUid) fail(1, "company-gate-failed", `Could not look up ${company} to set company-only access, so nothing was uploaded. Sign in again (/hq-login) or deploy with --access password.`);
      req("access-policy-company", "PUT", `/api/apps/${encodeURIComponent(appId)}/access-policy`, [...(idToken ? ["--header", `X-HQ-Pro-Authorization: Bearer ${idToken}`] : []), ...json({ mode: "company", companyUid, users: [], groups: [] })]);
    } else if (current !== "public") {
      req("access-mode-public", "POST", `/api/apps/${encodeURIComponent(appId)}/access-mode`, json({ mode: "public" }));
    }

    const dep = req("app-deploy", "POST", `/api/apps/${encodeURIComponent(appId)}/deploy`, ["--form-string", "type=app", ...(dbAck || hasDb ? ["--form-string", "database_billing_acknowledged=true"] : []), "--form-file", `file=${tarball}`], '(.deployId | type == "string" and length > 0) and (.statusUrl | type == "string" and length > 0)');
    const url = `https://${subdomain}.${process.env.HQ_DEPLOY_DOMAIN ?? "indigo-hq.com"}`;
    let gate: number | null = null;
    try {
      gate = (await fetch(`${url}/`, { redirect: "manual", signal: AbortSignal.timeout(8_000) })).status;
    } catch {
      gate = null;
    }
    const record = { company, appName, appId, subdomain, url, access, deployId: dep.deployId, statusUrl: dep.statusUrl, database: true, provider: cfg.prototype.provider ?? "sandbox", deployedAt: new Date().toISOString(), api };
    writeFileSync(deployJson, `${JSON.stringify(record, null, 2)}\n`);
    return {
      ok: true,
      company,
      url,
      appName,
      appId,
      deployId: dep.deployId,
      statusUrl: dep.statusUrl,
      access,
      files: guard.file_count,
      ...(password && givenPw === undefined ? { password, passwordNote: "Share this password with the people who should see the pages. It is saved in ~/.hq/deploy-passwords.json." } : {}),
      ...(access === "password" && !password ? { passwordNote: `The existing password was kept. Look it up with: jq -r '."${subdomain}".password' ~/.hq/deploy-passwords.json` } : {}),
      ...(access === "public" ? { warning: "The pages are public: anyone with the link can book. Sandbox data is not meant for the public." } : {}),
      database: exempt ? "The database is free for this company." : hasDb ? "The app already has its database." : "Database added ($10 a month, accepted with --accept-database-billing).",
      gateCheck: gate === null ? "not reachable yet" : access === "public" ? `answered ${gate}` : gate === 302 ? "gated (302)" : `answered ${gate}; check the gate`,
      sandbox: (cfg.prototype.provider ?? "sandbox") === "sandbox",
      deployRecord: deployJson,
      requests,
      next: ["Run due reminders and webhooks every 5 minutes: see knowledge/booking/operations.md (/schedule).", "Check it: hq-booking.sh owner session"],
    };
  } finally {
    rmSync(tarball, { force: true });
  }
}

// --- dev server -----------------------------------------------------------------

async function cmdDevServe(fl: Flags): Promise<null> {
  const key = process.env[OWNER_SECRET];
  if (!key) fail(2, "no-owner-key", "The owner key was not available. Run setup first.");
  const { startDevServer } = await import("./server.ts");
  const s = await startDevServer({ configPath: need(fl, "config"), port: num(fl, "port", 0, 65535) ?? 5180, ownerKey: key });
  process.stdout.write(`${JSON.stringify({ ok: true, url: s.url, sandbox: true, store: "memory", note: "Local dev server with sandbox providers. Data lasts until it stops. Owner commands: --url " + s.url })}\n`);
  const stop = () => {
    s.close().then(() => process.exit(0));
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  return null;
}

// --- main -----------------------------------------------------------------------

async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv;
  try {
    const fl = parse(rest);
    let result: Json | null;
    switch (cmd) {
      case "setup":
        result = cmdSetup(fl);
        break;
      case "hosts":
        result = cmdHosts(fl);
        break;
      case "owner":
        result = await cmdOwner(fl);
        break;
      case "agent":
        result = await cmdAgent(fl);
        break;
      case "deploy":
        result = await cmdDeploy(fl);
        break;
      case "dev-serve":
        result = await cmdDevServe(fl);
        break;
      default:
        fail(2, "usage", `Unknown launcher command ${String(cmd)}.`);
    }
    if (result) process.stdout.write(`${JSON.stringify(result)}\n`);
    return 0;
  } catch (e) {
    if (e instanceof Exit) {
      process.stdout.write(`${JSON.stringify(e.body)}\n`);
      return e.code;
    }
    process.stdout.write(`${JSON.stringify({ ok: false, error: "internal", message: (e as Error).message })}\n`);
    return 2;
  }
}

if (process.argv[1] && /launcher\.ts$/.test(process.argv[1])) {
  main(process.argv.slice(2)).then((code) => {
    if (code !== 0 || process.argv[2] !== "dev-serve") process.exitCode = code;
  });
}
