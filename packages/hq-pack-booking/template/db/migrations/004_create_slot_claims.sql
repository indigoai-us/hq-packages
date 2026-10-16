CREATE TABLE IF NOT EXISTS slot_claims (
  claim_key text NOT NULL,
  owner_type text,
  owner_id text,
  group_key text,
  expires_at bigint,
  created_at bigint,
  PRIMARY KEY (claim_key)
);
