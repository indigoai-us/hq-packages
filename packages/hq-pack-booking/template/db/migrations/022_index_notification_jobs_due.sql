CREATE INDEX ASYNC IF NOT EXISTS notification_jobs_due_idx ON notification_jobs (status, run_at);
