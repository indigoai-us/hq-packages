CREATE TABLE IF NOT EXISTS holds (
  id text NOT NULL,
  event_type_id text,
  duration bigint,
  start_at bigint,
  end_at bigint,
  host_ids text,
  seats bigint,
  link_id text,
  claim_keys text,
  expires_at bigint,
  created_at bigint,
  PRIMARY KEY (id)
);
