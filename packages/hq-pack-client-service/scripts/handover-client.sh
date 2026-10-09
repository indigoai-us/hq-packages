#!/usr/bin/env bash
# handover-client.sh — the deterministic engine behind the /handover-client skill.
#
#   handover-client.sh verify        --client <slug> [roster opts] [firm-identity opts]
#   handover-client.sh transfer      --client <slug> --to <email|prs_uid>
#                                    --approval approved|declined [--initiator-role <r>]
#                                    [--reason <text>] [--roster-after <path>]
#                                    [--no-read-back] [roster opts] [firm-identity opts]
#   handover-client.sh verify-access --client <slug> [--roster-after <path>] [firm-identity opts]
#   handover-client.sh status        --client <slug> [roster opts] [firm-identity opts]
#
# Roster options       --roster <path> | (default) read it through --hq-bin
# Firm identity        --firm-member <email>[:role] (repeatable) | --firm-domain <domain>
# Common options       --hq-root <path> --session-company <slug> --hq-bin <path>
#                      --checklist <path> --pack-dir <path> --cloud | --local-only
#                      --dry-run --quiet
#
# Exit codes
#   0  the verb completed — including "BLOCKED" from `verify`/`status` reported
#      cleanly, a DECLINED approval gate, and the local-only notice. None of
#      those are failures; they are answers.
#   1  the verb was REFUSED, or a read-back found a MISMATCH. Nothing
#      irreversible was done by this script in that state.
#   2  usage / environment problem
#
#   `verify --strict` and `transfer` turn a BLOCKED checklist into exit 1,
#   because there the answer gates an action.
#
# ---------------------------------------------------------------------------
# Design notes — read before changing anything
# ---------------------------------------------------------------------------
#
# 1. UNKNOWN IS NEVER DONE (policy hq-absent-field-never-means-constraining-value).
#    Every checklist item resolves to exactly one of DONE / INCOMPLETE / UNKNOWN,
#    and BOTH of the last two block. A checked box whose mechanical cross-check
#    cannot be run is UNKNOWN, not DONE — a human ticking a box is a claim, and a
#    claim this engine cannot corroborate is not evidence. Absent roster, absent
#    firm identity, an unparsable table cell, a `TODO` left in place, a membership
#    row with no `status` field: all UNKNOWN. This is the whole point of the
#    story — handover is irreversible from the firm's side, so the only safe
#    resolution of "I don't know" is "stop".
#
# 2. THIS SCRIPT MAKES NO EXTERNAL CALL OF ITS OWN.
#    Exactly one seam reaches outward: `$HQ_BIN` (default `hq`), invoked only for
#    `members list` (read) and `company transfer initiate` (the write). Every such
#    invocation goes through hq_call(), which records it, so a test can point
#    --hq-bin at a mock and assert on the exact argv. There is no curl, no gh, no
#    aws, no ssh anywhere in this file.
#
# 3. THE APPROVAL GATE IS THE ONLY DOOR TO THE WRITE.
#    `transfer` performs the `hq company transfer initiate` call if and ONLY if
#    --approval approved was passed. `declined` and ABSENT both do nothing at all
#    — not a partial write, not a staged file, nothing — and both say so. Absent
#    is UNDECIDED and is reported as such; it is never read as approval.
#    (Policy client-service-approval-gate-external-actions.)
#
# 4. READ THE RESULT BACK; DO NOT ASSUME THE WRITE WORKED.
#    After the transfer, firm access is re-derived from a FRESH roster read and
#    compared against the end-state the checklist declares. A mismatch is exit 1
#    with the specific rows named. "The command exited 0" is not evidence about
#    the state of a membership graph.
#
# 5. ONE COMPANY PER SESSION. Everything here runs in a session bound to the
#    CLIENT company: it reads companies/{client}/ and nothing from the firm tree.
#    Firm identity arrives as flags — names, not paths — exactly like the
#    provenance metadata in new-client.sh and client-pack.sh.
#
# 6. SET -E STATUS RETURNS (policy hq-bash-set-e-status-returns). Functions that
#    return non-zero as a status signal are called inside an `if`/`&&` condition
#    or with the `|| rc=$?` capture idiom, never bare.
#
# 7. SECRET HYGIENE. Section 3 of the checklist is read for secret NAMES and
#    dispositions only. This engine never reads, prints, writes, or requests a
#    secret VALUE, and never invokes a reveal path.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

VERB=""
PACK_DIR_OVERRIDE=""
HQ_ROOT="${HQ_ROOT:-}"
SESSION_COMPANY="${HQ_CLIENT_SERVICE_SESSION_COMPANY:-}"
HQ_BIN="${HQ_CLIENT_SERVICE_HQ_BIN:-hq}"
CLIENT=""
CHECKLIST_OVERRIDE=""
ROSTER_FILE=""
ROSTER_AFTER_FILE=""
FIRM_MEMBERS=()
FIRM_DOMAINS=()
TARGET=""
APPROVAL=""            # "" = UNDECIDED | approved | declined
INITIATOR_ROLE=""      # "" = omit the flag entirely (server keeps its safe default)
REASON=""
CLOUD_REQUESTED=""     # "" = auto | yes | no
READ_BACK=1
STRICT=0
DRY_RUN=0
QUIET=0

# ---------------------------------------------------------------------------
# output / errors
# ---------------------------------------------------------------------------
say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
line() { [ "$QUIET" -eq 1 ] || printf '  %-26s %s\n' "$1" "$2"; }

die_usage() { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 2; }
die_op()    { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# findings — the verification ledger
# ---------------------------------------------------------------------------
FINDINGS=()
N_DONE=0
N_INCOMPLETE=0
N_UNKNOWN=0

finding() { # finding <DONE|INCOMPLETE|UNKNOWN> <section> <message>
  FINDINGS+=("$1"$'\t'"$2"$'\t'"$3")
  case "$1" in
    DONE)       N_DONE=$((N_DONE + 1)) ;;
    INCOMPLETE) N_INCOMPLETE=$((N_INCOMPLETE + 1)) ;;
    UNKNOWN)    N_UNKNOWN=$((N_UNKNOWN + 1)) ;;
  esac
}

print_findings() {
  local f state sec msg
  for f in "${FINDINGS[@]:-}"; do
    [ -n "$f" ] || continue
    state="${f%%$'\t'*}"
    sec="${f#*$'\t'}"; sec="${sec%%$'\t'*}"
    msg="${f##*$'\t'}"
    printf '  %-10s §%-2s %s\n' "$state" "$sec" "$msg"
  done
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

# Status-returning: only ever called inside a condition.
is_slug() { printf '%s' "${1:-}" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; }

require_slug() { # require_slug <value> <what>
  local v="${1:-}" what="$2"
  [ -n "$v" ] || die_usage "E_USAGE" "--${what} <slug> is required"
  case "$v" in
    _*) die_usage "E_SLUG_RESERVED" \
"'${v}' starts with an underscore. Leading-underscore names are reserved for
       pseudo-directories and are never a company." ;;
  esac
  if ! is_slug "$v"; then
    die_usage "E_SLUG_INVALID" "'${v}' is not a valid slug"
  fi
}

trim() { printf '%s' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

strip_ansi() { sed -E 's/'$'\x1b''\[[0-9;]*[A-Za-z]//g'; }

# A cell that is empty, a `TODO`, a `?`, or an em-dash placeholder carries no
# information. It is UNKNOWN — never "nothing to do".
is_placeholder() { # is_placeholder <text>
  local v
  v="$(lower "$(trim "${1:-}")")"
  case "$v" in
    ""|todo|"tbd"|"?"|"—"|"-"|"n/a"|"na"|"..."|"xxx") return 0 ;;
  esac
  return 1
}

resolve_hq_root() {
  if [ -z "$HQ_ROOT" ]; then
    HQ_ROOT="$(cd -- "${PACK_DIR}/../../.." && pwd -P)"
    [ -d "${HQ_ROOT}/companies" ] || HQ_ROOT="$PWD"
  fi
  [ -d "$HQ_ROOT" ] || die_usage "E_USAGE" "--hq-root does not exist: ${HQ_ROOT}"
  HQ_ROOT="$(cd -- "$HQ_ROOT" && pwd -P)"
  COMPANIES_DIR="${HQ_ROOT}/companies"
}

# ---------------------------------------------------------------------------
# session binding — same contract as new-client.sh / client-pack.sh
# ---------------------------------------------------------------------------

resolve_session_company() {
  local out rc=0
  if [ -n "$SESSION_COMPANY" ]; then printf '%s' "$SESSION_COMPANY"; return 0; fi
  if [ -x "${HQ_ROOT}/core/scripts/hq-session.sh" ]; then
    out="$("${HQ_ROOT}/core/scripts/hq-session.sh" get company_slug 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || out=""
    [ "$out" = "null" ] && out=""
    printf '%s' "$out"
    return 0
  fi
  printf ''
}

require_session_bound_to() { # require_session_bound_to <slug>
  local want="$1" got
  got="$(resolve_session_company)"
  if [ -z "$got" ]; then
    die_op "E_SESSION_UNKNOWN" \
"cannot determine which company this session is bound to, so a handover of
       '${want}' is refused. Unknown is not authorization. Bind the session
       (core/scripts/hq-session.sh set company_slug ${want}) or state it
       explicitly with --session-company ${want}."
  fi
  if [ "$got" != "$want" ]; then
    die_op "E_SESSION_SCOPE" \
"this session is bound to '${got}' but /handover-client operates on client
       company '${want}'. Handover runs in a CLIENT-bound session; the firm side
       arrives as --firm-member / --firm-domain names, never as a path."
  fi
}

# ---------------------------------------------------------------------------
# cloud posture — read from the filesystem, never by calling anything
# ---------------------------------------------------------------------------
CLOUD_MODE=""
CLOUD_REASON=""

resolve_cloud_mode() { # resolve_cloud_mode <company.yaml or ->
  local co_yaml="$1" has_key declared

  if [ "$CLOUD_REQUESTED" = "no" ]; then
    CLOUD_MODE="local"; CLOUD_REASON="--local-only was passed"; return 0
  fi
  if [ "$CLOUD_REQUESTED" = "yes" ]; then
    CLOUD_MODE="cloud"; CLOUD_REASON="--cloud was passed"; return 0
  fi
  if [ -n "$co_yaml" ] && [ "$co_yaml" != "-" ] && [ -f "$co_yaml" ] && command -v yq >/dev/null 2>&1; then
    has_key="$(yq -r 'has("cloud")' "$co_yaml" 2>/dev/null || printf 'false')"
    if [ "$has_key" = "true" ]; then
      declared="$(yq -r '.cloud' "$co_yaml" 2>/dev/null || printf '')"
      if [ "$declared" = "true" ]; then
        CLOUD_MODE="cloud"; CLOUD_REASON="company.yaml declares cloud: true"; return 0
      fi
      CLOUD_MODE="local"; CLOUD_REASON="company.yaml declares cloud: ${declared}"; return 0
    fi
    CLOUD_MODE="local"
    CLOUD_REASON="company.yaml has no 'cloud' key — UNDECLARED, which is unknown, not cloud-backed"
    return 0
  fi
  CLOUD_MODE="local"
  CLOUD_REASON="no company.yaml to read a cloud declaration from — unknown, so cloud steps are skipped"
}

# ---------------------------------------------------------------------------
# the ONE outward seam
# ---------------------------------------------------------------------------
HQ_OUT=""
HQ_RC=0

hq_call() { # hq_call <args...> — records to HQ_OUT/HQ_RC. Status-returning.
  HQ_RC=0
  HQ_OUT="$("$HQ_BIN" "$@" 2>&1)" || HQ_RC=$?
  [ -n "${HQ_CALL_LOG:-}" ] && printf '%s %s\n' "$HQ_BIN" "$*" >> "$HQ_CALL_LOG"
  return "$HQ_RC"
}

# ---------------------------------------------------------------------------
# roster — active memberships, with PRESENCE read separately from value
# ---------------------------------------------------------------------------
# Internal form: one TSV row per member, "email<TAB>role<TAB>status".
# A field the source did not carry is the literal `__absent__`, which is UNKNOWN
# everywhere downstream and never collapses to a value.

ROSTER=""
ROSTER_STATE=""     # known | unknown
ROSTER_REASON=""

parse_roster_json() { # parse_roster_json <file> -> TSV on stdout; non-zero if unusable
  # Shape is validated FIRST and separately, so that a legitimately EMPTY roster
  # (a known, meaningful answer) is never confused with an unreadable one.
  jq -e '
    if type == "array" then true
    elif type == "object" and (has("members")) and ((.members | type) == "array") then true
    else false end
  ' "$1" >/dev/null 2>&1 || return 1
  jq -r '
    def rows:
      if type == "array" then .[]
      else .members[] end;
    rows
    | [ (if has("personEmail") and (.personEmail != null) and (.personEmail != "")
           then (.personEmail | tostring)
         elif has("personUid") and (.personUid != null) and (.personUid != "")
           then (.personUid | tostring)
         else "__absent__" end),
        (if has("role") and (.role != null) then (.role | tostring) else "__absent__" end),
        (if has("status") and (.status != null) then (.status | tostring) else "__absent__" end)
      ] | @tsv
  ' "$1" 2>/dev/null || return 1
  return 0
}

parse_roster_table() { # parse_roster_table <file> -> TSV on stdout; non-zero if unusable
  local body header_seen=0 lineout email role
  body="$(strip_ansi < "$1")"

  # An explicit, recognised "there are none" is KNOWN and empty.
  if printf '%s\n' "$body" | grep -q '^No active members found'; then
    return 0
  fi
  # The pending-invite view answers a different question entirely.
  if printf '%s\n' "$body" | grep -qE '^TARGET[[:space:]]+ROLE[[:space:]]+INVITED_BY'; then
    return 1
  fi
  while IFS= read -r lineout; do
    [ -n "$(trim "$lineout")" ] || continue
    case "$lineout" in
      EMAIL*ROLE*NAME*) header_seen=1; continue ;;
      "Share a secret with a member:"*) continue ;;
    esac
    [ "$header_seen" -eq 1 ] || continue
    email="$(trim "$(printf '%s' "$lineout" | awk -F'  +' '{print $1}')")"
    role="$(trim "$(printf '%s' "$lineout" | awk -F'  +' '{print $2}')")"
    [ -n "$email" ] || continue
    [ -n "$role" ] || role="__absent__"
    # The default `hq members list` view is the ACTIVE roster by construction —
    # that is what the EMAIL/ROLE/NAME header identifies. The pending view is
    # rejected above rather than mistaken for it.
    printf '%s\t%s\t%s\n' "$email" "$role" "active"
  done <<< "$body"
  [ "$header_seen" -eq 1 ] || return 1
  return 0
}

load_roster_from_file() { # load_roster_from_file <path>
  local path="$1" first out rc=0
  if [ ! -f "$path" ]; then
    ROSTER_STATE="unknown"; ROSTER_REASON="no roster file at ${path}"; return 0
  fi
  first="$(trim "$(grep -v '^[[:space:]]*$' "$path" 2>/dev/null | head -1 || true)")"
  case "$first" in
    \[*|\{*)
      if ! command -v jq >/dev/null 2>&1; then
        ROSTER_STATE="unknown"; ROSTER_REASON="roster is JSON but jq is not installed"; return 0
      fi
      out="$(parse_roster_json "$path")" || rc=$?
      if [ "$rc" -ne 0 ]; then
        ROSTER_STATE="unknown"; ROSTER_REASON="roster JSON at ${path} is not a readable member list"; return 0
      fi ;;
    *)
      out="$(parse_roster_table "$path")" || rc=$?
      if [ "$rc" -ne 0 ]; then
        ROSTER_STATE="unknown"
        ROSTER_REASON="roster text at ${path} is not the active-member view (no EMAIL/ROLE/NAME header)"
        return 0
      fi ;;
  esac
  ROSTER="$out"
  ROSTER_STATE="known"
  ROSTER_REASON="read from ${path}"
}

load_roster_from_hq() { # load_roster_from_hq <company>
  local co="$1" tmp rc=0
  if ! command -v "$HQ_BIN" >/dev/null 2>&1 && [ ! -x "$HQ_BIN" ]; then
    ROSTER_STATE="unknown"
    ROSTER_REASON="no roster file was given and '${HQ_BIN}' is not available to read one — unknown, not empty"
    return 0
  fi
  if [ "$CLOUD_MODE" != "cloud" ]; then
    ROSTER_STATE="unknown"
    ROSTER_REASON="this company is not cloud-backed, so there is no membership graph to read"
    return 0
  fi
  hq_call members list --company "$co" || rc=$?
  if [ "$rc" -ne 0 ]; then
    ROSTER_STATE="unknown"
    ROSTER_REASON="'${HQ_BIN} members list --company ${co}' failed (rc=${rc}) — unknown, not empty"
    return 0
  fi
  tmp="$(mktemp -t handover-roster)"
  printf '%s\n' "$HQ_OUT" > "$tmp"
  load_roster_from_file "$tmp"
  rm -f "$tmp"
  [ "$ROSTER_STATE" = "known" ] && ROSTER_REASON="read live via ${HQ_BIN} members list --company ${co}"
  return 0
}

load_roster() { # load_roster <company> <explicit-file-or-empty>
  ROSTER=""; ROSTER_STATE=""; ROSTER_REASON=""
  if [ -n "${2:-}" ]; then
    load_roster_from_file "$2"
  else
    load_roster_from_hq "$1"
  fi
}

# ---------------------------------------------------------------------------
# firm identity — supplied as names, never derived from the firm tree
# ---------------------------------------------------------------------------
FIRM_IDENTITY_STATE=""   # known | unknown

resolve_firm_identity() {
  if [ "${#FIRM_MEMBERS[@]}" -eq 0 ] && [ "${#FIRM_DOMAINS[@]}" -eq 0 ]; then
    FIRM_IDENTITY_STATE="unknown"
  else
    FIRM_IDENTITY_STATE="known"
  fi
}

is_firm_side() { # is_firm_side <email> — status-returning
  local email who dom
  email="$(lower "$1")"
  for who in "${FIRM_MEMBERS[@]:-}"; do
    [ -n "$who" ] || continue
    [ "$(lower "${who%%:*}")" = "$email" ] && return 0
  done
  for dom in "${FIRM_DOMAINS[@]:-}"; do
    [ -n "$dom" ] || continue
    case "$email" in
      *"@$(lower "${dom#@}")") return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# checklist parsing
# ---------------------------------------------------------------------------

checklist_items() { # checklist_items <file> -> "<section-number>\t<0|1>\t<text>"
  awk '
    /^##[[:space:]]+[0-9]+\./ {
      sec = $2; sub(/\..*$/, "", sec); next
    }
    /^-[[:space:]]\[[ xX]\][[:space:]]/ {
      if (sec == "") next
      st = substr($0, 4, 1)
      txt = substr($0, 7)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", txt)
      printf "%s\t%s\t%s\n", sec, (st == " " ? "0" : "1"), txt
    }
  ' "$1"
}

table_rows() { # table_rows <file> <header-substring> -> raw "| a | b |" rows
  awk -v hdr="$2" '
    index($0, hdr) > 0 && substr($0,1,1) == "|" { intab = 1; next }
    intab && /^\|[[:space:]:|-]+\|[[:space:]]*$/ { next }
    intab && substr($0,1,1) == "|" { print; next }
    intab { intab = 0 }
  ' "$1"
}

cell() { # cell <raw-row> <1-based index>
  printf '%s' "$1" | awk -F'|' -v n="$(( $2 + 1 ))" '{ v=$n; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v }'
}

field_after_label() { # field_after_label <file> <label-substring> -> value
  # Handles both `**Label:** value` and `**Label:**` followed by the value on the
  # next non-blank line, because the template uses both shapes.
  awk -v lbl="$2" '
    index($0, lbl) > 0 && !found {
      rest = $0
      sub(/.*\*\*[[:space:]]*/, "", rest)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
      if (rest != "") { print rest; found = 1; exit }
      want = 1; found = 1; next
    }
    want && NF > 0 {
      v = $0
      sub(/^[-*][[:space:]]+/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v; exit
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# the declared end-state: who the firm keeps, and at what role
# ---------------------------------------------------------------------------
# "none"            -> the firm keeps nothing at all
# "a@f.com:admin, b@f.com"  -> exactly those, at exactly those roles ("" = any)
END_STATE_KIND=""    # none | list | unknown
END_STATE_LIST=()
END_STATE_RAW=""

parse_end_state() { # parse_end_state <raw>
  local raw entry
  raw="$(trim "${1:-}")"
  END_STATE_RAW="$raw"
  END_STATE_LIST=()
  if is_placeholder "$raw"; then END_STATE_KIND="unknown"; return 0; fi
  case "$(lower "$raw")" in
    none|"none."|"nothing"|"no residual access"|"no access") END_STATE_KIND="none"; return 0 ;;
  esac
  # A sentence is not a machine-readable end state. Only an explicit list is.
  if ! printf '%s' "$raw" | grep -q '@'; then
    END_STATE_KIND="unknown"; return 0
  fi
  END_STATE_KIND="list"
  while IFS= read -r entry; do
    entry="$(trim "$entry")"
    [ -n "$entry" ] || continue
    END_STATE_LIST+=("$entry")
  done <<< "$(printf '%s' "$raw" | tr ',;' '\n\n')"
  [ "${#END_STATE_LIST[@]}" -gt 0 ] || END_STATE_KIND="unknown"
}

# ---------------------------------------------------------------------------
# VERIFICATION — the checklist, item by item, plus the mechanical cross-checks
# ---------------------------------------------------------------------------

verify_checkboxes() { # every unchecked box blocks, by section
  local rec sec checked text short
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    sec="${rec%%$'\t'*}"
    checked="${rec#*$'\t'}"; checked="${checked%%$'\t'*}"
    text="${rec##*$'\t'}"
    short="$(printf '%s' "$text" | cut -c1-72)"
    if [ "$checked" = "0" ]; then
      finding INCOMPLETE "$sec" "unchecked: ${short}"
    else
      finding DONE "$sec" "checked:   ${short}"
    fi
  done <<< "$(checklist_items "$CHECKLIST")"
}

verify_section1_team() { # client team invited AND active, with an owner/admin
  local row email role status n_client=0 n_client_admin=0

  if [ "$FIRM_IDENTITY_STATE" != "known" ]; then
    finding UNKNOWN 1 "which members are firm-side is UNDECLARED — pass --firm-member <email> and/or --firm-domain <domain>. Without it, 'the client team owns this company' cannot be checked, and a checked box is a claim, not evidence."
    return 0
  fi
  if [ "$ROSTER_STATE" != "known" ]; then
    finding UNKNOWN 1 "the active-member roster could not be read (${ROSTER_REASON}). No roster is not an empty roster."
    return 0
  fi

  while IFS=$'\t' read -r email role status; do
    [ -n "$email" ] || continue
    if [ "$email" = "__absent__" ]; then
      finding UNKNOWN 1 "a membership row carries no identifiable person — cannot classify it as firm-side or client-side"
      continue
    fi
    if [ "$status" = "__absent__" ]; then
      finding UNKNOWN 1 "membership ${email} has no status field — absent is not 'active'"
      continue
    fi
    if [ "$(lower "$status")" != "active" ]; then
      # A pending invite is explicitly not ownership (§1 says so).
      if ! is_firm_side "$email"; then
        finding INCOMPLETE 1 "client-side ${email} is '${status}', not active — a pending invite is not ownership"
      fi
      continue
    fi
    if is_firm_side "$email"; then continue; fi
    n_client=$((n_client + 1))
    if [ "$role" = "__absent__" ]; then
      finding UNKNOWN 1 "client-side ${email} is active but carries no role — absent is not owner"
      continue
    fi
    case "$(lower "$role")" in
      owner|admin) n_client_admin=$((n_client_admin + 1)) ;;
    esac
  done <<< "$ROSTER"

  if [ "$n_client" -eq 0 ]; then
    finding INCOMPLETE 1 "no ACTIVE client-side member on this company — the client cannot own an HQ they are not in"
  else
    finding DONE 1 "${n_client} active client-side member(s) on the roster"
  fi
  if [ "$n_client_admin" -eq 0 ]; then
    finding INCOMPLETE 1 "no active client-side owner/admin — access could not be granted or revoked without the firm"
  else
    finding DONE 1 "${n_client_admin} client-side owner/admin — access is grantable without the firm"
  fi
}

verify_section2_packs() { # every applied pack has an explicit decision, and is in it
  local packs_dir="${CO_DIR}/.hq-packs" applied=() name row pack decision rc
  local status_out state_counts

  if [ -d "$packs_dir" ]; then
    for name in "$packs_dir"/*/; do
      [ -d "$name" ] || continue
      name="$(basename -- "$name")"
      case "$name" in _*|.*) continue ;; esac
      applied+=("$name")
    done
  fi

  # Decisions declared in the checklist table.
  local -a tbl_pack=() tbl_decision=()
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    pack="$(cell "$row" 1)"
    decision="$(cell "$row" 2)"
    [ -n "$pack" ] || continue
    tbl_pack+=("$pack")
    tbl_decision+=("$decision")
  done <<< "$(table_rows "$CHECKLIST" '| Pack | Decision')"

  local i found
  # 1. Every applied pack must appear with a real decision.
  for name in "${applied[@]:-}"; do
    [ -n "$name" ] || continue
    found=""
    i=0
    while [ "$i" -lt "${#tbl_pack[@]}" ]; do
      if [ "$(lower "${tbl_pack[$i]}")" = "$(lower "$name")" ]; then found="${tbl_decision[$i]}"; break; fi
      i=$((i + 1))
    done
    if [ -z "$found" ]; then
      finding UNKNOWN 2 "pack '${name}' is applied in this company but has no row in the checklist's decision table — 'nobody said' is not 'keep'"
      continue
    fi
    if is_placeholder "$found"; then
      finding UNKNOWN 2 "pack '${name}' has no stay/remove decision recorded (cell is '${found:-empty}')"
      continue
    fi
    case "$(lower "$found")" in
      stay|keep|stays|retain) decision="stay" ;;
      remove|removed|delete|deleted) decision="remove" ;;
      *) finding UNKNOWN 2 "pack '${name}' decision '${found}' is neither stay nor remove"; continue ;;
    esac

    rc=0
    status_out="$(bash "${PACK_DIR}/scripts/client-pack.sh" status --client "$CLIENT" --pack "$name" \
      --hq-root "$HQ_ROOT" --session-company "$CLIENT" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$decision" = "remove" ]; then
        finding DONE 2 "pack '${name}': decision=remove and no manifest remains"
      else
        finding UNKNOWN 2 "pack '${name}': decision=stay but client-pack.sh status could not classify it (rc=${rc})"
      fi
      continue
    fi
    state_counts="$(printf '%s\n' "$status_out" | awk '{print $1}' | grep -cE '^(clean|fork|unknown-sha)$' || true)"
    if [ "$decision" = "remove" ]; then
      if [ "${state_counts:-0}" -gt 0 ]; then
        finding INCOMPLETE 2 "pack '${name}': decision=remove but ${state_counts} manifest-owned file(s) are still present — run client-pack.sh remove"
      else
        finding DONE 2 "pack '${name}': decision=remove and no manifest-owned file remains"
      fi
    else
      if printf '%s\n' "$status_out" | awk '{print $1}' | grep -q '^missing$'; then
        finding INCOMPLETE 2 "pack '${name}': decision=stay but manifest-owned file(s) are missing — run client-pack.sh update"
      else
        finding DONE 2 "pack '${name}': decision=stay and every manifest-owned file is present"
      fi
    fi
  done

  # 2. A decision for a pack that is not applied is stale, not harmful — say so.
  i=0
  while [ "$i" -lt "${#tbl_pack[@]}" ]; do
    pack="${tbl_pack[$i]}"
    if is_placeholder "$pack"; then
      finding UNKNOWN 2 "the pack decision table still holds a placeholder row — an unfilled table is not an empty one"
    fi
    i=$((i + 1))
  done

  if [ "${#applied[@]:-0}" -eq 0 ]; then
    finding DONE 2 "no firm pack is applied in this company (no .hq-packs/ entries)"
  fi
}

verify_section3_secrets() { # NAMES and dispositions only — never a value
  local row name disposition rows=0 unresolved=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="$(cell "$row" 1)"
    disposition="$(cell "$row" 3)"
    [ -n "$name" ] || continue
    rows=$((rows + 1))
    if is_placeholder "$name"; then
      finding UNKNOWN 3 "the secret table still holds a placeholder row — unfilled is not 'no secrets'"
      unresolved=$((unresolved + 1))
      continue
    fi
    if [ "$(lower "$name")" = "none" ]; then
      finding DONE 3 "the firm declares it held no secret for this engagement"
      continue
    fi
    if is_placeholder "$disposition"; then
      finding UNKNOWN 3 "secret '${name}' has no rotated/deleted disposition recorded"
      unresolved=$((unresolved + 1))
      continue
    fi
    case "$(lower "$disposition")" in
      *rotat*|*delet*|*remov*|*revok*)
        finding DONE 3 "secret '${name}': ${disposition}" ;;
      *)
        finding UNKNOWN 3 "secret '${name}' disposition '${disposition}' is neither rotated nor deleted"
        unresolved=$((unresolved + 1)) ;;
    esac
  done <<< "$(table_rows "$CHECKLIST" '| Secret name |')"

  if [ "$rows" -eq 0 ]; then
    finding UNKNOWN 3 "the secret table has no rows at all — an absent table is unknown, not 'no secrets'"
  fi
}

verify_section8_signoff() {
  local row who name rows=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    who="$(cell "$row" 1)"
    name="$(cell "$row" 2)"
    case "$(lower "$who")" in
      *sign-off*|*signoff*) ;;
      *) continue ;;
    esac
    rows=$((rows + 1))
    if is_placeholder "$name"; then
      finding INCOMPLETE 8 "${who} has not been recorded"
    else
      finding DONE 8 "${who}: ${name}"
    fi
  done <<< "$(table_rows "$CHECKLIST" '| Firm sign-off |')"
  if [ "$rows" -eq 0 ]; then
    finding UNKNOWN 8 "no sign-off rows could be read from the checklist"
  fi
}

verify_end_state_declared() {
  parse_end_state "$(field_after_label "$CHECKLIST" 'Residual firm access after sign-off')"
  case "$END_STATE_KIND" in
    none) finding DONE 8 "declared end state: the firm retains NO access after sign-off" ;;
    list) finding DONE 8 "declared end state: the firm retains exactly ${#END_STATE_LIST[@]} agreed grant(s) — ${END_STATE_LIST[*]}" ;;
    *)    finding UNKNOWN 8 "the residual-firm-access line is '${END_STATE_RAW:-empty}' — post-transfer access cannot be verified against an end state nobody wrote down" ;;
  esac
}

run_verification() {
  FINDINGS=(); N_DONE=0; N_INCOMPLETE=0; N_UNKNOWN=0
  verify_checkboxes
  verify_section1_team
  verify_section2_packs
  verify_section3_secrets
  verify_section8_signoff
  verify_end_state_declared
}

verification_verdict() { # prints READY | BLOCKED
  if [ "$N_INCOMPLETE" -eq 0 ] && [ "$N_UNKNOWN" -eq 0 ]; then
    printf 'READY'
  else
    printf 'BLOCKED'
  fi
}

# ---------------------------------------------------------------------------
# post-transfer read-back
# ---------------------------------------------------------------------------
# Compare the roster the world ACTUALLY has against the end state the checklist
# declares. This never trusts the exit code of the transfer command.

READBACK_PROBLEMS=()

read_back_access() { # read_back_access <roster-tsv> -> 0 match, 1 mismatch/unknown
  READBACK_PROBLEMS=()
  local rows="$1" email role status want want_email want_role matched i
  local -a seen=()

  if [ "$FIRM_IDENTITY_STATE" != "known" ]; then
    READBACK_PROBLEMS+=("firm identity is UNDECLARED — cannot tell which memberships are the firm's")
    return 1
  fi
  if [ "$END_STATE_KIND" = "unknown" ]; then
    READBACK_PROBLEMS+=("the checklist declares no machine-readable end state, so there is nothing to verify against")
    return 1
  fi

  while IFS=$'\t' read -r email role status; do
    [ -n "$email" ] || continue
    [ "$email" = "__absent__" ] && { READBACK_PROBLEMS+=("a membership row carries no identifiable person"); continue; }
    [ "$status" = "__absent__" ] && { READBACK_PROBLEMS+=("membership ${email} has no status field — absent is not 'inactive'"); continue; }
    [ "$(lower "$status")" = "active" ] || continue
    is_firm_side "$email" || continue

    if [ "$END_STATE_KIND" = "none" ]; then
      READBACK_PROBLEMS+=("firm-side ${email} is STILL an active ${role} — the checklist says the firm retains nothing")
      continue
    fi
    matched=0
    i=0
    while [ "$i" -lt "${#END_STATE_LIST[@]}" ]; do
      want="${END_STATE_LIST[$i]}"
      want_email="$(lower "$(trim "${want%%:*}")")"
      want_role=""
      [ "$want" != "${want##*:}" ] && [ "${want#*:}" != "$want" ] && want_role="$(lower "$(trim "${want#*:}")")"
      if [ "$want_email" = "$(lower "$email")" ]; then
        matched=1
        seen+=("$want_email")
        if [ -n "$want_role" ] && [ "$want_role" != "$(lower "$role")" ]; then
          READBACK_PROBLEMS+=("firm-side ${email} is '${role}' but the checklist agreed '${want_role}'")
        fi
        break
      fi
      i=$((i + 1))
    done
    if [ "$matched" -eq 0 ]; then
      READBACK_PROBLEMS+=("firm-side ${email} is an active ${role} but is NOT in the checklist's agreed residual access")
    fi
  done <<< "$rows"

  # An agreed grant that is not actually present is also a mismatch: the
  # checklist and the world disagree, and this engine does not pick a winner.
  i=0
  while [ "$i" -lt "${#END_STATE_LIST[@]:-0}" ]; do
    want_email="$(lower "$(trim "${END_STATE_LIST[$i]%%:*}")")"
    matched=0
    for want in "${seen[@]:-}"; do
      [ "$want" = "$want_email" ] && matched=1
    done
    [ "$matched" -eq 0 ] && READBACK_PROBLEMS+=("the checklist agrees residual access for ${want_email} but no active membership for them was read back")
    i=$((i + 1))
  done

  [ "${#READBACK_PROBLEMS[@]:-0}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------

[ $# -gt 0 ] || die_usage "E_USAGE" "a verb is required: verify | transfer | verify-access | status"
VERB="$1"; shift
case "$VERB" in
  verify|transfer|verify-access|status) ;;
  -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die_usage "E_USAGE" "unknown verb '${VERB}' — expected verify | transfer | verify-access | status" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --client) CLIENT="${2:-}"; shift 2 ;;
    --checklist) CHECKLIST_OVERRIDE="${2:-}"; shift 2 ;;
    --roster) ROSTER_FILE="${2:-}"; shift 2 ;;
    --roster-after) ROSTER_AFTER_FILE="${2:-}"; shift 2 ;;
    --firm-member) FIRM_MEMBERS+=("${2:-}"); shift 2 ;;
    --firm-domain) FIRM_DOMAINS+=("${2:-}"); shift 2 ;;
    --to) TARGET="${2:-}"; shift 2 ;;
    --approval)
      APPROVAL="${2:-}"; shift 2
      case "$APPROVAL" in
        approved|declined) ;;
        *) die_usage "E_USAGE" "--approval must be 'approved' or 'declined'. Omit it entirely to mean UNDECIDED — which is not approval." ;;
      esac ;;
    --initiator-role)
      INITIATOR_ROLE="${2:-}"; shift 2
      case "$INITIATOR_ROLE" in
        admin|member|guest|remove) ;;
        owner) die_usage "E_USAGE" "--initiator-role cannot be 'owner' — a handover where the firm keeps owner is not a handover" ;;
        *) die_usage "E_USAGE" "--initiator-role must be admin | member | guest | remove" ;;
      esac ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --hq-root) HQ_ROOT="${2:-}"; shift 2 ;;
    --hq-bin) HQ_BIN="${2:-}"; shift 2 ;;
    --pack-dir) PACK_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --session-company) SESSION_COMPANY="${2:-}"; shift 2 ;;
    --cloud) CLOUD_REQUESTED="yes"; shift ;;
    --local-only) CLOUD_REQUESTED="no"; shift ;;
    --no-read-back) READ_BACK=0; shift ;;
    --strict) STRICT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die_usage "E_USAGE" "unknown argument: $1" ;;
  esac
done

resolve_hq_root
if [ -n "$PACK_DIR_OVERRIDE" ]; then
  [ -d "$PACK_DIR_OVERRIDE" ] || die_usage "E_USAGE" "--pack-dir does not exist: ${PACK_DIR_OVERRIDE}"
  PACK_DIR="$(cd -- "$PACK_DIR_OVERRIDE" && pwd -P)"
fi

require_slug "$CLIENT" "client"
CO_DIR="${COMPANIES_DIR}/${CLIENT}"
[ -d "$CO_DIR" ] || die_op "E_CLIENT_NOT_FOUND" "no company at ${CO_DIR}"

require_session_bound_to "$CLIENT"

CHECKLIST="${CHECKLIST_OVERRIDE:-${CO_DIR}/handover-checklist.md}"
[ -f "$CHECKLIST" ] || die_op "E_NO_CHECKLIST" \
"no handover checklist at ${CHECKLIST}.
       /handover-client walks the checklist /new-client stages; without it there
       is no declared end state, and an undeclared end state is UNKNOWN — which
       never authorizes an irreversible ownership transfer."

resolve_cloud_mode "$( [ -f "${CO_DIR}/company.yaml" ] && printf '%s' "${CO_DIR}/company.yaml" || printf '-' )"
resolve_firm_identity

# ===========================================================================
# VERB: status — read-only posture, no verdict
# ===========================================================================
if [ "$VERB" = "status" ]; then
  load_roster "$CLIENT" "$ROSTER_FILE"
  parse_end_state "$(field_after_label "$CHECKLIST" 'Residual firm access after sign-off')"
  say "handover-client status — client ${CLIENT}"
  line "checklist:" "$CHECKLIST"
  line "cloud posture:" "${CLOUD_MODE} (${CLOUD_REASON})"
  line "firm identity:" "$( [ "$FIRM_IDENTITY_STATE" = "known" ] \
    && printf '%s member(s), %s domain(s)' "${#FIRM_MEMBERS[@]}" "${#FIRM_DOMAINS[@]}" \
    || printf 'UNDECLARED — pass --firm-member / --firm-domain' )"
  line "roster:" "${ROSTER_STATE} (${ROSTER_REASON})"
  line "declared end state:" "${END_STATE_KIND}${END_STATE_RAW:+ — ${END_STATE_RAW}}"
  line "checklist boxes:" "$(checklist_items "$CHECKLIST" | awk -F'\t' '{ t++; if ($2=="1") c++ } END { printf "%d of %d checked", c+0, t+0 }')"
  exit 0
fi

# ===========================================================================
# VERB: verify — walk the checklist, report, never write
# ===========================================================================
if [ "$VERB" = "verify" ]; then
  load_roster "$CLIENT" "$ROSTER_FILE"
  run_verification
  VERDICT="$(verification_verdict)"

  say "handover-client verify — client ${CLIENT}"
  line "checklist:" "$CHECKLIST"
  line "cloud posture:" "${CLOUD_MODE} (${CLOUD_REASON})"
  line "roster:" "${ROSTER_STATE} (${ROSTER_REASON})"
  say ""
  print_findings
  say ""
  say "SUMMARY  ${N_DONE} done, ${N_INCOMPLETE} incomplete, ${N_UNKNOWN} unknown"
  if [ "$VERDICT" = "READY" ]; then
    say "VERDICT  READY — every checklist item is verified done."
  else
    say "VERDICT  BLOCKED — handover is not offered."
    say "         An UNKNOWN item is not a formality to clear later. It is the"
    say "         reason this handover is not done: an unverifiable claim cannot"
    say "         authorize an irreversible transfer of ownership."
  fi
  if [ "$CLOUD_MODE" != "cloud" ]; then
    say ""
    say "NOTE   ownership transfer requires a cloud-backed company. ${CLOUD_REASON}."
    say "       The checklist walk above still applies; only the transfer step is"
    say "       unavailable here. Run /designate-team ${CLIENT} to make it cloud-backed."
  fi
  if [ "$VERDICT" = "BLOCKED" ] && [ "$STRICT" -eq 1 ]; then exit 1; fi
  exit 0
fi

# ===========================================================================
# VERB: verify-access — post-transfer read-back, on its own
# ===========================================================================
if [ "$VERB" = "verify-access" ]; then
  parse_end_state "$(field_after_label "$CHECKLIST" 'Residual firm access after sign-off')"
  load_roster "$CLIENT" "${ROSTER_AFTER_FILE:-$ROSTER_FILE}"

  say "handover-client verify-access — client ${CLIENT}"
  line "declared end state:" "${END_STATE_KIND}${END_STATE_RAW:+ — ${END_STATE_RAW}}"
  line "roster:" "${ROSTER_STATE} (${ROSTER_REASON})"

  if [ "$ROSTER_STATE" != "known" ]; then
    say ""
    say "MISMATCH  the post-transfer roster could not be read, so firm access is"
    say "          UNVERIFIED. Not-read is not not-present."
    exit 1
  fi
  RB_RC=0
  read_back_access "$ROSTER" || RB_RC=$?
  if [ "$RB_RC" -eq 0 ]; then
    say ""
    say "OK     firm access matches the checklist's declared end state (read back from the live roster, not assumed)"
    exit 0
  fi
  say ""
  say "MISMATCH  firm access does NOT match the checklist's declared end state:"
  for p in "${READBACK_PROBLEMS[@]:-}"; do
    [ -n "$p" ] || continue
    say "          - ${p}"
  done
  exit 1
fi

# ===========================================================================
# VERB: transfer — verify, gate, execute, read back
# ===========================================================================

load_roster "$CLIENT" "$ROSTER_FILE"
run_verification
VERDICT="$(verification_verdict)"

say "handover-client transfer — client ${CLIENT}"
line "checklist:" "$CHECKLIST"
line "cloud posture:" "${CLOUD_MODE} (${CLOUD_REASON})"
line "roster:" "${ROSTER_STATE} (${ROSTER_REASON})"
say ""
print_findings
say ""
say "SUMMARY  ${N_DONE} done, ${N_INCOMPLETE} incomplete, ${N_UNKNOWN} unknown"

if [ "$VERDICT" != "READY" ]; then
  say "VERDICT  BLOCKED"
  die_op "E_CHECKLIST_BLOCKED" \
"the handover checklist is not satisfied: ${N_INCOMPLETE} incomplete, ${N_UNKNOWN} unknown.
       No transfer was offered and nothing was changed. Resolve every item above
       — including the UNKNOWN ones, which block exactly as hard as the
       unchecked ones — then re-run."
fi
say "VERDICT  READY"

# Local-only is a clear answer, not a failure.
if [ "$CLOUD_MODE" != "cloud" ]; then
  say ""
  say "NOTE   ownership transfer requires a cloud-backed company."
  say "       ${CLOUD_REASON}."
  say "       A local-only HQ company has no membership graph to move: there is"
  say "       no owner row, no vault custody and no billing authority to hand"
  say "       over. The checklist above is satisfied and NOTHING was changed."
  say "NEXT   run /designate-team ${CLIENT} to make this company cloud-backed,"
  say "       then re-run /handover-client."
  exit 0
fi

[ -n "$TARGET" ] || die_usage "E_USAGE" "--to <email|prs_uid> is required for transfer — the person who becomes owner"

# --- the approval gate ------------------------------------------------------
say ""
say "APPROVAL GATE — ownership transfer of ${CLIENT}"
say "  Becomes owner:  ${TARGET}"
say "  The firm will:  $( [ -z "$INITIATOR_ROLE" ] \
  && printf 'stay on the company as admin (the server default — NOT removed)' \
  || { [ "$INITIATOR_ROLE" = "remove" ] && printf 'be REMOVED from the company entirely' || printf 'be downgraded to %s' "$INITIATOR_ROLE"; } )"
say "  Declared end state after sign-off: ${END_STATE_RAW}"
say ""
say "  This nominates ${TARGET} as owner. Ownership moves when THEY accept, and"
say "  when it does, the owner role, billing authority and vault custody all move"
say "  with it. From the firm's side that is IRREVERSIBLE: the firm cannot undo"
say "  it unilaterally — only the new owner can transfer the company back."

case "$APPROVAL" in
  approved) ;;
  declined)
    say ""
    say "DECLINED  the approval gate was declined. NOTHING was changed:"
    say "          no nomination was created, no role was altered, no access was"
    say "          removed. Re-run with an approval when the firm is ready."
    exit 0 ;;
  *)
    say ""
    say "UNDECIDED no approval was recorded. Absent is not approval, so nothing"
    say "          was changed. Pass --approval approved only after an explicit"
    say "          in-session human yes (policy"
    say "          client-service-approval-gate-external-actions)."
    exit 0 ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "PLAN   --dry-run: the approved transfer was NOT executed. It would run:"
  say "         ${HQ_BIN} company transfer initiate --company ${CLIENT} --to ${TARGET}${INITIATOR_ROLE:+ --initiator-role ${INITIATOR_ROLE}}${REASON:+ --reason '${REASON}'} --yes"
  exit 0
fi

# --- execute ----------------------------------------------------------------
say ""
say "EXEC   ${HQ_BIN} company transfer initiate --company ${CLIENT} --to ${TARGET}"
TRANSFER_ARGS=(company transfer initiate --company "$CLIENT" --to "$TARGET")
[ -n "$INITIATOR_ROLE" ] && TRANSFER_ARGS+=(--initiator-role "$INITIATOR_ROLE")
[ -n "$REASON" ] && TRANSFER_ARGS+=(--reason "$REASON")
# --yes is correct here and only here: the explicit in-session human approval
# already happened at the gate above, and this engine is not a TTY.
TRANSFER_ARGS+=(--yes)

TR_RC=0
hq_call "${TRANSFER_ARGS[@]}" || TR_RC=$?
printf '%s\n' "$HQ_OUT" | sed 's/^/       /'
if [ "$TR_RC" -ne 0 ]; then
  die_op "E_TRANSFER_FAILED" \
"the ownership transfer command exited ${TR_RC}. Treat the state as UNKNOWN, not
       as unchanged: run '${HQ_BIN} company transfer status --company ${CLIENT}'
       before retrying."
fi
say "OK     nomination submitted at $(now_iso). Ownership moves when ${TARGET} accepts."

# --- read the result back ---------------------------------------------------
if [ "$READ_BACK" -eq 0 ]; then
  say "NOTE   --no-read-back: firm access was NOT verified. That leaves the end"
  say "       state UNKNOWN. Run 'handover-client.sh verify-access --client ${CLIENT}'."
  exit 0
fi

say ""
say "READ-BACK  re-reading memberships — the transfer's exit code is not evidence"
ROSTER=""; ROSTER_STATE=""; ROSTER_REASON=""
load_roster "$CLIENT" "$ROSTER_AFTER_FILE"
line "roster:" "${ROSTER_STATE} (${ROSTER_REASON})"
if [ "$ROSTER_STATE" != "known" ]; then
  die_op "E_READBACK_UNKNOWN" \
"the post-transfer roster could not be read, so firm access is UNVERIFIED.
       The nomination WAS submitted. Verify by hand with
       '${HQ_BIN} members list --company ${CLIENT}'."
fi
RB_RC=0
read_back_access "$ROSTER" || RB_RC=$?
if [ "$RB_RC" -eq 0 ]; then
  say "OK     firm access matches the checklist's declared end state"
  exit 0
fi
say "MISMATCH  firm access does NOT match the checklist's declared end state:"
for p in "${READBACK_PROBLEMS[@]:-}"; do
  [ -n "$p" ] || continue
  say "          - ${p}"
done
die_op "E_ACCESS_MISMATCH" \
"post-transfer firm access does not match what the checklist says the client
       approved. The nomination was submitted; the access reduction is NOT done.
       Fix the grants above, then re-run 'handover-client.sh verify-access'."
