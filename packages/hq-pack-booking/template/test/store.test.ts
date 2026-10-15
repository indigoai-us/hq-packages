import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ConflictError } from "../api/_lib/errors.ts";
import { MemoryStore } from "../api/_lib/memory-store.ts";
import { SqlStore, sqlState } from "../api/_lib/sql-store.ts";
import { migrationFiles, TABLES } from "../api/_lib/tables.ts";
import { FakeSql, SqlError } from "./fake-sql.ts";
import { booking, runStoreContract } from "./store-contract.ts";

const noSleep = { sleep: async () => undefined };

runStoreContract("memory", () => new MemoryStore());
runStoreContract("sql", () => new SqlStore(new FakeSql(), noSleep));

const here = dirname(fileURLToPath(import.meta.url));

test("migration files match the table list, one statement each, DSQL-safe", () => {
  const dir = join(here, "..", "db", "migrations");
  const onDisk = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
  const expected = migrationFiles();
  assert.deepEqual(onDisk, expected.map((f) => f.name));
  for (const f of expected) {
    const sql = readFileSync(join(dir, f.name), "utf8");
    assert.equal(sql, f.sql, `${f.name} differs from tables.ts; regenerate it`);
    assert.equal(sql.split(";").filter((x) => x.trim()).length, 1, `${f.name} has more than one statement`);
    assert.doesNotMatch(sql, /SERIAL|REFERENCES|FOREIGN KEY|\bjsonb?\b|CREATE TRIGGER|EXTENSION/i);
    if (/INDEX/.test(sql)) assert.match(sql, /CREATE INDEX ASYNC/);
  }
  assert.equal(expected.filter((f) => f.name.includes("_create_")).length, Object.keys(TABLES).length);
});

test("memory store refuses a nested call inside a transaction", async () => {
  const s = new MemoryStore();
  await assert.rejects(s.transaction(async () => s.get("bookings", { id: "x" })), /Nested store call/);
  // The queue keeps working after a failure.
  await s.insert("bookings", booking("ok"));
  assert.equal(await s.count("bookings"), 1);
});

test("sql store retries lost races and then reports a conflict", async () => {
  const db = new FakeSql();
  const s = new SqlStore(db, noSleep);
  db.failCommits = 2;
  await s.transaction((tx) => tx.insert("bookings", booking("b1")));
  assert.equal(db.conflicts, 2);
  assert.ok(await s.get("bookings", { id: "b1" }));

  db.failCommits = 10;
  await assert.rejects(s.transaction((tx) => tx.insert("bookings", booking("b2"))), (e: unknown) => e instanceof ConflictError && /at the same moment/.test((e as Error).message));
  db.failCommits = 0;
  assert.equal(await s.get("bookings", { id: "b2" }), null);
});

test("sql store maps unique violations to conflicts and passes other errors through", async () => {
  const errors: unknown[] = [new SqlError("23505", "duplicate key"), new SqlError("42P01", "no table"), new Error("plain")];
  for (const err of errors) {
    const s = new SqlStore(
      {
        query: async () => {
          throw err;
        },
        transaction: async () => {
          throw err;
        },
      },
      noSleep,
    );
    if (sqlState(err) === "23505") {
      await assert.rejects(s.get("bookings", { id: "x" }), ConflictError);
      await assert.rejects(s.transaction(async () => 1), ConflictError);
    } else {
      await assert.rejects(s.get("bookings", { id: "x" }), (e: unknown) => e === err);
    }
  }
  assert.equal(sqlState("nope"), undefined);
  assert.equal(sqlState({ code: 5 }), undefined);
});

test("sql store writes parameterised SQL and decodes pg types", async () => {
  const db = new FakeSql();
  const s = new SqlStore(db, noSleep);
  await s.insert("bookings", booking("b1", { start_at: 1_800_000_000_000 }));
  const insert = db.statements.at(-1) as string;
  assert.match(insert, /^INSERT INTO bookings \(id, event_type_id, .*\) VALUES \(\$1, \$2, .*\) ON CONFLICT DO NOTHING$/);
  assert.doesNotMatch(insert, /b1|1800000000000/);
  const got = await s.get("bookings", { id: "b1" });
  assert.equal(got?.start_at, 1_800_000_000_000);
  assert.equal(typeof got?.start_at, "number");
  assert.deepEqual(got?.calendar, { ana: "ev1" });
  assert.equal(db.statements.at(-1), "SELECT * FROM bookings WHERE id = $1 LIMIT 1");
  await s.find("bookings", { status: "confirmed", start_at: { gte: 1 } }, { orderBy: "start_at", desc: true, limit: 5, offset: 2 });
  assert.equal(db.statements.at(-1), "SELECT * FROM bookings WHERE status = $1 AND start_at >= $2 ORDER BY start_at DESC LIMIT 5 OFFSET 2");
  await assert.rejects(s.find("bookings", { nope: 1 } as never), /Unknown column/);
  await assert.rejects(s.find("bookings", { location: "x" } as never), /json column/);
  await assert.rejects(s.find("bookings", {}, { orderBy: "nope" as never }), /Unknown column/);
  await assert.rejects(s.get("bookings", {}), /Missing key column/);
  await assert.rejects(s.removeWhere("bookings", {}), /needs a condition/);
});

test("sql store decodes text booleans from other drivers", async () => {
  const s = new SqlStore(
    {
      query: async () => ({ rows: [{ member_id: "m", enabled: "t", limits: { maxPerWeek: 2 }, updated_at: 5 }], rowCount: 1 }),
      transaction: async (fn) => fn({ query: async () => ({ rows: [], rowCount: 0 }) }),
    },
    noSleep,
  );
  const row = await s.get("agent_delegations", { member_id: "m" });
  assert.equal(row?.enabled, true);
  assert.deepEqual(row?.limits, { maxPerWeek: 2 });
  assert.equal(await s.update("agent_delegations", { member_id: "m" }, {}), true);
  assert.equal(await s.count("agent_delegations"), 0);
});

test("fake sql refuses statements it does not model", async () => {
  const db = new FakeSql();
  await assert.rejects(db.query("SELECT 1"), /cannot run/);
  await assert.rejects(db.query("SELECT * FROM nope"), /does not exist/);
  await assert.rejects(db.query("SELECT * FROM bookings WHERE id LIKE $1", ["x"]), /cannot parse/);
});
