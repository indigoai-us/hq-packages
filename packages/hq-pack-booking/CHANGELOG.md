# Changelog

## 0.1.0

First release: the foundation for HQ Booking.

- `booking.yaml` schema for hosts, hours, overrides, holidays, calendars
  (Google, Microsoft, iCal feeds by vault secret name), event types
  (one-on-one, round-robin, collective, group), durations, buffers, notice,
  window, daily limits, seats, guests, secret event types, locations,
  questions, cancel and reschedule policy, routing forms, notifications,
  webhooks, embeds, theme and data retention.
- A dependency-free checker for the schema plus cross-field rules, each with
  a named error code and a plain message.
- The availability engine: open times per host in the host's time zone,
  correct across daylight-saving changes, with round-robin assignment,
  collective intersection and group seats.
- `hq-booking.sh` with `doctor`, `path`, `validate` and `slots`, scoped to the
  session's company.
- `/booking` skill, setup guide, settings reference and three example configs.
