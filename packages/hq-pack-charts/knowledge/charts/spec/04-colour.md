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

| Skin role | From the brand pack | Fallback |
|---|---|---|
| `--dg-paper` | `--color-bg` | leave unset (chart.css default) |
| `--dg-paper-raised` | `--color-surface` | `--white` |
| `--dg-paper-sunk` | `--color-text` at about 4.5% alpha | leave unset |
| `--dg-paper-dark` | `--color-bg-dark` (dark theme ground) | leave unset |
| `--dg-ink` | `--color-text` | leave unset |
| `--dg-muted` | `--color-text-muted` | leave unset |
| `--dg-soft` | `--mid-gray` | `--color-text-muted` |
| `--dg-rule` | `--divider` | `--color-border` at about 14% alpha |
| `--dg-rule-strong` | `--color-border` | leave unset |
| `--dg-positive`, `--dg-negative` | the brand's success / error colours, if it defines any | leave unset |
| `--dg-positive-tint`, `--dg-negative-tint` | the same colours at about 12% alpha | leave unset |
| `--dg-font-display` | `--font-display` | leave unset |
| `--dg-font-body` | `--font-body` | leave unset |
| `--dg-font-mono` | `--font-mono` | leave unset |

"Leave unset" keeps the chart.css default for that role. Write "X at N% alpha" as
`color-mix(in srgb, var(X) N%, transparent)`. Never map a brand accent
onto `--dg-positive` or `--dg-negative`; those carry meaning.

**Step 2: chart roles.** Additionally map:

| Chart role | From the brand pack | Fallback |
|---|---|---|
| `--ch-hero`, `--ch-data-1` | `--color-accent` | the brand's most saturated colour |
| `--ch-data-2` … `--ch-data-6` | `--color-accent-secondary`, then tints of the accent toward paper | mono ladder |
| `--ch-ramp-1` … `--ch-ramp-5` | five steps from paper to accent | mono ramp |

Paste the brand pack's `:root` tokens, then set both steps in one `:root` block
after the generated stylesheet:

```css
:root {
  --dg-paper:        var(--color-bg);
  --dg-paper-raised: var(--color-surface);
  --dg-ink:          var(--color-text);
  --dg-muted:        var(--color-text-muted);
  --dg-soft:         var(--mid-gray);
  --dg-rule:         var(--divider);
  --dg-rule-strong:  var(--color-border);
  --dg-font-display: var(--font-display);
  --dg-font-body:    var(--font-body);
  --dg-font-mono:    var(--font-mono);
  --ch-hero:         var(--color-accent);
  --ch-data-1:       var(--color-accent);
  --ch-data-2:       var(--color-accent-secondary);
}
```

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
