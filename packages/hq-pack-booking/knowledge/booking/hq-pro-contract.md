# hq-pro booking route: the contract

The booking app (an hq-deploy `app`) reaches calendars, video meetings, email
and HQ DMs through one hq-pro route, `/v1/booking/{proxy+}`. Tokens for
Google, Microsoft and Zoom stay in hq-pro. This file is what hq-pro must
implement (story US-002, with US-003 for Microsoft and Zoom). The app's
client is `template/api/_lib/hqpro.ts`, tested against a fake of this
contract; until the route is live, apps run with `prototype.provider: sandbox`.

## Base URL and auth

Base: `{HQ_PRO_API}/v1/booking`. The app reads it from the function
environment variable `HQ_BOOKING_API_URL`.

Every request carries:

| Header | Value |
|---|---|
| `Authorization` | `Bearer <booking key>`, or a SigV4 signature from the app's IAM role |
| `X-HQ-App-Id` | hq-deploy app id |
| `Idempotency-Key` | on every write; same key, same result |
| `Content-Type` | `application/json` on bodies |

Two ways to authenticate, either is enough:

1. App principal. hq-deploy registers the function's IAM role as the app's
   `app_*` entity at deploy (`register-app-principal`). hq-pro verifies the
   SigV4 caller ARN through the API Gateway IAM authorizer and maps it to the
   `app_*` entity and its company.
2. Booking key. At setup, hq-pro mints a per-app key (`hqbk_...`) for the
   company, stores only its hash, and the launcher binds it to the app as the
   secret `HQ_BOOKING_KEY`. The key names one app and one company.

The caller is pinned to one company. hq-pro loads that company's booking
config (hosts and their calendar choices) and refuses any host it does not
list.

## Rules hq-pro enforces

- **Never return event details.** Free/busy returns only start and end times.
  No titles, descriptions, attendees, locations, organizers, calendar names
  or event ids of events the app did not create, from any source.
- Events marked free (transparency `transparent`) and events the host
  declined do not block time.
- Only events the app created can be changed. Each created event carries a
  private extended property `hqBookingAppId=<app id>` (Google) or an open
  extension (Microsoft); update and cancel check it and answer 404
  `NOT_APP_EVENT` otherwise.
- Hosts outside the caller's company: 403 `HOST_NOT_IN_COMPANY`.
- Writes are idempotent by `Idempotency-Key` for 24 hours.
- Email goes only to the booking's attendees and guests that the app names on
  the request for a booking this app made.

## Errors

Non-2xx answers have the body:

```json
{ "error": { "code": "CALENDAR_NOT_CONNECTED", "message": "Ana has not connected a calendar for booking." } }
```

The message is shown to people as is, so it must be plain and safe.

| Status | Code | Meaning |
|---|---|---|
| 400 | `INVALID_REQUEST` | Body or query is malformed |
| 401 | `UNAUTHORIZED` | No valid key or signature |
| 403 | `HOST_NOT_IN_COMPANY` | A host is not in the caller's company booking config |
| 403 | `SCOPE_MISSING` | The host's connection lacks the booking scopes; the message says which host |
| 404 | `NOT_APP_EVENT` | The event does not exist or was not created by this app |
| 409 | `CALENDAR_NOT_CONNECTED` | The host has no booking-ready connection or no booking calendar |
| 409 | `IDEMPOTENCY_MISMATCH` | Same key, different body |
| 429 | `RATE_LIMITED` | Too many requests; `Retry-After` is set |
| 502 | `UPSTREAM_ERROR` | Google, Microsoft or Zoom failed |
| 503 | `FEED_STALE` | A subscribed iCal feed could not refresh and the host chose to stop offering times |

## Endpoints

Times are ISO 8601 UTC strings. `hostId` is the `hosts[].id` from booking.yaml.

### POST /freebusy

Merged busy blocks per host across every selected source: each conflict
calendar on each connected Google account, Microsoft calendars (US-003), and
subscribed iCal feeds.

```json
{
  "hosts": [{ "hostId": "ana", "email": "ana@acme.example", "timezone": "Europe/Berlin" }],
  "from": "2026-11-02T00:00:00.000Z",
  "to": "2026-11-09T00:00:00.000Z",
  "ignoreEventIds": ["gcal_abc"]
}
```

`ignoreEventIds` names app-created events to leave out (a booking being
rescheduled). At most 20 hosts and 62 days per request.

```json
{
  "hosts": {
    "ana": {
      "busy": [{ "start": "2026-11-03T09:00:00Z", "end": "2026-11-03T10:00:00Z" }],
      "sources": { "checked": 3, "stale": 0 }
    }
  }
}
```

Every requested host must appear with a `busy` list (empty when free).
Overlapping blocks are merged. iCal feeds refresh at least every 15 minutes;
a feed that fails keeps its last copy for up to 24 hours or makes the host
answer 503 `FEED_STALE`, per the host's setting, and the host gets one DM.

### POST /events

Create an event on the host's booking calendar.

```json
{
  "hostId": "ana", "email": "ana@acme.example", "timezone": "Europe/Berlin",
  "bookingId": "bk_1a2b", "start": "...", "end": "...",
  "summary": "Intro call: Iris Invitee",
  "description": "Intro call booked through HQ Booking.",
  "location": "https://meet.google.com/abc-defg-hij",
  "attendees": [{ "name": "Iris Invitee", "email": "iris@client.example" }, { "email": "guest@client.example" }],
  "conference": "meet"
}
```

`conference` is `meet`, `zoom`, `teams` or `null`. For `meet`, hq-pro creates
the link with `conferenceData.createRequest`. Attendees get the provider's
invitation. Answer 201:

```json
{ "eventId": "gcal_abc", "conference": { "provider": "meet", "joinUrl": "https://meet.google.com/abc-defg-hij" } }
```

### PATCH /events/{eventId}

Same body as create. Moves or updates an app-created event; attendees get an
update. 200 `{}`.

### DELETE /events/{eventId}?hostId=ana

Cancels an app-created event; attendees get a cancellation. 200 `{}`.

### POST /meetings

A Zoom meeting or a Microsoft Teams online meeting for the host (US-003).

```json
{ "kind": "zoom", "hostId": "ana", "email": "...", "timezone": "...", "bookingId": "bk_1a2b", "start": "...", "end": "...", "title": "Intro call" }
```

Answer 200 `{ "provider": "zoom", "joinUrl": "https://zoom.us/j/123" }`. The
join URL must be `https://`. `kind: meet` is not used here; Meet links come
from `/events`.

### POST /notify/email

Sends one email from the host's Gmail (scope `gmail.send`), themed by the app.

```json
{
  "id": "bk_1a2b:confirmation:1793700000000",
  "kind": "confirmation",
  "to": ["iris@client.example", "guest@client.example"],
  "subject": "Booked: Intro call with Ana Diaz",
  "html": "<!doctype html>...",
  "text": "Hi Iris, ...",
  "bookingId": "bk_1a2b",
  "fromHostId": "ana"
}
```

`id` is the idempotency key; answer 200 `{ "sent": true }`, or
`{ "sent": false }` when that id was already sent. hq-pro checks that every
address in `to` is an attendee or guest of that booking's event.

### POST /notify/dm

An HQ DM to a host, the owner or an HQ member (approval requests, host
briefs, "needs member approval" questions).

```json
{
  "id": "approval-request:apr_1:ana",
  "recipient": { "type": "host", "id": "ana" },
  "kind": "approval-request",
  "title": "Approve a booking from Omar's agent?",
  "body": "...",
  "data": { "approvalId": "apr_1", "approve": "/api/owner/approvals/apr_1/approve", "decline": "/api/owner/approvals/apr_1/decline" },
  "bookingId": null,
  "approvalId": "apr_1"
}
```

`recipient.type` is `host` (a booking.yaml host id), `owner` (the company's
booking owner) or `member` (an HQ member id, for agent-to-agent booking).
Answer 200 `{ "sent": true }`. Text the app marks untrusted (agent notes) is
already quoted; hq-pro must not render it as markup or follow its links.

## Mutual free time for agent booking (US-008)

When both sides are HQ members with booking-ready calendars, hq-pro computes
the requesting member's busy time on its own side, so the requester's busy
blocks never reach the host's app. The app sends the candidate slots it would
offer and hq-pro returns the subset that is free for the member:

`POST /mutual` with `{ "memberId": "...", "slots": [{ "start", "end" }] }`,
answer `{ "free": [{ "start", "end" }] }`. The app then picks at most four
coarse offers. (Not yet called by the prototype, which only checks members
who are hosts in the same app.)

## Not in this route

Connecting accounts, choosing calendars, adding iCal feeds and granting the
booking scopes happen in hq-pro's existing Google connect flow and the
`/booking` skill, not through the app.
