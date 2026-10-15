CREATE TABLE IF NOT EXISTS sandbox_events (
  id text NOT NULL,
  host_id text,
  start_at bigint,
  end_at bigint,
  kind text,
  title text,
  booking_id text,
  conference text,
  attendees text,
  status text,
  created_at bigint,
  updated_at bigint,
  PRIMARY KEY (id)
);
