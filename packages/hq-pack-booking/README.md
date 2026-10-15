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

Not built yet: calendar connection (hq-pro), the hosted booking pages and
API (hq-deploy), emails and reminders, the agent's setup and management flow,
and agent-to-agent booking. Each is a later story in the project plan.

## Contents

| Path | Purpose |
|------|---------|
| `skills/booking/` | The `/booking` skill |
| `scripts/hq-booking.sh` | `doctor`, `path`, `validate`, `slots` |
| `knowledge/booking/` | Setup, the settings reference, three example configs |
| `template/shared/` | Schema, checker, availability engine and their tests (shared by the launcher and, later, the booking app) |
| `tests/` | Pack tests (any OS) and an end-to-end install check |
| `cover.jpg` | Marketplace card image (`hq-road-sunrise` from the HQ wallpaper set) |

## Tests

```bash
bash packages/hq-pack-booking/tests/booking.test.sh   # typecheck, unit tests with coverage, launcher
bash packages/hq-pack-booking/tests/e2e-install.sh    # installs into a throwaway HQ with the real hq CLI
```
