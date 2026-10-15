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
- booking.yaml: optional `prototype` and per-event-type `agentBooking`;
  `prototype.appName` and `prototype.companyName`.

Launcher and `/booking` skill for the prototype.

- `hq-booking.sh setup`: booking.yaml from an example, an owner key saved in
  the company vault (`BOOKING_OWNER_KEY`, via stdin) with only its SHA-256 in
  the file; re-runs keep the key, `--rotate-owner-key` replaces it.
- `build`: copies the template to `workspace/booking-builds/{co}/`, applies
  `companies/{co}/booking/overrides/`, builds and stages the upload, and
  refuses more than 100 files.
- `deploy`: uploads as an hq-deploy `app` with a database through the
  `/deploy` skill's helper scripts; sets the access gate (password by default)
  before the upload; follows the database billing rule (Indigo exempt, others
  need `--accept-database-billing`); records `deploy.json` without secrets.
- `owner`: bookings, cancel, reschedule, no-show, links, a plain-text "times
  for an email" snippet, analytics, outbox, notifications, approvals, agent
  keys and delegation, webhooks, audit, invitee deletion and the jobs run. The
  owner key is read from the vault per call and sent only to the company's
  own app or a local dev server.
- `agent`: event types, offered times, book, list, cancel and reschedule with
  another company's app using an agent key from the vault (prototype of
  `hq book <company>/<event>`).
- `hosts list|add|remove`: members only; sandbox hosts are booking ready at
  once.
- `dev`: the app locally with the vault's owner key.
- Every new command refuses another company (`--company`, linked files,
  linked folders, other apps' URLs). Pack tests cover each against a fake HQ
  with two companies, a stub vault, a local dev instance and a fake hq-deploy
  API.
- Docs: the rewritten skill, `operations.md`, `agent-booking.md` and
  `approvals.md`; setup and config reference updated.

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
