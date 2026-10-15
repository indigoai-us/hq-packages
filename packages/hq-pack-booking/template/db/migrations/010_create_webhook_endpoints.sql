CREATE TABLE IF NOT EXISTS webhook_endpoints (
  id text NOT NULL,
  url text,
  events text,
  secret text,
  active boolean,
  created_at bigint,
  PRIMARY KEY (id)
);
