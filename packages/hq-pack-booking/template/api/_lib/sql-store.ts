// Store over Postgres-compatible SQL, written for Aurora DSQL:
// - Optimistic concurrency: a transaction that conflicts with a concurrent
//   one fails at COMMIT with SQLSTATE 40001 (OC000). It is retried with
//   backoff; after the last attempt the race is lost and ConflictError is
//   thrown, which the API reports as 409.
// - Duplicate keys are detected with INSERT ... ON CONFLICT DO NOTHING so the
//   transaction stays usable; two concurrent inserts of the same key both
//   succeed locally and one of them fails at COMMIT (40001, or 23505).
// - bigint comes back from pg as a string and json is stored as text; both
//   are converted here.
// The database is injected (db.ts wraps @hq/db), so tests drive this with a
// fake query function.

import { ConflictError } from "./errors.ts";
import type { Condition, FindOptions, Store, Tx, Where } from "./store.ts";
import { TABLES, type ColumnType, type TableName, type Tables } from "./tables.ts";

export interface QueryResult {
  rows: Record<string, unknown>[];
  rowCount: number | null;
}

export interface SqlClient {
  query(sql: string, params?: unknown[]): Promise<QueryResult>;
}

/** A pool plus a way to run statements on one connection between BEGIN and COMMIT. */
export interface Database extends SqlClient {
  transaction<R>(fn: (client: SqlClient) => Promise<R>): Promise<R>;
}

export interface SqlStoreOptions {
  maxAttempts?: number;
  baseDelayMs?: number;
  sleep?: (ms: number) => Promise<void>;
}

type Row = Record<string, unknown>;

export function sqlState(err: unknown): string | undefined {
  const code = err && typeof err === "object" ? (err as { code?: unknown }).code : undefined;
  return typeof code === "string" ? code : undefined;
}

const SERIALIZATION = "40001";
const UNIQUE = "23505";

function columnType(table: TableName, column: string): ColumnType {
  const type = TABLES[table].columns[column];
  if (!type) throw new Error(`Unknown column ${table}.${column}`);
  return type;
}

function encode(type: ColumnType, value: unknown): unknown {
  if (value === undefined || value === null) return null;
  return type === "json" ? JSON.stringify(value) : value;
}

function decode(type: ColumnType, value: unknown): unknown {
  if (value === null || value === undefined) return null;
  switch (type) {
    case "int":
      return typeof value === "number" ? value : Number(value);
    case "json":
      return typeof value === "string" ? JSON.parse(value) : value;
    case "bool":
      return value === true || value === "t" || value === "true";
    default:
      return value;
  }
}

function decodeRow(table: TableName, raw: Row): Row {
  const out: Row = {};
  for (const [col, type] of Object.entries(TABLES[table].columns)) out[col] = decode(type, raw[col]);
  return out;
}

class Params {
  readonly values: unknown[] = [];
  add(v: unknown): string {
    this.values.push(v);
    return `$${this.values.length}`;
  }
}

function whereSql(table: TableName, where: Record<string, Condition | undefined> | undefined, p: Params): string[] {
  const parts: string[] = [];
  for (const [col, cond] of Object.entries(where ?? {})) {
    if (cond === undefined) continue;
    const type = columnType(table, col);
    if (type === "json") throw new Error(`Cannot filter on json column ${table}.${col}`);
    if (cond === null) {
      parts.push(`${col} IS NULL`);
    } else if (typeof cond !== "object") {
      parts.push(`${col} = ${p.add(cond)}`);
    } else {
      if (cond.in !== undefined) parts.push(cond.in.length === 0 ? "FALSE" : `${col} IN (${cond.in.map((v) => p.add(v)).join(", ")})`);
      if (cond.ne !== undefined) parts.push(cond.ne === null ? `${col} IS NOT NULL` : `${col} <> ${p.add(cond.ne)}`);
      if (cond.lt !== undefined) parts.push(`${col} < ${p.add(cond.lt)}`);
      if (cond.lte !== undefined) parts.push(`${col} <= ${p.add(cond.lte)}`);
      if (cond.gt !== undefined) parts.push(`${col} > ${p.add(cond.gt)}`);
      if (cond.gte !== undefined) parts.push(`${col} >= ${p.add(cond.gte)}`);
    }
  }
  return parts;
}

function keyWhere(table: TableName, key: Row): Record<string, Condition> {
  const out: Record<string, Condition> = {};
  for (const k of TABLES[table].key) {
    const v = key[k];
    if (v === undefined || v === null) throw new Error(`Missing key column ${table}.${k}`);
    out[k] = v as Condition;
  }
  return out;
}

const clause = (parts: string[]) => (parts.length ? ` WHERE ${parts.join(" AND ")}` : "");

function makeTx(client: SqlClient): Tx {
  return {
    async get(table, key) {
      const p = new Params();
      const res = await client.query(`SELECT * FROM ${table}${clause(whereSql(table, keyWhere(table, key as unknown as Row), p))} LIMIT 1`, p.values);
      const row = res.rows[0];
      return row ? (decodeRow(table, row) as never) : null;
    },
    async find(table, where, options) {
      const p = new Params();
      const opts = (options ?? {}) as unknown as FindOptions<Row>;
      let sql = `SELECT * FROM ${table}${clause(whereSql(table, where as Row as Record<string, Condition>, p))}`;
      if (opts.orderBy) {
        columnType(table, opts.orderBy);
        sql += ` ORDER BY ${opts.orderBy} ${opts.desc ? "DESC" : "ASC"}`;
      }
      if (opts.limit !== undefined) sql += ` LIMIT ${Math.max(0, Math.floor(opts.limit))}`;
      if (opts.offset) sql += ` OFFSET ${Math.max(0, Math.floor(opts.offset))}`;
      const res = await client.query(sql, p.values);
      return res.rows.map((r) => decodeRow(table, r)) as never;
    },
    async count(table, where) {
      const p = new Params();
      const res = await client.query(`SELECT count(*) AS n FROM ${table}${clause(whereSql(table, where as Record<string, Condition>, p))}`, p.values);
      return Number(res.rows[0]?.n ?? 0);
    },
    async insert(table, row) {
      const p = new Params();
      const cols = Object.keys(TABLES[table].columns);
      const marks = cols.map((c) => p.add(encode(columnType(table, c), (row as unknown as Row)[c])));
      const res = await client.query(`INSERT INTO ${table} (${cols.join(", ")}) VALUES (${marks.join(", ")}) ON CONFLICT DO NOTHING`, p.values);
      if (!res.rowCount) throw new ConflictError();
    },
    async update(table, key, patch, guard) {
      const p = new Params();
      const sets = Object.entries(patch as unknown as Row)
        .filter(([c, v]) => v !== undefined && !TABLES[table].key.includes(c))
        .map(([c, v]) => `${c} = ${p.add(encode(columnType(table, c), v))}`);
      if (sets.length === 0) return (await this.get(table, key)) !== null;
      const parts = whereSql(table, keyWhere(table, key as unknown as Row), p).concat(whereSql(table, guard as Record<string, Condition>, p));
      const res = await client.query(`UPDATE ${table} SET ${sets.join(", ")}${clause(parts)}`, p.values);
      return (res.rowCount ?? 0) > 0;
    },
    async remove(table, key) {
      const p = new Params();
      const res = await client.query(`DELETE FROM ${table}${clause(whereSql(table, keyWhere(table, key as unknown as Row), p))}`, p.values);
      return (res.rowCount ?? 0) > 0;
    },
    async removeWhere(table, where) {
      const p = new Params();
      const parts = whereSql(table, where as Record<string, Condition>, p);
      if (parts.length === 0) throw new Error(`removeWhere on ${table} needs a condition.`);
      const res = await client.query(`DELETE FROM ${table}${clause(parts)}`, p.values);
      return res.rowCount ?? 0;
    },
  };
}

export class SqlStore implements Store {
  readonly kind = "sql" as const;
  private readonly db: Database;
  private readonly direct: Tx;
  private readonly maxAttempts: number;
  private readonly baseDelayMs: number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(db: Database, options: SqlStoreOptions = {}) {
    this.db = db;
    this.direct = makeTx(db);
    this.maxAttempts = options.maxAttempts ?? 4;
    this.baseDelayMs = options.baseDelayMs ?? 15;
    this.sleep = options.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  }

  private async retry<R>(run: () => Promise<R>): Promise<R> {
    for (let attempt = 1; ; attempt++) {
      try {
        return await run();
      } catch (err) {
        const state = sqlState(err);
        if (state === UNIQUE) throw new ConflictError();
        if (state !== SERIALIZATION) throw err;
        if (attempt >= this.maxAttempts) throw new ConflictError("Someone else changed this at the same moment. Try again.");
        await this.sleep(this.baseDelayMs * 2 ** (attempt - 1) * (0.5 + Math.random() / 2));
      }
    }
  }

  transaction<R>(fn: (tx: Tx) => Promise<R>): Promise<R> {
    return this.retry(() => this.db.transaction((client) => fn(makeTx(client))));
  }

  get<K extends TableName>(table: K, key: Partial<Tables[K]>) {
    return this.retry(() => this.direct.get(table, key));
  }
  find<K extends TableName>(table: K, where?: Where<Tables[K]>, options?: FindOptions<Tables[K]>) {
    return this.retry(() => this.direct.find(table, where, options));
  }
  count<K extends TableName>(table: K, where?: Where<Tables[K]>) {
    return this.retry(() => this.direct.count(table, where));
  }
  insert<K extends TableName>(table: K, row: Tables[K]) {
    return this.retry(() => this.direct.insert(table, row));
  }
  update<K extends TableName>(table: K, key: Partial<Tables[K]>, patch: Partial<Tables[K]>, guard?: Where<Tables[K]>) {
    return this.retry(() => this.direct.update(table, key, patch, guard));
  }
  remove<K extends TableName>(table: K, key: Partial<Tables[K]>) {
    return this.retry(() => this.direct.remove(table, key));
  }
  removeWhere<K extends TableName>(table: K, where: Where<Tables[K]>) {
    return this.retry(() => this.direct.removeWhere(table, where));
  }
}
