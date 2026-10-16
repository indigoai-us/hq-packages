# Sandbox now, real providers later

The prototype runs every outside service as a sandbox inside the app's own
database (`prototype.provider: sandbox`). Responses say `sandbox: true`.

| Part | Prototype (sandbox) | Real version |
|------|---------------------|--------------|
| Busy times | Sandbox calendars per host, inside the app | Google Calendar free/busy, Microsoft Graph `getSchedule`, iCal feeds from the vault |
| Calendar events | Sandbox events, readable through the owner API's sandbox calendar route | Created, moved and canceled on the host's Google or Outlook calendar |
| Video links | `https://sandbox.hq-booking.invalid/meet/...` (do not open) | Google Meet, Zoom or Teams links |
| Email | Stored in the outbox (`owner outbox`), never sent | Sent through Gmail (or HQ's mail sender) |
| HQ DMs to hosts and members | Stored as sandbox notifications | Real HQ DMs, including the calendar connect link for new hosts |
| New hosts | Booking ready at once | Left out of open times until they connect a calendar |
| Agent keys | Minted by the owner with `owner agent-key` | Issued by hq-pro from the member's HQ sign-in |

Switching a company to the real providers means `prototype.provider: hqpro`
(calls the hq-pro booking route in `hq-pro-contract.md`), which needs the
provider approvals below.

## What each approval unlocks

**Google (OAuth verification of sensitive scopes).** HQ's existing Google
sign-in app needs `calendar.events`, `calendar.freebusy` and `gmail.send`
approved. That unlocks reading Google hosts' free/busy, writing booking events
with Meet links into their calendars, and sending confirmation and reminder
emails from Gmail. Google reviews in about 10 business days after a demo video
of the working booking flow, so the video waits for a working end-to-end
booking page. These scopes are sensitive, not restricted, so no security
assessment (CASA) is needed for them.

**Zoom (a General app published as Unlisted).** A user-managed app named HQ
Booking with granular meeting create, update and delete scopes and user read.
That unlocks Zoom links for hosts outside Indigo's own Zoom account. Zoom
publishes no review time; plan for weeks, including at least one round of
fixes. It needs a deauthorization endpoint, a support page and verified
domains.

**Microsoft (an Entra app registration).** Delegated `User.Read`,
`offline_access`, `Calendars.ReadWrite` and possibly `OnlineMeetings.ReadWrite`.
That unlocks Outlook free/busy, Outlook events and Teams links. Microsoft does
not review the app, but publisher verification avoids an "unverified" warning,
and some customer tenants need an admin to consent.

The drafted submissions, owner steps and open decisions are in the Indigo
company's HQ Booking project, in its preflight notes (one file per provider
plus a summary). They are not copied here.
