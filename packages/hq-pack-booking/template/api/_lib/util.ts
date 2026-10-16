// Small helpers: ids, tokens, hashing, and input checks with plain messages.

import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { badRequest } from "./errors.ts";

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
export const WEEK = 7 * DAY;

export function newId(prefix: string): string {
  return `${prefix}_${randomBytes(12).toString("hex")}`;
}

/** A random bearer secret. Shown once; only its SHA-256 is stored. */
export function newToken(prefix: string): string {
  return `${prefix}_${randomBytes(24).toString("base64url")}`;
}

export function sha256Hex(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

export function hmacHex(secret: string, text: string): string {
  return createHmac("sha256", secret).update(text, "utf8").digest("hex");
}

/** Constant-time comparison of two hex digests of equal length. */
export function sameHex(a: string, b: string): boolean {
  if (a.length !== b.length || !/^[0-9a-f]*$/.test(a) || !/^[0-9a-f]*$/.test(b)) return false;
  return timingSafeEqual(Buffer.from(a, "hex"), Buffer.from(b, "hex"));
}

/** Deterministic 32-bit number from text, for sandbox data and coarse picks. */
export function hash32(text: string): number {
  return createHash("sha256").update(text, "utf8").digest().readUInt32BE(0);
}

export function iso(ms: number): string {
  return new Date(ms).toISOString();
}

export function isRecord(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

const EMAIL = /^[^@\s<>"]+@[^@\s<>"]+\.[^@\s<>"]+$/;

export function isEmail(v: unknown): v is string {
  return typeof v === "string" && v.length <= 254 && EMAIL.test(v);
}

/** Required or optional trimmed text with a length cap. */
export function text(value: unknown, field: string, opts: { max: number; min?: number; optional?: boolean }): string | undefined {
  if (value === undefined || value === null || value === "") {
    if (opts.optional) return undefined;
    throw badRequest("missing-field", `${field} is required.`, { field });
  }
  if (typeof value !== "string") throw badRequest("bad-field", `${field} must be text.`, { field });
  const trimmed = value.trim();
  if (trimmed.length < (opts.min ?? (opts.optional ? 0 : 1))) throw badRequest("missing-field", `${field} is required.`, { field });
  if (trimmed.length > opts.max) throw badRequest("too-long", `${field} must be at most ${opts.max} characters.`, { field });
  return trimmed;
}

export function requiredText(value: unknown, field: string, max: number): string {
  return text(value, field, { max }) as string;
}

/** An ISO 8601 date-time with an explicit offset or Z. */
export function instant(value: unknown, field: string): number {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/.test(value)) {
    throw badRequest("bad-time", `${field} must be a date-time such as 2026-11-02T15:00:00Z.`, { field });
  }
  const t = Date.parse(value);
  const [y, m, d] = value.slice(0, 10).split("-").map(Number) as [number, number, number];
  const check = new Date(Date.UTC(y, m - 1, d));
  if (Number.isNaN(t) || check.getUTCMonth() !== m - 1 || check.getUTCDate() !== d) {
    throw badRequest("bad-time", `${field} is not a real date-time.`, { field });
  }
  return t;
}

export function optionalInstant(value: unknown, field: string): number | undefined {
  return value === undefined || value === null || value === "" ? undefined : instant(value, field);
}

export function integer(value: unknown, field: string, min: number, max: number): number {
  const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
  if (typeof n !== "number" || !Number.isInteger(n) || n < min || n > max) {
    throw badRequest("bad-number", `${field} must be a whole number from ${min} to ${max}.`, { field });
  }
  return n;
}

export function optionalInteger(value: unknown, field: string, min: number, max: number): number | undefined {
  return value === undefined || value === null || value === "" ? undefined : integer(value, field, min, max);
}

export function bool(value: unknown, field: string): boolean | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "boolean") throw badRequest("bad-field", `${field} must be true or false.`, { field });
  return value;
}

export function slugValue(value: unknown, field: string): string {
  if (typeof value !== "string" || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(value)) {
    throw badRequest("bad-field", `${field} must be lowercase letters, digits and hyphens.`, { field });
  }
  return value;
}

/** Start of the UTC week (Monday 00:00Z) containing t. */
export function weekStart(t: number): number {
  const d = new Date(t);
  const day = (d.getUTCDay() + 6) % 7;
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) - day * DAY;
}

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

export function clampText(s: string, max: number): string {
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

/** "HH:MM-HH:MM" with the end after the start; 24:00 allowed as an end. */
export function parseRangeText(value: unknown, field: string): string {
  const m = typeof value === "string" ? /^([01]\d|2[0-3]):([0-5]\d)-(([01]\d|2[0-3]):([0-5]\d)|24:00)$/.exec(value) : null;
  if (!m) throw badRequest("bad-hours", `${field} must look like 09:00-17:00.`, { field });
  const [a, b] = (value as string).split("-") as [string, string];
  const mins = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
  if (mins(b) <= mins(a)) throw badRequest("bad-hours", `${field} must end after it starts.`, { field });
  return value as string;
}

export function rangeMinutes(range: string): { start: number; end: number } {
  const [a, b] = range.split("-") as [string, string];
  const mins = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
  return { start: mins(a), end: mins(b) };
}
