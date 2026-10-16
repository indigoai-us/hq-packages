// Providers backed by the hq-pro booking route (/v1/booking/{proxy+}). The
// route is not live yet; this client follows the contract in
// knowledge/booking/hq-pro-contract.md and is tested against a fake fetch.

import { ProviderError } from "./errors.ts";
import type {
  BusyBlock,
  CalendarEventInput,
  CalendarHost,
  CalendarProvider,
  Conference,
  DirectMessage,
  EmailMessage,
  Mailer,
  MeetingInput,
  Notifier,
  Providers,
  VideoProvider,
} from "./providers.ts";
import { iso } from "./util.ts";

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body?: string; signal?: AbortSignal }) => Promise<{
  ok: boolean;
  status: number;
  text(): Promise<string>;
}>;

export interface HqProOptions {
  /** Base URL of the booking route, for example https://api.example/v1/booking */
  baseUrl: string;
  /** Request headers that authenticate the app (a booking key or a signed app principal request). */
  authorize: () => Promise<Record<string, string>> | Record<string, string>;
  appId: string;
  fetch: FetchLike;
  timeoutMs?: number;
}

/** Authenticate with the per-app booking key bound as an app secret. */
export function bookingKeyAuth(key: string): () => Record<string, string> {
  return () => ({ authorization: `Bearer ${key}` });
}

export class HqProClient {
  private readonly opts: HqProOptions;
  constructor(opts: HqProOptions) {
    this.opts = { ...opts, baseUrl: opts.baseUrl.replace(/\/+$/, "") };
  }

  async call<T>(method: string, path: string, body?: unknown, idempotencyKey?: string): Promise<T> {
    const headers: Record<string, string> = {
      accept: "application/json",
      "x-hq-app-id": this.opts.appId,
      ...(await this.opts.authorize()),
    };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (idempotencyKey) headers["idempotency-key"] = idempotencyKey;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.opts.timeoutMs ?? 8000);
    let res;
    try {
      res = await this.opts.fetch(`${this.opts.baseUrl}${path}`, {
        method,
        headers,
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
        signal: controller.signal,
      });
    } catch {
      throw new ProviderError("provider-unreachable", "The calendar service did not answer. Try again in a minute.");
    } finally {
      clearTimeout(timer);
    }
    const raw = await res.text();
    let parsed: unknown = undefined;
    try {
      parsed = raw ? JSON.parse(raw) : {};
    } catch {
      parsed = undefined;
    }
    if (!res.ok) {
      const err = (parsed as { error?: { code?: unknown; message?: unknown } } | undefined)?.error;
      const code = typeof err?.code === "string" ? err.code : `http-${res.status}`;
      const message = typeof err?.message === "string" ? err.message : "The calendar service refused the request.";
      throw new ProviderError(code, message, res.status === 404 ? 404 : 502);
    }
    if (parsed === undefined) throw new ProviderError("bad-response", "The calendar service sent an answer this app could not read.");
    return parsed as T;
  }
}

function hostRef(h: CalendarHost) {
  return { hostId: h.id, email: h.email, timezone: h.timezone };
}

function eventBody(input: CalendarEventInput) {
  return {
    ...hostRef(input.host),
    bookingId: input.bookingId,
    start: iso(input.start),
    end: iso(input.end),
    summary: input.summary,
    description: input.description,
    location: input.location ?? null,
    attendees: input.attendees,
    conference: input.conference ?? null,
  };
}

function toConference(c: unknown): Conference | undefined {
  if (!c || typeof c !== "object") return undefined;
  const { provider, joinUrl } = c as { provider?: unknown; joinUrl?: unknown };
  if (typeof joinUrl !== "string" || !/^https:\/\//.test(joinUrl)) return undefined;
  return { provider: typeof provider === "string" ? provider : "video", joinUrl, sandbox: false };
}

export class HqProCalendar implements CalendarProvider {
  readonly name = "hqpro" as const;
  private readonly client: HqProClient;
  constructor(client: HqProClient) {
    this.client = client;
  }

  async freeBusy(hosts: CalendarHost[], range: { from: number; to: number }, options: { ignoreEventIds?: string[] } = {}): Promise<Record<string, BusyBlock[]>> {
    const res = await this.client.call<{ hosts?: Record<string, { busy?: { start: string; end: string }[] }> }>("POST", "/freebusy", {
      hosts: hosts.map(hostRef),
      from: iso(range.from),
      to: iso(range.to),
      ignoreEventIds: options.ignoreEventIds ?? [],
    });
    const out: Record<string, BusyBlock[]> = {};
    for (const h of hosts) {
      const busy = res.hosts?.[h.id]?.busy;
      if (!Array.isArray(busy)) throw new ProviderError("bad-response", `The calendar service sent no busy times for ${h.id}.`);
      out[h.id] = busy
        .map((b) => ({ start: Date.parse(b.start), end: Date.parse(b.end) }))
        .filter((b) => Number.isFinite(b.start) && Number.isFinite(b.end) && b.end > b.start)
        .sort((a, b) => a.start - b.start);
    }
    return out;
  }

  async createEvent(input: CalendarEventInput): Promise<{ eventId: string; conference?: Conference }> {
    const res = await this.client.call<{ eventId?: unknown; conference?: unknown }>("POST", "/events", eventBody(input), input.idempotencyKey);
    if (typeof res.eventId !== "string") throw new ProviderError("bad-response", "The calendar service did not return an event id.");
    const conference = toConference(res.conference);
    return { eventId: res.eventId, ...(conference ? { conference } : {}) };
  }

  async updateEvent(eventId: string, input: CalendarEventInput): Promise<void> {
    await this.client.call("PATCH", `/events/${encodeURIComponent(eventId)}`, eventBody(input), input.idempotencyKey);
  }

  async cancelEvent(eventId: string, host: CalendarHost): Promise<void> {
    await this.client.call("DELETE", `/events/${encodeURIComponent(eventId)}?hostId=${encodeURIComponent(host.id)}`);
  }
}

export class HqProVideo implements VideoProvider {
  readonly name = "hqpro";
  private readonly client: HqProClient;
  constructor(client: HqProClient) {
    this.client = client;
  }
  async createMeeting(input: MeetingInput): Promise<Conference> {
    const res = await this.client.call<unknown>(
      "POST",
      "/meetings",
      { kind: input.kind, ...hostRef(input.host), bookingId: input.bookingId, start: iso(input.start), end: iso(input.end), title: input.title },
      `meeting:${input.bookingId}:${input.kind}`,
    );
    const c = toConference(res);
    if (!c) throw new ProviderError("bad-response", "The video service did not return a join link.");
    return c;
  }
}

export class HqProMailer implements Mailer {
  readonly name = "hqpro";
  private readonly client: HqProClient;
  constructor(client: HqProClient) {
    this.client = client;
  }
  async send(m: EmailMessage): Promise<boolean> {
    const res = await this.client.call<{ sent?: unknown }>("POST", "/notify/email", m, m.id);
    return res.sent !== false;
  }
}

export class HqProNotifier implements Notifier {
  readonly name = "hqpro";
  private readonly client: HqProClient;
  constructor(client: HqProClient) {
    this.client = client;
  }
  async send(m: DirectMessage): Promise<boolean> {
    const res = await this.client.call<{ sent?: unknown }>("POST", "/notify/dm", m, m.id);
    return res.sent !== false;
  }
}

/** hq-pro calendar, mail and DM. Video stays as given (sandbox in the prototype). */
export function hqProProviders(opts: HqProOptions, video: VideoProvider): Providers {
  const client = new HqProClient(opts);
  return {
    calendar: new HqProCalendar(client),
    video,
    mailer: new HqProMailer(client),
    notifier: new HqProNotifier(client),
  };
}
