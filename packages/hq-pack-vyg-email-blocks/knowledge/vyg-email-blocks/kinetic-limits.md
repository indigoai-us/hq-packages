# Kinetic limits (Apple Mail checkbox-state HTML)

The kinetic tier wraps the links-tier table DOM in hidden
`<input type="checkbox|radio">` controls and `:checked ~` sibling CSS so Apple
Mail shoppers can switch variants, step quantity 1–5, page a carousel, and pick
a subscription action **without AMP or JavaScript**. Chosen state is encoded as
duplicated action links with `?c=<index>` on the **same** minted token
(64 tokens/send budget). Source: VYG `docs/features/email-interactive-kinetic.md`
(US-007).

## Support-gate pattern

```html
<div data-vyg-kinetic="{uid}" data-vyg-tier="kinetic">
  <style>
    #{uid}-gate:checked ~ .vyg-k-fallback { display:none !important; }
    #{uid}-gate:checked ~ .vyg-k-stage { display:block !important; }
  </style>
  <!--[if !mso]><!-->
  <input type="checkbox" id="{uid}-gate" class="vyg-k-gate" checked="checked"
         style="opacity:0;max-height:0;max-width:0;position:absolute;overflow:hidden;border:0;">
  <!-- variant / qty / slide / action radios, same off-screen style, not display:none -->
  <div class="vyg-k-stage" style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:0;line-height:0;">
    <!-- labels + per-state <a href="__VYG_ACTION_n__?c=i&t=kinetic"> -->
  </div>
  <!--<![endif]-->
  <div class="vyg-k-fallback">
    <!-- links-tier table -->
  </div>
</div>
```

**Gmail-safe CSS:** any rule that hides `.vyg-k-fallback` or reveals
`.vyg-k-stage` MUST include `:checked` in its selector. Default stage
visibility is the inline style, not a stylesheet.

Inputs are off-screen (`opacity:0;position:absolute`), **not** `display:none`.
Apple Mail will not apply `:checked` to a `display:none` checkbox.

You do not author this markup. VYG's kinetic renderer wraps the links DOM.
Do not try to hand-roll a second checkbox hack in the brand shell.

## Apple Mail matrix

| Client | Version | `:checked ~` | radio/checkbox + `label[for]` | Notes |
|--------|---------|--------------|-------------------------------|-------|
| iOS Mail | iOS 18, iOS 26, iOS 27 (as of 2026-10) | Works | Works | WebKit. Gate checkbox must not be `display:none`. |
| iPadOS Mail | same train | Works | Works | Same WebKit as iPhone. |
| macOS Mail | Sonoma 14, Sequoia 15, Tahoe 26 | Works | Works | Dark Mode inverts some dark CTAs; labels remain tappable. |

### What works (Apple Mail)

- Variant radios reveal the matching Checkout link (`?c=` → `payload.choices[].variant_id`).
- Quantity radios 1–5 on the same token (cartesian with variant).
- Carousel prev/next labels check the adjacent slide radio; one slide visible.
- Subscription action radios; delay days nested when `delay` is configured.
- Fallback links remain in the HTML for clients that ignore `:checked`.

### Limits

- No JavaScript. No `:hover`-only affordances. Interaction is tap/click on `<label for>`.
- Per-block kinetic HTML budget **100,000** UTF-8 bytes; over that → links-only + `BLOCK_DEGRADED_SIZE`.
- Variant picker caps at 8; quantity is 1–5. Cartesian choices live on one token (8 KiB payload CHECK).
- Gmail iOS is WebKit but does **not** reliably apply `:checked` sibling CSS in mail; the inline-hidden stage keeps that client on the links fallback (safe).
- Image-heavy 6-item carts stay under the cap with normal catalog titles; pathological titles trip degrade by design.

## Mail Privacy Protection (MPP)

iOS 15+ MPP **prefetches images** through an Apple proxy (fires when the
message is downloaded, not when viewed). MPP does **not** prefetch, crawl, or
activate hyperlinks. Action tokens on kinetic/links CTAs are not spent by MPP;
only a real tap hits the action route. Prefetched images must stay on the
catalog CDN; they are not tokens.

## Outlook (Windows)

Outlook for Windows (Microsoft 365 / Outlook 2021, Word renderer) strips the
`<!--[if !mso]><!-->` block. Kinetic stage, gate checkbox, and radios are
absent. The shopper sees the links-tier table only: image + title + price,
then View cart / Checkout (and accessory Add links when present). No quantity
stepper, no variant pills, no carousel prev/next.

## Gmail web

Gmail web keeps the kinetic markup in the source but does not apply
`:checked ~` sibling rules, so the stage stays at its inline `display:none`.
The screenshot is the same links table as Outlook. Clipping still applies
near ~102 KB; the 100 KB kinetic degrade is the safety margin.

## Do not

- `display:none` the gate checkbox (you should not be emitting the gate at all).
- Mint extra tokens or put JSON in URL params.
- Rely on `:checked` for Gmail/Outlook layout.
- Ship a kinetic-only design that is unusable as a links table.
