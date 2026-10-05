# AMP-for-Email registration prerequisites (US-016)

Gmail and Yahoo render a live AMP part only when the **sending domain** is
registered for dynamic email. VYG attaches `text/x-amp-html` in SES Raw MIME
**only when** `ampHtml` is present **and**
`brand_email_domains.amp_registration_status = verified`. Otherwise the send
is Simple HTML (links + kinetic in the HTML part). Source:
`docs/features/email-amp-registration.md` and `libs/core/email/src/data/domains.ts`.

Interactive templates are still worth sending before AMP is verified: Apple
Mail gets kinetic, everyone else gets links. AMP is the Gmail/Yahoo live-data
upgrade, not the floor.

## When the AMP part ships

| Condition | MIME |
|-----------|------|
| No `<vyg-block>` in the template | Simple HTML (`amp_html` is NULL) |
| Blocks present, domain not `verified` | Simple HTML; AMP assembled on save but **not** attached |
| Blocks present, domain `verified`, AMP part ≤ 102,400 B and broker Detail under 240 KB | SES Raw: HTML + `text/x-amp-html` |
| AMP part > 102,400 B or Detail over budget | AMP dropped, warning `AMP_DROPPED_SIZE`, Simple HTML |

Live AMP `amp-list` data comes from **local** catalog tables and a 5-minute
subscription cache, never from Shopify or the subscription platform on open.

## Prerequisites (per sending domain)

1. DKIM, SPF, and DMARC aligned on the From domain (SES identity `verified`).
   Use `email_domain_add` / `email_domain_recheck`.
2. Sending history on the domain (ramp complete or at least a week of
   production mail).
3. Low spam/complaint rate (deliverability guard not paused).
4. A sample AMP4EMAIL message Google/Yahoo can open, sent from `hello@<domain>`.

## Forms (manual — VYG does not submit them)

- Google: https://developers.google.com/gmail/ampemail/register
- Yahoo: https://senders.yahooinc.com/amp

Confirm the current form URLs before a run; vendors move these.

Sample-send destinations VYG documents:

- Google: `ampforemail.whitelisting@gmail.com`
- Yahoo: `amp-email-onboarding@yahooinc.com`

After both forms are submitted, record the refs with
**`email_domain_amp_request`** (`domain_id`, `google_form_ref`,
`yahoo_form_ref`). That tool does **not** submit the vendor forms.

## State machine

`brand_email_domains.amp_registration_status`:

| From | Event | To | Guard |
|------|--------|----|--------|
| `none` | `request` | `requested` | Google **and** Yahoo form refs required |
| `requested` | `request` | `requested` | updates form refs |
| `requested` | `auto_verify` | `verified` | ≥2 distinct recipients on ≥2 UTC days of Google-proxy amp-list hits |
| `requested` | `ops_verify` | `verified` | staff hub |
| `verified` | `revoke` | `revoked` | staff |
| `requested` | `reject` | `rejected` | staff |
| `rejected` | `request` | `requested` | 30 days since `amp_rejected_at` + new form refs |

Invalid transitions error. A request older than 21 days with no Google-proxy
hit is flagged stale (`AMP_REGISTRATION_STALE`).

Auto-verify looks for amp-list fetches whose user-agent contains
`Google-AMPHTML`. CORS on the data route is pinned to AMP proxy origins
(`mail.google.com`, `mail.yahoo.com`, `amp.gmail.dev`).

## Authoring implications

- Do not put `<script>` or `on*` handlers in `body_html`. AMP scripts are
  injected only into the generated AMP document (`cdn.ampproject.org` AMP
  runtime). `SCRIPT_BLOCKED` / `HANDLER_BLOCKED` still fire on the HTML body.
- `AMP_INVALID` is a quality-gate **error** on save: the vendored AMP4EMAIL
  validator rejected the assembled document. Fix the shell (invalid nested
  markup, disallowed tags) and re-validate.
- `amp-list` `src` is rewritten to `/api/email/amp/<token>` at mint. You do
  not author amp-list URLs.
- Cross-brand tokens 403 and write no interaction row.
