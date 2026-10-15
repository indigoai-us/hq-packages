CREATE TABLE IF NOT EXISTS host_assignments (
  event_type_id text NOT NULL,
  host_id text NOT NULL,
  bookings bigint,
  last_booked_at bigint,
  PRIMARY KEY (event_type_id, host_id)
);
