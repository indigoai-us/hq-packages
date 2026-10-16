---
name: mobile-ux-check
description: Check the client's key pages on a phone-sized viewport and against the analytics export's bounce by device. Finds the layout problems that show up as a mobile-versus-desktop gap, with a screenshot-level description and the fix.
triggers:
  - mobile check
  - does it work on a phone
  - mobile ux
  - mobile bounce
maturity: HQ-native (authored for this package)
---
# /mobile-ux-check

## Method

1. From the analytics export, list bounce and exit per page by device. A
   gap over 15 points between mobile and desktop on the same page (the
   playbook's rule) is a layout problem, not a traffic problem. Rank pages
   by the gap.
2. For each ranked page, render it at 375 by 812 (the browser skill or a
   fetch with a mobile user agent) and walk it top to bottom. Record, with
   the element quoted: the hero readable without pinching, the primary
   button visible without scrolling, text under 16 pixels, tap targets
   under 44 pixels, horizontal scroll, images that push the headline down,
   forms whose keyboard hides the button, sticky bars covering content.
3. Run Lighthouse mobile when the tool is available; under 60 is a fix.
   Otherwise note "Lighthouse not run".
4. Write `reports/{YYYY-MM-DD}-mobile-check.md`: the gap table from the
   export, one finding per page with the element and the fix, and the pages
   with no gap (say so; do not invent problems there).

## Rules

- The gap comes from the export; the cause comes from the walk. Report
  both or say which is missing.
- Fixes are layout and order changes, never brand changes.
