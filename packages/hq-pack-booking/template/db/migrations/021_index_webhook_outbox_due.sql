CREATE INDEX ASYNC IF NOT EXISTS webhook_outbox_due_idx ON webhook_outbox (status, next_attempt_at);
