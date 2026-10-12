#!/bin/bash
# firm-setup.sh: the client-service firm setup for an agency, with the tools
# the agency actually uses. Each --bind links one slot (crm, billing,
# agreements, portal, transcripts) to a tool, for example
#   --bind crm=HubSpot:cli
# for a CRM the agency reaches through HQ integrations. Slots not bound here
# stay undecided (never guessed, never forced empty) so they can be linked
# later by running this again with a --bind. Safe to re-run: a slot that is
# already decided is never changed.
#
# Usage (from the HQ root):
#   bash core/packages/hq-pack-agency-kit/scripts/firm-setup.sh \
#     --firm <slug> [--agency-name "<Agency>"] [--bind <slot>=<tool>:<connector>]...
#
# Exit codes: 0 ok, 1 usage error, 2 the firm setup failed (reason on stderr).
set -uo pipefail

ROOT="${HQ_ROOT:-$PWD}"
FIRM="" BINDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --agency-name) shift 2 ;;
    --bind) BINDS+=(--bind "${2:-}"); shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "firm-setup: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$FIRM" ] || { echo "firm-setup: --firm is required" >&2; exit 1; }
case "$FIRM" in _*|*[!a-z0-9-]*) echo "firm-setup: invalid firm slug: $FIRM" >&2; exit 1 ;; esac
CS="$ROOT/core/packages/hq-pack-client-service/scripts"
[ -d "$CS" ] || { echo "firm-setup: E_NO_CLIENT_SERVICE hq-pack-client-service is not installed" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "firm-setup: E_ENV_YQ_MISSING the firm setup needs yq (brew install yq)" >&2; exit 2; }

out="$(cd "$ROOT" && HQ_ROOT="$ROOT" bash "$CS/onboard-firm.sh" --company "$FIRM" --root "$ROOT" --non-interactive --no-auto ${BINDS[@]+"${BINDS[@]}"} 2>&1)"; rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "firm-setup: the firm setup failed (exit $rc)" >&2; exit 2; }
echo "firm-setup: firm=$FIRM ok"
