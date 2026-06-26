#!/bin/bash
# Inspect a self-contained HTML deck for the HQ presenter-mode contract.
# Usage: check-deck.sh <path-to-deck.html>
# Prints a per-capability report and a one-word verdict on the last line:
#   READY        — presenter mode is fully wired (just deploy + emit links)
#   PARTIAL      — some hooks present; injecting the bundle will complete it
#   NEEDS-BUNDLE — slides exist but no presenter machinery; inject the bundle
#   NOT-A-DECK   — no .deck-slide slides found
set -euo pipefail
F="${1:?usage: check-deck.sh <deck.html>}"
[ -f "$F" ] || { echo "no such file: $F" >&2; exit 2; }

has() { grep -q "$1" "$F" && echo "yes" || echo "no"; }

SLIDES=$(has 'deck-slide')
BUNDLE=$(has 'HQ PRESENTER MODE: bundle start')
NOTES_DATA=$(has 'id="notes-data"')
APPLY_DECK=$(has '__knApplyDeck')
APPLY_NOTES=$(has '__knApplyNotes')
SYNC=$(has 'ps.pndsn.com')
FIT=$(grep -q -e '--fit' "$F" && echo "yes" || echo "no")

printf '%-22s %s\n' "slides (.deck-slide):" "$SLIDES"
printf '%-22s %s\n' "presenter bundle:" "$BUNDLE"
printf '%-22s %s\n' "notes-data JSON:" "$NOTES_DATA"
printf '%-22s %s\n' "deck sync hook:" "$APPLY_DECK"
printf '%-22s %s\n' "notes sync hook:" "$APPLY_NOTES"
printf '%-22s %s\n' "pubnub bridge:" "$SYNC"
printf '%-22s %s\n' "scale-to-fit:" "$FIT"
echo "---"

if [ "$SLIDES" = "no" ]; then
  echo "VERDICT: NOT-A-DECK"
elif [ "$APPLY_DECK" = "yes" ] && [ "$APPLY_NOTES" = "yes" ] && [ "$SYNC" = "yes" ] && [ "$NOTES_DATA" = "yes" ]; then
  echo "VERDICT: READY"
elif [ "$APPLY_DECK" = "yes" ] || [ "$SYNC" = "yes" ] || [ "$BUNDLE" = "yes" ]; then
  echo "VERDICT: PARTIAL"
else
  echo "VERDICT: NEEDS-BUNDLE"
fi
