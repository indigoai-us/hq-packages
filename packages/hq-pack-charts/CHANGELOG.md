# Changelog

## 0.1.1 — 2026-11-06

- Fix: the `/chart` skill and `spec/04-colour.md` pointed at
  `core/knowledge/public/design-styles/formulas/diagram/binding.md`, which no pack
  ships, so brand binding had no mapping to follow (feedback 1b4acf28). The
  brand-token to `--dg-*` mapping now lives in `spec/04-colour.md` § Brand binding.
- The Brand binding paste block now gives every `--ch-*` line a fallback
  (`var(--color-accent, var(--ch-ink))` for hero and data-1,
  `var(--color-accent-secondary, #5b5853)` for data-2) and writes the documented
  `--dg-*` fallbacks. A brand pack missing a source token no longer renders
  black marks. The tables' Fallback columns now say what the sample emits.
- Dropped the recommend on `hq-pack-diagrams`, which does not exist, and the
  pointers to `assets/examples/`, which is not shipped, from
  `knowledge/charts/README.md` and the pack README layout block.
- The skill description says "brand-bound per spec/04-colour.md" instead of
  "the same skin as /diagram".
- Added `tests/references.test.sh`, run by CI, which fails on references outside
  the pack, pack-relative paths that do not resolve (including backticked paths
  and layout-fence paths in the pack README), recommended packs that do not
  exist, and a missing `## Brand binding` heading in `spec/04-colour.md`.

## 0.1.0 — 2026-09-01

First cut. Wired 2 contributions: knowledge `charts`, skill `chart`.

- `chart.css`: one token contract for every chart, sharing the `--dg-*` role
  vocabulary with hq-pack-diagrams so a bound brand skins both. Four palettes
  (mono, slate, moss, ember), light/dark/auto, CSS-only motion verbs, sheet slots.
- Three families with 28 registered types (27 with a gallery card, 1 planned):
  ledger (10), plain (10), signal (8). Three report sheets.
- `scripts/lint-chart.py`: 25 rules covering the token contract, self-containment,
  accessibility, type floors, palette locking, card structure, viewBox bounds,
  and bar proportionality against `<title>` values.
- `scripts/sync-assets.py`, `scripts/contact-sheet.py`, `scripts/test-lint.py`.
- Spec in nine files under `knowledge/charts/spec/`.

Design reference, not source: the family split (record-level / familiar / fast),
data-shape-first selection, tiered audit with written rejections, one-conclusion
cards, the honesty contract, and one-palette-per-delivery were studied in the
open-source `lieflat-charts` skill (PolyForm Noncommercial). Every template,
token, rule text, and script here is HQ's own.
