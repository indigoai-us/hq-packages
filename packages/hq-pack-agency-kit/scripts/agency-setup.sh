#!/usr/bin/env bash
# agency-setup.sh: install the agency playbook into a firm company.
#
# Copies templates/playbook/*.md into companies/{firm}/knowledge/agency-playbook/,
# filling the agency's answers into the placeholders. Never overwrites a playbook
# file that already exists: the firm's own edits always win. Re-running only adds
# files that are missing.
#
# Usage (from the HQ root):
#   bash core/packages/hq-pack-agency-kit/scripts/agency-setup.sh \
#     --firm <slug> --name "<Agency Name>" \
#     [--services "..."] [--ideal-client "..."] [--pricing "..."] \
#     [--tools "..."] [--voice "..."] [--client-mode folder|company]
#     [--root <hq-root>] [--dry-run]
#
# Exit codes: 0 ok, 1 usage error, 2 firm company missing.
set -euo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HQ_ROOT:-$PWD}"
FIRM="" NAME="" DRY=0
SERVICES="" IDEAL="" PRICING="" TOOLS="" VOICE="" CLIENT_MODE="folder"

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --services) SERVICES="${2:-}"; shift 2 ;;
    --ideal-client) IDEAL="${2:-}"; shift 2 ;;
    --pricing) PRICING="${2:-}"; shift 2 ;;
    --tools) TOOLS="${2:-}"; shift 2 ;;
    --voice) VOICE="${2:-}"; shift 2 ;;
    --client-mode) CLIENT_MODE="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "agency-setup: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$FIRM" ] && [ -n "$NAME" ] || { echo "agency-setup: --firm and --name are required" >&2; exit 1; }
case "$FIRM" in ''|_*|*[!a-z0-9-]*) echo "agency-setup: invalid firm slug: $FIRM" >&2; exit 1 ;; esac
case "$CLIENT_MODE" in folder|company) ;; *) echo "agency-setup: --client-mode must be folder or company" >&2; exit 1 ;; esac
[ -d "$ROOT/companies/$FIRM" ] || { echo "agency-setup: E_COMPANY_NOT_FOUND companies/$FIRM does not exist. Create the company first." >&2; exit 2; }

DEST="$ROOT/companies/$FIRM/knowledge/agency-playbook"
TODAY="$(date -u +%Y-%m-%d)"
placeholder() { [ -n "$1" ] && printf '%s' "$1" || printf '_Not answered yet. Run /agency-setup again or edit this section._'; }

export AK_AGENCY_NAME="$NAME" AK_TODAY="$TODAY"
AK_SERVICES="$(placeholder "$SERVICES")"; export AK_SERVICES
AK_IDEAL_CLIENT="$(placeholder "$IDEAL")"; export AK_IDEAL_CLIENT
AK_PRICING_MODEL="$(placeholder "$PRICING")"; export AK_PRICING_MODEL
AK_TOOLS="$(placeholder "$TOOLS")"; export AK_TOOLS
AK_VOICE="$(placeholder "$VOICE")"; export AK_VOICE
export AK_CLIENT_MODE="$CLIENT_MODE"

# Literal (not regex) replacement, so answers containing & or \ survive intact.
render() {
  awk '
    function repl(s, key, val,   out, i) {
      out = ""
      while ((i = index(s, key)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(key)) }
      return out s
    }
    {
      line = $0
      line = repl(line, "{{AGENCY_NAME}}", ENVIRON["AK_AGENCY_NAME"])
      line = repl(line, "{{TODAY}}", ENVIRON["AK_TODAY"])
      line = repl(line, "{{SERVICES}}", ENVIRON["AK_SERVICES"])
      line = repl(line, "{{IDEAL_CLIENT}}", ENVIRON["AK_IDEAL_CLIENT"])
      line = repl(line, "{{PRICING_MODEL}}", ENVIRON["AK_PRICING_MODEL"])
      line = repl(line, "{{TOOLS}}", ENVIRON["AK_TOOLS"])
      line = repl(line, "{{VOICE}}", ENVIRON["AK_VOICE"])
      line = repl(line, "{{CLIENT_MODE}}", ENVIRON["AK_CLIENT_MODE"])
      print line
    }' "$1"
}

[ "$DRY" = 1 ] || mkdir -p "$DEST"
written=0 kept=0
for tpl in "$PACK_DIR"/templates/playbook/*.md; do
  base="$(basename "$tpl")"
  if [ -e "$DEST/$base" ]; then
    echo "kept     knowledge/agency-playbook/$base (already exists)"
    kept=$((kept + 1))
    continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "would write knowledge/agency-playbook/$base"
  else
    tmp="$(mktemp)"
    render "$tpl" > "$tmp" && mv "$tmp" "$DEST/$base"
    echo "wrote    knowledge/agency-playbook/$base"
  fi
  written=$((written + 1))
done
echo "agency-setup: firm=$FIRM written=$written kept=$kept"
if [ "$DRY" = 1 ]; then echo "agency-setup: dry run, nothing written"; fi
exit 0
