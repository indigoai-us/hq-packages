CREATE TABLE IF NOT EXISTS outbox_emails (
  id text NOT NULL,
  booking_id text,
  kind text,
  to_addrs text,
  subject text,
  html text,
  text_body text,
  sandbox boolean,
  created_at bigint,
  PRIMARY KEY (id)
);
