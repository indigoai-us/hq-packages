// The part of @hq/db this app uses. hq-deploy supplies the real module at
// bundle time (src/tenant-api/hq-db in hq-deploy); see
// knowledge/booking/hosting.md.
declare module "@hq/db" {
  export interface HqDbResult {
    rows: Record<string, unknown>[];
    rowCount: number | null;
  }
  export interface HqDbClient {
    query(sql: string, params?: unknown[]): Promise<HqDbResult>;
    release(): void;
  }
  export interface HqDbPool {
    query(sql: string, params?: unknown[]): Promise<HqDbResult>;
    connect(): Promise<HqDbClient>;
  }
  export function getDb(): HqDbPool;
}
