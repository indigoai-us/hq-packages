#!/usr/bin/env bash
# practice-client.sh: load the Northwind Labs practice client's documents into a firm.
#
# Copies examples/practice-client/inputs/* into
# companies/{firm}/clients/{slug}/onboarding/inputs/, filling {{AGENCY_NAME}}.
# Run it after the client-service engagement phase has created
# companies/{firm}/clients/{slug}/. Refuses if inputs already exist, so a
# the person's practice work is never overwritten.
#
# Usage (from the HQ root):
#   bash core/packages/hq-pack-agency-kit/scripts/practice-client.sh \
#     --firm <slug> --agency-name "<Agency Name>" [--client practice-northwind] \
#     [--root <hq-root>] [--include-answer-key]
#
# The instructor answer key (inputs/README.md "For instructors" section) is
# stripped unless --include-answer-key is passed.
#
# Exit codes: 0 ok, 1 usage error or refused, 2 engagement folder missing.
set -euo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HQ_ROOT:-$PWD}"
FIRM="" AGENCY="" CLIENT="practice-northwind" KEY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --agency-name) AGENCY="${2:-}"; shift 2 ;;
    --client) CLIENT="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --include-answer-key) KEY=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "practice-client: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$FIRM" ] && [ -n "$AGENCY" ] || { echo "practice-client: --firm and --agency-name are required" >&2; exit 1; }
case "$FIRM$CLIENT" in *[!a-z0-9-]*) echo "practice-client: slugs must be lowercase letters, digits and hyphens" >&2; exit 1 ;; esac

ENG="$ROOT/companies/$FIRM/clients/$CLIENT"
[ -d "$ENG" ] || { echo "practice-client: E_NO_ENGAGEMENT companies/$FIRM/clients/$CLIENT does not exist. Run the client-service engagement phase first." >&2; exit 2; }
DEST="$ENG/onboarding/inputs"
if [ -d "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  echo "practice-client: E_INPUTS_EXIST $DEST already has files. Nothing was changed." >&2
  exit 1
fi

mkdir -p "$DEST"
export AK_AGENCY_NAME="$AGENCY"
for src in "$PACK_DIR"/examples/practice-client/inputs/*; do
  base="$(basename "$src")"
  tmp="$(mktemp)"
  if [ "$base" = README.md ] && [ "$KEY" = 0 ]; then
    awk '/^## For instructors/ { exit } { print }' "$src" > "$tmp"
  else
    # Literal replacement, so a name containing & or \ survives intact.
    awk '{
      s = $0; out = ""; key = "{{AGENCY_NAME}}"
      while ((i = index(s, key)) > 0) { out = out substr(s, 1, i - 1) ENVIRON["AK_AGENCY_NAME"]; s = substr(s, i + length(key)) }
      print out s
    }' "$src" > "$tmp"
  fi
  mv "$tmp" "$DEST/$base"
  echo "wrote    clients/$CLIENT/onboarding/inputs/$base"
done
echo "practice-client: loaded into companies/$FIRM/clients/$CLIENT/onboarding/inputs"
