#!/bin/bash
# skills-library-install.sh: copy the pack's skills into the agency's own
# skills directory, companies/<firm>/skills/<slug>/, so they show up in the
# company's skills view and sync with the company like any other company skill.
#
# Every pack skill is copied except the setup-only ones (agency-setup,
# practice-client). A skill the agency already has with the same slug is left
# alone, so local edits survive re-runs and pack updates.
#
# Usage:
#   bash scripts/skills-library-install.sh --firm <slug>
#
# Run from the HQ root (or set HQ_ROOT). Prints one JSON line:
#   {"ok":true,"installed":N,"kept":M,"dir":"companies/<firm>/skills"}
# Exit codes: 0 ok, 1 usage error, 2 the firm directory does not exist.
set -uo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HQ_ROOT:-$PWD}"
FIRM=""
SKIP="agency-setup practice-client"

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$FIRM" ] || { echo "usage: skills-library-install.sh --firm <slug>" >&2; exit 1; }
[ -d "$ROOT/companies/$FIRM" ] || { echo "no such company directory: companies/$FIRM" >&2; exit 2; }

DEST="$ROOT/companies/$FIRM/skills"
mkdir -p "$DEST"
installed=0 kept=0
for src in "$PACK_DIR"/skills/*/; do
  slug="$(basename "$src")"
  case " $SKIP " in *" $slug "*) continue ;; esac
  [ -f "$src/SKILL.md" ] || continue
  if [ -e "$DEST/$slug" ]; then
    kept=$((kept + 1))
    continue
  fi
  cp -R "$src" "$DEST/$slug"
  installed=$((installed + 1))
done
printf '{"ok":true,"installed":%d,"kept":%d,"dir":"companies/%s/skills"}\n' "$installed" "$kept" "$FIRM"
