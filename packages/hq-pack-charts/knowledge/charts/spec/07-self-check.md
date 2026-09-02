# 07 — Self-check

Run this before calling a chart done. The linter covers the first block
mechanically; the rest needs judgement and eyes.

## Mechanical (the linter)

```bash
python3 scripts/sync-assets.py <file.html>
python3 scripts/lint-chart.py <file.html>
```

Zero errors. Read every warning and either fix it or write down why it stands.

## Honesty

- [ ] Bars and columns start at zero and are proportional; no broken axis.
- [ ] Any size-encoded dot or square uses `sqrt`.
- [ ] Ring sweeps equal share × 360.
- [ ] Every unit is named in the subtitle; unit-chart rounding is footnoted.
- [ ] No demo number, demo source, or demo conclusion survives.
- [ ] Every mark the reader could point at has a label, value, or hover.

## Selection

- [ ] At least three candidates were compared and the rejections are written.
- [ ] Every chart has a locked `type`, gallery file, and card title.
- [ ] A fallback or signal type has its reason written.
- [ ] Across the page, no silhouette repeats without a reason; count ≤ 6.
- [ ] Each chart carries exactly one conclusion and its `h2` states it as a sentence.

## Form

- [ ] Card has all four parts: title, subtitle, figure, source.
- [ ] One hero at most; everything else is quiet or a series slot.
- [ ] No label below the floor; no two labels overlap.
- [ ] One palette per file; brand binding, if any, only touched `:root`.
- [ ] Motion verbs are on marks only; the hero lands last.
- [ ] `<desc>` states the finding in prose.

## Eyes

- [ ] You opened the file over `http://localhost` (not `file://`, which snapshots
      motion in the Browser pane) and looked at every figure, not a sample.
- [ ] The hero is the first thing you saw.
- [ ] The family test: placed beside its gallery card, this reads as the same
      template family, not "similar in style".

An unviewed chart is not done.
