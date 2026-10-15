// Rate limits kept as counters in the store (one row per key per window) and
// the audit log. Audit entries carry ids, never invitee names or emails.

import { HttpError } from "./errors.ts";
import type { Services } from "./services.ts";
import type { Tx } from "./store.ts";
import { newId } from "./util.ts";

/** Count one hit against key; throws 429 with a plain message past the limit. */
export async function rateLimit(s: Services, key: string, limit: number, windowMs: number, message: string): Promise<void> {
  const now = s.now();
  const windowEnd = Math.floor(now / windowMs) * windowMs + windowMs;
  const rowKey = `${key}:${windowEnd}`;
  const over = await s.store.transaction(async (tx) => {
    const row = await tx.get("rate_counters", { key: rowKey });
    if (!row) {
      await tx.insert("rate_counters", { key: rowKey, count: 1, window_end: windowEnd });
      return false;
    }
    if (row.count >= limit) return true;
    await tx.update("rate_counters", { key: rowKey }, { count: row.count + 1 });
    return false;
  });
  if (over) {
    throw new HttpError(429, "rate-limited", message, { retryAfterSeconds: Math.max(1, Math.ceil((windowEnd - now) / 1000)) });
  }
}

/** Current count for a key in its window, without counting a hit. */
export async function rateCount(s: Services, key: string, windowMs: number): Promise<number> {
  const windowEnd = Math.floor(s.now() / windowMs) * windowMs + windowMs;
  return (await s.store.get("rate_counters", { key: `${key}:${windowEnd}` }))?.count ?? 0;
}

export async function purgeCounters(s: Services): Promise<number> {
  return s.store.removeWhere("rate_counters", { window_end: { lt: s.now() } });
}

export interface AuditEntry {
  actor: string;
  action: string;
  bookingId?: string | null;
  hostIds?: string[];
  memberId?: string | null;
  detail?: Record<string, unknown>;
}

export async function audit(tx: Tx, now: number, e: AuditEntry): Promise<void> {
  await tx.insert("audit_log", {
    id: newId("aud"),
    at: now,
    actor: e.actor,
    action: e.action,
    booking_id: e.bookingId ?? null,
    host_ids: e.hostIds ?? [],
    member_id: e.memberId ?? null,
    detail: e.detail ?? {},
  });
}
