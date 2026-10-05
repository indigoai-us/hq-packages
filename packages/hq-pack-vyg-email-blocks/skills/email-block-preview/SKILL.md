---
name: email-block-preview
description: Render a VYG interactive email at all three tiers (links, kinetic, AMP) via email_template_preview_tiers and write the HTML into the project folder for human review. Use when the user says "preview the email", "show all tiers", "render kinetic and AMP", or after /email-block-design.
---

# /email-block-preview — three-tier HTML for review

Render the working template at **links**, **kinetic**, and **AMP** without
sending. Write each body to the project folder so the brand can open them in a
browser. Tokens are **not** minted; action hrefs stay as `__VYG_ACTION_<n>__`
sentinels. That is expected in a preview.

## Prerequisites

- MCP connected (brand user on `https://api.vyg.app/mcp`, or staff on
  `https://agents-mcp.vyg.app/mcp`).
- A `template_id` from `/email-block-design`, **or** `subject` + `body_html`
  from `email-blocks/<slug>.html`. Prefer `template_id` when it exists.

## Step 1 — Render

Call **`email_template_preview_tiers`** with either:

- `{ "template_id": "<uuid>" }`, or
- `{ "subject": "...", "body_html": "..." }`

Optional `recipient_context` (`email`, `first_name`, `last_name`, `checkout`,
`subscription`). Omit it to get the brand's details plus a two-item sample cart
and an active sample subscription.

Do **not** use `email_template_preview` for this skill — that is the single
default-tier preview. This skill needs all three tiers.

## Step 2 — Write files

Create `email-blocks/previews/` if needed. Write three UTF-8 HTML files:

| File | Source field |
|------|----------------|
| `email-blocks/previews/<slug>-links.html` | `links.html` |
| `email-blocks/previews/<slug>-kinetic.html` | `kinetic.html` |
| `email-blocks/previews/<slug>-amp.html` | `amp.html` (may be `null` when the body has no `<vyg-block>` — then write a one-line stub that says AMP was not assembled) |

Use the template name / slug from `email-blocks/<slug>.meta.md` when present,
otherwise `preview`. Overwrite previous previews for the same slug.

If `amp.html` is null on a template that **has** blocks, say so — AMP assembly
failed or was skipped; check `issues` / `amp.warnings`.

## Step 3 — Report

Summarize, do not dump the HTML in chat:

- Byte sizes of each file vs budgets (design-guide): links **95,000** UTF-8
  bytes delivered, kinetic **100,000** (over → `BLOCK_DEGRADED_SIZE`, links
  fallback), AMP part **102,400** (over → `AMP_DROPPED_SIZE`, AMP dropped at
  send).
- `links.warnings`, `kinetic.warnings`, `amp.warnings`, and top-level `issues`.
- Whether sentinels (`__VYG_ACTION_`) are present (yes in preview; they mint on
  send).

Tell the brand to open the three files locally. Kinetic interactivity needs a
client that honors `:checked` sibling CSS (Safari is a decent stand-in for
Apple Mail). Gmail/Outlook will look like the links file — that is the product.

## Operating rules

1. Always write **three** files, even if AMP is a stub.
2. Never mint tokens and never send from this skill.
3. Never "fix" sentinels into real URLs in the preview files.
4. If validate issues came back on the preview payload, offer to return to
   `/email-block-design` rather than publishing over errors.
