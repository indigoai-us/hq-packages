CREATE TABLE IF NOT EXISTS notifications (
  id text NOT NULL,
  recipient_type text,
  recipient_id text,
  kind text,
  title text,
  body text,
  data text,
  booking_id text,
  approval_id text,
  sandbox boolean,
  created_at bigint,
  PRIMARY KEY (id)
);
