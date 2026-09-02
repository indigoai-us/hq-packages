# Changelog

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
