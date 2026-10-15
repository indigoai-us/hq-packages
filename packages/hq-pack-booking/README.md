# hq-pack-booking

`/booking` for HQ. HQ Booking gives an HQ company its own branded booking
pages, a Calendly replacement that the company sets up by talking to the HQ
agent and hosts on hq-deploy. One-on-one, round-robin, everyone-free
(collective) and group events are checked against the hosts' real calendars.

The company's whole setup is one file, `companies/{co}/booking/booking.yaml`.
The agent writes and edits it; the pack checks it and works out which times to
offer.

## Status

0.1.0, the foundation release. Verified:

- `booking.yaml` has a full schema covering hosts, hours, overrides, holidays,
  calendars, event types, locations, questions, policies, routing forms,
  notifications, webhooks, embeds, theme and data retention.
- `hq-booking.sh validate` reports every problem with its path and a plain
  message, including rules that span fields (collective with seats,
  round-robin with one host, unknown hosts, iCal links pasted where a vault
  secret name belongs). The three example configs pass.
- The availability engine handles working hours, overrides, holidays,
  buffers, notice, window, daily limits, several durations, round-robin
  assignment, collective and group seats, and daylight-saving changes in the
  host's and the visitor's zones. Line coverage is above 90 percent.
- The launcher refuses a config inside another company's folder, including
  through a symlink.

Unreleased, the sandbox prototype. Verified by the pack tests:

- The booking API for hq-deploy (public, owner and agent routes), its
  database migrations, and sandbox calendar, video, email and DM providers.
- `hq-booking.sh setup`, `build`, `deploy`, `dev`, `owner`, `agent` and
  `hosts`. The owner key goes to the vault and never appears in output,
  booking.yaml or deploy.json. `deploy` follows the `/deploy` skill's request
  sequence, tested against a fake hq-deploy API. `owner` and `agent` are
  tested against a local dev instance, including an outside company's agent
  asking for time, the host approving, and a revoked key being refused.
- Every new command refuses another company's files, folders, `--company`
  and app URLs.

Not verified yet: a real deploy to hq-deploy (the first one is done by hand),
real calendars, video and email (they need Google, Zoom and Microsoft
approvals, see `knowledge/booking/approvals.md`), the `hq booking` and
`hq book` CLI commands, and hq-pro's company directory.

## Contents

| Path | Purpose |
|------|---------|
| `skills/booking/` | The `/booking` skill |
| `scripts/hq-booking.sh` | `doctor`, `path`, `validate`, `slots`, `setup`, `build`, `deploy`, `dev`, `owner`, `agent`, `hosts` |
| `knowledge/booking/` | Setup, operations, agent booking, sandbox and approvals, the settings reference, hosting, the hq-pro contract, three example configs |
| `template/` | The booking app: pages, `api/`, `db/migrations/`, `shared/` engine, `dev/` (dev server, stage, launcher helpers) and tests |
| `tests/` | Pack tests (any OS), their fixtures, and an end-to-end install check |
| `cover.jpg` | Marketplace card image (`hq-road-sunrise` from the HQ wallpaper set) |

## Tests

```bash
bash packages/hq-pack-booking/tests/booking.test.sh   # typecheck, unit tests with coverage, launcher flows
BOOKING_TEST_STUB_DEPLOY=1 bash packages/hq-pack-booking/tests/booking.test.sh   # deploy with the stand-in /deploy scripts, as on CI
bash packages/hq-pack-booking/tests/e2e-install.sh    # installs into a throwaway HQ with the real hq CLI
```
