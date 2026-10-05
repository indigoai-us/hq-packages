# Design guide — size budgets and the three-tier rule

Interactive email is **one block contract, three renderers**. Author the brand
shell once. VYG expands each `<vyg-block>` at send time.

## The three-tier rule

| Tier | What the shopper gets | Who |
|------|------------------------|-----|
| **links** | Table HTML. Every action is a signed `<a href>`. Shared DOM. | Every client (the floor). |
| **kinetic** | Links DOM wrapped in `:checked` radios/checkboxes. Apple Mail can pick variant / qty / slide / subscription action. Everyone else sees the links fallback in the same part. | Apple Mail (iOS/iPadOS/macOS). Gmail/Outlook ignore `:checked` and keep the fallback. |
| **AMP** | AMP4EMAIL part (`text/x-amp-html`) with `amp-list` / `amp-form` / `amp-carousel`. Attached only when the sending domain is AMP-`verified`. | Gmail and Yahoo, after registration (see amp-prerequisites.md). |

Do **not** ship three templates. Do **not** put JavaScript in `body_html`. Do
**not** design a kinetic-only experience that is unusable as a links table —
Gmail will show that table.

A fourth internal tier `static` exists for A/B: `email_flow_variant_add`
`interactive_pair: true` derives `<name> (static)` via `render(static)` so the
control arm has no blocks.

## Size budgets

| Surface | Budget | On overflow |
|---------|--------|-------------|
| Links delivered HTML | **95,000** UTF-8 bytes (`LINKS_HTML_BYTE_BUDGET`) | Stay under; Gmail clips near ~102 KB. Size tests use max-length tokens. |
| Kinetic HTML (per block wrap) | **100,000** UTF-8 bytes (`KINETIC_HTML_BYTE_BUDGET`) | Degrade to links + warning `BLOCK_DEGRADED_SIZE`. |
| AMP MIME part | **102,400** bytes (`AMP_PART_MAX_BYTES`, 100 KiB) | Drop AMP part + warning `AMP_DROPPED_SIZE`; send Simple HTML. |
| EventBridge broker Detail | **240,000** bytes | Same AMP drop (`AMP_DROPPED_SIZE`). |
| Template `body_html` input | **100,000** characters on MCP tools | Tool rejects the argument. |
| Action tokens per send | **64** (`ACTION_TOKEN_BUDGET_PER_SEND`) | Extra actions omitted + `TOKEN_BUDGET_EXCEEDED`. Choice state folds onto one token via `?c=`. |
| Action payload | **8 KiB** CHECK on `email_action_tokens.payload` | Do not stuff catalogs into payloads. |
| Compact JWT in the URL | **≤ 200** chars, claims `{jti,bid,exp}` only | Everything else lives on the token row. |

Practical tips:

- 6-item cart with normal catalog titles stays under kinetic 100 KB.
- Prefer 600px table shells, 72px thumbnails, system fonts.
- Do not inline large SVGs or base64 images in the shell.
- Carousel links grid is capped at 4; kinetic/AMP allow 8 slides.
- After `/email-block-preview`, compare file sizes to these numbers.

## Tag and shell rules

```html
<vyg-block type="cart" config='{"max_items":3}'>
  <table …>{{{block.body}}}</table>
</vyg-block>
```

- Exactly **one** `{{{block.body}}}` (triple mustache) per tag.
- `config` is a JSON **object** in a quoted attribute. Extra keys fail.
- Outer template still needs `{{unsubscribe}}` (working href) and should
  include `{{brand.address}}`.
- Supported Mustache variables: see `email_template_variables_list`.
  Documentation entries `block.body` and `blocks.<type>` describe the tag
  system; they are not interpolated by Mustache.
- No `<script>`, no `on*` handlers, no `javascript:` URLs in `body_html`.
- Images: https catalog CDN. MPP will prefetch them; they must not be tokens.
- Write-action links confirm on a hosted page and execute on **POST** (link
  scanners issue GET).

## Quality-gate codes

Errors block save (`email_template_validate` / create / update). Warnings
save but are persisted on the send as `render_warnings`.

| Code | Severity | Meaning |
|------|----------|---------|
| `BLOCK_CONTRACT_INVALID` | error | Config JSON/Zod failed; message includes the path. |
| `BLOCK_SLOT_MISSING` | error | Shell has zero or more than one `{{{block.body}}}`. |
| `BLOCK_UNKNOWN` | error | `type` is missing or not in the v1 registry. |
| `BLOCK_NOT_ALLOWED` | error | Tags on a non-agent source (imports). |
| `AMP_INVALID` | error | Vendored AMP4EMAIL validator rejected the assembled AMP document. |
| `SCRIPT_BLOCKED` | error | `<script>` in `body_html` (AMP runtime scripts are only in the generated AMP part). |
| `HANDLER_BLOCKED` | error | `on*` handler in `body_html`. |
| `URL_BLOCKED` | error | Disallowed scheme (e.g. `javascript:`). |
| `URL_NOT_ALLOWLISTED` | error | `custom_action` webhook host not on the brand allowlist. |
| `UNSUBSCRIBE_MISSING` | error | No working `href="{{unsubscribe}}"`. |
| `BLOCK_CATALOG_STALE` | warning | Catalog not ready / older than 48 h; payload-only items. |
| `BLOCK_COLLECTION_UNKNOWN` | warning | Accessory/carousel collection handle missing. |
| `BLOCK_NO_PRODUCTS` | warning | Cart/carousel had nothing to render. |
| `BLOCK_NO_SUBSCRIPTION` | warning | Subscription block, no mirror context. |
| `BLOCK_DEGRADED_SIZE` | warning | Kinetic over 100 KB → links fallback. |
| `CHECKOUT_VARIANT_UNRESOLVED` | warning | Could not resolve a Shopify variant for the permalink. |
| `AMP_DROPPED_SIZE` | warning | AMP part omitted (102,400 B or broker budget). |
| `TOKEN_BUDGET_EXCEEDED` | warning | More than 64 actions on the send. |

`email_template_validate` attaches 1-based `line` hints for block tags and AMP
`line:col`, plus Zod `path`.

## MCP tools (exact names)

| Tool | Role |
|------|------|
| `email_block_contracts_list` | Live JSON Schema + example_config + webhook key |
| `email_template_validate` | Quality gates, no write |
| `email_template_preview_tiers` | `{ links, kinetic, amp }` HTML |
| `email_template_test_send_interactive` | Self-only send, dry-run tokens |
| `email_template_create` / `email_template_update` | Save (live on save) |
| `email_template_preview` | Single default-tier preview (not the three-tier skill) |
| `email_template_test_send` | Static test send (not the interactive skill) |
| `email_domain_amp_request` | Record Google+Yahoo form refs |
| `email_flow_create` / `email_broadcast_create` | Publish |
| `email_flow_variant_add` | `interactive_pair` static-vs-interactive A/B |

There is **no** `email_block_validate` and **no**
`email_template_interactive_test_send`. Use the names in this table.
