// The only module that imports @hq/db. hq-deploy's bundler resolves it from
// its runtime source tree (an esbuild alias); it is not an npm package, so
// types/hq-db.d.ts describes the part used here and tests never load this file.

import { getDb } from "@hq/db";
import type { Database, QueryResult, SqlClient } from "./sql-store.ts";

export function createDatabase(): Database {
  const pool = getDb();
  return {
    query: (sql, params) => pool.query(sql, params) as Promise<QueryResult>,
    async transaction(fn) {
      // No retry here: SqlStore retries the whole function on 40001.
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const inner: SqlClient = { query: (sql, params) => client.query(sql, params) as Promise<QueryResult> };
        const result = await fn(inner);
        await client.query("COMMIT");
        return result;
      } catch (err) {
        await client.query("ROLLBACK").catch(() => undefined);
        throw err;
      } finally {
        client.release();
      }
    },
  };
}
