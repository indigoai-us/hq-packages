CREATE TABLE IF NOT EXISTS agent_delegations (
  member_id text NOT NULL,
  enabled boolean,
  limits text,
  updated_at bigint,
  PRIMARY KEY (member_id)
);
