CREATE TABLE IF NOT EXISTS rate_counters (
  key text NOT NULL,
  count bigint,
  window_end bigint,
  PRIMARY KEY (key)
);
