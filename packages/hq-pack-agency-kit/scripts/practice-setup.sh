#!/bin/bash
# practice-setup.sh: the steps after the playbook, in one command, so a setup
# bot (or a person) runs them in order without knowing the client-service pack:
#
#   1. the client-service firm setup with every slot empty
#   2. Northwind Labs recorded as a practice client (local only)
#   3. Northwind's onboarding documents loaded
#
# Safe to re-run: a firm already set up, a practice client already recorded,
# and documents already loaded are all treated as done.
#
# Usage:
#   bash scripts/practice-setup.sh --firm <slug> --agency-name "<Agency Name>"
#
# Run from the HQ root (or set HQ_ROOT). Exit codes: 0 ok, 1 usage error,
# 2 a step failed (the step is named on stderr).
set -uo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HQ_ROOT:-$PWD}"
CS="$ROOT/core/packages/hq-pack-client-service/scripts"
FIRM="" AGENCY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --agency-name) AGENCY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "practice-setup: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$FIRM" ] && [ -n "$AGENCY" ] || { echo "practice-setup: --firm and --agency-name are required" >&2; exit 1; }
case "$FIRM" in ''|_*|*[!a-z0-9-]*) echo "practice-setup: invalid firm slug: $FIRM" >&2; exit 1 ;; esac
[ -d "$CS" ] || { echo "practice-setup: E_NO_CLIENT_SERVICE hq-pack-client-service is not installed" >&2; exit 2; }

step() {
  # step <name> <ok-pattern> -- <command...>: run; a failure whose output matches ok-pattern counts as done.
  local name="$1" ok="$2"; shift 3
  local out rc
  out="$(cd "$ROOT" && HQ_ROOT="$ROOT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && { [ -z "$ok" ] || ! printf '%s' "$out" | grep -q -E "$ok"; }; then
    printf '%s\n' "$out" >&2
    echo "practice-setup: step failed: $name (exit $rc)" >&2
    exit 2
  fi
  echo "practice-setup: $name done"
}

if [ -d "$ROOT/companies/$FIRM/clients" ] && [ -f "$ROOT/companies/$FIRM/client-service.yaml" ]; then
  echo "practice-setup: firm setup already done"
else
  step "firm setup" "" -- bash "$CS/onboard-firm.sh" --company "$FIRM" \
    --empty crm --empty billing --empty agreements --empty portal --empty transcripts
fi
step "practice client record" "E_SLUG_COLLISION" -- bash "$CS/new-client.sh" engagement \
  --firm "$FIRM" --client practice-northwind --client-name "Northwind Labs (practice)" --local-only
step "practice documents" "E_INPUTS_EXIST" -- bash "$PACK_DIR/scripts/practice-client.sh" \
  --firm "$FIRM" --agency-name "$AGENCY" --root "$ROOT"
echo "practice-setup: firm=$FIRM ok"
