# Block contract reference (v1)

Snapshot of what **`email_block_contracts_list`** returns: JSON Schema derived
from the Zod configs, example configs, actions, and required render context.
Contract version is **1**. Call the tool at design time; extra keys are rejected
(`.strict()`).

Always drop a block as:

```html
<vyg-block type="<type>" config='{…json object…}'>
  <!-- brand shell; must contain exactly one of: -->
  {{{block.body}}}
</vyg-block>
```

`type` is one of `cart`, `subscription`, `custom_action`, `review`, `form`,
`carousel`. `config` is a JSON object (HTML-attribute quoted). Inner HTML is
the brand shell. **Exactly one** `{{{block.body}}}` slot (triple mustache).
Zero or two → `BLOCK_SLOT_MISSING`. Unknown type → `BLOCK_UNKNOWN`. Invalid
JSON or Zod failure → `BLOCK_CONTRACT_INVALID` with a path (e.g. `max_items`).

Klaviyo imports and any non-`agent` source reject every placement with
`BLOCK_NOT_ALLOWED`.

## Shared

`email_block_contracts_list` also returns (custom_action webhook mode):

| Field | Value |
|-------|--------|
| `webhook_signature_header` | `X-VYG-Signature` |
| `webhook_signature_format` | `sha256=<hex>` |
| `webhook_signing_key` | per-brand derived HMAC key (hex). The root secret is never returned. Rotating the root rotates every brand key. |
| `custom_action.property_name_pattern` | `^custom_[a-z0-9_]{1,40}$` |
| `custom_action.webhook_url` | https only; host must be on the brand allowlist |

Webhook POSTs: `https` only, DNS-resolved public addresses, no private /
loopback / link-local / metadata ranges, `redirect: 'manual'` (redirects
refused), 5 s timeout, body discarded.

---

## cart

**Required context:** `products`, `event.checkout_url`

**Actions:** `cart.view`, `cart.rebuild`, `cart.add_item`, `discount.apply`

Hydrates line items from catalog at render (live price / compare-at / image /
`inventory_quantity`). Sold-out (`<= 0`) renders without an action.
`cart.rebuild` re-reads inventory at tap and drops `<= 0` lines as
`meta.dropped_variants`. Checkout ceiling is a Shop Pay-prefilled cart
permalink (`event.shop_pay_checkout_url` when present).

```json
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "max_items": { "type": "integer", "minimum": 1, "maximum": 12, "default": 6 },
    "accessory_collection_handle": { "type": "string", "minLength": 1, "maxLength": 128 },
    "discount_code": { "type": "string", "minLength": 1, "maxLength": 64 },
    "show_compare_at": { "type": "boolean", "default": false },
    "discount_mint": {
      "type": "object",
      "properties": {
        "percent": { "type": "number", "minimum": 5, "maximum": 50 },
        "expires_hours": { "type": "integer", "minimum": 1, "maximum": 168 }
      }
    }
  }
}
```

Cross-field: `discount_mint` cannot be set together with `discount_code`.
`discount_mint` mints a single-use percent code (1 per contact / 7 days, 500 per
brand / day).

**Example:** `{ "max_items": 3, "show_compare_at": false }`

Catalog older than 48 h → `BLOCK_CATALOG_STALE` (payload-only items). Unknown
accessory handle → `BLOCK_COLLECTION_UNKNOWN` (omit accessories). Unresolved
variant at checkout URL build → `CHECKOUT_VARIANT_UNRESOLVED`.

---

## subscription

**Required context:** `subscription` (from the local `subscription_contracts`
mirror — never a live provider call on the send path)

**Actions:** `subscription.delay`, `subscription.skip`, `subscription.swap`,
`subscription.reactivate`, `subscription.add_to_next_order`

Owner match (contact + platform email) is required on write; mismatch → 403.
Swap on prepaid → `SWAP_NOT_ALLOWED`. Reactivation lists up to 3 cancelled
contracts from the local mirror. No context → `BLOCK_NO_SUBSCRIPTION`.

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["actions"],
  "properties": {
    "actions": {
      "type": "array",
      "minItems": 1,
      "maxItems": 5,
      "items": {
        "type": "string",
        "enum": ["delay", "skip", "swap", "reactivate", "add_to_next_order"]
      }
    },
    "delay_days_options": {
      "type": "array",
      "maxItems": 6,
      "items": { "type": "integer", "exclusiveMinimum": 0 }
    },
    "swap_variant_scope": { "type": "string", "enum": ["same_product", "collection"] },
    "upsell_collection_handle": { "type": "string", "minLength": 1, "maxLength": 128 },
    "reactivate_discount_code": { "type": "string", "minLength": 1, "maxLength": 64 }
  }
}
```

**Example:** `{ "actions": ["delay", "skip"], "delay_days_options": [7, 14, 30] }`

Provider coverage: ReCharge all five; Stay AI delay / skip / reactivate / add
(not swap). Skio writes follow the coverage map.

---

## custom_action

**Required context:** `contact.email`

**Actions:** `custom`

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["action_id", "label", "mode"],
  "properties": {
    "action_id": {
      "type": "string",
      "minLength": 1,
      "maxLength": 64,
      "pattern": "^[a-z0-9_]+$"
    },
    "label": { "type": "string", "minLength": 1, "maxLength": 80 },
    "mode": { "type": "string", "enum": ["cdp_property", "webhook", "discount"] },
    "property_name": { "type": "string", "pattern": "^custom_[a-z0-9_]{1,40}$" },
    "webhook_url": { "type": "string", "format": "uri" },
    "discount_code": { "type": "string", "minLength": 1, "maxLength": 64 }
  }
}
```

Cross-field:

- `cdp_property` requires `property_name` (publishes `email_custom_action`).
- `webhook` requires `webhook_url` starting with `https://`. Host not on the
  brand allowlist → `URL_NOT_ALLOWLISTED`.
- `discount` requires `discount_code`.

**Example:** `{ "action_id": "waitlist", "label": "Join waitlist", "mode": "cdp_property", "property_name": "custom_waitlist" }`

---

## review

**Required context:** `product`

**Actions:** `review.submit`

Tap-to-rate. Write-back: Judge.me, Okendo; `vyg` stores locally. `product_source: last_order` uses the last order's product; `product_id` requires `product_id`.

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["product_source", "platform"],
  "properties": {
    "product_source": { "type": "string", "enum": ["last_order", "product_id"] },
    "platform": { "type": "string", "enum": ["judgeme", "okendo", "yotpo", "junip", "vyg"] },
    "min_chars_for_text": { "type": "integer", "minimum": 0, "maximum": 2000, "default": 0 },
    "product_id": { "type": "string", "minLength": 1, "maxLength": 128 }
  }
}
```

**Example:** `{ "product_source": "last_order", "platform": "vyg", "min_chars_for_text": 0 }`

---

## form

**Required context:** `contact`

**Actions:** `form.submit`

Up to 5 steps. Hosted page `GET /email/form/<token>`; POST writes CDP profile
properties on the brand-scoped CDP lane and SMS consent via
`recordEmailFormSmsConsent` (source `email_form`). Phone numbers must never
appear in `sms_optin` options (those become URL query values).

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["steps"],
  "properties": {
    "steps": {
      "type": "array",
      "minItems": 1,
      "maxItems": 5,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["question", "type"],
        "properties": {
          "question": { "type": "string", "minLength": 1, "maxLength": 200 },
          "type": { "type": "string", "enum": ["single", "multi", "text", "sms_optin"] },
          "options": {
            "type": "array",
            "maxItems": 6,
            "items": { "type": "string", "minLength": 1, "maxLength": 80 }
          },
          "property_name": { "type": "string", "pattern": "^custom_[a-z0-9_]{1,40}$" },
          "scoring": { "type": "object", "additionalProperties": { "type": "number" } }
        }
      }
    }
  }
}
```

Cross-field per step: `single`/`multi` require `options`; every type except
`sms_optin` requires `property_name`; `scoring` keys must match options.

**Example:**

```json
{
  "steps": [
    {
      "question": "How did you hear about us?",
      "type": "single",
      "options": ["Friend", "Ad", "Other"],
      "property_name": "custom_source"
    }
  ]
}
```

---

## carousel

**Required context:** `products`

**Actions:** `cart.add_item` (when `slide_action` is `cart.add_item`)

Hydrates slides from catalog (`collection` / `products` / `catalog_product_images.url`).
Links tier: ≤4 grid. Kinetic: radio prev/next, ≤8 slides. AMP: `amp-carousel type=slides` + `amp-list`.

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["source", "slide_action"],
  "properties": {
    "source": { "type": "string", "enum": ["collection", "products", "images"] },
    "collection_handle": { "type": "string", "minLength": 1, "maxLength": 128 },
    "product_ids": { "type": "array", "maxItems": 8, "items": { "type": "string", "minLength": 1 } },
    "images": {
      "type": "array",
      "maxItems": 8,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["src"],
        "properties": {
          "src": { "type": "string", "format": "uri" },
          "alt": { "type": "string", "maxLength": 200 }
        }
      }
    },
    "max_slides": { "type": "integer", "minimum": 1, "maximum": 8, "default": 4 },
    "slide_action": { "type": "string", "enum": ["product_url", "cart.add_item"] }
  }
}
```

Cross-field: `collection` requires `collection_handle`; `products` requires
`product_ids`; `images` requires `images`.

**Example:** `{ "source": "collection", "collection_handle": "featured", "max_slides": 4, "slide_action": "product_url" }`
