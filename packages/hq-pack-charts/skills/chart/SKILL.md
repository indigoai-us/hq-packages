---
name: chart
description: |
  Turn data into a polished, publishable chart or a full-page report sheet as one
  self-contained HTML file with inline SVG. Three families — ledger (record-level,
  slow read), plain (familiar forms, editorial finish), signal (big numbers, fast
  read) — plus three report sheets. Token-driven (the SVG carries classes, never
  colours), brand-bound through the same skin as /diagram, CSS-only motion, no
  chart library, and a linter that fails colour literals, broken proportions,
  sub-floor type, and demo data. Use when the user asks for a chart, graph, plot,
  visualization, KPI tiles, dashboard, one-pager, brief, weekly or monthly report,
  or says "show me the numbers". For architecture, flow, and reasoning figures
  use /diagram instead.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# Chart

One self-contained `.html` per delivery. Embedded stylesheet, inline SVG, CSS-only
motion, no JavaScript needed to draw, no external images, no chart library. It
renders offline, prints, and re-skins by swapping one `:root` block.

The design system is in `knowledge/charts/spec/`. **Load only what you need.**
`00-grammar.md` and `02-honesty.md` you should know by heart.

## 0. Resolve the skin — no questions asked

Do not interview the user about branding. HQ already knows.

```bash
cat workspace/threads/handoff.json 2>/dev/null | grep -o '"company"[^,]*'
```

| Situation | Do |
|---|---|
| A company is bound and has `companies/{co}/knowledge/design-styles/packs/*/design-tokens.css` | Map it per `core/knowledge/public/design-styles/formulas/diagram/binding.md`, then the chart additions in `spec/04-colour.md` § Brand binding |
| A company is bound with no brand pack | Default skin. Mention once that `/newcompany` can generate a brand pack |
| No company bound | Default skin. Say nothing |

## 1. Decide the mode, then whether to draw

**Chart mode is the default.** Report-sheet mode only when the user explicitly
asks for a report, one-pager, brief, weekly/monthly/annual report, poster, or
dashboard page. "Analyse this" is chart mode: deliver the strongest one to three
charts and offer the sheet in a sentence. Rich data is not a reason to switch.

Then, from `spec/00-grammar.md`:

> Would a reader learn more from this than from three well-written sentences?

One number is a sentence. Two states is a table. **"A table would serve you better
here, want that instead?" is a correct answer** and the most under-used one.

## 2. Read the shape, audit the roster, lock the type

Never ask which chart they want. Classify the data shape (`spec/00-grammar.md`),
then follow `spec/03-selection.md`:

1. Audit `ledger` and `plain` primaries first. Compare at least three candidates.
2. `fallback` types only with a written reason. Five shapes bypass the audit
   (OHLC, five-number summary, parallel measures, year heat, stacked composition).
3. `signal` is a documented downgrade unless the user asked for a dashboard,
   weekly report, status board, or "three seconds".
4. Out-of-roster is last, via `spec/08-authoring-a-type.md`.

Record the lock for every chart before composing the page:

```
type · gallery file · card title · reason · rejected candidates
```

The roster is `knowledge/charts/types/registry.yaml`; the selection table is
`knowledge/charts/types/README.md`. A `status: planned` type has no card. Do not
improvise it.

## 3. How many

Independent conclusions decide the count, not columns. One question → one chart.
An article → four to six across different shapes. Six is the ceiling per page.
Duplicated conclusions collapse. Drafts do not count.

## 4. Build from the card

1. Open the family's gallery (`assets/galleries/{ledger,plain,signal}.html`), find
   the locked card by its title, and copy that `figure.ch-card` into a copy of
   `assets/template.html` (or the chosen `assets/sheets/*.html` in sheet mode).
2. Keep the card's geometry, encoding, label placement, and motion classes.
   Replace data, labels, `h2` conclusion, subtitle (marks · unit · range), source,
   `<title>`, `<desc>`, and `data-ch-type`.
3. Choose the file's palette from data semantics (`spec/04-colour.md`): ordered
   series → `slate`; ≤ 4 kinds → `moss`; one hero → `ember`; unclear → `mono`.
   One `data-ch-palette` per file.
4. Delete every card and comment you did not use. No demo number, demo source, or
   demo conclusion survives.

**The one rule that matters most:** the SVG carries semantic classes and never
carries a colour. No `fill="#…"`, no `style=`, no `font-family`, no `<script src>`,
no chart library. The linter fails the file otherwise.

## 5. Gate, then look

Run the self-check in `spec/07-self-check.md`. Then:

```bash
cd core/packages/hq-pack-charts
python3 scripts/sync-assets.py <your-file.html>
python3 scripts/lint-chart.py <your-file.html>
```

A clean lint means nothing mechanical is wrong. It is not a passing grade.

Then **look at it**, every figure:

```bash
python3 scripts/contact-sheet.py <your-file.html> --cols 2 --open
```

Serve over `http://localhost` (`python3 -m http.server` in the file's directory)
when checking in the Browser pane; `file://` snapshots motion and returns blank
frames on scroll. **An unviewed chart is not done.**

## 6. Deliver

Print the path and, per chart, the lock line (type, reason). If the user wants it
shared, use `/deploy`; never hand-roll hosting. For a transparent PNG/SVG export,
remove `rect.ch-bg` first.

## Never

- Put a colour, a font, or a `style=` in the SVG.
- Hand-edit the inlined `<style>` block. Change `assets/chart.css` and re-sync.
- Break an axis, start a bar above zero, or size a dot linearly.
- Use two palettes in one file, or two heroes in one card.
- Ship a chart you have not looked at.
- Ship demo data.
- Add JavaScript to draw, or a chart library.
- Copy a template's demo conclusion as the user's title.
