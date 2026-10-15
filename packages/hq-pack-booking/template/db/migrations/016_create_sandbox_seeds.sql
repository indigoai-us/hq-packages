CREATE TABLE IF NOT EXISTS sandbox_seeds (
  host_id text NOT NULL,
  day text NOT NULL,
  created_at bigint,
  PRIMARY KEY (host_id, day)
);
