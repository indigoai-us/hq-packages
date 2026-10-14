#!/usr/bin/env bash
# grade-practice.sh: grade a Northwind Labs practice run against the answer key.
#
# Reads the four onboarding outputs (01-client-brief.md, 02-intake-request.md,
# 03-audit.md, 04-kickoff-package.md) under
# companies/{firm}/clients/{client}/onboarding/ and checks each of the eight
# planted issues from the instructor answer key
# (examples/practice-client/inputs/README.md, "For instructors") against them.
# Issue titles are read from the key, so the key stays the single description
# of what a good run catches; the match patterns live here.
#
# Prints one line per issue: `found   N  Title  (file)` or `MISSING N  Title`,
# then a summary line `grade-practice: found=F missing=M of 8`.
#
# Usage (from the HQ root):
#   bash core/packages/hq-pack-agency-kit/scripts/grade-practice.sh --firm <slug> \
#     [--client practice-northwind] [--root <hq-root>]
#   bash core/packages/hq-pack-agency-kit/scripts/grade-practice.sh --dir <onboarding-dir>
#
# Exit codes: 0 all eight found, 1 one or more missing, 2 usage error or
# onboarding files missing.
set -euo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HQ_ROOT:-$PWD}"
FIRM="" CLIENT="practice-northwind" DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --client) CLIENT="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "grade-practice: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DIR" ]; then
  [ -n "$FIRM" ] || { echo "grade-practice: --firm or --dir is required" >&2; exit 2; }
  case "$FIRM$CLIENT" in *[!a-z0-9-]*) echo "grade-practice: slugs must be lowercase letters, digits and hyphens" >&2; exit 2 ;; esac
  DIR="$ROOT/companies/$FIRM/clients/$CLIENT/onboarding"
fi
[ -d "$DIR" ] || { echo "grade-practice: E_NO_ONBOARDING $DIR does not exist. Run onboarding first." >&2; exit 2; }

FILES=(01-client-brief.md 02-intake-request.md 03-audit.md 04-kickoff-package.md)
missing_files=0
for f in "${FILES[@]}"; do
  [ -f "$DIR/$f" ] || { echo "grade-practice: E_MISSING_OUTPUT $f is not in $DIR" >&2; missing_files=1; }
done
[ "$missing_files" = 0 ] || exit 2

# Issue titles from the answer key: lines like `1. **Brands.** ...`.
KEY="$PACK_DIR/examples/practice-client/inputs/README.md"
[ -f "$KEY" ] || { echo "grade-practice: answer key not found at $KEY" >&2; exit 2; }
TITLES=()
while IFS= read -r t; do TITLES+=("$t"); done < <(
  awk '/^## For instructors/{f=1;next} f && /^[0-9]+\. \*\*/{ sub(/^[0-9]+\. \*\*/,""); sub(/\.?\*\*.*$/,""); print }' "$KEY"
)
[ "${#TITLES[@]}" = 8 ] || { echo "grade-practice: answer key lists ${#TITLES[@]} issues, expected 8" >&2; exit 2; }

# One entry per issue. Patterns separated by `|||` must ALL match somewhere in
# the four files (case-insensitive, extended regex). Each pattern is a set of
# alternatives that a run would plausibly use for the same point.
PATTERNS=(
  'edge|academy'
  'landing[- ]?page|||refresh|||exclu|out of scope|not cover'
  'form submission|any form|form fill|lead form'
  '46 ?%|46 percent|||(0|zero|no) enterprise'
  'september only|one month|single month|migration|july and august'
  'approver|sign-?off|||linkedin|||brand guidelines|||crm (read )?access|access to (the|their) crm'
  'demo'
  'cost per (opportunity|sqo|lead)|per[- ]opportunity|mismatched periods|period mismatch|different periods|q3 total|||deadline|business days|overdue|has passed|already passed|have passed'
)

grep_any() { # $1 pattern -> prints the first file that matches, status 1 if none
  local f
  for f in "${FILES[@]}"; do
    if grep -qiE -- "$1" "$DIR/$f"; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

found=0 missing=0
for i in "${!PATTERNS[@]}"; do
  n=$((i + 1)); title="${TITLES[$i]}"
  all_ok=1 where=""
  spec="${PATTERNS[$i]}"
  while [ -n "$spec" ]; do
    case "$spec" in
      *'|||'*) part="${spec%%|||*}"; spec="${spec#*|||}" ;;
      *) part="$spec"; spec="" ;;
    esac
    if hit="$(grep_any "$part")"; then
      [ -n "$where" ] || where="$hit"
    else
      all_ok=0
    fi
  done
  if [ "$all_ok" = 1 ]; then
    found=$((found + 1)); printf 'found   %d  %s  (%s)\n' "$n" "$title" "$where"
  else
    missing=$((missing + 1)); printf 'MISSING %d  %s\n' "$n" "$title"
  fi
done

printf 'grade-practice: found=%d missing=%d of 8\n' "$found" "$missing"
[ "$missing" = 0 ]
