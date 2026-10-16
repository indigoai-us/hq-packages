// URL parameters the booking pages understand. Pure, so node --test runs it.
//
//   name, email          prefill the invitee
//   a_<questionId>       prefill an intake answer (checkbox: comma list)
//   utm_source … utm_content   saved on the booking
//   duration, date, tz, hour   pick defaults (hour: 12 or 24)
//   hosts                round-robin host subset from a routing form
//   embed=1, embed_origin, mode   set by embed.js

import type { Question } from "./types.ts";

export const UTM_KEYS = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"] as const;
export type Utm = Partial<Record<(typeof UTM_KEYS)[number], string>>;

export interface Prefill {
  name: string;
  email: string;
  answers: Record<string, string | string[]>;
}

function clip(v: string, max: number): string {
  return v.length > max ? v.slice(0, max) : v;
}

export function parsePrefill(search: string | URLSearchParams, questions: Question[] = []): Prefill {
  const q = typeof search === "string" ? new URLSearchParams(search) : search;
  const answers: Record<string, string | string[]> = {};
  const byId = new Map(questions.map((x) => [x.id, x]));
  for (const [key, value] of q) {
    if (!key.startsWith("a_")) continue;
    const id = key.slice(2);
    const question = byId.get(id);
    if (questions.length && !question) continue; // unknown ids would be refused by the API
    const text = clip(value, question?.maxLength ?? 2000);
    if (question?.type === "checkbox") {
      const picked = text.split(",").map((s) => s.trim()).filter(Boolean);
      answers[id] = question.options ? picked.filter((p) => question.options!.includes(p)) : picked;
    } else if (question?.options && (question.type === "select" || question.type === "radio")) {
      if (question.options.includes(text)) answers[id] = text;
    } else {
      answers[id] = text;
    }
  }
  return { name: clip(q.get("name") ?? "", 200), email: clip(q.get("email") ?? "", 254), answers };
}

export function parseUtm(search: string | URLSearchParams): Utm {
  const q = typeof search === "string" ? new URLSearchParams(search) : search;
  const out: Utm = {};
  for (const k of UTM_KEYS) {
    const v = q.get(k);
    if (v) out[k] = clip(v, 200);
  }
  return out;
}

export interface EmbedParams {
  embedded: boolean;
  origin: string | null;
  mode: "inline" | "popup-button" | "popup-text" | null;
}

export function parseEmbed(search: string | URLSearchParams): EmbedParams {
  const q = typeof search === "string" ? new URLSearchParams(search) : search;
  const embedded = q.get("embed") === "1";
  const rawOrigin = q.get("embed_origin");
  let origin: string | null = null;
  if (rawOrigin) {
    try {
      const u = new URL(rawOrigin);
      if (u.protocol === "https:" || u.protocol === "http:") origin = u.origin;
    } catch {
      origin = null;
    }
  }
  const m = q.get("mode");
  const mode = m === "inline" || m === "popup-button" || m === "popup-text" ? m : null;
  return { embedded, origin, mode };
}

/**
 * May the page post to / render inside this parent origin? Same origin is
 * always fine; otherwise an empty allowedOrigins list means any origin (the
 * prototype default) and a non-empty one must list it.
 */
export function embedAllowed(parentOrigin: string | null, ownOrigin: string, allowedOrigins: string[]): boolean {
  if (!parentOrigin) return allowedOrigins.length === 0;
  if (parentOrigin === ownOrigin) return true;
  if (allowedOrigins.length === 0) return true;
  return allowedOrigins.includes(parentOrigin);
}

/** Query params to carry from one booking page to the next (prefill, utm, embed, hosts). */
export function carryParams(search: string | URLSearchParams, extra: Record<string, string | undefined> = {}): string {
  const q = typeof search === "string" ? new URLSearchParams(search) : search;
  const out = new URLSearchParams();
  for (const [k, v] of q) {
    if (k === "name" || k === "email" || k.startsWith("a_") || k.startsWith("utm_") || k === "embed" || k === "embed_origin" || k === "mode" || k === "tz" || k === "hour") out.append(k, v);
  }
  for (const [k, v] of Object.entries(extra)) {
    if (v === undefined || v === "") out.delete(k);
    else out.set(k, v);
  }
  const s = out.toString();
  return s ? `?${s}` : "";
}

/** Turn form answers into the API shape: numbers for number questions, arrays for checkbox, empty ones left out. */
export function answersForApi(questions: Question[], values: Record<string, string | string[]>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const q of questions) {
    const v = values[q.id];
    if (v === undefined) continue;
    if (q.type === "checkbox") {
      const list = Array.isArray(v) ? v : v ? [v] : [];
      if (list.length) out[q.id] = list;
    } else {
      const s = (Array.isArray(v) ? v.join(", ") : v).trim();
      if (!s) continue;
      out[q.id] = q.type === "number" && /^-?\d+(\.\d+)?$/.test(s) ? Number(s) : s;
    }
  }
  return out;
}

/** Guests field text -> list of trimmed, de-duplicated entries. */
export function parseGuests(text: string): string[] {
  const seen = new Set<string>();
  return text
    .split(/[\s,;]+/)
    .map((s) => s.trim())
    .filter((s) => s && !seen.has(s.toLowerCase()) && seen.add(s.toLowerCase()));
}

export function looksLikeEmail(s: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
}
