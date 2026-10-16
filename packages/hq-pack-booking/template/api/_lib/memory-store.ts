// In-memory Store for local dev and tests. Transactions run one at a time
// (a promise queue), so a check-then-write inside one transaction can never
// interleave with another. A failed transaction is undone from an undo log.
// Calls made outside transaction() are single-statement transactions.

import { AsyncLocalStorage } from "node:async_hooks";
import { ConflictError } from "./errors.ts";
import { compareBy, matches, type FindOptions, type Store, type Tx, type Where } from "./store.ts";
import { TABLES, type TableName, type Tables } from "./tables.ts";

type Row = Record<string, unknown>;

function keyOf(table: TableName, row: Row): string {
  return JSON.stringify(TABLES[table].key.map((k) => row[k] ?? null));
}

const clone = <T>(v: T): T => structuredClone(v);
const defined = (r: Row): Row => Object.fromEntries(Object.entries(r).filter(([, v]) => v !== undefined));

export class MemoryStore implements Store {
  readonly kind = "memory" as const;
  private readonly data = new Map<TableName, Map<string, Row>>();
  private queue: Promise<unknown> = Promise.resolve();
  private readonly inTx = new AsyncLocalStorage<boolean>();

  private table(name: TableName): Map<string, Row> {
    let t = this.data.get(name);
    if (!t) {
      t = new Map();
      this.data.set(name, t);
    }
    return t;
  }

  async transaction<R>(fn: (tx: Tx) => Promise<R>): Promise<R> {
    if (this.inTx.getStore()) throw new Error("Nested store call inside a transaction. Use the tx argument.");
    const run = async (): Promise<R> => {
      const undo: (() => void)[] = [];
      const tx = this.makeTx(undo);
      try {
        return await this.inTx.run(true, () => fn(tx));
      } catch (err) {
        for (let i = undo.length - 1; i >= 0; i--) (undo[i] as () => void)();
        throw err;
      }
    };
    const result = this.queue.then(run, run);
    this.queue = result.catch(() => undefined);
    return result;
  }

  private makeTx(undo: (() => void)[]): Tx {
    const set = (table: TableName, key: string, row: Row | undefined) => {
      const t = this.table(table);
      const before = t.get(key);
      undo.push(() => (before === undefined ? t.delete(key) : t.set(key, before)));
      if (row === undefined) t.delete(key);
      else t.set(key, row);
    };
    const select = (table: TableName, where?: Where<Row>) => [...this.table(table).values()].filter((r) => matches(r, where));
    const tx: Tx = {
      get: async (table, key) => {
        const row = this.table(table).get(keyOf(table, key as unknown as Row));
        return row ? (clone(row) as never) : null;
      },
      find: async (table, where, options) => {
        let rows = select(table, where as Where<Row>);
        const opts = (options ?? {}) as unknown as FindOptions<Row>;
        if (opts.orderBy) rows.sort(compareBy<Row>(opts.orderBy, opts.desc));
        rows = rows.slice(opts.offset ?? 0, opts.limit !== undefined ? (opts.offset ?? 0) + opts.limit : undefined);
        return rows.map(clone) as never;
      },
      count: async (table, where) => select(table, where as Where<Row>).length,
      insert: async (table, row) => {
        const key = keyOf(table, row as unknown as Row);
        if (this.table(table).has(key)) throw new ConflictError();
        set(table, key, clone(row as unknown as Row));
      },
      update: async (table, key, patch, guard) => {
        const k = keyOf(table, key as unknown as Row);
        const row = this.table(table).get(k);
        if (!row || !matches(row, guard as Where<Row>)) return false;
        set(table, k, { ...row, ...clone(defined(patch as unknown as Row)) });
        return true;
      },
      remove: async (table, key) => {
        const k = keyOf(table, key as unknown as Row);
        if (!this.table(table).has(k)) return false;
        set(table, k, undefined);
        return true;
      },
      removeWhere: async (table, where) => {
        const rows = select(table, where as Where<Row>);
        for (const r of rows) set(table, keyOf(table, r), undefined);
        return rows.length;
      },
    };
    return tx;
  }

  get<K extends TableName>(table: K, key: Partial<Tables[K]>) {
    return this.transaction((tx) => tx.get(table, key));
  }
  find<K extends TableName>(table: K, where?: Where<Tables[K]>, options?: FindOptions<Tables[K]>) {
    return this.transaction((tx) => tx.find(table, where, options));
  }
  count<K extends TableName>(table: K, where?: Where<Tables[K]>) {
    return this.transaction((tx) => tx.count(table, where));
  }
  insert<K extends TableName>(table: K, row: Tables[K]) {
    return this.transaction((tx) => tx.insert(table, row));
  }
  update<K extends TableName>(table: K, key: Partial<Tables[K]>, patch: Partial<Tables[K]>, guard?: Where<Tables[K]>) {
    return this.transaction((tx) => tx.update(table, key, patch, guard));
  }
  remove<K extends TableName>(table: K, key: Partial<Tables[K]>) {
    return this.transaction((tx) => tx.remove(table, key));
  }
  removeWhere<K extends TableName>(table: K, where: Where<Tables[K]>) {
    return this.transaction((tx) => tx.removeWhere(table, where));
  }
}
