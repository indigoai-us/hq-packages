CREATE TABLE IF NOT EXISTS single_use_links (
  token_hash text NOT NULL,
  id text,
  event_type_id text,
  single_use boolean,
  expires_at bigint,
  used_at bigint,
  used_by text,
  revoked_at bigint,
  created_at bigint,
  PRIMARY KEY (token_hash)
);
