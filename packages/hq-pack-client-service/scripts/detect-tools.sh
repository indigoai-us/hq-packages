#!/usr/bin/env bash
# detect-tools.sh — propose adapter-slot candidates from what a firm ALREADY has.
#
#   detect-tools.sh --company <slug> [--root <path>] [--format yaml|tsv]
#                   [--secret-names-file <path>] [--mcp-config <path>]...
#                   [--patterns <path>] [--quiet]
#
# Exit codes
#   0  scan completed (candidates may be empty — that is a result, not a failure)
#   2  environment/usage problem
#
# What this script is, and is not
#   * It is a HEURISTIC. It proposes; it never binds. /onboard-firm decides, and
#     a human can overrule every line of output.
#   * The vendor names in the pattern table below are detection strings only.
#     Nothing in this pack branches on them: they end up either as a firm's own
#     `binding.tool_name` (the firm's label, opaque to the pack) or as a
#     `recommended.tool` hint on an empty slot. Delete the whole table and the
#     pack still runs — every slot simply stays undeclared until asked about.
#     See knowledge/client-service/adapter-contracts.md.
#
# Credential hygiene — the hard one
#   * Secret NAMES are read. Secret VALUES are never read, resolved, printed or
#     stored. This script never invokes `hq secrets get`, `--reveal`, `exec`,
#     `env`, or `hq run`; the only vault call it makes is the name listing.
#   * Anything that arrives from the vault listing and does not look like a bare
#     vault NAME is dropped before it can reach stdout.
#
# Policy hq-absent-field-never-means-constraining-value
#   * "Could not scan a source" and "scanned the source and found nothing" are
#     DIFFERENT results and are reported differently (`status: unavailable` vs
#     `status: scanned`). A source we could not read never resolves into
#     "the firm has no such tool".
#   * A candidate whose transport is unknown is reported with
#     `auto_bindable: false` rather than being given a guessed connector.
#
# Policy hq-auto-select-skips-underscore-pseudo-dirs
#   * Every directory listing here excludes `_`-prefixed pseudo-dirs with a
#     general rule (`_*`), never a named special case. This pack creates
#     `clients/_templates/`, so the defect this policy names is live here.
#
# Policy hq-bash-set-e-status-returns
#   * No function that returns non-zero as a status signal is called bare under
#     `set -e`; such calls are inside `if`/`&&` or use `|| rc=$?`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

COMPANY=""
ROOT=""
FORMAT="yaml"
SECRET_NAMES_FILE=""
PATTERNS_FILE=""
QUIET=0
MCP_EXTRA=()

die_env() { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 2; }
note() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --company) COMPANY="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    --secret-names-file) SECRET_NAMES_FILE="${2:-}"; shift 2 ;;
    --mcp-config) MCP_EXTRA+=("${2:-}"); shift 2 ;;
    --patterns) PATTERNS_FILE="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die_env "E_USAGE" "unknown argument: $1" ;;
  esac
done

[ -n "$COMPANY" ] || die_env "E_USAGE" "--company <slug> is required"
case "$FORMAT" in yaml|tsv) : ;; *) die_env "E_USAGE" "--format must be yaml or tsv" ;; esac

# Default root: <root>/core/packages/hq-pack-client-service/scripts/ -> <root>.
if [ -z "$ROOT" ]; then
  ROOT="$(cd -- "${PACK_DIR}/../../.." && pwd)"
  [ -d "${ROOT}/companies" ] || ROOT="$PWD"
fi
[ -d "$ROOT" ] || die_env "E_ROOT_NOT_FOUND" "no such root: ${ROOT}"

CO_DIR="${ROOT}/companies/${COMPANY}"

# ---------------------------------------------------------------------------
# Pattern table — detection strings, NOT contract. `slot|tool_label|regex`.
# ---------------------------------------------------------------------------
PATTERNS_BUILTIN='crm|attio|attio
crm|hubspot|hubspot
crm|salesforce|salesforce|sfdc
crm|pipedrive|pipedrive
crm|folk|(^|[^a-z])folk([^a-z]|$)
crm|close|(^|[^a-z])close(io)?([^a-z]|$)
crm|copper|copper
crm|affinity|affinity
billing|stripe|stripe
billing|quickbooks|quickbooks|qbo
billing|xero|xero
billing|freshbooks|freshbooks
billing|chargebee|chargebee
billing|recurly|recurly
billing|invoiced|invoiced
billing|harvest|harvest
agreements|docusign|docusign
agreements|dropbox-sign|(dropbox.?sign|hellosign)
agreements|pandadoc|pandadoc
agreements|adobe-sign|(adobe.?sign|echosign)
agreements|signnow|signnow
agreements|ironclad|ironclad
portal|notion|notion
portal|linear|linear
portal|asana|asana
portal|clickup|clickup
portal|monday|monday
portal|basecamp|basecamp
portal|trello|trello
portal|jira|jira
portal|vercel|vercel
portal|netlify|netlify
portal|cloudflare-pages|cloudflare
transcripts|recall|recall
transcripts|fireflies|fireflies
transcripts|otter|otter
transcripts|grain|grain
transcripts|gong|gong
transcripts|fathom|fathom
transcripts|granola|granola
transcripts|tldv|tldv
transcripts|zoom|zoom'

if [ -n "$PATTERNS_FILE" ]; then
  [ -f "$PATTERNS_FILE" ] || die_env "E_PATTERNS_NOT_FOUND" "no such patterns file: ${PATTERNS_FILE}"
  PATTERNS="$(cat "$PATTERNS_FILE")"
else
  PATTERNS="$PATTERNS_BUILTIN"
fi

SLOTS='crm
billing
agreements
portal
transcripts'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

RAW="$(mktemp -t cs-detect-raw.XXXXXX)"
AGG="$(mktemp -t cs-detect-agg.XXXXXX)"
cleanup() { rm -f "$RAW" "$AGG"; }
trap cleanup EXIT

# lower <string>
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# A bare vault NAME, never a value. Mirrors the schema's secret_name pattern.
# Returns non-zero as a status signal — only ever called inside `if`.
is_vault_name() {
  local n="$1"
  [ ${#n} -le 64 ] || return 1
  grep -Eq '^[A-Za-z][A-Za-z0-9_./-]{2,63}$' <<< "$n"
}

# record <slot> <tool> <evidence> <connector-or-dash> <secret-or-dash>
record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RAW"
}

# match_token <token> <evidence> <connector-or-dash> <secret-or-dash>
# Records every slot/tool whose regex matches the token.
match_token() {
  local tok slot tool re
  tok="$(lower "$1")"
  [ -n "$tok" ] || return 0
  while IFS='|' read -r slot tool re; do
    [ -n "${slot:-}" ] || continue
    [ -n "${re:-}" ] || re="$tool"
    if grep -Eq -- "$re" <<< "$tok"; then
      record "$slot" "$tool" "$2" "$3" "$4"
    fi
  done <<< "$PATTERNS"
}

# ---------------------------------------------------------------------------
# source 1 — the company's settings/
# ---------------------------------------------------------------------------
SETTINGS_STATUS="unavailable"
SETTINGS_DETAIL="no settings directory at companies/${COMPANY}/settings"
SETTINGS_DIR="${CO_DIR}/settings"

if [ -d "$SETTINGS_DIR" ]; then
  SETTINGS_STATUS="scanned"
  SETTINGS_DETAIL="companies/${COMPANY}/settings"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    base="$(basename -- "$entry")"
    case "$base" in
      _*|README*|.*) continue ;;   # general leading-underscore exclusion
    esac
    base="${base%.*}"
    match_token "$base" "company-settings" "-" "-"
  done <<< "$(find "$SETTINGS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# source 2 — configured MCP servers
# ---------------------------------------------------------------------------
MCP_STATUS="unavailable"
MCP_DETAIL="no MCP config found at any known path"
MCP_FILES=()
for f in \
  "${CO_DIR}/settings/mcp.json" \
  "${CO_DIR}/.mcp.json" \
  "${ROOT}/.mcp.json"
do
  # `[ ... ] && cmd` as a bare statement would trip `set -e` when the test is
  # false (policy hq-bash-set-e-status-returns), so the test is a condition.
  if [ -f "$f" ]; then MCP_FILES+=("$f"); fi
done
if [ "${#MCP_EXTRA[@]}" -gt 0 ]; then
  for f in "${MCP_EXTRA[@]}"; do
    [ -f "$f" ] || die_env "E_MCP_CONFIG_NOT_FOUND" "no such MCP config: ${f}"
    MCP_FILES+=("$f")
  done
fi

if ! command -v yq >/dev/null 2>&1; then
  MCP_DETAIL="yq is not installed — MCP config could not be parsed"
elif [ "${#MCP_FILES[@]}" -eq 0 ]; then
  : # keep the "not found" detail
else
  MCP_STATUS="scanned"
  MCP_DETAIL="$(printf '%s ' "${MCP_FILES[@]}" | sed "s|${ROOT}/||g; s| *$||")"
  for f in "${MCP_FILES[@]}"; do
    while IFS= read -r server; do
      [ -n "$server" ] || continue
      [ "$server" != "null" ] || continue
      match_token "$server" "mcp-server" "mcp" "-"
    done <<< "$(yq -p json -r '.mcpServers // {} | keys | .[]' "$f" 2>/dev/null || true)"
  done
fi

# ---------------------------------------------------------------------------
# source 3 — vault secret NAMES (names only, never values)
# ---------------------------------------------------------------------------
SECRETS_STATUS="unavailable"
SECRETS_DETAIL="no vault listing available (hq CLI not on PATH and no --secret-names-file)"
SECRETS_COUNT=0

collect_secret_names() { # prints one candidate name per line
  if [ -n "$SECRET_NAMES_FILE" ]; then
    cat "$SECRET_NAMES_FILE"
    return 0
  fi
  # NAME LISTING ONLY. Never `get`, never `--reveal`, never `exec`/`env`/`run`.
  hq secrets list --company "$COMPANY" 2>/dev/null || true
}

if [ -n "$SECRET_NAMES_FILE" ] && [ ! -f "$SECRET_NAMES_FILE" ]; then
  die_env "E_SECRET_NAMES_FILE_NOT_FOUND" "no such file: ${SECRET_NAMES_FILE}"
fi

if [ -n "$SECRET_NAMES_FILE" ] || command -v hq >/dev/null 2>&1; then
  SECRETS_STATUS="scanned"
  if [ -n "$SECRET_NAMES_FILE" ]; then
    SECRETS_DETAIL="name list supplied by --secret-names-file"
  else
    SECRETS_DETAIL="hq secrets list (names and metadata only)"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Take only the first whitespace-delimited field: a listing may carry
    # metadata columns, and we want the NAME and nothing else.
    name="${line%%[[:space:]]*}"
    if is_vault_name "$name"; then
      SECRETS_COUNT=$((SECRETS_COUNT + 1))
      # A vault name is not a transport, but a credential existing for a tool
      # means the firm can reach it over its API. That is the only inference
      # made here, and it is recorded as evidence so a human can reject it.
      match_token "$(printf '%s' "$name" | tr './-' '   ')" "vault-secret-name" "api" "$name"
    fi
  done <<< "$(collect_secret_names)"
fi

# ---------------------------------------------------------------------------
# clients/ — reported so onboarding knows whether it is scaffolding or adding to
# an existing tree. `_`-prefixed pseudo-dirs (this pack ships `_templates/`) are
# excluded by a general rule so nothing downstream can auto-select one.
# ---------------------------------------------------------------------------
CLIENTS_DIR="${CO_DIR}/clients"
CLIENTS_STATUS="absent"
CLIENT_LIST=()
if [ -d "$CLIENTS_DIR" ]; then
  CLIENTS_STATUS="present"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    base="$(basename -- "$entry")"
    case "$base" in
      _*|.*) continue ;;   # general leading-underscore exclusion — never a named case
    esac
    CLIENT_LIST+=("$base")
  done <<< "$(find "$CLIENTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort || true)"
fi

# ---------------------------------------------------------------------------
# aggregate — merge per (slot, tool); connector precedence mcp > api > unknown
# ---------------------------------------------------------------------------
if [ -s "$RAW" ]; then
  awk -F'\t' '
    {
      key = $1 SUBSEP $2
      seenkey = key SUBSEP $3
      if (!(seenkey in seen)) {
        seen[seenkey] = 1
        ev[key] = (key in ev) ? ev[key] "," $3 : $3
      }
      rank = ($4 == "mcp") ? 3 : (($4 == "api") ? 2 : 1)
      if (rank > r[key]) { r[key] = rank; conn[key] = $4 }
      if ($5 != "-" && !(key in sec)) sec[key] = $5
    }
    END {
      for (k in ev) {
        split(k, a, SUBSEP)
        printf "%s\t%s\t%s\t%s\t%s\n", a[1], a[2], conn[k], ((k in sec) ? sec[k] : "-"), ev[k]
      }
    }
  ' "$RAW" | LC_ALL=C sort > "$AGG"
fi

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
yaml_escape() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

if [ "$FORMAT" = "tsv" ]; then
  printf 'SOURCE\tcompany_settings\t%s\t%s\n' "$SETTINGS_STATUS" "$SETTINGS_DETAIL"
  printf 'SOURCE\tmcp_servers\t%s\t%s\n' "$MCP_STATUS" "$MCP_DETAIL"
  printf 'SOURCE\tvault_secret_names\t%s\t%s\n' "$SECRETS_STATUS" "$SECRETS_DETAIL"
  printf 'CLIENTS\t%s\t%s\n' "$CLIENTS_STATUS" "$CLIENTS_DIR"
  if [ "${#CLIENT_LIST[@]}" -gt 0 ]; then
    for c in "${CLIENT_LIST[@]}"; do printf 'CLIENT\t%s\n' "$c"; done
  fi
  while IFS=$'\t' read -r slot tool conn sec ev; do
    [ -n "${slot:-}" ] || continue
    auto="false"; if [ "$conn" != "-" ]; then auto="true"; fi
    printf 'CANDIDATE\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slot" "$tool" "$conn" "$sec" "$ev" "$auto"
  done < "$AGG"
  exit 0
fi

printf '# detect-tools.sh report — CANDIDATES ONLY. Nothing here is bound.\n'
printf '# Secret NAMES were read; no secret value was read, resolved or printed.\n'
printf 'schema: hq.client-service.detect-report\n'
printf 'schema_version: 1\n'
printf 'firm: %s\n' "$COMPANY"
printf 'root: %s\n' "$(yaml_escape "$ROOT")"
printf 'sources:\n'
printf '  # `unavailable` means NOT SCANNED, which is unknown. It never means\n'
printf '  # "the firm has no such tool" — absent evidence adds no constraint.\n'
printf '  company_settings:\n    status: %s\n    detail: %s\n' "$SETTINGS_STATUS" "$(yaml_escape "$SETTINGS_DETAIL")"
printf '  mcp_servers:\n    status: %s\n    detail: %s\n' "$MCP_STATUS" "$(yaml_escape "$MCP_DETAIL")"
printf '  vault_secret_names:\n    status: %s\n    detail: %s\n    names_seen: %s\n' \
  "$SECRETS_STATUS" "$(yaml_escape "$SECRETS_DETAIL")" "$SECRETS_COUNT"
printf 'clients_dir:\n  status: %s\n  path: %s\n' "$CLIENTS_STATUS" "$(yaml_escape "$CLIENTS_DIR")"
printf '  # Leading-underscore pseudo-dirs (_templates, _archive) are excluded.\n'
if [ "${#CLIENT_LIST[@]}" -eq 0 ]; then
  printf '  existing_clients: []\n'
else
  printf '  existing_clients:\n'
  for c in "${CLIENT_LIST[@]}"; do printf '    - %s\n' "$(yaml_escape "$c")"; done
fi
printf 'candidates:\n'
while IFS= read -r slot; do
  [ -n "$slot" ] || continue
  rows="$(awk -F'\t' -v s="$slot" '$1 == s' "$AGG" 2>/dev/null || true)"
  if [ -z "$rows" ]; then
    printf '  %s: []\n' "$slot"
    continue
  fi
  printf '  %s:\n' "$slot"
  while IFS=$'\t' read -r xslot tool conn sec ev; do
    [ -n "${xslot:-}" ] || continue
    printf '    - tool_name: %s\n' "$(yaml_escape "$tool")"
    if [ "$conn" = "-" ]; then
      printf '      connector: null        # transport unknown from this evidence — ask, never guess\n'
      printf '      auto_bindable: false\n'
    else
      printf '      connector: %s\n' "$conn"
      printf '      auto_bindable: true\n'
    fi
    if [ "$sec" = "-" ]; then
      printf '      secret_name: null      # undeclared, NOT "no auth needed"\n'
    else
      printf '      secret_name: %s\n' "$(yaml_escape "$sec")"
    fi
    printf '      evidence: [%s]\n' "$(printf '%s' "$ev" | sed 's/,/, /g')"
  done <<< "$rows"
done <<< "$SLOTS"
