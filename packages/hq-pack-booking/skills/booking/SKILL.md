---
name: booking
description: >-
  HQ Booking: branded booking pages (a Calendly replacement) for the active HQ
  company. Use when the user says /booking, "set up booking", "booking page",
  "scheduling link", "let people book time with me", "round-robin", "check my
  booking settings", or asks what times a booking page would offer. This
  release checks booking.yaml and previews open times; setup, hosting and
  calendar connection come in later releases of the pack.
---

# /booking: HQ Booking

HQ Booking gives a company its own booking pages. Everything is described in
one file per company, `companies/{co}/booking/booking.yaml`, which the agent
writes and edits by conversation.

**Script (after install):** `core/packages/hq-pack-booking/scripts/hq-booking.sh`
**Settings reference:** `core/knowledge/booking/config-reference.md`
**Examples:** `core/knowledge/booking/examples/`

```bash
B=core/packages/hq-pack-booking/scripts/hq-booking.sh
bash "$B" doctor                 # Node.js 22.6+ present? dependency installed?
bash "$B" path                   # where this company's booking.yaml lives
bash "$B" validate [file]        # check booking.yaml; every problem with its path
bash "$B" slots --event <id> [--duration 30] [--days 7] [--tz Europe/London] [--busy busy.json]
```

Each command prints one JSON object. Exit 0 ok, 1 the file has problems or the
request was refused, 2 usage or setup error (read `message` and `fix`).

## What works in this release

- Writing and checking `booking.yaml`: hosts, working hours, date overrides,
  holidays, calendars to check, event types (one-on-one, round-robin,
  collective, group with seats), durations, buffers, notice, booking window,
  daily limits, guests, secret event types, locations, questions, cancel and
  reschedule rules, routing forms, notifications, webhooks, embeds, theme and
  data retention.
- Previewing the times an event type would offer, in any time zone, with
  optional busy times and existing bookings.

Not yet: connecting calendars, publishing a live page, taking bookings,
emails. If the user asks for those, say plainly that this part of HQ Booking
is not built yet, and offer to prepare their `booking.yaml` now so it is ready.

## 1. Confirm the company

Read the session company with `hq core hq-session get company_slug`. If it is
empty or `personal`, ask which company the booking pages are for and bind it.
Never read or write another company's `booking/` folder; the script refuses.

## 2. Write or change booking.yaml

1. Run `path`. If the file does not exist, start from the closest example in
   `core/knowledge/booking/examples/` and fill in what the user told you:
   names, emails, time zone, hours, the meetings they offer.
2. Ask only for what you cannot infer. Defaults are fine for buffers,
   increments and the booking window.
3. Calendar links from iCloud, Fastmail or other providers are credentials.
   Store them with `hq secrets set NAME` (see `/hq-secrets`) and write only
   the secret name under `calendars.conflicts` as `{ source: ical, secret:
   NAME }`. Never paste a calendar link into the file or the chat.
4. Run `validate` after every change. Fix each error by its `path`. Explain
   any problem you cannot fix in one plain sentence.

## 3. Preview times

Run `slots --event <id> --tz <the visitor's zone>` and show the next few
times in plain words. Pass `--busy` with a JSON file of busy blocks per host
when the user wants to see the effect of their calendar.

## Rules

- One company per session. The file path and every host belong to it.
- Secrets are names in the file, values in the vault.
- Report errors in plain words; do not paste raw JSON at the user.
