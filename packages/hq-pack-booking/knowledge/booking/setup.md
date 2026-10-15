# HQ Booking setup

HQ Booking gives an HQ company its own booking pages, configured by talking to
the agent and hosted on hq-deploy. This page covers what the pack needs and how
its pieces fit. Day-to-day running is in `operations.md`.

## Requirements

- Node.js 22.6 or newer. The launcher and the app's API run their TypeScript
  sources directly with Node's built-in type stripping.
- npm. `hq-booking.sh` installs the template's YAML reader on first use, and
  `build` installs the app's packages in its own build folder.
- An HQ sign-in (`/hq-login`) with permission to write the company's secrets
  and deploy its apps.

Check Node and npm with `bash core/packages/hq-pack-booking/scripts/hq-booking.sh doctor`.

## First run

```bash
B=core/packages/hq-pack-booking/scripts/hq-booking.sh
bash "$B" setup --from solo-consultant --company-name "Acme"   # booking.yaml + owner key
bash "$B" hosts add --email ana@acme.example                   # real hosts (members only)
bash "$B" validate
bash "$B" build
bash "$B" deploy                                               # password-protected
```

`setup` starts from one of the examples (`solo-consultant`,
`sales-round-robin`, `class-with-seats`), fills in the company slug, sets the
sandbox provider, saves a new owner key in the company vault as
`BOOKING_OWNER_KEY` and writes only its SHA-256 into the file. Running it
again keeps the key; `--rotate-owner-key` replaces it.

## Where things live

| Path | What it is |
|------|------------|
| `companies/{co}/booking/booking.yaml` | The company's booking settings. One file per company. |
| `companies/{co}/booking/overrides/` | Optional replacements for page components, applied at build. |
| `companies/{co}/booking/deploy.json` | Where the app is deployed (no secrets). |
| `workspace/booking-builds/{co}/` | Build folder and the staged upload. |
| `core/packages/hq-pack-booking/template/` | The app: pages, API (`api/`), migrations (`db/`), engine (`shared/`). |
| `core/packages/hq-pack-booking/template/shared/booking.schema.json` | The shape of `booking.yaml`. |
| `core/packages/hq-pack-booking/template/API.md` | The public, owner and agent API. |
| `core/knowledge/booking/examples/` | Three starting configs. |

## Calendars and secrets

Google and Microsoft calendars are named by account and calendar id. Calendars
from other providers are added as read-only iCal subscription links. Those
links let anyone read the calendar, so they go in the HQ vault
(`hq secrets set NAME`) and `booking.yaml` holds only the secret's name. The
checker rejects a link pasted into the file and does not repeat it back.

In the prototype, calendars, video links, email and DMs are sandboxed; see
`approvals.md` for what the real providers need.

## Team hosts

Hosts must be members of the company. `hosts add --email` checks the member
list (`hq members list`) and refuses anyone else; if the list cannot be read
it says so and continues. In the sandbox a new host can be booked at once. In
the real version HQ sends the host a DM with a link to connect a calendar and
leaves them out of open times until they do. `hosts remove` takes a host off
every event type; their existing bookings stay.

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
