// The storage contract. Two implementations satisfy it: memory-store.ts (local
// dev and tests) and sql-store.ts (Aurora DSQL through @hq/db). Both pass the
// same contract suite in test/store-contract.ts.
//
// Rules every implementation keeps:
// - insert() of an existing primary key throws ConflictError and leaves the
//   transaction usable (SQL uses INSERT ... ON CONFLICT DO NOTHING).
// - transaction() is all-or-nothing. A transaction that loses a race to a
//   concurrent one is retried a few times, then fails with ConflictError.
// - Rows come back as plain copies; changing them changes nothing stored.

import type { TableName, Tables } from "./tables.ts";

export type Scalar = string | number | boolean | null;

export type Condition =
  | Scalar
  | { lt?: number | string; lte?: number | string; gt?: number | string; gte?: number | string; ne?: Scalar; in?: Exclude<Scalar, null>[] };

export type Where<T> = { [K in keyof T]?: Condition };

export interface FindOptions<T> {
  orderBy?: keyof T & string;
  desc?: boolean;
  limit?: number;
  offset?: number;
}

export interface Tx {
  get<K extends TableName>(table: K, key: Partial<Tables[K]>): Promise<Tables[K] | null>;
  find<K extends TableName>(table: K, where?: Where<Tables[K]>, options?: FindOptions<Tables[K]>): Promise<Tables[K][]>;
  count<K extends TableName>(table: K, where?: Where<Tables[K]>): Promise<number>;
  /** Throws ConflictError when the primary key exists. */
  insert<K extends TableName>(table: K, row: Tables[K]): Promise<void>;
  /** Updates one row by key when it also matches guard. Returns whether a row changed. */
  update<K extends TableName>(table: K, key: Partial<Tables[K]>, patch: Partial<Tables[K]>, guard?: Where<Tables[K]>): Promise<boolean>;
  remove<K extends TableName>(table: K, key: Partial<Tables[K]>): Promise<boolean>;
  removeWhere<K extends TableName>(table: K, where: Where<Tables[K]>): Promise<number>;
}

export interface Store extends Tx {
  readonly kind: "memory" | "sql";
  transaction<R>(fn: (tx: Tx) => Promise<R>): Promise<R>;
}

function isOps(c: Condition): c is Exclude<Condition, Scalar> {
  return c !== null && typeof c === "object";
}

/** Shared evaluation of a Where, used by the in-memory store and the fake SQL engine. */
export function matches(row: Record<string, unknown>, where: Record<string, Condition | undefined> | undefined): boolean {
  if (!where) return true;
  for (const [col, cond] of Object.entries(where)) {
    if (cond === undefined) continue;
    const v = row[col] as Scalar | undefined;
    if (!isOps(cond)) {
      if (cond === null ? v !== null && v !== undefined : v !== cond) return false;
      continue;
    }
    // SQL semantics: a NULL column never matches IN, <> or a comparison.
    if (cond.in !== undefined && (v === null || v === undefined || !cond.in.includes(v))) return false;
    if (cond.ne !== undefined && (v === null || v === undefined || (cond.ne !== null && v === cond.ne))) return false;
    if (cond.lt !== undefined && !(v !== null && v !== undefined && v < cond.lt)) return false;
    if (cond.lte !== undefined && !(v !== null && v !== undefined && v <= cond.lte)) return false;
    if (cond.gt !== undefined && !(v !== null && v !== undefined && v > cond.gt)) return false;
    if (cond.gte !== undefined && !(v !== null && v !== undefined && v >= cond.gte)) return false;
  }
  return true;
}

export function compareBy<T>(column: keyof T, desc: boolean | undefined): (a: T, b: T) => number {
  return (a, b) => {
    const x = a[column] as unknown as Scalar;
    const y = b[column] as unknown as Scalar;
    // Postgres order: NULLs sort as the largest value.
    const r = x === y ? 0 : x === null ? 1 : y === null ? -1 : x < y ? -1 : 1;
    return desc ? -r : r;
  };
}
