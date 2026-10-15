// Every table the booking app stores, as one list. The SQL store, the
// in-memory store and the migrations in db/migrations/ all follow it; a test
// checks the migration files match createTableSql() exactly.
//
// Column types: text, int (bigint; times are epoch milliseconds), bool, and
// json (stored as text, because Aurora DSQL has no json column type).
// Ids are made by the app (prefix_hex), so there is no SERIAL and no default.

export type ColumnType = "text" | "int" | "bool" | "json";

export interface TableSpec {
  key: readonly string[];
  columns: Readonly<Record<string, ColumnType>>;
  /** Extra async indexes: [index suffix, columns]. */
  indexes?: readonly (readonly [string, readonly string[]])[];
}

export type Json = unknown;

export interface BookingRow {
  id: string;
  event_type_id: string;
  kind: string;
  host_ids: string[];
  start_at: number;
  end_at: number;
  duration: number;
  status: "confirmed" | "canceled";
  location: Json;
  timezone: string;
  manage_token_hash: string;
  created_by: "invitee" | "owner" | "agent";
  agent_key_id: string | null;
  member_id: string | null;
  agent_note: string | null;
  utm: Json;
  link_id: string | null;
  claim_keys: string[];
  calendar: Record<string, string>;
  calendar_status: string;
  cancel_reason: string | null;
  canceled_at: number | null;
  canceled_by: string | null;
  reschedule_count: number;
  no_show: boolean;
  created_at: number;
  updated_at: number;
}

export interface AttendeeRow {
  booking_id: string;
  name: string;
  email: string | null;
  email_lower: string | null;
  answers: Record<string, unknown>;
  guests: string[];
  redacted_at: number | null;
}

export interface HoldRow {
  id: string;
  event_type_id: string;
  duration: number;
  start_at: number;
  end_at: number;
  host_ids: string[];
  seats: number;
  link_id: string | null;
  claim_keys: string[];
  expires_at: number;
  created_at: number;
}

export interface ClaimRow {
  claim_key: string;
  owner_type: "hold" | "booking" | "approval" | "group";
  owner_id: string;
  group_key: string | null;
  expires_at: number | null;
  created_at: number;
}

export interface HostAssignmentRow {
  event_type_id: string;
  host_id: string;
  bookings: number;
  last_booked_at: number | null;
}

export interface LinkRow {
  token_hash: string;
  id: string;
  event_type_id: string;
  single_use: boolean;
  expires_at: number | null;
  used_at: number | null;
  used_by: string | null;
  revoked_at: number | null;
  created_at: number;
}

export interface AgentKeyRow {
  key_hash: string;
  id: string;
  member_id: string;
  member_name: string;
  member_email: string;
  member_company: string;
  label: string | null;
  created_at: number;
  revoked_at: number | null;
}

export interface DelegationLimits {
  eventTypes?: string[];
  maxDuration?: number;
  maxPerWeek?: number;
  /** HH:MM-HH:MM in the member's time zone. */
  hours?: string;
  days?: string[];
  timezone?: string;
  /** Companies the agent may book with. Empty or missing means any. */
  companies?: string[];
}

export interface DelegationRow {
  member_id: string;
  enabled: boolean;
  limits: DelegationLimits;
  updated_at: number;
}

export interface ApprovalRow {
  id: string;
  event_type_id: string;
  duration: number;
  start_at: number;
  end_at: number;
  host_ids: string[];
  claim_keys: string[];
  agent_key_id: string;
  member_id: string;
  member_name: string;
  member_email: string;
  member_company: string;
  topic: string | null;
  status: "pending" | "approved" | "declined" | "expired";
  expires_at: number;
  created_at: number;
  decided_at: number | null;
  booking_id: string | null;
}

export interface WebhookEndpointRow {
  id: string;
  url: string;
  events: string[];
  secret: string;
  active: boolean;
  created_at: number;
}

export interface WebhookOutboxRow {
  id: string;
  endpoint_id: string;
  event: string;
  payload: string;
  idempotency_key: string;
  status: "pending" | "delivered" | "failed";
  attempts: number;
  next_attempt_at: number;
  last_status: number | null;
  last_error: string | null;
  created_at: number;
  delivered_at: number | null;
}

export interface NotificationJobRow {
  id: string;
  booking_id: string;
  kind: "reminder" | "follow-up" | "host-brief";
  offset_minutes: number;
  run_at: number;
  status: "pending" | "done" | "skipped" | "canceled" | "failed";
  attempts: number;
  last_error: string | null;
  created_at: number;
  done_at: number | null;
}

export interface OutboxEmailRow {
  id: string;
  booking_id: string | null;
  kind: string;
  to_addrs: string[];
  subject: string;
  html: string;
  text_body: string;
  sandbox: boolean;
  created_at: number;
}

export interface NotificationRow {
  id: string;
  recipient_type: "host" | "member" | "owner";
  recipient_id: string;
  kind: string;
  title: string;
  body: string;
  data: Json;
  booking_id: string | null;
  approval_id: string | null;
  sandbox: boolean;
  created_at: number;
}

export interface SandboxEventRow {
  id: string;
  host_id: string;
  start_at: number;
  end_at: number;
  kind: "busy" | "booking";
  title: string;
  booking_id: string | null;
  conference: Json;
  attendees: string[];
  status: "confirmed" | "canceled";
  created_at: number;
  updated_at: number;
}

export interface SandboxSeedRow {
  host_id: string;
  day: string;
  created_at: number;
}

export interface AuditRow {
  id: string;
  at: number;
  actor: string;
  action: string;
  booking_id: string | null;
  host_ids: string[];
  member_id: string | null;
  detail: Json;
}

export interface RateCounterRow {
  key: string;
  count: number;
  window_end: number;
}

export interface Tables {
  bookings: BookingRow;
  attendees: AttendeeRow;
  holds: HoldRow;
  slot_claims: ClaimRow;
  host_assignments: HostAssignmentRow;
  single_use_links: LinkRow;
  agent_keys: AgentKeyRow;
  agent_delegations: DelegationRow;
  approvals: ApprovalRow;
  webhook_endpoints: WebhookEndpointRow;
  webhook_outbox: WebhookOutboxRow;
  notification_jobs: NotificationJobRow;
  outbox_emails: OutboxEmailRow;
  notifications: NotificationRow;
  sandbox_events: SandboxEventRow;
  sandbox_seeds: SandboxSeedRow;
  audit_log: AuditRow;
  rate_counters: RateCounterRow;
}

export type TableName = keyof Tables;

export const TABLES: { readonly [K in TableName]: TableSpec } = {
  bookings: {
    key: ["id"],
    columns: {
      id: "text", event_type_id: "text", kind: "text", host_ids: "json", start_at: "int", end_at: "int", duration: "int",
      status: "text", location: "json", timezone: "text", manage_token_hash: "text", created_by: "text", agent_key_id: "text",
      member_id: "text", agent_note: "text", utm: "json", link_id: "text", claim_keys: "json", calendar: "json",
      calendar_status: "text", cancel_reason: "text", canceled_at: "int", canceled_by: "text", reschedule_count: "int",
      no_show: "bool", created_at: "int", updated_at: "int",
    },
    indexes: [["start", ["start_at"]]],
  },
  attendees: {
    key: ["booking_id"],
    columns: { booking_id: "text", name: "text", email: "text", email_lower: "text", answers: "json", guests: "json", redacted_at: "int" },
    indexes: [["email", ["email_lower"]]],
  },
  holds: {
    key: ["id"],
    columns: {
      id: "text", event_type_id: "text", duration: "int", start_at: "int", end_at: "int", host_ids: "json", seats: "int",
      link_id: "text", claim_keys: "json", expires_at: "int", created_at: "int",
    },
  },
  slot_claims: {
    key: ["claim_key"],
    columns: { claim_key: "text", owner_type: "text", owner_id: "text", group_key: "text", expires_at: "int", created_at: "int" },
  },
  host_assignments: {
    key: ["event_type_id", "host_id"],
    columns: { event_type_id: "text", host_id: "text", bookings: "int", last_booked_at: "int" },
  },
  single_use_links: {
    key: ["token_hash"],
    columns: {
      token_hash: "text", id: "text", event_type_id: "text", single_use: "bool", expires_at: "int", used_at: "int",
      used_by: "text", revoked_at: "int", created_at: "int",
    },
  },
  agent_keys: {
    key: ["key_hash"],
    columns: {
      key_hash: "text", id: "text", member_id: "text", member_name: "text", member_email: "text", member_company: "text",
      label: "text", created_at: "int", revoked_at: "int",
    },
  },
  agent_delegations: {
    key: ["member_id"],
    columns: { member_id: "text", enabled: "bool", limits: "json", updated_at: "int" },
  },
  approvals: {
    key: ["id"],
    columns: {
      id: "text", event_type_id: "text", duration: "int", start_at: "int", end_at: "int", host_ids: "json", claim_keys: "json",
      agent_key_id: "text", member_id: "text", member_name: "text", member_email: "text", member_company: "text", topic: "text",
      status: "text", expires_at: "int", created_at: "int", decided_at: "int", booking_id: "text",
    },
  },
  webhook_endpoints: {
    key: ["id"],
    columns: { id: "text", url: "text", events: "json", secret: "text", active: "bool", created_at: "int" },
  },
  webhook_outbox: {
    key: ["id"],
    columns: {
      id: "text", endpoint_id: "text", event: "text", payload: "text", idempotency_key: "text", status: "text", attempts: "int",
      next_attempt_at: "int", last_status: "int", last_error: "text", created_at: "int", delivered_at: "int",
    },
    indexes: [["due", ["status", "next_attempt_at"]]],
  },
  notification_jobs: {
    key: ["id"],
    columns: {
      id: "text", booking_id: "text", kind: "text", offset_minutes: "int", run_at: "int", status: "text", attempts: "int",
      last_error: "text", created_at: "int", done_at: "int",
    },
    indexes: [["due", ["status", "run_at"]]],
  },
  outbox_emails: {
    key: ["id"],
    columns: {
      id: "text", booking_id: "text", kind: "text", to_addrs: "json", subject: "text", html: "text", text_body: "text",
      sandbox: "bool", created_at: "int",
    },
  },
  notifications: {
    key: ["id"],
    columns: {
      id: "text", recipient_type: "text", recipient_id: "text", kind: "text", title: "text", body: "text", data: "json",
      booking_id: "text", approval_id: "text", sandbox: "bool", created_at: "int",
    },
  },
  sandbox_events: {
    key: ["id"],
    columns: {
      id: "text", host_id: "text", start_at: "int", end_at: "int", kind: "text", title: "text", booking_id: "text",
      conference: "json", attendees: "json", status: "text", created_at: "int", updated_at: "int",
    },
  },
  sandbox_seeds: {
    key: ["host_id", "day"],
    columns: { host_id: "text", day: "text", created_at: "int" },
  },
  audit_log: {
    key: ["id"],
    columns: { id: "text", at: "int", actor: "text", action: "text", booking_id: "text", host_ids: "json", member_id: "text", detail: "json" },
  },
  rate_counters: {
    key: ["key"],
    columns: { key: "text", count: "int", window_end: "int" },
  },
};

const SQL_TYPES: Record<ColumnType, string> = { text: "text", int: "bigint", bool: "boolean", json: "text" };

export function createTableSql(name: TableName): string {
  const spec = TABLES[name];
  const cols = Object.entries(spec.columns).map(([col, type]) => {
    const notNull = spec.key.includes(col) ? " NOT NULL" : "";
    return `  ${col} ${SQL_TYPES[type]}${notNull}`;
  });
  cols.push(`  PRIMARY KEY (${spec.key.join(", ")})`);
  return `CREATE TABLE IF NOT EXISTS ${name} (\n${cols.join(",\n")}\n);\n`;
}

export function createIndexSql(name: TableName, suffix: string, columns: readonly string[]): string {
  return `CREATE INDEX ASYNC IF NOT EXISTS ${name}_${suffix}_idx ON ${name} (${columns.join(", ")});\n`;
}

/** The migration files, in order: one statement per file. */
export function migrationFiles(): { name: string; sql: string }[] {
  const files: { name: string; sql: string }[] = [];
  let n = 1;
  const num = () => String(n++).padStart(3, "0");
  for (const name of Object.keys(TABLES) as TableName[]) {
    files.push({ name: `${num()}_create_${name}.sql`, sql: createTableSql(name) });
  }
  for (const name of Object.keys(TABLES) as TableName[]) {
    for (const [suffix, columns] of TABLES[name].indexes ?? []) {
      files.push({ name: `${num()}_index_${name}_${suffix}.sql`, sql: createIndexSql(name, suffix, columns) });
    }
  }
  return files;
}
