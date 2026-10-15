// A fake Postgres for SqlStore tests that behaves like Aurora DSQL where it
// matters: snapshot reads, optimistic concurrency (a transaction whose
// written rows were changed by a later commit fails at COMMIT with SQLSTATE
// 40001 / OC000), bigint values returned as strings and json kept as text.
// It understands exactly the statement shapes sql-store.ts writes and throws
// on anything else, so a new shape cannot slip through untested.

import { TABLES, type ColumnType, type TableName } from "../api/_lib/tables.ts";
import type { Database, QueryResult, SqlClient } from "../api/_lib/sql-store.ts";

type Row = Record<string, unknown>;
interface Version {
  seq: number;
  row: Row | null;
}

export class SqlError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

function pk(table: TableName, row: Row): string {
  return JSON.stringify(TABLES[table].key.map((k) => row[k]));
}

function colType(table: TableName, col: string): ColumnType {
  const t = TABLES[table].columns[col];
  if (!t) throw new SqlError("42703", `column "${col}" does not exist`);
  return t;
}

function wire(table: TableName, row: Row): Row {
  const out: Row = {};
  for (const [c, t] of Object.entries(TABLES[table].columns)) {
    const v = row[c] ?? null;
    out[c] = v !== null && t === "int" ? String(v) : v;
  }
  return out;
}

type Pred = (row: Row) => boolean;

function parseWhere(table: TableName, text: string | undefined, params: unknown[]): Pred {
  if (!text) return () => true;
  const preds: Pred[] = text.split(" AND ").map((part) => {
    if (part === "FALSE") return () => false;
    let m = /^(\w+) IS (NOT )?NULL$/.exec(part);
    if (m) {
      const [, col, not] = m as unknown as [string, string, string | undefined];
      colType(table, col);
      return (r) => (r[col] === null || r[col] === undefined) !== !!not;
    }
    m = /^(\w+) IN \((.+)\)$/.exec(part);
    if (m) {
      const col = m[1] as string;
      const values = (m[2] as string).split(", ").map((p) => params[Number(p.slice(1)) - 1]);
      return (r) => r[col] !== null && r[col] !== undefined && values.includes(r[col]);
    }
    m = /^(\w+) (=|<>|<=|>=|<|>) \$(\d+)$/.exec(part);
    if (!m) throw new SqlError("42601", `fake-sql cannot parse condition: ${part}`);
    const [, col, op, idx] = m as unknown as [string, string, string, string];
    colType(table, col);
    const v = params[Number(idx) - 1] as number | string | boolean;
    return (r) => {
      const x = r[col] as number | string | boolean | null | undefined;
      if (x === null || x === undefined) return false;
      switch (op) {
        case "=":
          return x === v;
        case "<>":
          return x !== v;
        case "<":
          return x < v;
        case "<=":
          return x <= v;
        case ">":
          return x > v;
        default:
          return x >= v;
      }
    };
  });
  return (r) => preds.every((p) => p(r));
}

interface TxState {
  start: number;
  writes: Map<string, { table: TableName; key: string; row: Row | null }>;
}

export class FakeSql implements Database {
  private seq = 0;
  private readonly data = new Map<TableName, Map<string, Version[]>>();
  readonly statements: string[] = [];
  /** Make the next N commits fail with 40001, as a lost race would. */
  failCommits = 0;
  commits = 0;
  conflicts = 0;

  private versions(table: TableName): Map<string, Version[]> {
    let m = this.data.get(table);
    if (!m) {
      m = new Map();
      this.data.set(table, m);
    }
    return m;
  }

  private visible(table: TableName, tx: TxState): Row[] {
    const out = new Map<string, Row>();
    for (const [key, history] of this.versions(table)) {
      let row: Row | null = null;
      for (const v of history) if (v.seq <= tx.start) row = v.row;
      if (row) out.set(key, row);
    }
    for (const w of tx.writes.values()) {
      if (w.table !== table) continue;
      if (w.row) out.set(w.key, w.row);
      else out.delete(w.key);
    }
    return [...out.values()];
  }

  private exec(sql: string, params: unknown[], tx: TxState): QueryResult {
    this.statements.push(sql);
    let m = /^SELECT (\*|count\(\*\) AS n) FROM (\w+)(?: WHERE (.+?))?(?: ORDER BY (\w+) (ASC|DESC))?(?: LIMIT (\d+))?(?: OFFSET (\d+))?$/.exec(sql);
    if (m) {
      const [, what, t, where, order, dir, limit, offset] = m as unknown as [string, string, TableName, string?, string?, string?, string?, string?];
      if (!TABLES[t]) throw new SqlError("42P01", `relation "${t}" does not exist`);
      let rows = this.visible(t, tx).filter(parseWhere(t, where, params));
      if (what !== "*") return { rows: [{ n: String(rows.length) }], rowCount: 1 };
      if (order) {
        colType(t, order);
        rows.sort((a, b) => {
          const x = a[order] as number | string | null;
          const y = b[order] as number | string | null;
          const r = x === y ? 0 : x === null ? 1 : y === null ? -1 : x < y ? -1 : 1;
          return dir === "DESC" ? -r : r;
        });
      }
      const from = Number(offset ?? 0);
      rows = rows.slice(from, limit === undefined ? undefined : from + Number(limit));
      return { rows: rows.map((r) => wire(t, r)), rowCount: rows.length };
    }
    m = /^INSERT INTO (\w+) \(([\w, ]+)\) VALUES \(([$\d, ]+)\) ON CONFLICT DO NOTHING$/.exec(sql);
    if (m) {
      const t = m[1] as TableName;
      const cols = (m[2] as string).split(", ");
      const row: Row = {};
      cols.forEach((c, i) => {
        colType(t, c);
        row[c] = params[i] ?? null;
      });
      for (const k of TABLES[t].key) if (row[k] === null) throw new SqlError("23502", `null value in column "${k}"`);
      const key = pk(t, row);
      if (this.visible(t, tx).some((r) => pk(t, r) === key)) return { rows: [], rowCount: 0 };
      tx.writes.set(`${t}|${key}`, { table: t, key, row });
      return { rows: [], rowCount: 1 };
    }
    m = /^UPDATE (\w+) SET (.+?) WHERE (.+)$/.exec(sql);
    if (m) {
      const t = m[1] as TableName;
      const sets = (m[2] as string).split(", ").map((s) => {
        const [col, p] = s.split(" = ") as [string, string];
        colType(t, col);
        return [col, params[Number(p.slice(1)) - 1]] as const;
      });
      const rows = this.visible(t, tx).filter(parseWhere(t, m[3], params));
      for (const r of rows) {
        const next = { ...r };
        for (const [c, v] of sets) next[c] = v ?? null;
        const key = pk(t, r);
        tx.writes.set(`${t}|${key}`, { table: t, key, row: next });
      }
      return { rows: [], rowCount: rows.length };
    }
    m = /^DELETE FROM (\w+) WHERE (.+)$/.exec(sql);
    if (m) {
      const t = m[1] as TableName;
      const rows = this.visible(t, tx).filter(parseWhere(t, m[2], params));
      for (const r of rows) {
        const key = pk(t, r);
        tx.writes.set(`${t}|${key}`, { table: t, key, row: null });
      }
      return { rows: [], rowCount: rows.length };
    }
    throw new SqlError("42601", `fake-sql cannot run: ${sql}`);
  }

  private commit(tx: TxState): void {
    if (this.failCommits > 0) {
      this.failCommits--;
      this.conflicts++;
      throw new SqlError("40001", "change conflicts with another transaction, please retry: (OC000)");
    }
    for (const w of tx.writes.values()) {
      const history = this.versions(w.table).get(w.key) ?? [];
      const last = history[history.length - 1];
      if (last && last.seq > tx.start) {
        this.conflicts++;
        throw new SqlError("40001", "change conflicts with another transaction, please retry: (OC000)");
      }
    }
    const seq = ++this.seq;
    for (const w of tx.writes.values()) {
      const history = this.versions(w.table).get(w.key) ?? [];
      history.push({ seq, row: w.row });
      this.versions(w.table).set(w.key, history);
    }
    this.commits++;
  }

  private client(tx: TxState): SqlClient {
    return {
      query: async (sql, params = []) => {
        await new Promise((r) => setImmediate(r));
        return this.exec(sql, params, tx);
      },
    };
  }

  async query(sql: string, params: unknown[] = []): Promise<QueryResult> {
    await new Promise((r) => setImmediate(r));
    const tx: TxState = { start: this.seq, writes: new Map() };
    const result = this.exec(sql, params, tx);
    if (tx.writes.size) this.commit(tx);
    return result;
  }

  async transaction<R>(fn: (client: SqlClient) => Promise<R>): Promise<R> {
    const tx: TxState = { start: this.seq, writes: new Map() };
    const result = await fn(this.client(tx));
    await new Promise((r) => setImmediate(r));
    this.commit(tx);
    return result;
  }
}
