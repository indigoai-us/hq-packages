CREATE TABLE IF NOT EXISTS webhook_outbox (
  id text NOT NULL,
  endpoint_id text,
  event text,
  payload text,
  idempotency_key text,
  status text,
  attempts bigint,
  next_attempt_at bigint,
  last_status bigint,
  last_error text,
  created_at bigint,
  delivered_at bigint,
  PRIMARY KEY (id)
);
