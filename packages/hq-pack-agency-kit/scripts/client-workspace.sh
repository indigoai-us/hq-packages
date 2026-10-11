#!/usr/bin/env bash
# client-workspace.sh: scaffold a client workspace from the kit's template.
#
# Copies templates/client-workspace/ into companies/{firm}/clients/{client}/,
# filling the placeholders. Never overwrites a file that already exists, so
# re-running only adds what is missing. The engagement folder must already
# exist (run /new-client first); this script never creates engagement.md.
#
# Mode decides where the client's own work lives:
#   folder   the clients/{client}/ folder is the whole workspace (default)
#   company  the client also gets its own HQ company; this script prints the
#            steps for that and writes nothing outside the firm company
#
# Usage (from the HQ root):
#   bash core/packages/hq-pack-agency-kit/scripts/client-workspace.sh \
#     --firm <slug> --client <slug> --client-name "<Client Name>" \
#     [--mode folder|company] [--agency-name "<Agency>"] [--root <hq-root>] [--dry-run]
#
# When --mode is omitted the default comes from the playbook's
# "Default client workspace:" line in agency-profile.md, then falls back to folder.
#
# Exit codes: 0 ok, 1 usage error, 2 firm company or engagement folder missing.
set -euo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HQ_ROOT:-$PWD}"
FIRM="" CLIENT="" CLIENT_NAME="" MODE="" AGENCY_NAME="" DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --client) CLIENT="${2:-}"; shift 2 ;;
    --client-name) CLIENT_NAME="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --agency-name) AGENCY_NAME="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "client-workspace: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$FIRM" ] && [ -n "$CLIENT" ] || { echo "client-workspace: --firm and --client are required" >&2; exit 1; }
for s in "$FIRM" "$CLIENT"; do
  case "$s" in ''|_*|*[!a-z0-9-]*) echo "client-workspace: invalid slug: $s" >&2; exit 1 ;; esac
done
[ -d "$ROOT/companies/$FIRM" ] || { echo "client-workspace: E_COMPANY_NOT_FOUND companies/$FIRM does not exist." >&2; exit 2; }

DEST="$ROOT/companies/$FIRM/clients/$CLIENT"
PLAYBOOK="$ROOT/companies/$FIRM/knowledge/agency-playbook/agency-profile.md"
[ -d "$DEST" ] || { echo "client-workspace: E_NO_ENGAGEMENT companies/$FIRM/clients/$CLIENT does not exist. Run /new-client first." >&2; exit 2; }

# Mode: flag, then playbook default, then folder.
if [ -z "$MODE" ] && [ -f "$PLAYBOOK" ]; then
  MODE="$(grep -m1 '^Default client workspace:' "$PLAYBOOK" | sed 's/^Default client workspace:[[:space:]]*//' | tr -d '[:space:]' || true)"
fi
case "$MODE" in
  ''|_*) MODE="folder" ;;
  folder|company) ;;
  *) echo "client-workspace: --mode must be folder or company (got: $MODE)" >&2; exit 1 ;;
esac

# Agency name: flag, then playbook frontmatter, then the firm slug.
if [ -z "$AGENCY_NAME" ] && [ -f "$PLAYBOOK" ]; then
  AGENCY_NAME="$(grep -m1 '^agency:' "$PLAYBOOK" | sed 's/^agency:[[:space:]]*//' || true)"
fi
[ -n "$AGENCY_NAME" ] || AGENCY_NAME="$FIRM"
[ -n "$CLIENT_NAME" ] || CLIENT_NAME="$CLIENT"

export CW_CLIENT_NAME="$CLIENT_NAME" CW_CLIENT_SLUG="$CLIENT" CW_AGENCY_NAME="$AGENCY_NAME"
export CW_MODE="$MODE" CW_TODAY="$(date -u +%Y-%m-%d)"

# Literal (not regex) replacement, so names containing & or \ survive intact.
render() {
  awk '
    function repl(s, key, val,   out, i) {
      out = ""
      while ((i = index(s, key)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(key)) }
      return out s
    }
    {
      line = $0
      line = repl(line, "{{CLIENT_NAME}}", ENVIRON["CW_CLIENT_NAME"])
      line = repl(line, "{{CLIENT_SLUG}}", ENVIRON["CW_CLIENT_SLUG"])
      line = repl(line, "{{AGENCY_NAME}}", ENVIRON["CW_AGENCY_NAME"])
      line = repl(line, "{{WORKSPACE_MODE}}", ENVIRON["CW_MODE"])
      line = repl(line, "{{TODAY}}", ENVIRON["CW_TODAY"])
      print line
    }' "$1"
}

SRC="$PACK_DIR/templates/client-workspace"
written=0 kept=0
while IFS= read -r tpl; do
  rel="${tpl#"$SRC"/}"
  out="$DEST/$rel"
  if [ -e "$out" ]; then
    echo "kept     clients/$CLIENT/$rel (already exists)"
    kept=$((kept + 1))
    continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "would write clients/$CLIENT/$rel"
  else
    mkdir -p "$(dirname "$out")"
    tmp="$(mktemp)"
    render "$tpl" > "$tmp" && mv "$tmp" "$out"
    echo "wrote    clients/$CLIENT/$rel"
  fi
  written=$((written + 1))
done < <(find "$SRC" -type f | LC_ALL=C sort)

echo "client-workspace: firm=$FIRM client=$CLIENT mode=$MODE written=$written kept=$kept"
if [ "$DRY" = 1 ]; then echo "client-workspace: dry run, nothing written"; fi

if [ "$MODE" = "company" ]; then
  cat <<EOF

client-workspace: company mode. The client's own HQ company is not created by
this script. Next, in this session:

  1. Create the company (skip if companies/$CLIENT already exists):
       /newcompany $CLIENT
  2. Add it to the session alongside the firm:
       bash core/scripts/hq-session.sh add company $CLIENT
  3. Create the client-facing home:
       bash core/packages/hq-pack-client-service/scripts/new-client.sh client-home \\
         --client $CLIENT --client-name "$CLIENT_NAME" --local-only --company-scaffold auto
  4. When done working in the client company:
       bash core/scripts/hq-session.sh remove company $CLIENT

Nothing in clients/$CLIENT/ is copied into companies/$CLIENT/. Firm skills reach
the client company only through /client-pack.
EOF
fi
exit 0
