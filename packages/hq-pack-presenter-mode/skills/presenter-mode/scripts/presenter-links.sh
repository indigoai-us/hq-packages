#!/bin/bash
# Build the three Presenter Mode links from a deployed deck base URL and print a
# cheat sheet. The presentation + notes links share one sync room; the audience
# link is sync-free so a public viewer can never hijack navigation.
#
# Usage: presenter-links.sh <base-url> [room]
#   base-url : the hq-deploy hosted URL, e.g. https://hq-corey-keynote.indigo-hq.com
#   room     : optional sync room code; a random one is generated when omitted
set -euo pipefail
BASE="${1:?usage: presenter-links.sh <base-url> [room]}"
BASE="${BASE%/}"
ROOM="${2:-room-$(openssl rand -hex 3)}"

AUDIENCE="$BASE"
PRESENT="$BASE/?present=1&sync=$ROOM"
NOTES="$BASE/?notes&sync=$ROOM"

cat <<EOF
PRESENTER MODE — links ready (sync room: $ROOM)

  PRESENTATION  $PRESENT
    → the slides. Put this on the projector/external screen. Press P for full-screen.

  NOTES / SCRIPT  $NOTES
    → your teleprompter: script + bullets (press B to toggle), current/next thumbnails.
      Keep this on your laptop. Arrow keys here drive BOTH screens.

  AUDIENCE (no sync)  $AUDIENCE
    → safe public link to share afterward; it never follows or controls the room.

How to run it:
  • Open NOTES on your laptop, PRESENTATION on the screen the audience sees.
  • Advance with ← / → / Space on either device — the other follows within ~1s.
  • Keys: P present · N pop-out notes · B script/bullets · Home/End jump · Esc exit.

Tip: both PRESENTATION and NOTES must carry the SAME ?sync=$ROOM to stay linked.
EOF
