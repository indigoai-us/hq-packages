# 04 — Colour

## Mono is the floor

Every chart reads correctly in mono, because the hero is ink and everything else is
a lightness ladder. Colour is added on top, never relied on. A chart that only
works in colour is a defect.

## Choosing a palette

Colour does not need to be asked for. Decide from the data:

| Data semantics | Palette | Why |
|---|---|---|
| One series that has an order (time, rank, intensity) | `slate` | a sequential blue ramp reads as order |
| Two to four unordered kinds that must be told apart | `moss` | four distinguishable hues, restrained |
| Everything quiet except one point | `ember` | one warm hero on a grey field |
| Unclear fit, more than six categories, or a formal register | `mono` | it always works |

The user's explicit request wins over the table. "Make it prettier" is not a
request for colour; "use our brand colours" is.

## One system per delivery

One file, one `data-ch-palette`. A page of six charts is six charts in the same
palette. If one chart cannot work in the chosen palette, change the page's
palette, or return to mono. Never patch one card locally (`CH151`).

## Brand binding

When a company is bound and has a brand pack, the design-styles binding formula
(`core/knowledge/public/design-styles/formulas/diagram/binding.md`) maps its tokens
to `--dg-*` roles. `chart.css` inherits every `--dg-*` value through its fallbacks,
so a bound diagram skin is already a bound chart skin. Additionally map:

| Chart role | From the brand pack | Fallback |
|---|---|---|
| `--ch-hero`, `--ch-data-1` | `--color-accent` | the brand's most saturated colour |
| `--ch-data-2` … `--ch-data-6` | `--color-accent-secondary`, then tints of the accent toward paper | mono ladder |
| `--ch-ramp-1` … `--ch-ramp-5` | five steps from paper to accent | mono ramp |

Set them in the `:root` block after the generated stylesheet. The figure is
untouched. Check contrast before shipping: hero on paper at least 3:1, text at
least 4.5:1.

A custom palette is built only from explicit brand colours or hex values. Derive
the ladder and the ramp from those; do not invent extra hues.

## Semantic colour

`ch-up` / `ch-down` are the only colours that carry meaning by themselves, and even
they pair with a sign or a word. Never use series colour to mean good or bad.

## Dark

`data-ch-theme="dark"` inverts surface and ink and lightens the deltas. Test the
hero on the dark paper; if it vanishes, pick a palette whose hero survives, or use
`ch-card--dark` for a single dark card on a light page instead of a dark page.
