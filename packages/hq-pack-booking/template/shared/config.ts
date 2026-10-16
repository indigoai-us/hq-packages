// Load and check booking.yaml. Structure comes from booking.schema.json; the
// rules that span several fields (host references, event kinds, seats,
// routing targets) are here. Both run on every check, and every problem is
// reported with its path and a plain message.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { LineCounter, parseDocument } from "yaml";
import { SchemaChecker, joinPath, type Issue } from "./schema-check.ts";
import { isValidTimeZone, parseDate, parseRange, WEEKDAYS, type Weekday } from "./time.ts";

export type { Issue } from "./schema-check.ts";

export type Kind = "one-on-one" | "round-robin" | "collective" | "group";

export type CalendarRef =
  | { source: "google" | "microsoft"; account: string; calendar: string }
  | { source: "ical"; secret: string; label?: string };

export type Location =
  | { type: "meet" | "zoom" | "teams" }
  | { type: "custom"; url?: string; label?: string }
  | { type: "phone"; caller: "host" | "invitee" }
  | { type: "in-person"; address: string };

export interface Question {
  id: string;
  label: string;
  type: "text" | "textarea" | "email" | "phone" | "select" | "radio" | "checkbox" | "number";
  required?: boolean;
  options?: string[];
  maxLength?: number;
}

export type WeeklyHours = Partial<Record<Weekday, string[]>>;

export interface Host {
  id: string;
  name: string;
  email: string;
  timezone?: string;
  hours: WeeklyHours;
  overrides?: { date: string; hours: string[] }[];
  holidays?: string[];
  calendars?: { conflicts: CalendarRef[]; bookInto?: CalendarRef };
  roundRobin?: { weight?: number; priority?: number };
  links?: { custom?: string; phone?: string };
}

export interface EventType {
  id: string;
  title: string;
  description?: string;
  kind: Kind;
  hosts: string[];
  durations: number[];
  defaultDuration?: number;
  startIncrement?: number;
  buffers?: { before?: number; after?: number };
  minimumNotice?: number;
  bookingWindow?: number;
  dailyLimit?: number;
  seats?: number;
  guests?: { max?: number };
  secret?: boolean;
  locations: Location[];
  questions?: Question[];
  policy?: { cancelCutoffHours?: number; rescheduleCutoffHours?: number; requireCancelReason?: boolean };
  confirmation?: { message?: string; redirectUrl?: string };
  agentBooking?: AgentBookingRules;
}

/** Per event type: who may book through an HQ agent and how. */
export interface AgentBookingRules {
  sameCompany?: "book" | "ask" | "deny";
  approvedCompanies?: string[];
  approvedMode?: "book" | "ask";
  others?: "ask" | "deny";
  blockedCompanies?: string[];
  lookupsPerHour?: number;
  bookingsPerWeek?: number;
}

export interface Notifications {
  confirmation?: boolean;
  reminders?: number[];
  followUp?: { enabled?: boolean; afterMinutes?: number };
  hostBrief?: { enabled?: boolean; minutesBefore?: number };
  meetingNotes?: boolean;
}

/** Launcher-written prototype settings. Only the hash of the owner key is stored. */
export interface PrototypeSettings {
  ownerKeySha256?: string;
  provider?: "sandbox" | "hqpro";
  appName?: string;
  companyName?: string;
}

export interface RoutingTarget {
  eventType?: string;
  hosts?: string[];
  url?: string;
}

export interface RoutingForm {
  id: string;
  title: string;
  questions: Question[];
  rules: { when: { question: string; equals?: string; in?: string[]; gte?: number; lte?: number }; to: RoutingTarget }[];
  default: RoutingTarget;
}

export interface BookingConfig {
  version: 1;
  company: string;
  timezone?: string;
  hosts: Host[];
  eventTypes: EventType[];
  routing?: { forms: RoutingForm[] };
  notifications?: Notifications;
  webhooks?: { url: string; events: string[]; signingSecret: string }[];
  embed?: { modes?: string[]; allowedOrigins?: string[] };
  theme?: Record<string, unknown>;
  dataRetention?: { inviteeDataDays?: number };
  prototype?: PrototypeSettings;
}

export interface CheckResult {
  ok: boolean;
  config?: BookingConfig;
  errors: Issue[];
}

const here = dirname(fileURLToPath(import.meta.url));
export const schema = JSON.parse(readFileSync(join(here, "booking.schema.json"), "utf8")) as Record<string, unknown>;
const checker = new SchemaChecker(schema);

const OPTION_TYPES = new Set(["select", "radio", "checkbox"]);

/** Parse booking.yaml text and check it. */
export function checkBookingYaml(text: string): CheckResult {
  const lines = new LineCounter();
  const doc = parseDocument(text, { prettyErrors: false, uniqueKeys: true, lineCounter: lines });
  if (doc.errors.length > 0) {
    return {
      ok: false,
      errors: doc.errors.map((e) => {
        const line = lines.linePos(e.pos[0]).line;
        return {
          path: "",
          code: "yaml-syntax",
          message: `The file is not valid YAML${line ? ` (line ${line})` : ""}: ${e.message.split("\n")[0]}`,
        };
      }),
    };
  }
  return checkConfig(doc.toJS());
}

/** Check an already-parsed config object. */
export function checkConfig(value: unknown): CheckResult {
  const errors = replaceSecretUrlIssues(value, checker.check(value));
  if (value && typeof value === "object" && !Array.isArray(value)) {
    errors.push(...crossFieldIssues(value as BookingConfig, errors));
  }
  const unique = dedupe(errors).sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return unique.length === 0
    ? { ok: true, config: value as BookingConfig, errors: [] }
    : { ok: false, errors: unique };
}

function dedupe(issues: Issue[]): Issue[] {
  const seen = new Set<string>();
  return issues.filter((i) => {
    const key = `${i.path}|${i.code}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function isObj(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

function arr<T>(v: unknown): T[] {
  return Array.isArray(v) ? (v as T[]) : [];
}

// A pasted iCal link where a vault secret name belongs gets a clear message
// instead of a format error, because the link is itself a credential.
function replaceSecretUrlIssues(value: unknown, issues: Issue[]): Issue[] {
  const urlPaths = new Set<string>();
  if (isObj(value)) {
    arr<unknown>(value.hosts).forEach((host, h) => {
      if (!isObj(host) || !isObj(host.calendars)) return;
      const refs: [string, unknown][] = arr<unknown>(host.calendars.conflicts).map((c, i) => [`hosts[${h}].calendars.conflicts[${i}]`, c]);
      refs.push([`hosts[${h}].calendars.bookInto`, host.calendars.bookInto]);
      for (const [path, ref] of refs) {
        if (isObj(ref) && ref.source === "ical" && typeof ref.secret === "string" && /^(https?|webcal):/i.test(ref.secret)) {
          urlPaths.add(`${path}.secret`);
        }
      }
    });
  }
  const kept = issues.filter((i) => !urlPaths.has(i.path));
  for (const path of urlPaths) {
    kept.push({
      path,
      code: "secret-is-url",
      message: `${path} contains the calendar link itself. That link lets anyone read the calendar, so store it in the HQ vault (hq secrets set NAME) and put only the secret's NAME here.`,
    });
  }
  return kept;
}

function crossFieldIssues(cfg: BookingConfig, structural: Issue[]): Issue[] {
  const issues: Issue[] = [];
  const add = (path: string, code: string, message: string) => issues.push({ path, code, message });
  const broken = (path: string) => structural.some((i) => i.path === path || i.path.startsWith(`${path}.`) || i.path.startsWith(`${path}[`));

  const hosts = arr<Host>(cfg.hosts).filter(isObj);
  const hostIds = new Map<string, Host>();
  hosts.forEach((host, h) => {
    const path = `hosts[${h}]`;
    if (typeof host.id === "string") {
      if (hostIds.has(host.id)) add(`${path}.id`, "duplicate-id", `${path}.id "${host.id}" is used by another host.`);
      hostIds.set(host.id, host);
    }

    const tz = host.timezone ?? cfg.timezone;
    if (!tz) {
      add(`${path}.timezone`, "missing-timezone", `${path} needs a time zone, here or as the top-level timezone.`);
    } else if (typeof tz === "string" && !isValidTimeZone(tz)) {
      add(host.timezone ? `${path}.timezone` : "timezone", "unknown-timezone", `"${tz}" is not a time zone this system knows. Use a name like America/New_York.`);
    }

    if (isObj(host.hours)) {
      for (const day of WEEKDAYS) checkRanges(arr<string>(host.hours[day]), joinPath(`${path}.hours`, day), add, broken);
    }
    const overrideDates = new Set<string>();
    arr<{ date: string; hours: string[] }>(host.overrides).forEach((o, i) => {
      const opath = `${path}.overrides[${i}]`;
      if (!isObj(o) || broken(opath)) return;
      if (!parseDate(o.date)) add(`${opath}.date`, "bad-date", `${opath}.date "${o.date}" is not a real calendar date.`);
      if (overrideDates.has(o.date)) add(`${opath}.date`, "duplicate-date", `${opath}.date ${o.date} has another override.`);
      overrideDates.add(o.date);
      checkRanges(arr<string>(o.hours), `${opath}.hours`, add, broken);
    });
    arr<string>(host.holidays).forEach((d, i) => {
      if (typeof d === "string" && !broken(`${path}.holidays[${i}]`) && !parseDate(d)) {
        add(`${path}.holidays[${i}]`, "bad-date", `${path}.holidays[${i}] "${d}" is not a real calendar date.`);
      }
    });

    if (isObj(host.calendars) && !broken(`${path}.calendars`)) {
      const book = host.calendars.bookInto;
      if (book) {
        if (book.source === "ical") {
          add(`${path}.calendars.bookInto`, "book-into-read-only", `${path}.calendars.bookInto is an iCal feed, which is read-only. New bookings need a Google or Microsoft calendar.`);
        } else {
          const listed = arr<CalendarRef>(host.calendars.conflicts).some(
            (c) => c.source === book.source && "account" in c && c.account === book.account && c.calendar === book.calendar,
          );
          if (!listed) add(`${path}.calendars.bookInto`, "book-into-not-checked", `${path}.calendars.bookInto must also be listed under conflicts, or bookings could overlap events on it.`);
        }
      }
    }
  });

  const events = arr<EventType>(cfg.eventTypes).filter(isObj);
  const eventIds = new Map<string, EventType>();
  events.forEach((ev, e) => {
    const path = `eventTypes[${e}]`;
    if (typeof ev.id === "string") {
      if (eventIds.has(ev.id)) add(`${path}.id`, "duplicate-id", `${path}.id "${ev.id}" is used by another event type.`);
      eventIds.set(ev.id, ev);
    }

    const evHosts = arr<string>(ev.hosts);
    evHosts.forEach((id, i) => {
      if (typeof id === "string" && !hostIds.has(id)) add(`${path}.hosts[${i}]`, "unknown-host", `${path}.hosts[${i}] "${id}" is not one of the hosts listed under hosts.`);
    });

    if (!broken(`${path}.kind`) && !broken(`${path}.hosts`)) {
      if (ev.kind === "one-on-one" && evHosts.length !== 1) {
        add(`${path}.hosts`, "one-on-one-needs-one-host", `${path} is one-on-one, so it needs exactly one host. Use round-robin or collective for several hosts.`);
      }
      if (ev.kind === "round-robin" && evHosts.length < 2) {
        add(`${path}.hosts`, "round-robin-needs-two-hosts", `${path} is round-robin, which shares bookings across hosts, so it needs at least two.`);
      }
      if (ev.kind === "collective" && evHosts.length < 2) {
        add(`${path}.hosts`, "collective-needs-two-hosts", `${path} is collective (everyone free), so it needs at least two hosts.`);
      }
    }
    if (!broken(`${path}.kind`)) {
      if (ev.seats !== undefined && ev.kind !== "group") {
        add(`${path}.seats`, "seats-not-allowed", `${path} is ${ev.kind}. Only group events have seats.`);
      }
      if (ev.kind === "group" && ev.seats === undefined) {
        add(`${path}.seats`, "group-needs-seats", `${path} is a group event, so it needs seats (how many people per slot).`);
      }
    }

    if (ev.defaultDuration !== undefined && Array.isArray(ev.durations) && !ev.durations.includes(ev.defaultDuration)) {
      add(`${path}.defaultDuration`, "default-duration-not-offered", `${path}.defaultDuration ${ev.defaultDuration} is not one of the durations offered.`);
    }

    checkQuestions(arr<Question>(ev.questions), `${path}.questions`, add);

    if (isObj(ev.agentBooking) && !broken(`${path}.agentBooking`)) {
      const blocked = new Set(arr<string>(ev.agentBooking.blockedCompanies));
      arr<string>(ev.agentBooking.approvedCompanies).forEach((slug, i) => {
        if (blocked.has(slug)) {
          add(`${path}.agentBooking.approvedCompanies[${i}]`, "company-approved-and-blocked", `${path}.agentBooking lists "${slug}" as both approved and blocked.`);
        }
      });
    }

    const seenLocations = new Set<string>();
    arr<Location>(ev.locations).forEach((loc, i) => {
      const lpath = `${path}.locations[${i}]`;
      if (!isObj(loc) || broken(lpath)) return;
      if (seenLocations.has(loc.type)) add(lpath, "duplicate-location", `${lpath} repeats the ${loc.type} location.`);
      seenLocations.add(loc.type);
      const listed = evHosts.map((id) => hostIds.get(id)).filter((h): h is Host => !!h);
      if (loc.type === "custom" && !loc.url) {
        for (const h of listed) {
          if (!h.links?.custom) add(lpath, "custom-link-missing", `${lpath} uses each host's own link, but host "${h.id}" has no links.custom.`);
        }
      }
      if (loc.type === "phone" && loc.caller === "invitee") {
        for (const h of listed) {
          if (!h.links?.phone) add(lpath, "phone-number-missing", `${lpath} has invitees call the host, but host "${h.id}" has no links.phone.`);
        }
      }
    });
  });

  if (isObj(cfg.routing)) {
    const formIds = new Set<string>();
    arr<RoutingForm>(cfg.routing.forms).forEach((form, f) => {
      const path = `routing.forms[${f}]`;
      if (!isObj(form) || broken(path)) return;
      if (formIds.has(form.id)) add(`${path}.id`, "duplicate-id", `${path}.id "${form.id}" is used by another form.`);
      formIds.add(form.id);
      checkQuestions(arr<Question>(form.questions), `${path}.questions`, add);
      const questionIds = new Set(arr<Question>(form.questions).map((q) => q.id));
      form.rules.forEach((rule, r) => {
        const rpath = `${path}.rules[${r}]`;
        const conditions = ["equals", "in", "gte", "lte"].filter((k) => k in rule.when);
        if (!questionIds.has(rule.when.question)) {
          add(`${rpath}.when.question`, "unknown-question", `${rpath}.when.question "${rule.when.question}" is not a question on this form.`);
        }
        const rangeOnly = conditions.length === 2 && conditions.includes("gte") && conditions.includes("lte");
        if (conditions.length !== 1 && !rangeOnly) {
          add(`${rpath}.when`, "bad-condition", `${rpath}.when needs one condition: equals, in, gte or lte (gte with lte is allowed for a range).`);
        }
        checkTarget(rule.to, `${rpath}.to`, eventIds, add);
      });
      checkTarget(form.default, `${path}.default`, eventIds, add);
    });
  }

  return issues;
}

function checkRanges(
  ranges: string[],
  path: string,
  add: (path: string, code: string, message: string) => void,
  broken: (path: string) => boolean,
): void {
  const parsed: { start: number; end: number; i: number }[] = [];
  ranges.forEach((r, i) => {
    const rpath = `${path}[${i}]`;
    if (typeof r !== "string" || broken(rpath)) return;
    const { start, end } = parseRange(r);
    if (start >= end) {
      add(rpath, "bad-range", `${rpath} "${r}" ends before it starts.`);
      return;
    }
    parsed.push({ start, end, i });
  });
  parsed.sort((a, b) => a.start - b.start);
  for (let k = 1; k < parsed.length; k++) {
    const prev = parsed[k - 1] as { end: number };
    const cur = parsed[k] as { start: number; i: number };
    if (cur.start < prev.end) add(`${path}[${cur.i}]`, "overlapping-hours", `${path}[${cur.i}] overlaps another time range on the same day.`);
  }
}

function checkQuestions(questions: Question[], path: string, add: (path: string, code: string, message: string) => void): void {
  const ids = new Set<string>();
  questions.forEach((q, i) => {
    if (!isObj(q)) return;
    const qpath = `${path}[${i}]`;
    if (ids.has(q.id)) add(`${qpath}.id`, "duplicate-id", `${qpath}.id "${q.id}" is used by another question.`);
    ids.add(q.id);
    if (OPTION_TYPES.has(q.type) && !q.options) add(`${qpath}.options`, "options-required", `${qpath} is a ${q.type} question, so it needs options.`);
    if (!OPTION_TYPES.has(q.type) && q.options) add(`${qpath}.options`, "options-not-allowed", `${qpath} is a ${q.type} question, which does not use options.`);
  });
}

function checkTarget(
  target: RoutingTarget,
  path: string,
  events: Map<string, EventType>,
  add: (path: string, code: string, message: string) => void,
): void {
  if (!isObj(target)) return;
  const hasEvent = typeof target.eventType === "string";
  const hasUrl = typeof target.url === "string";
  if (hasEvent === hasUrl) {
    add(path, "bad-target", `${path} must send people to either an eventType or a url, not both or neither.`);
    return;
  }
  if (target.hosts && !hasEvent) {
    add(`${path}.hosts`, "hosts-need-event-type", `${path}.hosts only works together with an eventType.`);
  }
  if (hasEvent) {
    const ev = events.get(target.eventType as string);
    if (!ev) {
      add(`${path}.eventType`, "unknown-event-type", `${path}.eventType "${target.eventType}" is not one of the event types.`);
      return;
    }
    arr<string>(target.hosts).forEach((h, i) => {
      if (!arr<string>(ev.hosts).includes(h)) add(`${path}.hosts[${i}]`, "host-not-on-event-type", `${path}.hosts[${i}] "${h}" is not a host of ${ev.id}.`);
    });
  }
}
