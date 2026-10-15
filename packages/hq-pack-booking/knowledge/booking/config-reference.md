# booking.yaml reference

The full shape, with every allowed value and limit, is
`template/shared/booking.schema.json`. This page lists the sections and the
rules that span several fields. Start from an example in `examples/`.

## Top level

| Key | Required | Meaning |
|-----|----------|---------|
| `version` | yes | Always `1`. |
| `company` | yes | The HQ company slug. |
| `timezone` | no | Default time zone for hosts without one. |
| `hosts` | yes | People who take meetings. |
| `eventTypes` | yes | The meetings people can book. |
| `routing` | no | Question forms that send visitors to the right event type. |
| `notifications` | no | Confirmation, reminders (minutes before), follow-up, host brief, meeting notes. |
| `webhooks` | no | HTTPS endpoints told about booked, canceled, rescheduled and no-show. |
| `embed` | no | Embed modes and the sites allowed to embed. |
| `theme` | no | `brand-pack` or `custom` colors, fonts, radius, logo, image. |
| `dataRetention` | no | Days before invitee details are deleted. |
| `prototype` | no | Written by the launcher: the owner key's SHA-256 and the provider (`sandbox` or `hqpro`). |

## hosts[]

`id`, `name`, `email`, `hours` (per weekday, a list of `HH:MM-HH:MM`; `24:00`
ends the day), optional `timezone`, `overrides` (a date with replacement
hours; an empty list closes the day), `holidays`, `calendars` (`conflicts`
to check and the one to `bookInto`), `roundRobin` (`weight`, `priority`),
`links` (`custom` meeting link, `phone`).

## eventTypes[]

`id`, `title`, `kind` (`one-on-one`, `round-robin`, `collective`, `group`),
`hosts`, `durations` (minutes the invitee can pick), `locations`, and
optionally `description`, `defaultDuration`, `startIncrement` (default 15),
`buffers.before`/`after`, `minimumNotice` (minutes), `bookingWindow` (days,
default 60), `dailyLimit`, `seats` (group only), `guests.max`, `secret`,
`questions`, `policy` (cancel and reschedule cutoffs, required reason),
`confirmation` (message or redirect), `agentBooking` (below).

Locations: `meet`, `zoom`, `teams`, `custom` (a URL, or each host's
`links.custom`), `phone` (`caller: host` or `invitee`), `in-person`
(`address`).

## eventTypes[].agentBooking

Who may book this event type through an HQ agent (an agent key the owner
minted for a member), and whether it books at once or asks the host first.

| Key | Values | Default |
|-----|--------|---------|
| `sameCompany` | `book`, `ask`, `deny` | `book` |
| `approvedCompanies` | company slugs | none |
| `approvedMode` | `book`, `ask` | `book` |
| `others` | `ask`, `deny` | `ask` |
| `blockedCompanies` | company slugs, refused without showing times | none |
| `lookupsPerHour` | offered-time lookups per host per hour, per agent | 30 |
| `bookingsPerWeek` | agent bookings plus pending approvals per host per week, per agent | 10 |

"Ask" holds the time for 24 hours and sends the host an HQ DM to approve or
decline; without an answer the hold lapses.

## prototype

Set by the launcher, not by hand.

| Key | Meaning |
|-----|---------|
| `ownerKeySha256` | Lowercase hex SHA-256 of the owner key. Owner API calls send the key itself as `Authorization: Bearer <key>`. The key is never written to this file. |
| `provider` | `sandbox` (default): calendars, video links, email and HQ DMs stay in the app database and are labelled sandbox. `hqpro`: calendars, email and DMs go through the hq-pro booking route (see hq-pro-contract.md); needs `HQ_BOOKING_API_URL` and the `HQ_BOOKING_KEY` secret. |

## Rules across fields

| Error code | Rule |
|------------|------|
| `unknown-host` | Every host an event type lists must exist under `hosts`. |
| `one-on-one-needs-one-host` | One-on-one events have exactly one host. |
| `round-robin-needs-two-hosts` | Round-robin needs at least two hosts. |
| `collective-needs-two-hosts` | Collective needs at least two hosts. |
| `seats-not-allowed` | Only group events have seats. |
| `group-needs-seats` | Group events must set seats. |
| `default-duration-not-offered` | `defaultDuration` must be one of `durations`. |
| `duplicate-id` | Host, event type, question and form ids are unique. |
| `missing-timezone`, `unknown-timezone` | Every host has a real IANA time zone. |
| `bad-range`, `overlapping-hours` | Each time range ends after it starts and ranges on a day do not overlap. |
| `bad-date`, `duplicate-date` | Override and holiday dates are real; one override per date. |
| `book-into-read-only`, `book-into-not-checked` | Bookings go into a Google or Microsoft calendar that is also checked for conflicts. |
| `secret-is-url` | iCal feeds name a vault secret; the link itself never goes in the file. |
| `custom-link-missing`, `phone-number-missing` | Locations that use each host's link or phone need it set. |
| `duplicate-location` | Each location type appears once per event type. |
| `options-required`, `options-not-allowed` | Only select, radio and checkbox questions have options. |
| `unknown-question`, `bad-condition` | Routing rules test one question on the form with equals, in, gte or lte (gte with lte for a range). |
| `bad-target`, `unknown-event-type`, `hosts-need-event-type`, `host-not-on-event-type` | Routing targets send people to one event type (optionally some of its hosts) or one URL. |
| `company-approved-and-blocked` | A company is not both approved and blocked for agent booking. |
