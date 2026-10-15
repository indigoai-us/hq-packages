// The contract every Store must meet. test/store.test.ts runs it against the
// in-memory store and against SqlStore over the fake DSQL engine.

import { test } from "node:test";
import assert from "node:assert/strict";
import { ConflictError } from "../api/_lib/errors.ts";
import type { Store } from "../api/_lib/store.ts";
import type { BookingRow, HostAssignmentRow } from "../api/_lib/tables.ts";

export function booking(id: string, over: Partial<BookingRow> = {}): BookingRow {
  return {
    id,
    event_type_id: "intro",
    kind: "one-on-one",
    host_ids: ["ana"],
    start_at: 1_000,
    end_at: 2_000,
    duration: 30,
    status: "confirmed",
    location: { type: "meet", joinUrl: "https://x.invalid/a" },
    timezone: "UTC",
    manage_token_hash: "ab",
    created_by: "invitee",
    agent_key_id: null,
    member_id: null,
    agent_note: null,
    utm: null,
    link_id: null,
    claim_keys: ["slot:a"],
    calendar: { ana: "ev1" },
    calendar_status: "created",
    cancel_reason: null,
    canceled_at: null,
    canceled_by: null,
    reschedule_count: 0,
    no_show: false,
    created_at: 5,
    updated_at: 5,
    ...over,
  };
}

export function runStoreContract(name: string, make: () => Store): void {
  test(`${name}: insert and get keep every column type`, async () => {
    const s = make();
    const b = booking("b1", { utm: { utm_source: "x" }, no_show: true, canceled_at: 1_700_000_000_000 });
    await s.insert("bookings", b);
    assert.deepEqual(await s.get("bookings", { id: "b1" }), b);
    assert.equal(await s.get("bookings", { id: "nope" }), null);
  });

  test(`${name}: duplicate keys raise ConflictError and leave the transaction usable`, async () => {
    const s = make();
    await s.insert("bookings", booking("b1"));
    await assert.rejects(s.insert("bookings", booking("b1")), ConflictError);
    await s.transaction(async (tx) => {
      await assert.rejects(tx.insert("bookings", booking("b1")), ConflictError);
      await tx.insert("bookings", booking("b2"));
    });
    assert.equal(await s.count("bookings"), 2);
  });

  test(`${name}: find filters, orders and pages`, async () => {
    const s = make();
    await s.insert("bookings", booking("a", { start_at: 10, status: "canceled", agent_key_id: "k1" }));
    await s.insert("bookings", booking("b", { start_at: 20, canceled_at: 7 }));
    await s.insert("bookings", booking("c", { start_at: 30, agent_key_id: "k2", canceled_at: 3 }));
    const ids = (rows: BookingRow[]) => rows.map((r) => r.id);
    assert.deepEqual(ids(await s.find("bookings", { status: "confirmed" }, { orderBy: "start_at" })), ["b", "c"]);
    assert.deepEqual(ids(await s.find("bookings", { start_at: { gte: 20, lt: 31 } }, { orderBy: "start_at", desc: true })), ["c", "b"]);
    assert.deepEqual(ids(await s.find("bookings", { start_at: { gt: 10, lte: 20 } })), ["b"]);
    assert.deepEqual(ids(await s.find("bookings", { agent_key_id: null })), ["b"]);
    assert.deepEqual(ids(await s.find("bookings", { agent_key_id: { ne: null } }, { orderBy: "start_at" })), ["a", "c"]);
    assert.deepEqual(ids(await s.find("bookings", { agent_key_id: { ne: "k1" } })), ["c"]);
    assert.deepEqual(ids(await s.find("bookings", { id: { in: ["a", "c", "z"] } }, { orderBy: "start_at" })), ["a", "c"]);
    assert.deepEqual(ids(await s.find("bookings", { id: { in: [] } })), []);
    assert.deepEqual(ids(await s.find("bookings", {}, { orderBy: "start_at", limit: 1, offset: 1 })), ["b"]);
    // NULLs sort last ascending and first descending, as in Postgres.
    assert.deepEqual(ids(await s.find("bookings", {}, { orderBy: "canceled_at" })), ["c", "b", "a"]);
    assert.deepEqual(ids(await s.find("bookings", {}, { orderBy: "canceled_at", desc: true })), ["a", "b", "c"]);
    assert.equal(await s.count("bookings", { status: "confirmed" }), 2);
    assert.equal(await s.count("bookings"), 3);
  });

  test(`${name}: update honours the guard and reports a change`, async () => {
    const s = make();
    await s.insert("bookings", booking("b1"));
    assert.equal(await s.update("bookings", { id: "b1" }, { status: "canceled" }, { status: "confirmed" }), true);
    assert.equal(await s.update("bookings", { id: "b1" }, { status: "canceled" }, { status: "confirmed" }), false);
    assert.equal(await s.update("bookings", { id: "zz" }, { status: "canceled" }), false);
    assert.equal(await s.update("bookings", { id: "b1" }, { reschedule_count: 2, host_ids: ["ben"], cancel_reason: undefined }), true);
    const row = await s.get("bookings", { id: "b1" });
    assert.equal(row?.status, "canceled");
    assert.deepEqual(row?.host_ids, ["ben"]);
    assert.equal(row?.reschedule_count, 2);
    assert.equal(await s.update("bookings", { id: "b1" }, {}), true);
  });

  test(`${name}: composite keys, remove and removeWhere`, async () => {
    const s = make();
    const row = (e: string, h: string): HostAssignmentRow => ({ event_type_id: e, host_id: h, bookings: 1, last_booked_at: null });
    await s.insert("host_assignments", row("demo", "ana"));
    await s.insert("host_assignments", row("demo", "ben"));
    await s.insert("host_assignments", row("intro", "ana"));
    assert.equal((await s.get("host_assignments", { event_type_id: "demo", host_id: "ben" }))?.bookings, 1);
    assert.equal(await s.remove("host_assignments", { event_type_id: "demo", host_id: "ben" }), true);
    assert.equal(await s.remove("host_assignments", { event_type_id: "demo", host_id: "ben" }), false);
    assert.equal(await s.removeWhere("host_assignments", { host_id: "ana" }), 2);
    assert.equal(await s.count("host_assignments"), 0);
  });

  test(`${name}: a failed transaction changes nothing`, async () => {
    const s = make();
    await s.insert("bookings", booking("keep"));
    await assert.rejects(
      s.transaction(async (tx) => {
        await tx.insert("bookings", booking("gone"));
        await tx.update("bookings", { id: "keep" }, { status: "canceled" });
        await tx.remove("bookings", { id: "keep" });
        throw new Error("stop");
      }),
      /stop/,
    );
    assert.equal(await s.get("bookings", { id: "gone" }), null);
    assert.equal((await s.get("bookings", { id: "keep" }))?.status, "confirmed");
  });

  test(`${name}: rows are copies`, async () => {
    const s = make();
    const b = booking("b1");
    await s.insert("bookings", b);
    b.host_ids.push("mutated");
    const got = (await s.get("bookings", { id: "b1" })) as BookingRow;
    got.host_ids.push("again");
    assert.deepEqual((await s.get("bookings", { id: "b1" }))?.host_ids, ["ana"]);
  });

  test(`${name}: 20 concurrent check-then-insert transactions on one key: exactly one wins`, async () => {
    const s = make();
    const results = await Promise.allSettled(
      Array.from({ length: 20 }, (_, i) =>
        s.transaction(async (tx) => {
          if (await tx.get("slot_claims", { claim_key: "slot:x" })) throw new ConflictError();
          await tx.insert("slot_claims", { claim_key: "slot:x", owner_type: "booking", owner_id: `b${i}`, group_key: null, expires_at: null, created_at: i });
          return i;
        }),
      ),
    );
    const won = results.filter((r) => r.status === "fulfilled");
    const lost = results.filter((r) => r.status === "rejected");
    assert.equal(won.length, 1);
    assert.equal(lost.length, 19);
    for (const r of lost) assert.ok((r as PromiseRejectedResult).reason instanceof ConflictError);
    assert.equal(await s.count("slot_claims"), 1);
  });

  test(`${name}: 20 concurrent inserts of one key: exactly one wins`, async () => {
    const s = make();
    const results = await Promise.allSettled(
      Array.from({ length: 20 }, (_, i) =>
        s.insert("slot_claims", { claim_key: "k", owner_type: "hold", owner_id: `h${i}`, group_key: null, expires_at: 1, created_at: i }),
      ),
    );
    assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
  });

  test(`${name}: concurrent read-modify-write keeps every increment`, async () => {
    const s = make();
    await s.insert("rate_counters", { key: "c", count: 0, window_end: 1 });
    await Promise.all(
      Array.from({ length: 3 }, () =>
        s.transaction(async (tx) => {
          const row = await tx.get("rate_counters", { key: "c" });
          await tx.update("rate_counters", { key: "c" }, { count: (row?.count ?? 0) + 1 });
        }),
      ),
    );
    assert.equal((await s.get("rate_counters", { key: "c" }))?.count, 3);
  });
}
