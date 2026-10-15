# HQ Booking setup

HQ Booking gives an HQ company its own booking pages, configured by talking to
the agent. This page covers what the pack needs and how its pieces fit.

## Requirements

- Node.js 22.6 or newer. The pack runs its TypeScript sources directly with
  Node's built-in type stripping, so there is no build step.
- npm, used once to install the template's one runtime dependency (`yaml`).
  `hq-booking.sh` installs it on first use.

Check both with `bash core/packages/hq-pack-booking/scripts/hq-booking.sh doctor`.

## Where things live

| Path | What it is |
|------|------------|
| `companies/{co}/booking/booking.yaml` | The company's booking settings. One file per company. |
| `core/packages/hq-pack-booking/template/shared/booking.schema.json` | The shape of `booking.yaml`. |
| `core/packages/hq-pack-booking/template/shared/config.ts` | Rules that span several fields, such as host references and seats. |
| `core/packages/hq-pack-booking/template/shared/availability.ts` | The engine that works out open times. |
| `core/knowledge/booking/examples/` | Three starting configs. |

## Calendars and secrets

Google and Microsoft calendars are named by account and calendar id. Calendars
from other providers are added as read-only iCal subscription links. Those
links let anyone read the calendar, so they go in the HQ vault
(`hq secrets set NAME`) and `booking.yaml` holds only the secret's name. The
checker rejects a link pasted into the file and does not repeat it back.

## How open times are worked out

For each host, the engine takes the weekly hours (or that date's override),
skips holidays, steps through the day by the event's start increment, and
keeps a start time when the whole meeting, plus its buffers, misses every busy
block and existing booking. Times are computed in each host's own time zone,
so daylight-saving changes in the host's or the visitor's zone never move a
meeting outside the host's hours. Minimum notice, the booking window and the
daily limit are applied last.

- One-on-one: the one host is free.
- Round-robin: at least one host is free; one is picked by priority, then by
  how far below their weighted share of bookings they are, then by who was
  booked least recently.
- Collective: every host is free.
- Group: every host is free and seats remain. Bookings of the same group slot
  share it instead of blocking it.

## What this release does not do yet

Connecting calendars, publishing the page on hq-deploy, taking bookings and
sending emails arrive in later releases.
