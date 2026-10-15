CREATE TABLE IF NOT EXISTS audit_log (
  id text NOT NULL,
  at bigint,
  actor text,
  action text,
  booking_id text,
  host_ids text,
  member_id text,
  detail text,
  PRIMARY KEY (id)
);
