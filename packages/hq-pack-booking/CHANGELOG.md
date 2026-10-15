# Changelog

## Unreleased

Booking app backend prototype (sandbox providers).

- Booking API for hq-deploy's `app` type: public slots, holds, bookings,
  cancel, reschedule, ics and routing forms; owner routes behind an owner
  key; agent routes with delegation limits, host rules, 24-hour approvals and
  rate limits. Documented in template/API.md.
- Double-booking guard on claim keys that holds under Aurora DSQL's
  optimistic concurrency; 20 parallel bookings of one slot give one booking.
- In-memory and SQL stores with one contract suite; DSQL migrations.
- Sandbox calendar, video, email and DM providers, and an hq-pro client for
  the booking route in knowledge/booking/hq-pro-contract.md.
- Reminders, follow-ups, host briefs and signed webhooks with retries, run by
  `POST /api/owner/jobs/run`.
- `npm run dev` local server and `npm run stage` deploy copy;
  knowledge/booking/hosting.md records how hq-deploy hosts it.
- booking.yaml: optional `prototype` and per-event-type `agentBooking`.

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
