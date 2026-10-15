// The double-booking guard. Every hold, pending approval and booking takes
// rows in slot_claims whose primary key names what it occupies:
//
//   slot:{eventType}:{host}:{start}   one per host (one-on-one, round-robin, collective)
//   cell:{host}:{cellStart}           every time cell the meeting covers, per host,
//                                     so overlapping times on other event types collide too
//   seat:{eventType}|{start}:{n}      group events: seat n of the slot
//
// Two writers that want the same time insert the same key. In memory the
// second insert sees the first; on Aurora DSQL both may insert before either
// commits, and the later COMMIT fails with 40001. Either way exactly one wins.
//
// Group events share their host cells: those rows belong to the group slot,
// not to one booking, and go away when its last seat is released.
// Claims of expired holds and approvals are taken over when someone else
// needs the key.

import { ConflictError } from "./errors.ts";
import type { EventType } from "./engine.ts";
import type { Tx } from "./store.ts";
import type { ClaimRow } from "./tables.ts";
import { MINUTE } from "./util.ts";

export interface ClaimOwner {
  type: "hold" | "booking" | "approval";
  id: string;
  /** When the claim lapses (holds and approvals); null for bookings. */
  expiresAt: number | null;
}

export function groupKey(eventTypeId: string, start: number): string {
  return `${eventTypeId}|${start}`;
}

export function cellKeys(hostId: string, start: number, end: number, cellMinutes: number): string[] {
  const size = cellMinutes * MINUTE;
  const keys: string[] = [];
  for (let t = Math.floor(start / size) * size; t < end; t += size) keys.push(`cell:${hostId}:${t}`);
  return keys;
}

async function isStale(tx: Tx, claim: ClaimRow, now: number): Promise<boolean> {
  if (claim.expires_at !== null && claim.expires_at <= now) return true;
  if (claim.owner_type === "group") {
    const seats = await tx.find("slot_claims", { group_key: claim.owner_id });
    return !seats.some((c) => c.expires_at === null || c.expires_at > now);
  }
  return false;
}

async function take(tx: Tx, key: string, owner: { type: ClaimRow["owner_type"]; id: string; expiresAt: number | null }, group: string | null, now: number): Promise<void> {
  const row: ClaimRow = { claim_key: key, owner_type: owner.type, owner_id: owner.id, group_key: group, expires_at: owner.expiresAt, created_at: now };
  try {
    await tx.insert("slot_claims", row);
    return;
  } catch (err) {
    if (!(err instanceof ConflictError)) throw err;
  }
  const existing = await tx.get("slot_claims", { claim_key: key });
  if (existing && existing.owner_id === owner.id) return;
  if (existing && !(await isStale(tx, existing, now))) throw new ConflictError("That time was just taken.");
  if (existing) await tx.remove("slot_claims", { claim_key: key });
  await tx.insert("slot_claims", row);
}

/**
 * Claim a time for an owner. Returns the keys the owner holds alone (stored on
 * the hold, approval or booking so they can be moved or released later).
 * Throws ConflictError when any part is taken.
 */
export async function claimTime(
  tx: Tx,
  ev: Pick<EventType, "id" | "kind" | "seats">,
  hostIds: string[],
  start: number,
  end: number,
  owner: ClaimOwner,
  cellMinutes: number,
  now: number,
): Promise<string[]> {
  if (ev.kind !== "group") {
    const keys = hostIds.flatMap((h) => [`slot:${ev.id}:${h}:${start}`, ...cellKeys(h, start, end, cellMinutes)]);
    for (const key of keys) await take(tx, key, owner, null, now);
    return keys;
  }
  const g = groupKey(ev.id, start);
  let seatKey: string | null = null;
  for (let n = 1; n <= (ev.seats ?? 0) && !seatKey; n++) {
    const key = `seat:${g}:${n}`;
    try {
      await take(tx, key, owner, g, now);
      seatKey = key;
    } catch (err) {
      if (!(err instanceof ConflictError)) throw err;
    }
  }
  if (!seatKey) throw new ConflictError("Every seat at that time is taken.");
  for (const h of hostIds) {
    for (const key of cellKeys(h, start, end, cellMinutes)) await take(tx, key, { type: "group", id: g, expiresAt: null }, null, now);
  }
  return [seatKey];
}

/** Move claims from one owner to another (hold or approval -> booking). Throws if any was lost. */
export async function transferClaims(tx: Tx, keys: string[], fromId: string, to: ClaimOwner): Promise<void> {
  for (const key of keys) {
    const ok = await tx.update("slot_claims", { claim_key: key }, { owner_type: to.type, owner_id: to.id, expires_at: to.expiresAt }, { owner_id: fromId });
    if (!ok) throw new ConflictError("The time you held was released and taken by someone else.");
  }
}

/** Release an owner's claims; frees a group slot's host cells when its last seat goes. */
export async function releaseClaims(tx: Tx, keys: string[], ownerId: string, now: number): Promise<void> {
  const groups = new Set<string>();
  for (const key of keys) {
    const claim = await tx.get("slot_claims", { claim_key: key });
    if (!claim || claim.owner_id !== ownerId) continue;
    if (claim.group_key) groups.add(claim.group_key);
    await tx.remove("slot_claims", { claim_key: key });
  }
  for (const g of groups) {
    const seats = await tx.find("slot_claims", { group_key: g });
    if (!seats.some((c) => c.expires_at === null || c.expires_at > now)) {
      await tx.removeWhere("slot_claims", { owner_type: "group", owner_id: g });
    }
  }
}
