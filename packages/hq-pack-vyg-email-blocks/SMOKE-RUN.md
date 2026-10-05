# Smoke run — hq-pack-vyg-email-blocks

Acceptance record for US-022. **Pending production deploy** of interactive
email (US-021 block tools + US-024 brand MCP adapter). Paste the run log
under [Log](#log) when the engineering manager executes this.

The smoke authenticates as a **brand user** (not staff) through the primary
MCP server's web-client OAuth.

## Preconditions

- Interactive-email stories through US-021 and US-024 are deployed to production.
- A **fresh HQ company** exists; the operator is an owner/member.
- The operator's VYG identity is a **brand user** of a `beta:email-channel` brand
  (pilot: LiveRecover Supply `078449e9-2e9c-4779-8347-a0b61a6936bf` is acceptable
  if a brand-new VYG brand is not available; still use brand-user OAuth).
- Never use SAV Eyewear.
- A verified sending domain exists on that brand (`email_domain_list`).

## Commands

From a clean HQ workspace for the fresh company:

```bash
# 1. Connect MCP as a BRAND user (web-client OAuth). Not agents-mcp.
claude mcp add --transport http vyg https://api.vyg.app/mcp
# Complete the browser OAuth as the brand user. Confirm tools/list includes
# email_block_contracts_list, email_template_validate,
# email_template_preview_tiers, email_template_test_send_interactive.

# 2. Install the pack on the clean company.
hq pack install @indigoai-us/hq-pack-vyg-email-blocks
# Fallback before npm publish:
# hq pack install github:indigoai-us/hq-packages#packages/hq-pack-vyg-email-blocks

# 3. Design a cart template (agent session).
#    Invoke /email-block-design for an abandoned-cart email.
#    Interview answers: goal=recover checkout; data=Shopify cart + catalog;
#    style=brand default. Agent must call email_block_contracts_list, author
#    HTML with <vyg-block type="cart" …>{{{block.body}}}</vyg-block>, then
#    email_template_validate until ok=true, then email_template_create.
#    Record template_id.

# 4. Preview all three tiers.
#    Invoke /email-block-preview with that template_id.
#    Confirm three files exist:
#      email-blocks/previews/<slug>-links.html
#      email-blocks/previews/<slug>-kinetic.html
#      email-blocks/previews/<slug>-amp.html

# 5. Interactive test-send to the signed-in brand user's inbox.
#    Invoke /email-block-test-send.
#    Confirm email_template_test_send_interactive returns sent=true,
#    is_test=true, action_dry_run=true.
```

Expected MCP-tool sequence (names are exact):

1. `email_block_contracts_list`
2. `email_template_validate` (repeat until `ok: true`)
3. `email_template_create` (status is **live** on save — VYG has no agent draft save)
4. `email_template_preview_tiers`
5. `email_template_test_send_interactive`

## Pass criteria

- [ ] Pack installed on a clean company (`hq pack install` succeeded).
- [ ] MCP session is a brand user on `https://api.vyg.app/mcp` (not staff on agents-mcp).
- [ ] A template with a valid cart block exists in the brand's template store.
- [ ] Three HTML preview files (links, kinetic, amp) were written to the project folder.
- [ ] Interactive test-send delivered to the signed-in user's inbox (`sent: true`).

## Log

_Paste the agent transcript / MCP tool-call log here after the production run._

```
(pending deploy)
```
