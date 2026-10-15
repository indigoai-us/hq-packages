# HQ Booking API

The booking pages, the owner tools and HQ agents call this API on the same
origin as the pages (`https://{app}.indigo-hq.com/api/...` on hq-deploy,
`http://127.0.0.1:5180/api/...` with `npm run dev`). Everything is JSON
unless noted. Times are ISO 8601 with an offset (`2026-11-03T15:00:00Z`).

Sources: `api/_lib/public-api.ts`, `owner-api.ts`, `agent-api.ts`. Hosting
details: `../knowledge/booking/hosting.md`.

## Conventions

- **Errors** always look like this, with a plain message that can be shown
  to people as is:

  ```json
  { "error": { "code": "slot-taken", "message": "Someone just took that time. Pick another time.", "details": { } } }
  ```

  `details` is present only for some codes (`field` or `question` for input
  errors, `retryAfterSeconds` for 429). No response ever carries a stack trace.
- **Status codes**: 200 read or change done, 201 created, 202 accepted but
  not booked (agent approvals), 400 bad input, 401 missing or wrong key,
  403 not allowed, 404 not found, 405 wrong method (with `Allow`), 409
  conflict (time taken, cutoff passed, already canceled), 410 gone (hold or
  link expired), 413 body over 64 KB, 429 rate limited (with `Retry-After`),
  502 a calendar or video provider failed, 503 not configured.
- **Sandbox**: in the prototype every calendar, video link, email and DM is a
  sandbox record in the app database. Responses say so with `sandbox: true`
  (config, bookings, locations, outbox). Join links look like
  `https://sandbox.hq-booking.invalid/meet/abc-defg-hij` and do not open.
- **No host calendar details** appear in public responses: slots are times
  only, round-robin slots never say which host is free, and the public event
  type view lists host names only (none for round-robin).
- **Headers** on every response: `cache-control: no-store`,
  `x-content-type-options: nosniff`, `referrer-policy: no-referrer`.
- **CORS**: public routes allow the origins in `embed.allowedOrigins`
  (preflight `OPTIONS` answers 204). Owner and agent routes are same-origin.
- **Rate limits** (per client IP, 10-minute windows): holds 20, bookings 10,
  cancel and reschedule 20 together, routing 60, failed owner sign-ins 20.

## Pages the UI must provide

The API builds links to these paths; the frontend must serve them.

| Path | Purpose |
|---|---|
| `/manage/{bookingId}?token={manageToken}` | Manage page from confirmation and reminder emails: show the booking, cancel, reschedule, download `.ics`. |
| `/l/{linkToken}` | Single-use or secret link minted by the owner. Resolve it with `GET /api/links/{token}`; on 410 show "This link has expired or was already used." Pass the token as `link` on the hold and booking. |

## Shared shapes

**EventType** (public view)

```json
{
  "id": "intro-call", "title": "Intro call", "description": "A short call…", "kind": "one-on-one",
  "durations": [15, 30], "defaultDuration": 30, "startIncrement": 15, "minimumNotice": 240, "bookingWindow": 30,
  "seats": null, "guestsMax": 2, "secret": false,
  "locations": [{ "type": "meet" }, { "type": "custom", "label": "Video link from the host" }, { "type": "phone", "caller": "host" }, { "type": "in-person", "address": "1 Main St" }],
  "questions": [{ "id": "company", "label": "Company name", "type": "text", "required": true }],
  "hosts": [{ "name": "Alex Rivera" }], "teamSize": 1,
  "policy": { "cancelCutoffHours": 4, "rescheduleCutoffHours": 4, "requireCancelReason": false },
  "confirmation": { "message": "See you soon", "redirectUrl": "https://…" },
  "timezone": "America/New_York"
}
```

- `kind`: `one-on-one`, `round-robin` (`hosts` is empty, `teamSize` counts
  them), `collective` (all hosts attend), `group` (`seats` per slot).
- `locations[].type`: `meet`, `zoom`, `teams`, `custom`, `phone` (`caller`
  `host` means the invitee must give a phone number), `in-person`.
- `questions[].type`: `text`, `textarea`, `email`, `phone`, `number`,
  `select`, `radio` (one of `options`), `checkbox` (a list from `options`).
- `timezone`: the first host's zone, a default for the picker.

**Booking** (public view)

```json
{
  "id": "bk_9f…", "status": "confirmed",
  "eventType": { "id": "intro-call", "title": "Intro call", "kind": "one-on-one" },
  "start": "2026-11-03T15:00:00.000Z", "end": "2026-11-03T15:30:00.000Z", "duration": 30,
  "timezone": "Europe/Paris",
  "location": { "type": "meet", "provider": "meet (sandbox)", "joinUrl": "https://sandbox.hq-booking.invalid/meet/…", "sandbox": true, "text": "https://sandbox.hq-booking.invalid/meet/…" },
  "hosts": [{ "name": "Alex Rivera" }],
  "invitee": { "name": "Iris Invitee", "email": "iris@client.example" },
  "guests": ["guest@client.example"], "answers": { "company": "Client Co" },
  "bookedBy": null, "cancelReason": null, "rescheduleCount": 0,
  "policy": { "canCancel": true, "canReschedule": true, "cancelCutoffHours": 4, "rescheduleCutoffHours": 4, "requireCancelReason": false },
  "confirmation": null, "sandbox": true
}
```

- `status`: `confirmed` or `canceled`.
- `location` by type: `meet|zoom|teams` → `provider`, `joinUrl`, `sandbox`;
  `custom` → `url`, `label`; `phone` → `caller`, `phone`; `in-person` →
  `address`. `text` is always a one-line description to display.
- `invitee` is null after the invitee's data was deleted.
- `bookedBy` is `"<member>'s agent for <member>"` for agent bookings.
- `policy.canCancel` / `canReschedule` already apply the cutoffs and the
  start time.

## Public routes

### GET /api/config/public

Everything the booking pages need to render.

```json
{
  "company": "northwind", "timezone": "America/New_York",
  "theme": { "source": "custom", "colors": { "primary": "#1f4d3a" }, "fonts": { "heading": "Fraunces", "body": "Inter" }, "radius": 8 },
  "embed": { "modes": ["inline"], "allowedOrigins": [] },
  "eventTypes": [EventType],
  "routingForms": [{ "id": "talk-to-sales", "title": "Talk to sales", "questions": [Question] }],
  "provider": "sandbox", "sandbox": true
}
```

Secret event types are left out; routing rules are not exposed.

### GET /api/event-types/{id}

`{ "eventType": EventType }`. Works for secret event types too (they are
reachable by id or link only). 404 `not-found`.

### GET /api/links/{token}

Resolve a link minted by the owner: `{ "eventType": EventType, "singleUse": true, "expiresAt": "…" | null }`.
404 `not-found` for an unknown token, 410 `link-expired` when expired,
revoked or already used.

### GET /api/slots

Query: `eventType` (required), `duration` (minutes, default the event's
default), `from` and `to` (default now and 7 days later; at most 62 days),
`tz` (zone for `date`/`time`, default the event's zone), `hosts` (comma list,
round-robin only, from a routing target).

```json
{
  "eventType": "intro-call", "duration": 30, "timezone": "Europe/Paris",
  "from": "…", "to": "…",
  "slots": [{ "start": "2026-11-03T14:00:00.000Z", "end": "2026-11-03T14:30:00.000Z", "date": "2026-11-03", "time": "15:00", "seatsLeft": 4 }]
}
```

`seatsLeft` is present for group events only. Held, pending and booked times
are not offered. Errors: 400 `missing-field`, `bad-duration`, `bad-time`,
`bad-range`, `bad-timezone`, `bad-hosts`, `hosts-not-allowed`,
`unknown-host`; 404 for an unknown event type.

### POST /api/routing/{formId}/evaluate

Body `{ "answers": { "seats": 120, "region": "EU" } }` (validated like booking
answers). Answer:

```json
{ "target": { "eventType": "demo", "hosts": ["ben"] }, "matchedRule": 1 }
```

or `{ "target": { "url": "https://…" }, "matchedRule": 2 }`. `matchedRule` is
null when the form's default was used. Pass `target.hosts` to slots and holds
as `hosts`.

### POST /api/holds

Hold a time for 5 minutes while the invitee fills the form.

Body: `{ "eventType": "intro-call", "start": "2026-11-03T14:00:00Z", "duration": 30, "link": "bl_…", "hosts": ["ben"] }`
(`duration`, `link` and `hosts` are optional. `link` is the token from
`/l/{token}`: send it on the hold and again on the booking.)

201: `{ "holdId": "hold_…", "eventType": "intro-call", "duration": 30, "start": "…", "end": "…", "expiresAt": "…" }`

Errors: 409 `slot-unavailable` (not open now) or `slot-taken` (lost a race),
410 `link-expired`, 400 `link-mismatch`, 404 `not-found` (link), 429.

### DELETE /api/holds/{holdId}

Release a hold (the invitee went back). `{ "released": true | false }`.

### POST /api/bookings

Book a held time.

```json
{
  "holdId": "hold_…",
  "name": "Iris Invitee", "email": "iris@client.example",
  "answers": { "company": "Client Co" },
  "guests": ["guest@client.example"],
  "location": { "type": "phone", "phone": "+33 1 23 45 67 89" },
  "timezone": "Europe/Paris",
  "utm": { "utm_source": "newsletter", "utm_campaign": "fall" },
  "link": "bl_…"
}
```

- `answers`: keyed by question id; required questions must be answered;
  unknown ids are refused.
- `guests`: up to the event type's `guestsMax` emails; added to the calendar
  event and to the emails.
- `location`: `{ "type": … }` or just the type string; defaults to the first
  location. Phone with `caller: host` needs `phone`.
- `timezone`: the invitee's zone, used in emails. Defaults to the event's.
- `utm`: only `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`,
  `utm_content`, each up to 200 characters.
- `link`: required when the hold was made with a link; a single-use link is
  used up here.

201:

```json
{
  "booking": Booking,
  "manageToken": "mt_…",
  "manageUrl": "/manage/bk_…?token=mt_…",
  "icsUrl": "/api/bookings/bk_…/ics?token=mt_…",
  "redirectUrl": null
}
```

Show `booking.confirmation.message`, or send the invitee to `redirectUrl`
when set. The booking creates the calendar event(s), the video link, the
confirmation email, a host DM, reminder, follow-up and brief jobs, and a
`booked` webhook.

Errors: 400 `missing-field`, `bad-email`, `answer-required`, `bad-answer`,
`unknown-question`, `bad-answers`, `too-many-guests`, `bad-guests`,
`bad-location`, `phone-required`, `bad-timezone`, `bad-utm`, `link-required`,
`link-mismatch`, `bad-json`; 409 `slot-taken`; 410 `hold-expired`,
`link-expired`; 413; 429; 502 `provider-failed` (nothing was booked).

### GET /api/bookings/{id}?token={manageToken}

`{ "booking": Booking }`. 403 `bad-token`, 404 `not-found`.

### POST /api/bookings/{id}/cancel

Body `{ "token": "mt_…", "reason": "Something came up" }`. `reason` is
required when `policy.requireCancelReason` (400 `reason-required`). Answer
`{ "booking": Booking }` with `status: canceled`. Errors: 403 `bad-token`;
409 `cancel-cutoff` (message names the hours), `already-started`,
`already-canceled`.

### POST /api/bookings/{id}/reschedule

Body `{ "token": "mt_…", "start": "…", "holdId": "hold_…", "reason": "…" }`.
`holdId` is optional; without it the new time is checked and taken directly.
The same calendar event moves (no second event); reminders are rescheduled;
a `rescheduled` webhook and email go out. Answer `{ "booking": Booking }`.
Errors: 400 `hold-mismatch`; 403; 409 `reschedule-cutoff`, `already-started`,
`already-canceled`, `slot-unavailable`, `slot-taken`; 410 `hold-expired`.

### GET /api/bookings/{id}/ics?token={manageToken}

`text/calendar` attachment (`STATUS:CANCELLED` once canceled; `SEQUENCE`
counts reschedules).

## Owner routes

Header `Authorization: Bearer <owner key>`. booking.yaml stores only the
key's SHA-256 (`prototype.ownerKeySha256`). 401 `unauthorized` for a missing
or wrong key; 503 `owner-not-configured` when no hash is set. Lists take
`limit` (1–200, default 50) and `offset`.

**OwnerBooking** = Booking plus:

```json
{
  "hostIds": ["ana"], "hosts": [{ "id": "ana", "name": "Ana Diaz" }],
  "createdBy": "invitee | owner | agent", "agentKeyId": null, "memberId": null,
  "agentNote": { "text": "Topic: Pricing", "untrusted": true },
  "utm": null, "linkId": null, "noShow": false,
  "calendarStatus": "created | updated | canceled | failed | update-failed | cancel-failed",
  "canceledBy": null, "canceledAt": null, "createdAt": "…", "updatedAt": "…", "inviteeRedacted": false
}
```

`agentNote` is text from another company's agent: always show it as quoted,
untrusted data.

| Method and path | Body or query | Answer |
|---|---|---|
| `GET /api/owner/session` | | `{ ok, company, provider, sandbox, store }` |
| `GET /api/owner/bookings` | `status` (`confirmed`/`canceled`), `eventType`, `host`, `email`, `createdBy`, `from`, `to` (on start time), `order` (`asc`, default newest first), `limit`, `offset` | `{ total, limit, offset, bookings: [OwnerBooking] }` |
| `GET /api/owner/bookings/{id}` | | `{ booking: OwnerBooking, audit: [{ at, actor, action, detail }] }` |
| `POST /api/owner/bookings/{id}/cancel` | `{ reason? }` | `{ booking }`; no cutoff or reason rule for the owner |
| `POST /api/owner/bookings/{id}/reschedule` | `{ start, reason? }` | `{ booking }`; no cutoff |
| `POST /api/owner/bookings/{id}/no-show` | `{ noShow: true \| false }` (default true) | `{ booking }`; 409 `not-started` before the start; sends a `no-show` webhook |
| `GET /api/owner/links` | | `{ links: [{ id, eventType, singleUse, expiresAt, usedAt, usedBy, revokedAt, createdAt }] }` |
| `POST /api/owner/links` | `{ eventType, singleUse? (default true), expiresInHours? (1–8760) }` | 201 `{ link, token, path: "/l/{token}" }`; the token is shown once |
| `POST /api/owner/links/{id}/revoke` | | `{ revoked: true }` |
| `GET /api/owner/analytics` | `from`, `to` (default the last 12 weeks) | `{ from, to, totals: { bookings, canceled, noShows }, byEventType: [Tally], byHost: [Tally], byWeek: [Tally] }`, Tally = `{ key, bookings, canceled, noShows }`, week keys are Monday dates (UTC) |
| `POST /api/owner/invitee-data/delete` | `{ email }` | `{ redacted, bookings: [ids] }`; name becomes "Deleted invitee", email, answers and guests are removed, stored emails and DMs are blanked, the booking stays |
| `POST /api/owner/retention/run` | | `{ redacted }` or `{ redacted: 0, skipped }` when `dataRetention.inviteeDataDays` is not set |
| `GET /api/owner/outbox` | `bookingId?` | `{ sandbox, emails: [{ id, bookingId, kind, to, subject, html, text, sandbox, createdAt }] }` (sandbox mail is stored, not sent) |
| `GET /api/owner/notifications` | `recipient?` (host or member id), `kind?` | `{ sandbox, notifications: [{ id, recipient: { type, id }, kind, title, body, data, bookingId, approvalId, sandbox, createdAt }] }` |
| `GET /api/owner/webhook-deliveries` | `status?` (`pending`, `delivered`, `failed`) | `{ deliveries: [{ id, endpointId, event, idempotencyKey, status, attempts, nextAttemptAt, lastStatus, lastError, createdAt, deliveredAt, payload }] }` |
| `GET /api/owner/audit` | `bookingId?`, `memberId?`, `action?` | `{ entries: [{ id, at, actor, action, bookingId, hostIds, memberId, detail }] }` |
| `GET /api/owner/sandbox/calendar` | `host` (required), `from`, `to` | `{ host: { id, name, timezone }, from, to, sandbox: true, busy: [{ start, end }], events: [{ id, kind: "busy" \| "booking", title, start, end, status, bookingId, conference, attendees }] }`; 404 unless the provider is sandbox |
| `GET /api/owner/webhooks` | | `{ configured: [{ id: "config:0", url, events, signingSecret (vault name), secretBound }], webhooks: [{ id, url, events, active, createdAt }] }` |
| `POST /api/owner/webhooks` | `{ url (public https), events: ["booked", "canceled", "rescheduled", "no-show"] }` | 201 `{ webhook, signingSecret }`; the secret is shown once |
| `PATCH /api/owner/webhooks/{id}` | `{ url?, events?, active? }` | `{ webhook }` |
| `DELETE /api/owner/webhooks/{id}` | | `{ deleted: true }` |
| `GET /api/owner/agent-keys` | | `{ agentKeys: [{ id, memberId, memberName, memberEmail, memberCompany, label, createdAt, revokedAt }] }` |
| `POST /api/owner/agent-keys` | `{ memberId (slug), memberName, memberEmail, memberCompany? (slug, default this company), label? }` | 201 `{ agentKey, key }`; the key is shown once |
| `POST /api/owner/agent-keys/{id}/revoke` | | `{ revoked: true }`; effective on the next request |
| `GET /api/owner/delegations` | | `{ delegations: [{ memberId, enabled, limits, updatedAt }] }` |
| `PUT /api/owner/delegations/{memberId}` | `{ enabled, limits? }` | `{ delegation }`. Limits: `eventTypes` (ids), `maxDuration` (minutes), `maxPerWeek`, `hours` (`"09:00-17:00"`), `days` (`["mon", …]`), `timezone`, `companies` (slugs the agent may book with) |
| `GET /api/owner/approvals` | `status?` (`pending`, `approved`, `declined`, `expired`) | `{ approvals: [{ id, status, eventType, start, end, duration, hostIds, requester: { memberId, name, email, company, agentKeyId }, topic: { text, untrusted: true } \| null, expiresAt, createdAt, decidedAt, bookingId }] }` |
| `POST /api/owner/approvals/{id}/approve` | | `{ status: "approved", booking: OwnerBooking }`; 409 `approval-closed` |
| `POST /api/owner/approvals/{id}/decline` | `{ reason? }` | `{ status: "declined" }` |
| `POST /api/owner/jobs/run` | | `{ reclaimed: { holds, approvals }, jobs: { done, skipped, failed }, webhooks: { delivered, retrying, failed }, retention: { redacted }, countersPurged, ranAt }` |

`POST /api/owner/jobs/run` is the scheduler hook. hq-deploy has no cron, so an
Outpost scheduled job calls it every few minutes with the owner key; the dev
server calls the same code every 30 seconds. It sends due reminders,
follow-ups and host briefs (each once, by a fixed id), retries webhooks
(after 1, 5, 30, 120 and 720 minutes, then `failed`), expires holds and
approvals, runs the retention purge and clears old rate counters.

### Webhooks

Each delivery is a POST with:

- `content-type: application/json`
- `x-hq-booking-event`: `booked`, `canceled`, `rescheduled` or `no-show`
- `idempotency-key`: the same on every retry of one event
- `x-hq-booking-signature`: `t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>">`
  with the endpoint's signing secret

Body: `{ "id": "<idempotency key>", "event": "booked", "createdAt": "…", "data": { id, eventType: { id, title }, status, start, end, timezone, hosts: [{ id, name }], invitee: { name, email } | null, answers, guests, location, utm, createdBy, noShow, cancelReason } }`.
Any 2xx counts as delivered.

## Agent routes

Header `Authorization: Bearer <agent key>`. An agent key stands for "member
X's agent acting for X". 401 `unauthorized` or `key-revoked`; 403
`delegation-off` until the owner turns on X's delegation.

Host rules per event type (`agentBooking` in booking.yaml): agents of this
company book at once by default; other companies ask first; approved
companies book (or ask); blocked companies get 403 `agent-not-allowed` with
no times. Every agent action is in the audit log.

### GET /api/agent/event-types

`{ member: { id, name, company }, eventTypes: [{ id, title, kind, durations, mode: "book" | "ask" }] }`
(event types the agent may not use are left out).

### GET /api/agent/offers

Query `eventType`, `duration?`, `from?`, `to?` (default 14 days, at most 31).
At most four coarse offers: one per day, on the hour or half hour, picked the
same way every time for the same agent and day, so repeated queries do not
reveal busy edges. When the member is also a host in this app, offers avoid
the member's busy time too; offers also respect the member's agent hours and
days.

`{ eventType, duration, mode, timezone, coarse: true, offers: [{ start, end, date, time }] }`

429 `rate-limited` past `agentBooking.lookupsPerHour` (default 30) lookups per
host per hour for this agent.

### POST /api/agent/bookings

Body `{ eventType, start, duration?, topic? (≤200), notes? (≤1000), location? }`.
`topic` and `notes` are stored as untrusted text and shown quoted.

| Outcome | Status and body |
|---|---|
| Booked | 201 `{ status: "booked", booking: Booking }` |
| Host asks first | 202 `{ status: "pending-approval", approvalId, expiresAt, message }`. The time is held 24 hours; the host gets a DM; no answer releases it and DMs the member. |
| Outside the member's limits | 202 `{ status: "needs-member-approval", message }`. Nothing is booked; the member gets a DM. |
| Not allowed | 403 `agent-not-allowed` |
| Weekly cap | 429 `rate-limited` past `agentBooking.bookingsPerWeek` (default 10) bookings plus pending requests per host per week for this agent |
| Time not open | 409 `slot-unavailable` or `slot-taken` |

### GET /api/agent/bookings

`{ bookings: [Booking], approvals: [{ id, status, eventType, start, end, expiresAt, bookingId }] }`
for this agent key only.

### POST /api/agent/bookings/{id}/cancel and /reschedule

Same bodies as the public routes without `token` (`{ reason? }`,
`{ start, reason? }`). Only bookings this agent key made (404 otherwise).
Cutoffs apply; a reschedule outside the member's limits answers 202
`needs-member-approval`.
