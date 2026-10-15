// Test harness: a booking app over a chosen store with a fixed clock, a fake
// webhook fetch, and helpers to call it like a browser would.

import { buildServices, createBookingApp, type BookingApp } from "../api/_lib/app.ts";
import type { BookingConfig } from "../api/_lib/engine.ts";
import type { FetchLike } from "../api/_lib/hqpro.ts";
import { MemoryStore } from "../api/_lib/memory-store.ts";
import type { Providers } from "../api/_lib/providers.ts";
import { SqlStore } from "../api/_lib/sql-store.ts";
import type { Store } from "../api/_lib/store.ts";
import { sha256Hex } from "../api/_lib/util.ts";
import { checkConfig } from "../shared/config.ts";
import { FakeSql } from "./fake-sql.ts";

// A made-up value for tests only; no real system accepts it.
export const OWNER_KEY = "test-owner-key-0123456789"; // gitleaks:allow
/** Monday 2 November 2026, 06:00 UTC. */
export const MONDAY = Date.parse("2026-11-02T06:00:00Z");

const week = { mon: ["09:00-17:00"], tue: ["09:00-17:00"], wed: ["09:00-17:00"], thu: ["09:00-17:00"], fri: ["09:00-17:00"] };

export function testConfig(over: Partial<BookingConfig> = {}): BookingConfig {
  const cfg = {
    version: 1,
    company: "acme",
    timezone: "UTC",
    hosts: [
      { id: "ana", name: "Ana Diaz", email: "ana@acme.example", hours: week, links: { phone: "+1 555 0100", custom: "https://meet.acme.example/ana" } },
      { id: "ben", name: "Ben Okafor", email: "ben@acme.example", hours: week, links: { phone: "+1 555 0101", custom: "https://meet.acme.example/ben" } },
    ],
    eventTypes: [
      {
        id: "intro",
        title: "Intro call",
        kind: "one-on-one",
        hosts: ["ana"],
        durations: [30, 60],
        defaultDuration: 30,
        guests: { max: 2 },
        locations: [{ type: "meet" }, { type: "phone", caller: "host" }, { type: "in-person", address: "1 Main St" }, { type: "custom" }],
        questions: [
          { id: "company", label: "Company", type: "text", required: true },
          { id: "size", label: "Team size", type: "select", options: ["1-10", "11+"] },
          { id: "seats", label: "Seats", type: "number" },
          { id: "topics", label: "Topics", type: "checkbox", options: ["a", "b"] },
          { id: "mail", label: "Work email", type: "email" },
          { id: "tel", label: "Phone", type: "phone" },
        ],
        policy: { cancelCutoffHours: 2, rescheduleCutoffHours: 2, requireCancelReason: true },
      },
      { id: "demo", title: "Demo", kind: "round-robin", hosts: ["ana", "ben"], durations: [30], locations: [{ type: "zoom" }] },
      { id: "panel", title: "Panel", kind: "collective", hosts: ["ana", "ben"], durations: [45], startIncrement: 15, locations: [{ type: "teams" }] },
      { id: "class", title: "Class", kind: "group", hosts: ["ben"], durations: [60], startIncrement: 60, seats: 3, locations: [{ type: "meet" }] },
      { id: "vip", title: "VIP", kind: "one-on-one", hosts: ["ben"], durations: [30], secret: true, locations: [{ type: "meet" }] },
    ],
    routing: {
      forms: [
        {
          id: "sales",
          title: "Sales",
          questions: [
            { id: "seats", label: "Seats", type: "number", required: true },
            { id: "region", label: "Region", type: "select", options: ["EU", "US"] },
          ],
          rules: [
            { when: { question: "seats", gte: 100 }, to: { eventType: "panel" } },
            { when: { question: "region", equals: "eu" }, to: { eventType: "demo", hosts: ["ben"] } },
            { when: { question: "region", in: ["US"] }, to: { url: "https://acme.example/us" } },
          ],
          default: { eventType: "demo" },
        },
      ],
    },
    notifications: { confirmation: true, reminders: [60], followUp: { enabled: true, afterMinutes: 30 }, hostBrief: { enabled: true, minutesBefore: 30 } },
    webhooks: [{ url: "https://hooks.acme.example/booking", events: ["booked", "canceled", "rescheduled", "no-show"], signingSecret: "BOOKING_WEBHOOK_SECRET" }],
    embed: { modes: ["inline"], allowedOrigins: ["https://www.acme.example"] },
    theme: { source: "custom", colors: { primary: "#123456" } },
    dataRetention: { inviteeDataDays: 30 },
    prototype: { ownerKeySha256: sha256Hex(OWNER_KEY), provider: "sandbox" },
    ...over,
  };
  for (const [k, v] of Object.entries(cfg)) if (v === undefined) delete (cfg as Record<string, unknown>)[k];
  const checked = checkConfig(cfg);
  if (!checked.ok) throw new Error(`test config invalid: ${JSON.stringify(checked.errors)}`);
  return cfg as BookingConfig;
}

export interface Delivery {
  url: string;
  headers: Record<string, string>;
  body: string;
}

export interface Harness {
  app: BookingApp;
  store: Store;
  clock: { now: number };
  deliveries: Delivery[];
  webhookStatus: number[];
  logs: string[];
  call(method: string, path: string, body?: unknown, headers?: Record<string, string>): Promise<{ status: number; body: any; headers: Headers; text: string }>;
  owner(method: string, path: string, body?: unknown): Promise<{ status: number; body: any; headers: Headers; text: string }>;
}

export function harness(opts: { config?: BookingConfig; store?: "memory" | "sql"; providers?: (store: Store, now: () => number) => Providers; secrets?: Record<string, string> } = {}): Harness {
  const store: Store = opts.store === "sql" ? new SqlStore(new FakeSql(), { sleep: async () => undefined }) : new MemoryStore();
  const clock = { now: MONDAY };
  const now = () => clock.now;
  const deliveries: Delivery[] = [];
  const webhookStatus: number[] = [];
  const logs: string[] = [];
  const fakeFetch: FetchLike = async (url, init) => {
    deliveries.push({ url, headers: init.headers, body: init.body ?? "" });
    const status = webhookStatus.shift() ?? 200;
    return { ok: status < 300, status, text: async () => "" };
  };
  const services = buildServices({
    config: opts.config ?? testConfig(),
    store,
    now,
    fetch: fakeFetch,
    secrets: opts.secrets ?? { BOOKING_WEBHOOK_SECRET: "whsec_test" },
    log: (m) => logs.push(m),
    ...(opts.providers ? { providers: opts.providers(store, now) } : {}),
  });
  const app = createBookingApp(services);
  const call: Harness["call"] = async (method, path, body, headers = {}) => {
    const res = await app.handle(
      new Request(`https://book.acme.example${path}`, {
        method,
        headers: { "x-forwarded-for": "203.0.113.7", ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
        ...(body !== undefined ? { body: typeof body === "string" ? body : JSON.stringify(body) } : {}),
      }),
    );
    const text = await res.text();
    let parsed: unknown = text;
    try {
      parsed = JSON.parse(text);
    } catch {
      /* not json */
    }
    return { status: res.status, body: parsed, headers: res.headers, text };
  };
  return {
    app,
    store,
    clock,
    deliveries,
    webhookStatus,
    logs,
    call,
    owner: (method, path, body) => call(method, path, body, { authorization: `Bearer ${OWNER_KEY}` }),
  };
}

export const invitee = { name: "Iris Invitee", email: "iris@client.example", timezone: "Europe/Paris" };
export const introAnswers = { company: "Client Co" };

/** First open slot for an event type, from the public slots API. */
export async function firstSlot(h: Harness, eventType: string, extra = ""): Promise<{ start: string; end: string; seatsLeft?: number }> {
  const r = await h.call("GET", `/api/slots?eventType=${eventType}${extra}`);
  if (r.status !== 200 || !r.body.slots.length) throw new Error(`no slots for ${eventType}: ${r.text}`);
  return r.body.slots[0];
}

/** Hold then book the first open slot. */
export async function book(h: Harness, eventType = "intro", body: Record<string, unknown> = {}, ip = "203.0.113.7") {
  const slot = await firstSlot(h, eventType);
  const hold = await h.call("POST", "/api/holds", { eventType, start: slot.start }, { "x-forwarded-for": ip });
  if (hold.status !== 201) throw new Error(`hold failed: ${hold.text}`);
  const answers = eventType === "intro" ? { answers: introAnswers } : {};
  const res = await h.call("POST", "/api/bookings", { holdId: hold.body.holdId, ...invitee, ...answers, ...body }, { "x-forwarded-for": ip });
  return { slot, hold, res };
}
