# Changelog

## 0.1.1 — 2026-11-06

- Fix: the `/chart` skill and `spec/04-colour.md` pointed at
  `core/knowledge/public/design-styles/formulas/diagram/binding.md`, which no pack
  ships, so brand binding had no mapping to follow (feedback 1b4acf28). The
  brand-token to `--dg-*` mapping now lives in `spec/04-colour.md` § Brand binding.
- Dropped the recommend on `hq-pack-diagrams`, which does not exist, and the
  `knowledge/charts/README.md` pointer to `assets/examples/`, which is not shipped.
- Added `tests/references.test.sh`, run by CI, which fails on references outside
  the pack, pack-relative paths that do not resolve, and recommended packs that do
  not exist.

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
