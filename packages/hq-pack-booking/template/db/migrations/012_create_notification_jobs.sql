CREATE TABLE IF NOT EXISTS notification_jobs (
  id text NOT NULL,
  booking_id text,
  kind text,
  offset_minutes bigint,
  run_at bigint,
  status text,
  attempts bigint,
  last_error text,
  created_at bigint,
  done_at bigint,
  PRIMARY KEY (id)
);
