CREATE TABLE IF NOT EXISTS attendees (
  booking_id text NOT NULL,
  name text,
  email text,
  email_lower text,
  answers text,
  guests text,
  redacted_at bigint,
  PRIMARY KEY (booking_id)
);
