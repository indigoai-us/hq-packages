CREATE TABLE IF NOT EXISTS agent_keys (
  key_hash text NOT NULL,
  id text,
  member_id text,
  member_name text,
  member_email text,
  member_company text,
  label text,
  created_at bigint,
  revoked_at bigint,
  PRIMARY KEY (key_hash)
);
