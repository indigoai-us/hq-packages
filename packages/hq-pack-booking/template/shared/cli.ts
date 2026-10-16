// Command-line entry used by scripts/hq-booking.sh.
//
//   cli.ts validate <booking.yaml>
//   cli.ts slots <booking.yaml> --event <id> [--duration <min>] [--from <ISO>] [--days <n>]
//                [--now <ISO>] [--busy <busy.json>] [--bookings <bookings.json>] [--tz <zone>]
//
// Each prints one JSON object. Exit 0 ok, 1 the file has problems, 2 usage or I/O.
// busy.json is {"<hostId>": [{"start": ISO, "end": ISO}, ...]}; bookings.json is
// [{"eventTypeId", "hostIds", "start": ISO, "end": ISO, "seats"?}].

import { readFileSync } from "node:fs";
import { checkBookingYaml, type BookingConfig } from "./config.ts";
import { computeSlots, SlotQueryError, type ExistingBooking, type HostInput } from "./availability.ts";
import { pickHost, statsFor } from "./assignment.ts";
import { DAY, isValidTimeZone } from "./time.ts";

function out(value: unknown, code: number): never {
  process.stdout.write(`${JSON.stringify(value)}\n`);
  process.exit(code);
}

function usage(message: string): never {
  out({ ok: false, error: "usage", message }, 2);
}

function readText(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    out({ ok: false, error: "unreadable", message: `Could not read ${path}.` }, 2);
  }
}

function flags(args: string[]): Map<string, string> {
  const map = new Map<string, string>();
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string;
    if (!a.startsWith("--")) usage(`Unexpected argument ${a}.`);
    const value = args[i + 1];
    if (value === undefined || value.startsWith("--")) usage(`${a} needs a value.`);
    map.set(a.slice(2), value);
    i++;
  }
  return map;
}

function instant(value: string, name: string): number {
  const t = Date.parse(value);
  if (Number.isNaN(t)) usage(`--${name} must be an ISO date-time such as 2026-11-02T09:00:00Z.`);
  return t;
}

function load(path: string): BookingConfig {
  const result = checkBookingYaml(readText(path));
  if (!result.ok || !result.config) out({ ok: false, file: path, errors: result.errors }, 1);
  return result.config;
}

const [command, file, ...rest] = process.argv.slice(2);
if (!command || !file) usage("Use: validate <booking.yaml> | slots <booking.yaml> --event <id>");

if (command === "validate") {
  if (rest.length) usage("validate takes only the file path.");
  const result = checkBookingYaml(readText(file));
  if (!result.ok || !result.config) out({ ok: false, file, errors: result.errors }, 1);
  out({
    ok: true,
    file,
    company: result.config.company,
    hosts: result.config.hosts.length,
    eventTypes: result.config.eventTypes.map((e) => ({ id: e.id, kind: e.kind, hosts: e.hosts.length, secret: e.secret === true })),
  }, 0);
}

if (command === "slots") {
  const f = flags(rest);
  const cfg = load(file);
  const eventId = f.get("event") ?? usage("--event is required.");
  const ev = cfg.eventTypes.find((e) => e.id === eventId) ?? usage(`No event type "${eventId}".`);
  const duration = f.has("duration") ? Number(f.get("duration")) : (ev.defaultDuration ?? (ev.durations[0] as number));
  const now = f.has("now") ? instant(f.get("now") as string, "now") : Date.now();
  const from = f.has("from") ? instant(f.get("from") as string, "from") : now;
  const days = f.has("days") ? Number(f.get("days")) : 7;
  if (!Number.isFinite(days) || days <= 0 || days > 365) usage("--days must be between 1 and 365.");
  const tz = f.get("tz");
  if (tz && !isValidTimeZone(tz)) usage(`--tz "${tz}" is not a time zone this system knows.`);

  const busyRaw = f.has("busy") ? (JSON.parse(readText(f.get("busy") as string)) as Record<string, { start: string; end: string }[]>) : {};
  const bookingsRaw = f.has("bookings") ? (JSON.parse(readText(f.get("bookings") as string)) as (Omit<ExistingBooking, "start" | "end"> & { start: string; end: string })[]) : [];
  const bookings: ExistingBooking[] = bookingsRaw.map((b) => ({ ...b, start: Date.parse(b.start), end: Date.parse(b.end) }));

  const hosts: HostInput[] = cfg.hosts.map((h) => ({
    id: h.id,
    timezone: (h.timezone ?? cfg.timezone) as string,
    hours: h.hours,
    overrides: h.overrides,
    holidays: h.holidays,
    busy: (busyRaw[h.id] ?? []).map((b) => ({ start: Date.parse(b.start), end: Date.parse(b.end) })),
  }));

  try {
    const slots = computeSlots({ eventType: ev, duration, hosts, bookings, now, from, to: from + days * DAY });
    const stats = ev.kind === "round-robin" ? statsFor(ev.id, cfg.hosts, bookings) : [];
    const display = tz
      ? new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
      : null;
    out({
      ok: true,
      eventType: ev.id,
      kind: ev.kind,
      duration,
      count: slots.length,
      slots: slots.map((s) => ({
        start: new Date(s.start).toISOString(),
        end: new Date(s.end).toISOString(),
        ...(display ? { local: display.format(new Date(s.start)) } : {}),
        hosts: ev.kind === "round-robin" ? [pickHost(s.hostIds, stats)] : s.hostIds,
        ...(s.seatsLeft !== undefined ? { seatsLeft: s.seatsLeft } : {}),
      })),
    }, 0);
  } catch (err) {
    if (err instanceof SlotQueryError) usage(err.message);
    throw err;
  }
}

usage(`Unknown command ${command}.`);
