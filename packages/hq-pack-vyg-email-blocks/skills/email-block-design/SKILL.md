---
name: email-block-design
description: Interview a brand on interactive-email goal, data, and style, then author a VYG template with <vyg-block> tags inside the brand shell and run email_template_validate until clean. Use when the user wants a cart, subscription, review, form, carousel, or custom-action email, or says "design an email block", "author a cart template", or "add interactive email".
---

# /email-block-design — author an interactive email template

Walk a brand from a goal to a **validated** VYG template that contains one or
more `<vyg-block>` tags. You do not invent a renderer. VYG expands the tags at
send time into three tiers (links, kinetic, AMP). Your job is the brand shell
and a contract-valid `config`.

Knowledge: `vyg-email-blocks` (block-contracts, design-guide, kinetic-limits,
amp-prerequisites).

## Prerequisites

1. **MCP connected.** Brand users: `https://api.vyg.app/mcp` (web-client OAuth).
   Staff may use `https://agents-mcp.vyg.app/mcp`. If `email_block_contracts_list`
   is missing from `tools/list`, stop and point at the pack README — do not
   improvise HTML as if it will send.
2. **Email channel** on the brand (`beta:email-channel`). A channel-gate error
   from any email tool means the brand is not enabled; say so.
3. Resolved **brand** (the MCP session's `bid`). Never mix another brand's
   templates, catalog, or webhook hosts.

## Step 1 — Interview

Ask, in one or two grouped questions (AskUserQuestion when available):

| Topic | What you need |
|-------|----------------|
| **Goal** | Abandoned cart, post-purchase subscription manage, review request, quiz, restock carousel, one-click waitlist, other. |
| **Data** | Shopify cart / catalog collections? Subscription provider (ReCharge, Stay AI, Skio)? Review platform (Judge.me, Okendo, …)? Webhook host for custom_action? |
| **Style** | Brand colors, fonts, CTA copy, max width (default 600px), whether to show compare-at prices, accessory upsells. |

Do not skip this. A cart block without catalog context degrades; a subscription
block without `subscription` context renders `BLOCK_NO_SUBSCRIPTION`.

## Step 2 — Load the live contract

Call **`email_block_contracts_list`**. It returns JSON Schema, `example_config`,
actions, required context, and this brand's webhook HMAC key (custom_action
webhook mode). Treat that payload as source of truth over the bundled knowledge
if they ever drift.

There is **no** `email_block_validate` tool. Validation is **`email_template_validate`**.

## Step 3 — Author the template

Write HTML to the project folder:

```
email-blocks/<slug>.html          # full body_html
email-blocks/<slug>.meta.md       # name, subject, preview_text, block types
```

Rules (the design-guide knowledge is the long form):

1. **One contract, three tiers.** Author the shell once. Do not emit three
   templates or any JavaScript / `on*` handlers / `<script>`.
2. **Tag syntax.** Config is a JSON object in a quoted attribute. The inner
   HTML is the brand shell and **must contain exactly one** `{{{block.body}}}`
   slot — not zero, not two, not `{{block.body}}`.

```html
<vyg-block type="cart" config='{"max_items":3,"show_compare_at":false}'>
  <table width="100%" cellpadding="0" cellspacing="0" role="presentation">
    <tr><td style="padding:16px 0;">{{{block.body}}}</td></tr>
  </table>
</vyg-block>
```

3. **Required chrome.** A subject. An HTML body. A working unsubscribe link
   (`href="{{unsubscribe}}"`). `{{brand.address}}` in the footer (warning if
   missing; live sends refuse without a postal address).
4. **No scripts, no handlers, no `javascript:` URLs.** AMP-aware exceptions
   exist only inside the AMP part VYG generates — never in `body_html`.
5. **Supported variables only.** Call `email_template_variables_list` if unsure.
   Unknown variables render blank and warn. `{{{block.body}}}` is the slot, not
   a Mustache variable you interpolate yourself.
6. **Strict configs.** Extra keys fail `BLOCK_CONTRACT_INVALID`. See
   block-contracts.md. Cart cannot set both `discount_code` and `discount_mint`.

### Cart starter (abandoned checkout)

```html
<!DOCTYPE html>
<html>
<body>
  <table width="600" cellpadding="0" cellspacing="0" role="presentation" style="margin:0 auto;font-family:Arial,Helvetica,sans-serif;color:#111111;">
    <tr><td style="padding:24px 16px 8px;">
      <p style="margin:0 0 12px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;">{{brand.name}}</p>
      <h1 style="margin:0 0 16px;font-size:28px;line-height:1.2;">You left something behind, {{contact.first_name}}</h1>
      <vyg-block type="cart" config='{"max_items":6,"show_compare_at":false}'>
        <div class="brand-cart">{{{block.body}}}</div>
      </vyg-block>
      <p style="margin:24px 0 8px;font-size:12px;color:#555;">{{brand.address}}</p>
      <p style="margin:0;font-size:12px;"><a href="{{unsubscribe}}">Unsubscribe</a></p>
    </td></tr>
  </table>
</body>
</html>
```

Subject example: `{{contact.first_name}}, your cart is waiting`.

If the brand wants accessories, add `accessory_collection_handle` (must exist in
catalog or you get `BLOCK_COLLECTION_UNKNOWN`). If they want a one-use percent
code, `discount_mint: { "percent": 10, "expires_hours": 48 }` — not together
with `discount_code`.

## Step 4 — Validate until clean

Call **`email_template_validate`** with `subject` + `body_html` (the files you
just wrote). Do **not** save yet.

- `ok: false` → fix every `severity: error` and retry. Use `line` / `path` hints.
- Common errors: `BLOCK_CONTRACT_INVALID`, `BLOCK_SLOT_MISSING`, `BLOCK_UNKNOWN`,
  `SCRIPT_BLOCKED`, `HANDLER_BLOCKED`, `URL_BLOCKED`, `URL_NOT_ALLOWLISTED`,
  `AMP_INVALID`, `UNSUBSCRIBE_MISSING`.
- Warnings (`BLOCK_CATALOG_STALE`, missing address) may remain; surface them,
  do not silently ignore catalog-stale on a cart/carousel.

Loop until `ok: true`. Do not declare the design done with errors.

## Step 5 — Save

VYG templates are **live on save**. There is no agent "draft" status on
`email_template_create` (legacy drafts exist only for imports). The project
files *are* the working draft.

Once validate is clean, call **`email_template_create`** with `name`, `subject`,
`body_html`, optional `preview_text`. Record `template.id` in
`email-blocks/<slug>.meta.md`.

If create is rejected with quality issues, fix and retry — nothing was written.

## Operating rules

1. **Contract first.** `email_block_contracts_list` before authoring.
2. **Validate before create.** Never `email_template_create` an unvalidated body.
3. **Exactly one `{{{block.body}}}` per tag.**
4. **No JavaScript in `body_html`.** Kinetic is CSS; AMP is generated.
5. **Brand scope.** One MCP session, one brand.
6. **Webhook custom actions:** `https` only; host must be on the brand allowlist
   (verified sending-domain roots + Shopify host + staff-set extra hosts). HMAC
   key comes from `email_block_contracts_list` — never invent one, never print
   the root secret (it is not returned).
7. **Do not** put card data, phone numbers, or PII in URLs or `config`.

## Next

- `/email-block-preview` — write links / kinetic / AMP HTML for review.
- `/email-block-test-send` — seed-inbox interactive send (needs the saved id).
- `/email-block-publish` — attach to a flow or broadcast.
