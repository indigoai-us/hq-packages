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

A company's brand pack lives at
`companies/{co}/knowledge/design-styles/packs/*/design-tokens.css`. Binding it is
two steps, both done here; no other pack is needed.

**Step 1: skin roles.** `chart.css` reads every surface, ink, structure, delta and
font value through a `--dg-*` fallback. Map the brand pack's tokens onto those
roles:

| Skin role | From the brand pack | Fallback the sample writes |
|---|---|---|
| `--dg-paper` | `--color-bg` | none: chart.css default |
| `--dg-paper-raised` | `--color-surface` | `var(--white)` |
| `--dg-paper-sunk` | `--color-text` at about 4.5% alpha | not in the sample: chart.css default |
| `--dg-paper-dark` | `--color-bg-dark` (dark theme ground) | not in the sample: chart.css default |
| `--dg-ink` | `--color-text` | none: chart.css default |
| `--dg-muted` | `--color-text-muted` | none: chart.css default |
| `--dg-soft` | `--mid-gray` | `var(--color-text-muted)` |
| `--dg-rule` | `--divider` | `color-mix(in srgb, var(--color-border) 14%, transparent)` |
| `--dg-rule-strong` | `--color-border` | none: chart.css default |
| `--dg-positive`, `--dg-negative` | the brand's success / error colours, if it defines any | not in the sample: chart.css default |
| `--dg-positive-tint`, `--dg-negative-tint` | the same colours at about 12% alpha | not in the sample: chart.css default |
| `--dg-font-display` | `--font-display` | none: chart.css default |
| `--dg-font-body` | `--font-body` | none: chart.css default |
| `--dg-font-mono` | `--font-mono` | none: chart.css default |

"None: chart.css default" is safe for a `--dg-*` role. If the pack lacks the
source token, the role becomes invalid and chart.css's own
`var(--dg-x, <default>)` applies. Write "X at N% alpha" as
`color-mix(in srgb, var(X) N%, transparent)`. Never map a brand accent
onto `--dg-positive` or `--dg-negative`; those carry meaning.

**Step 2: chart roles.** Additionally map:

| Chart role | From the brand pack | Fallback the sample writes |
|---|---|---|
| `--ch-hero`, `--ch-data-1` | `--color-accent` | `var(--ch-ink)`, the mono hero |
| `--ch-data-2` | `--color-accent-secondary` | `#5b5853`, the mono data-2; `#b5b0a6` in the dark rule |
| `--ch-data-3` … `--ch-data-6` | tints of the accent toward paper | not in the sample: chart.css mono ladder |
| `--ch-ramp-1` … `--ch-ramp-5` | five steps from paper to accent | not in the sample: chart.css mono ramp |

Every `--ch-*` line needs a fallback. chart.css sets the chart roles directly,
with no outer default, so a `--ch-*` line whose source token is missing renders
its marks black. Either keep the fallback or drop the line when the pack does
not define the source token.

Paste the brand pack's `:root` tokens, then set both steps in one `:root` block
and a dark-theme `--ch-data-2` rule, both after the generated stylesheet:

```css
:root {
  --dg-paper:        var(--color-bg);
  --dg-paper-raised: var(--color-surface, var(--white));
  --dg-ink:          var(--color-text);
  --dg-muted:        var(--color-text-muted);
  --dg-soft:         var(--mid-gray, var(--color-text-muted));
  --dg-rule:         var(--divider, color-mix(in srgb, var(--color-border) 14%, transparent));
  --dg-rule-strong:  var(--color-border);
  --dg-font-display: var(--font-display);
  --dg-font-body:    var(--font-body);
  --dg-font-mono:    var(--font-mono);
  --ch-hero:         var(--color-accent, var(--ch-ink));
  --ch-data-1:       var(--color-accent, var(--ch-ink));
  --ch-data-2:       var(--color-accent-secondary, #5b5853);
}

[data-ch-theme="dark"] {
  --ch-data-2:       var(--color-accent-secondary, #b5b0a6);
}
```

The `:root` block comes after chart.css, so it also overrides the dark theme's
`--ch-data-2`. The dark rule keeps series 2 at chart.css's dark value
(`#b5b0a6`) when the pack has no `--color-accent-secondary`. The auto theme does
not set `--ch-data-2`, so it needs no rule.

The pasted block also overrides the `slate`, `moss` and `ember` palette presets
(`data-ch-palette`): the brand's hero and data-2, or their fallbacks, replace the
preset's. Do not combine a brand binding with a palette preset. Dropping a
`--ch-*` line whose source token the pack lacks also works, and leaves
chart.css's theme- and palette-aware value in charge.

The figure is untouched. Check contrast before shipping: hero on paper at least 3:1, text at
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
