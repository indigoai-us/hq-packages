# hq-pack-vyg-email-blocks

![hq-pack-vyg-email-blocks — a brass mailbox on a walnut desk, interactive mail](cover.jpg)

Teach a brand's Claude Code or Codex how to design **unconstrained interactive
email** against VYG's block contract — cart, subscription, custom action,
review, form, carousel — then validate, preview all three render tiers, test-send,
and publish into a flow or broadcast. VYG does not have to build each design.

The **engine** lives in VYG (template render, action tokens, AMP MIME, SES).
This pack is the **experience layer**: skills that drive the MCP tools, plus
the contract and design knowledge those skills post against.

## MCP connection (not in the manifest)

Policy: the pack manifest (`package.yaml`) carries no credentials and no
connections contract. Connect MCP in the host, then install the pack.

| Who | Endpoint | OAuth |
|-----|----------|-------|
| **Brand users** (primary) | `https://api.vyg.app/mcp` | web-client OAuth |
| **Staff / agents** | `https://agents-mcp.vyg.app/mcp` | web-front OAuth |

Brand agents must authenticate as a **brand user** on the primary server. Staff
may use the agents server as an alternative; the same email + block tools are
mounted on both (US-024 adapter). Tool access is brand-match on the JWT `bid`
claim. The brand needs `beta:email-channel` (fleet-wide as of the email rollout).

Example (Claude Code, brand user):

```bash
claude mcp add --transport http vyg https://api.vyg.app/mcp
```

Example (staff / agent role):

```bash
claude mcp add --transport http vyg-agents https://agents-mcp.vyg.app/mcp
```

Never put API keys, OAuth client secrets, or these URLs in `package.yaml`.

## Install

```bash
hq pack install @indigoai-us/hq-pack-vyg-email-blocks                              # npm (after marketplace publish)
hq pack install github:indigoai-us/hq-packages#packages/hq-pack-vyg-email-blocks   # git
hq pack install ./packages/hq-pack-vyg-email-blocks                                # local
```

(`hq install` is an alias of `hq pack install` on current hq-core.)

## What it ships

| Skill | Does |
|-------|------|
| `/email-block-design` | Interview goal, data, and style. Author a template with `<vyg-block>` tags inside the brand shell. Run `email_template_validate` until clean. Save via `email_template_create`. |
| `/email-block-preview` | Render links, kinetic, and AMP via `email_template_preview_tiers`. Write three HTML files into the project folder. |
| `/email-block-test-send` | Interactive test send (`email_template_test_send_interactive`) to the signed-in user's inbox, plus an Apple Mail / Gmail checklist. |
| `/email-block-publish` | Attach the live template to a flow (`email_flow_create`) or broadcast (`email_broadcast_create`). Optional static-vs-interactive A/B via `email_flow_variant_add`. |

Knowledge (`knowledge/vyg-email-blocks/`):

- **block-contracts.md** — v1 contracts matching `email_block_contracts_list` (JSON Schema, example config, actions, required context).
- **kinetic-limits.md** — Apple Mail checkbox-hack matrix, Outlook/Gmail fallback, MPP notes (US-007).
- **amp-prerequisites.md** — Google/Yahoo AMP registration, state machine, sample-send (US-016).
- **design-guide.md** — size budgets, the three-tier rule, tag syntax, quality-gate codes.

## The three-tier rule

One block contract, three renderers that share the links DOM as base:

1. **links** — table HTML + signed action URLs. Every client.
2. **kinetic** — CSS `:checked` on top of links. Apple Mail. Everyone else sees the links fallback.
3. **AMP** — AMP4EMAIL part, attached only when the sending domain's `amp_registration_status` is `verified`.

Author the brand shell once. Do not ship three separate templates.

## Requires

- `hqCore >= 12.0.0`
- VYG email channel on the brand
- MCP connected (table above)
- A verified sending domain before test-send / publish
- Catalog sync for cart and carousel (payload-only fallback if stale)

## Smoke run

A live smoke run (fresh HQ company, brand-user OAuth, cart template, validate,
preview, test-send) and marketplace publish happen **after** production deploy.
The checklist and log slot live in [`SMOKE-RUN.md`](./SMOKE-RUN.md).

## Source of truth

[indigoai-us/hq-packages](https://github.com/indigoai-us/hq-packages)/packages/hq-pack-vyg-email-blocks
