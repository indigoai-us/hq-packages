#!/bin/bash
# import-clients.sh: give each of the agency's current clients a home in one
# step: the client-service engagement record (local only) and the Agency Kit
# client workspace (profile, access and assets, onboarding inputs, reports).
#
# The list is a file with one client per line: <slug><TAB><Client Name>.
# Blank lines and lines starting with # are ignored. Safe to re-run: a client
# that already has a home is left as it is and reported as existing.
#
# Usage (from the HQ root):
#   bash core/packages/hq-pack-agency-kit/scripts/import-clients.sh \
#     --firm <slug> --file <clients.tsv> [--agency-name "<Agency>"] [--root <hq-root>]
#
# Prints one line per client (created, exists or failed) and a total.
# Exit codes: 0 every client has a home, 1 usage error, 2 one or more failed.
set -uo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HQ_ROOT:-$PWD}"
FIRM="" FILE="" AGENCY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --file) FILE="${2:-}"; shift 2 ;;
    --agency-name) AGENCY="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "import-clients: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$FIRM" ] && [ -n "$FILE" ] || { echo "import-clients: --firm and --file are required" >&2; exit 1; }
case "$FIRM" in ''|_*|*[!a-z0-9-]*) echo "import-clients: invalid firm slug: $FIRM" >&2; exit 1 ;; esac
[ -f "$FILE" ] || { echo "import-clients: no such file: $FILE" >&2; exit 1; }
CS="$ROOT/core/packages/hq-pack-client-service/scripts"
[ -d "$CS" ] || { echo "import-clients: E_NO_CLIENT_SERVICE hq-pack-client-service is not installed" >&2; exit 2; }
[ -d "$ROOT/companies/$FIRM" ] || { echo "import-clients: E_COMPANY_NOT_FOUND companies/$FIRM" >&2; exit 2; }
# Client records need the firm setup's template; run it (deciding no slots) when missing.
if [ ! -f "$ROOT/companies/$FIRM/clients/_templates/engagement.template.md" ]; then
  bash "$PACK_DIR/scripts/firm-setup.sh" --firm "$FIRM" --root "$ROOT" >/dev/null 2>&1 \
    || { echo "import-clients: E_FIRM_SETUP the firm setup has not run and could not run (see firm-setup.sh)" >&2; exit 2; }
fi

created=0 existing=0 failed=0
while IFS=$'\t' read -r slug name || [ -n "${slug:-}" ]; do
  slug="$(printf '%s' "${slug:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  name="$(printf '%s' "${name:-}" | tr -d '\r' | sed 's/^ *//;s/ *$//')"
  case "$slug" in ''|\#*) continue ;; esac
  case "$slug" in _*|*[!a-z0-9-]*) echo "failed   $slug  (slugs are lowercase letters, digits and hyphens)"; failed=$((failed+1)); continue ;; esac
  [ -n "$name" ] || name="$slug"
  if [ -f "$ROOT/companies/$FIRM/clients/$slug/engagement.md" ] && [ -f "$ROOT/companies/$FIRM/clients/$slug/client-profile.md" ]; then
    echo "exists   $slug  $name"; existing=$((existing+1)); continue
  fi
  out="$(cd "$ROOT" && HQ_ROOT="$ROOT" bash "$CS/new-client.sh" engagement --firm "$FIRM" --client "$slug" \
    --client-name "$name" --local-only --hq-root "$ROOT" --session-company "$FIRM" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "E_SLUG_COLLISION"; then
    echo "failed   $slug  $name  (client record: $(printf '%s' "$out" | grep -m1 -o 'E_[A-Z_]*' || echo "exit $rc"))"
    failed=$((failed+1)); continue
  fi
  ws=(--firm "$FIRM" --client "$slug" --client-name "$name" --mode folder --root "$ROOT")
  [ -n "$AGENCY" ] && ws+=(--agency-name "$AGENCY")
  out="$(cd "$ROOT" && HQ_ROOT="$ROOT" bash "$PACK_DIR/scripts/client-workspace.sh" "${ws[@]}" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "failed   $slug  $name  (workspace: exit $rc)"; failed=$((failed+1)); continue
  fi
  echo "created  $slug  $name"; created=$((created+1))
done < "$FILE"

echo "import-clients: firm=$FIRM created=$created existing=$existing failed=$failed"
[ "$failed" -eq 0 ] || exit 2
