---
name: email-block-test-send
description: Send one interactive test copy of a VYG email template to the signed-in user's inbox (dry-run action tokens) and walk an Apple Mail + Gmail checklist. Use when the user says "test send", "send me the cart email", "seed inbox", or after /email-block-preview.
---

# /email-block-test-send — interactive seed-inbox send

Send **one** interactive test to the **signed-in account's email**. It cannot
target anyone else. Action tokens are minted with `payload.dry_run=true`: taps
simulate cart/subscription writes, record `email_interactions` with
`meta.dry_run=true`, and **do not** write to Shopify or the subscription
provider. The `email_sends` row is `is_test`.

Use **`email_template_test_send_interactive`**, not `email_template_test_send`.
The latter is the static/simple test send and will not mint dry-run action
tokens.

## Prerequisites

- MCP connected as the user who should receive the mail (brand user on
  `https://api.vyg.app/mcp` for the smoke path).
- A **saved** `template_id` (create via `/email-block-design` first). Archived
  templates cannot be sent.
- A **verified sending domain**. Call `email_domain_list` if unsure. Pass
  `from_domain` when the brand has more than one.

## Step 1 — Send

```
email_template_test_send_interactive
  template_id: <uuid>
  from_domain: <optional verified domain>
```

Success looks like:

```
sent: true
is_test: true
action_dry_run: true
to: <the signed-in user's email>
tokens_minted: <n>
```

If it errors:

| Message | What to do |
|---------|------------|
| no email address on file | The VYG user record has no email; cannot send. |
| a verified sending domain is required | `email_domain_add` + DNS + `email_domain_recheck`. |
| template is archived | Create a new template; do not un-archive. |
| unresolved action-token sentinels | Renderer/mint bug — do not retry blindly; report. |

`ses_dry_run: true` means SES itself was stubbed (dev). Production smoke wants
`ses_dry_run: false` with `sent: true`.

## Step 2 — Client checklist

Ask the brand to open the message in **Apple Mail** and **Gmail**. Record what
they see. This is the US-007 matrix; full notes in `kinetic-limits.md`.

### Apple Mail (iOS 18+/macOS Sonoma+)

- [ ] Kinetic stage visible (variant pills, qty 1–5, carousel prev/next, or
      subscription radios) — **not** just a static table.
- [ ] Tapping a label updates the Checkout / confirm link (`?c=`).
- [ ] Fallback links are in the HTML but hidden while `:checked` works.
- [ ] Gate checkbox is **not** `display:none` (if kinetic looks like links,
      the shell may have broken the support gate — return to design).
- [ ] Mail Privacy Protection does **not** fire actions (MPP prefetches images
      only). A tap is required to spend a token.

### Gmail (web and Gmail iOS)

- [ ] Looks like the **links** table (product rows + Checkout / View cart).
- [ ] No visible radios / steppers (stage stays inline-hidden).
- [ ] Checkout / View cart links work (they carry `?c=0` when choices exist).
- [ ] AMP part: only if the sending domain's `amp_registration_status` is
      `verified`. Otherwise Gmail shows the HTML part — expected.
- [ ] Clipping: body should stay under the 95 KB links / 100 KB kinetic /
      102,400 B AMP budgets. If Gmail clips, the template is too large.

### Outlook for Windows (optional)

- [ ] Links table only. Kinetic markup is dropped by the Word renderer
      (`<!--[if !mso]>…`). No quantity stepper, no pills.

### After a tap (any client)

- [ ] Redirect or hosted confirm/result page loads.
- [ ] Write actions confirm on POST (GET from a scanner must not mutate).
- [ ] Because this send is `dry_run`, Shopify/ReCharge/Stay/Skio must **not**
      show a real cart rebuild or skip. The interaction row should exist.

## Step 3 — Report

Write `email-blocks/<slug>.test-send.md` with `send_id`, `to`, `from`,
`tokens_minted`, `action_dry_run`, and the checklist results. Do not print
action tokens or URLs that contain them into chat beyond the send confirmation.

## Operating rules

1. **Self-only.** Never ask for a different recipient; the tool ignores that
   anyway and would error if it could.
2. **Interactive tool only** for block templates.
3. **Dry-run is the point.** Do not "upgrade" to a live action from this skill.
4. AMP in the MIME part requires domain `amp_registration_status=verified`.
   Unverified domains still send HTML. See `amp-prerequisites.md`.
