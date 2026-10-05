---
name: email-block-publish
description: Save a validated interactive email template as live (if needed) and attach it to a VYG flow or broadcast. Use when the user says "publish the email", "put this on the abandoned-cart flow", "send this as a broadcast", or after a successful /email-block-test-send.
---

# /email-block-publish — live template on a flow or broadcast

Attach the validated template to something that actually sends: an automated
**flow** or a **broadcast**. VYG `email_template_create` already saves **live**
(usable in flows). This skill is the attach step, plus a create if the working
copy was never saved.

## Prerequisites

- MCP connected (brand user on `https://api.vyg.app/mcp`, or staff on
  `https://agents-mcp.vyg.app/mcp`).
- `email_template_validate` is `ok: true` on the body you are publishing.
- A verified sending domain (`email_domain_list`).
- Brand postal address on file (`email_brand_address_get`) — going live
  refuses without it.
- For Shopify triggers (`checkout/abandoned`, `order/delivered`): a connected
  store. Custom E-Com brands use `custom_event` instead.

## Step 1 — Confirm the live template

If `email-blocks/<slug>.meta.md` already has a `template_id`, call
`email_template_get`. Status must be `live` (not `archived`).

If the working copy is only files on disk:

1. `email_template_validate` with `subject` + `body_html` until `ok: true`.
2. `email_template_create` (live on save). Record the id.

To edit an existing live template, `email_template_update` with
`expected_version` from `email_template_get`. Archived → create a new one.

## Step 2 — Choose the vehicle

Ask: **flow** (event-triggered, e.g. abandoned checkout) or **broadcast**
(segment, one-shot or recurring)?

### Flow — `email_flow_create`

Created **paused**. Review with `email_flow_get`, then `email_flow_activate`.

Exactly one trigger:

- `trigger_event`: `"checkout/abandoned"` or `"order/delivered"` (Shopify), or
- `custom_event`: `{ "type": "<brand event>" }` (Custom E-Com).

Email step:

```
action: { type: "email", template_id: "<live uuid>", from_domain: "<optional>" }
```

Do **not** use `type: "resend"` for block templates. Resend is a different rail
and rejects `<vyg-block>` tags.

Optional wait before the email step (`wait` field on create).

Optional static-vs-interactive A/B after the flow exists:

```
email_flow_variant_add
  flow_id: <id>
  interactive_pair: true
```

That derives a static control via `render(static)` and adds the interactive
template as variant `b`. Requires no test already running.

Then, when the brand is ready: `email_flow_activate`. Surface warnings
(unverified domain, missing address) instead of activating over them.

### Broadcast — `email_broadcast_create`

Needs `segment_id` from `email_segment_list` / `email_segment_create`, a live
`template_id`, and a schedule (`one_shot` `send_at` or recurring
`first_send_at` + `every_hours`). The broadcast is scheduled immediately;
pause with `email_broadcast_pause`.

Confirm the segment and send time with the user before calling create.
Unsubscribed and suppressed addresses are skipped automatically.

## Step 3 — Record

Write `email-blocks/<slug>.publish.md`: template id + version, flow id or
broadcast id, trigger/segment, whether variants were added, next step
(activate / wait for send_at).

## Operating rules

1. **Validate is still the gate.** Do not attach a body that fails quality
   gates just because an older live row exists — update first.
2. **Paused flows.** Create paused; activate only after the brand confirms.
3. **Broadcasts send.** Treat create as a send schedule; confirm first.
4. **Email node, not Resend,** for interactive templates.
5. **One brand.** Never copy another company's `template_id` into this brand.
6. AMP still depends on per-domain registration. Publishing a block template
   to a domain that is not AMP-verified is allowed; Gmail gets HTML+kinetic
   fallback. Say that plainly.
