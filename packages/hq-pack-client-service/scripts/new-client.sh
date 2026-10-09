#!/usr/bin/env bash
# new-client.sh — the deterministic engine behind the /new-client skill.
#
#   new-client.sh engagement  --firm <slug> --client <slug> [--client-name <str>]
#                             [--firm-name <str>] [--cloud|--local-only]
#                             [--hq-root <path>] [--session-company <slug>]
#                             [--dry-run] [--quiet]
#
#   new-client.sh client-home --client <slug> [--handoff <path>] [--client-name <str>]
#                             [--firm-name <str>] [--cloud|--local-only]
#                             [--invites approved|declined] [--invite <email>[:<role>]]...
#                             [--company-scaffold auto|require] [--no-manifest]
#                             [--hq-root <path>] [--session-company <slug>]
#                             [--dry-run] [--quiet]
#
#   new-client.sh status      --firm <slug> [--client <slug>] [--hq-root <path>]
#
# Exit codes
#   0  the phase completed (or --dry-run planned it)
#   1  the phase was REFUSED or failed — nothing destructive was done
#   2  usage / environment problem
#
# ---------------------------------------------------------------------------
# Design notes — read before changing anything
# ---------------------------------------------------------------------------
#
# 1. TWO PHASES, TWO SESSIONS, NEVER ONE.
#    A session may be bound to exactly one company (mandatory-scope-authorizer),
#    and this flow spans two: the FIRM and the CLIENT. So it is split exactly the
#    way /client-pack (US-006) is split:
#
#      engagement   runs in a FIRM-bound session.   Writes companies/{firm}/ only.
#      client-home  runs in a CLIENT-bound session. Writes companies/{client}/ only.
#
#    The two phases hand off through a company-neutral record under workspace/.
#    That record carries the firm's SLUG as provenance metadata — a name, not a
#    path. `client-home` never dereferences it and never reads the firm tree.
#
# 2. NO EXTERNAL CALL, EVER.
#    This engine touches the local filesystem and nothing else. It sends no
#    invite, runs no /newcompany, runs no /designate-team, calls no CRM, no
#    portal, no vault, no network. Outward-facing work is emitted as an explicit
#    plan for a human to approve and run. `command -v hq` is used to detect
#    whether a cloud identity could exist; `hq` itself is never executed.
#
# 3. THE INVITE GATE IS REAL.
#    Inviting a person is outward-facing. Invites are emitted ONLY when
#    `--invites approved` is passed, which the skill passes ONLY after an explicit
#    in-session human approval. `--invites declined` skips invites and completes
#    everything else. Absent is neither: it is UNDECIDED, which resolves to "do
#    not emit" and is reported as an open question, never as approval.
#    (Policy client-service-approval-gate-external-actions.)
#
# 4. ABSENT IS UNKNOWN (policy hq-absent-field-never-means-constraining-value).
#    Presence and value are read separately, everywhere. An absent `cloud:` key in
#    a company.yaml is not `cloud: false`; an absent slot is not an empty slot; an
#    absent invite decision is not approval; an absent handoff record is not
#    "there was no firm". Every unknown resolves toward doing less, and says so.
#
# 5. SLOT STATE IS RESOLVED IN ONE PLACE.
#    ../workers/client-services/scripts/slot-state.sh (US-004) is THE tri-state
#    resolver. This script shells out to it and parses `state=`. There is no
#    second implementation of bound/empty/undeclared in this file, on purpose.
#
# 6. UNDERSCORE PSEUDO-DIRS (policy hq-auto-select-skips-underscore-pseudo-dirs).
#    clients/ contains `_templates/`. Every listing and every auto-selection goes
#    through list_selectable_dirs(), which drops `_`-prefixed entries by a general
#    rule — never a named special case for the directory that exists today. A
#    client slug may not begin with `_` for the same reason.
#
# 7. SET -E STATUS RETURNS (policy hq-bash-set-e-status-returns).
#    Functions that return non-zero as a status signal are called inside an
#    `if`/`&&` condition or with the `|| rc=$?` capture idiom, never bare.
#
# 8. SECRET HYGIENE. Secret NAMES may be referenced; a secret VALUE never enters
#    this script, its output, or anything it writes.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
SLOT_STATE="${PACK_DIR}/workers/client-services/scripts/slot-state.sh"
LAYOUT="${PACK_DIR}/workers/client-services/scripts/engagement-layout.sh"
CHECKLIST_TEMPLATE="${PACK_DIR}/templates/handover-checklist.md"

# Slots whose bindings this flow can act on at client creation. billing,
# agreements and transcripts have nothing to write until there is an agreement or
# a call, so they are deliberately not touched here.
CREATION_SLOTS='crm
portal'

VERB=""
PACK_DIR_OVERRIDE=""
HQ_ROOT="${HQ_ROOT:-}"
SESSION_COMPANY="${HQ_CLIENT_SERVICE_SESSION_COMPANY:-}"
FIRM=""
CLIENT=""
CLIENT_NAME=""
FIRM_NAME=""
HANDOFF=""
CLOUD_REQUESTED=""      # "" = auto-detect | yes | no   (tri-state, absent = auto)
INVITES=""              # "" = undecided | approved | declined
INVITEES=()
COMPANY_SCAFFOLD="auto" # auto | require
WRITE_MANIFEST=1
DRY_RUN=0
QUIET=0

CHANGES=0
NOTES=()

# ---------------------------------------------------------------------------
# output / errors
# ---------------------------------------------------------------------------
say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
line() { [ "$QUIET" -eq 1 ] || printf '  %-24s %s\n' "$1" "$2"; }
note() { NOTES+=("$1"); }

die_usage() { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 2; }
die_op()    { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
today()   { date -u +%Y-%m-%d; }

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
       pseudo-directories (clients/_templates/ is one) and are never a company or
       a client engagement." ;;
  esac
  if ! is_slug "$v"; then
    die_usage "E_SLUG_INVALID" "'${v}' is not a valid slug — lowercase letters, digits and hyphens, starting with a letter or digit"
  fi
}

# Policy hq-auto-select-skips-underscore-pseudo-dirs: ONE general leading-
# underscore rule, used by every listing and every auto-selection in this file.
list_selectable_dirs() { # list_selectable_dirs <parent> -> names, one per line
  local parent="$1" entry name
  [ -d "$parent" ] || return 0
  for entry in "$parent"/*/; do
    [ -d "$entry" ] || continue
    name="$(basename -- "$entry")"
    case "$name" in
      _*|.*) continue ;;
    esac
    printf '%s\n' "$name"
  done
}

# Substitute the template placeholders without sed escaping hazards: display
# names are free text and may contain /, &, backslashes.
render() { # render <text> <key=value>...
  local text="$1"; shift
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    text="${text//\{\{${key}\}\}/${value}}"
  done
  printf '%s' "$text"
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
# session binding — same contract as client-pack.sh (US-006)
# ---------------------------------------------------------------------------

resolve_session_company() { # prints the bound company slug, or empty
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

require_session_bound_to() { # require_session_bound_to <slug> <what>
  local want="$1" what="$2" got
  got="$(resolve_session_company)"
  if [ -z "$got" ]; then
    die_op "E_SESSION_UNKNOWN" \
"cannot determine which company this session is bound to, so writes into ${what}
       '${want}' are refused. Unknown is not authorization. Bind the session
       (core/scripts/hq-session.sh set company_slug ${want}) or state it
       explicitly with --session-company ${want} when running outside a session."
  fi
  if [ "$got" != "$want" ]; then
    die_op "E_SESSION_SCOPE" \
"this session is bound to '${got}' but this phase writes into ${what} '${want}'.
       /new-client is two phases in two sessions: 'engagement' in a FIRM-bound
       session, 'client-home' in a CLIENT-bound session."
  fi
}

# ---------------------------------------------------------------------------
# cloud posture — detected from the filesystem, never by calling anything
# ---------------------------------------------------------------------------

CLOUD_MODE=""     # cloud | local
CLOUD_REASON=""

resolve_cloud_mode() { # resolve_cloud_mode <company.yaml path or ->
  local co_yaml="$1" declared="" has_key=""

  if [ "$CLOUD_REQUESTED" = "no" ]; then
    CLOUD_MODE="local"; CLOUD_REASON="--local-only was passed"; return 0
  fi

  if ! command -v hq >/dev/null 2>&1; then
    CLOUD_MODE="local"
    CLOUD_REASON="no 'hq' CLI on PATH, so there is no cloud identity to act with"
    if [ "$CLOUD_REQUESTED" = "yes" ]; then
      CLOUD_REASON="--cloud was requested but there is no 'hq' CLI on PATH — cloud steps cannot run here"
    fi
    return 0
  fi

  if [ "$CLOUD_REQUESTED" = "yes" ]; then
    CLOUD_MODE="cloud"; CLOUD_REASON="--cloud was passed and an hq CLI is present"; return 0
  fi

  # Auto: only a POSITIVE cloud declaration counts. Presence of the key and its
  # value are read separately — an absent `cloud:` key is UNKNOWN, and unknown
  # never authorizes a cloud step.
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
    CLOUD_REASON="company.yaml has no 'cloud' key — UNDECLARED, which is unknown, not cloud-backed; pass --cloud to override"
    return 0
  fi

  CLOUD_MODE="local"
  CLOUD_REASON="no company.yaml to read a cloud declaration from — unknown, so cloud steps are skipped"
}

# ---------------------------------------------------------------------------
# slot state — delegated to the ONE resolver (US-004)
# ---------------------------------------------------------------------------

slot_state_of() { # slot_state_of <config> <slot> -> bound|empty|undeclared|unreadable
  local config="$1" slot="$2" out rc=0
  [ -f "$SLOT_STATE" ] || { printf 'unreadable'; return 0; }
  out="$(bash "$SLOT_STATE" --config "$config" --slot "$slot" --format kv 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then printf 'unreadable'; return 0; fi
  printf '%s' "$out" | sed -n 's/^slot='"${slot}"' state=\([a-z]*\).*$/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# per-slot join key — delegated to the ONE layout resolver (US-002/D1)
# ---------------------------------------------------------------------------

join_key_of() { # join_key_of <config> <engagement> <slot> -> "<state>\t<value>\t<source>"
  # Never derives a key locally. An unreadable resolver yields `unreadable`,
  # which the caller renders as "resolve it by hand" — never as a value.
  local config="$1" engagement="$2" slot="$3" out rc=0 line
  [ -f "$LAYOUT" ] || { printf 'unreadable\t\t'; return 0; }
  out="$(bash "$LAYOUT" --config "$config" --engagement "$engagement" \
           --slot "$slot" --format kv 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then printf 'unreadable\t\t'; return 0; fi
  line="$(printf '%s' "$out" | sed -n "s/^dedupe_key_for=${slot} //p" | head -1)"
  [ -n "$line" ] || { printf 'unreadable\t\t'; return 0; }
  printf '%s\t%s\t%s' \
    "$(printf '%s' "$line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')" \
    "$(printf '%s' "$line" | sed -n 's/^value=\([^ ]*\).*/\1/p')" \
    "$(printf '%s' "$line" | sed -n 's/.*source=\([a-z-]*\).*/\1/p')"
}

# Renders the join-key bullet for a pending adapter record.
join_key_line() { # join_key_line <config> <engagement> <slot>
  local state value source
  IFS=$'\t' read -r state value source <<<"$(join_key_of "$1" "$2" "$3")"
  case "$state" in
    resolved)
      printf -- '- **Join key for this slot:** `%s` (resolved at `source=%s`)' \
        "$value" "$source" ;;
    declared-none)
      printf -- '- **Join key for this slot: UNRESOLVED** — the config declares no join value for `%s` (`source=%s`, `state=declared-none`). Report it and make **no write**: an unresolved key is not a licence to guess one.' \
        "$3" "$source" ;;
    *)
      printf -- '- **Join key for this slot: could not be resolved here.** Resolve it at call time with `engagement-layout.sh --engagement %s --slot %s` before any write.' \
        "$2" "$3" ;;
  esac
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------

[ $# -gt 0 ] || die_usage "E_USAGE" "a verb is required: engagement | client-home | status"
VERB="$1"; shift
case "$VERB" in
  engagement|client-home|status) ;;
  -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die_usage "E_USAGE" "unknown verb '${VERB}' — expected engagement | client-home | status" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --firm) FIRM="${2:-}"; shift 2 ;;
    --client) CLIENT="${2:-}"; shift 2 ;;
    --client-name) CLIENT_NAME="${2:-}"; shift 2 ;;
    --firm-name) FIRM_NAME="${2:-}"; shift 2 ;;
    --handoff) HANDOFF="${2:-}"; shift 2 ;;
    --hq-root) HQ_ROOT="${2:-}"; shift 2 ;;
    # Only needed when this engine runs from a COPY of itself outside its pack —
    # the verification suite does exactly that to build deliberately broken
    # builds. Normal runs resolve the pack from the script's own location.
    --pack-dir) PACK_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --session-company) SESSION_COMPANY="${2:-}"; shift 2 ;;
    --cloud) CLOUD_REQUESTED="yes"; shift ;;
    --local-only) CLOUD_REQUESTED="no"; shift ;;
    --invites)
      INVITES="${2:-}"; shift 2
      case "$INVITES" in
        approved|declined) ;;
        *) die_usage "E_USAGE" "--invites must be 'approved' or 'declined'. Omit it entirely to mean UNDECIDED — which is not approval." ;;
      esac ;;
    --invite) INVITEES+=("${2:-}"); shift 2 ;;
    --company-scaffold)
      COMPANY_SCAFFOLD="${2:-}"; shift 2
      case "$COMPANY_SCAFFOLD" in
        auto|require) ;;
        *) die_usage "E_USAGE" "--company-scaffold must be auto or require" ;;
      esac ;;
    --no-manifest) WRITE_MANIFEST=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die_usage "E_USAGE" "unknown argument: $1" ;;
  esac
done

resolve_hq_root
if [ -n "$PACK_DIR_OVERRIDE" ]; then
  [ -d "$PACK_DIR_OVERRIDE" ] || die_usage "E_USAGE" "--pack-dir does not exist: ${PACK_DIR_OVERRIDE}"
  PACK_DIR="$(cd -- "$PACK_DIR_OVERRIDE" && pwd -P)"
  SLOT_STATE="${PACK_DIR}/workers/client-services/scripts/slot-state.sh"
LAYOUT="${PACK_DIR}/workers/client-services/scripts/engagement-layout.sh"
  CHECKLIST_TEMPLATE="${PACK_DIR}/templates/handover-checklist.md"
fi
command -v yq >/dev/null 2>&1 || die_usage "E_ENV_YQ_MISSING" "yq (mikefarah v4) is required"

HANDOFF_DIR="${HQ_ROOT}/workspace/client-service/new-client"

# ===========================================================================
# VERB: status — read-only
# ===========================================================================
if [ "$VERB" = "status" ]; then
  require_slug "$FIRM" "firm"
  FIRM_DIR="${COMPANIES_DIR}/${FIRM}"
  [ -d "$FIRM_DIR" ] || die_op "E_FIRM_NOT_FOUND" "no company at ${FIRM_DIR}"
  CLIENTS_DIR="${FIRM_DIR}/clients"
  CONFIG="${FIRM_DIR}/client-service.yaml"

  say "new-client status — firm ${FIRM}"
  line "clients dir:" "${CLIENTS_DIR}$( [ -d "$CLIENTS_DIR" ] || printf ' (absent — run /onboard-firm)')"

  SELECTABLE=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    SELECTABLE+=("$name")
  done <<< "$(list_selectable_dirs "$CLIENTS_DIR")"

  if [ "${#SELECTABLE[@]}" -eq 0 ]; then
    line "engagements:" "none (leading-underscore pseudo-dirs such as _templates are never listed or selected)"
  else
    line "engagements:" "${SELECTABLE[*]}"
  fi

  if [ -z "$CLIENT" ]; then
    if [ "${#SELECTABLE[@]}" -eq 1 ]; then
      CLIENT="${SELECTABLE[0]}"
      line "auto-selected:" "${CLIENT} (the only selectable engagement)"
    elif [ "${#SELECTABLE[@]}" -eq 0 ]; then
      line "auto-select:" "refused — no selectable engagement exists"
    else
      line "auto-select:" "refused — ${#SELECTABLE[@]} engagements, ambiguity is an error not a guess"
    fi
  fi

  if [ -n "$CLIENT" ]; then
    line "engagement.md:" "$( [ -f "${CLIENTS_DIR}/${CLIENT}/engagement.md" ] && printf 'present' || printf 'ABSENT' )"
    line "adapter entries:" "$( ls -1 "${CLIENTS_DIR}/${CLIENT}/adapters" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true )"
  fi

  say "  slots (via the one resolver, workers/client-services/scripts/slot-state.sh):"
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    line "  ${slot}" "$(slot_state_of "$CONFIG" "$slot")"
  done <<< "$CREATION_SLOTS"
  exit 0
fi

# ===========================================================================
# VERB: engagement — FIRM-bound phase
# ===========================================================================
if [ "$VERB" = "engagement" ]; then
  require_slug "$FIRM" "firm"
  require_slug "$CLIENT" "client"

  FIRM_DIR="${COMPANIES_DIR}/${FIRM}"
  [ -d "$FIRM_DIR" ] || die_op "E_FIRM_NOT_FOUND" \
    "no company at ${FIRM_DIR} — /new-client attaches an engagement to an EXISTING firm and never creates one"

  require_session_bound_to "$FIRM" "firm company"

  CONFIG="${FIRM_DIR}/client-service.yaml"
  CLIENTS_DIR="${FIRM_DIR}/clients"
  TEMPLATE="${CLIENTS_DIR}/_templates/engagement.template.md"
  ENGAGEMENT_DIR="${CLIENTS_DIR}/${CLIENT}"
  ENGAGEMENT="${ENGAGEMENT_DIR}/engagement.md"

  [ -f "$TEMPLATE" ] || die_op "E_NO_ENGAGEMENT_TEMPLATE" \
"no engagement template at ${TEMPLATE}.
       The firm has not been onboarded (or the template was removed). Run
       /onboard-firm for ${FIRM} first — this phase instantiates the FIRM's
       template and never invents one."

  # --- collision: abort, and change NOTHING -------------------------------
  # Checked before any write. An existing engagement is a human's file and a
  # human's history; overwriting it is the one failure this guard exists for.
  if [ -e "$ENGAGEMENT_DIR" ] || [ -L "$ENGAGEMENT_DIR" ]; then
    die_op "E_SLUG_COLLISION" \
"companies/${FIRM}/clients/${CLIENT} already exists — refusing to touch it.
       An existing engagement is never overwritten, merged into, or reset by
       /new-client. Nothing was written by this run.
       Existing engagement record: ${ENGAGEMENT}
       If this is the same client, open that file and continue there.
       If it is a different client with a colliding name, pick a distinct slug
       (e.g. ${CLIENT}-2 or a qualified form such as ${CLIENT}-eu)."
  fi

  [ -n "$CLIENT_NAME" ] || CLIENT_NAME="$CLIENT"
  if [ -z "$FIRM_NAME" ]; then
    FIRM_NAME="$(yq -r '.name // ""' "${FIRM_DIR}/company.yaml" 2>/dev/null || printf '')"
    [ -n "$FIRM_NAME" ] && [ "$FIRM_NAME" != "null" ] || FIRM_NAME="$FIRM"
  fi

  resolve_cloud_mode "${FIRM_DIR}/company.yaml"

  # --- slot plan (read-only; the ONE resolver decides) ---------------------
  PLAN_SLOTS=()
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    PLAN_SLOTS+=("${slot}=$(slot_state_of "$CONFIG" "$slot")")
  done <<< "$CREATION_SLOTS"

  say "new-client engagement — firm ${FIRM}, client ${CLIENT}"
  line "engagement:" "$ENGAGEMENT"
  line "from template:" "$TEMPLATE"
  line "cloud posture:" "${CLOUD_MODE} (${CLOUD_REASON})"
  for entry in "${PLAN_SLOTS[@]}"; do
    slot="${entry%%=*}"; state="${entry#*=}"
    case "$state" in
      bound) line "slot ${slot}:" "bound — a pending mirror entry will be written" ;;
      empty) line "slot ${slot}:" "empty — the firm declared it runs no ${slot} tool; NO adapter entry is written" ;;
      undeclared) line "slot ${slot}:" "undeclared — unknown, not empty; NO adapter entry is written. Run /onboard-firm to answer it" ;;
      *) line "slot ${slot}:" "unreadable — treated as undeclared; NO adapter entry is written" ;;
    esac
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  --dry-run: nothing written"
    exit 0
  fi

  mkdir -p "$ENGAGEMENT_DIR"
  CHANGES=$((CHANGES + 1))

  TEMPLATE_BODY="$(cat "$TEMPLATE")"
  render "$TEMPLATE_BODY" \
    "CLIENT_NAME=${CLIENT_NAME}" \
    "FIRM_NAME=${FIRM_NAME}" \
    "CLIENT_SLUG=${CLIENT}" \
    "FIRM_SLUG=${FIRM}" \
    "TODAY=$(today)" > "$ENGAGEMENT"
  CHANGES=$((CHANGES + 1))
  line "created" "$ENGAGEMENT"

  # --- adapter entries: bound slots ONLY ----------------------------------
  # A pending mirror record is a LOCAL note describing the call a human will
  # approve later. Nothing is sent from here. An empty or undeclared slot
  # produces no file at all — not an empty file, not a placeholder.
  for entry in "${PLAN_SLOTS[@]}"; do
    slot="${entry%%=*}"; state="${entry#*=}"
    [ "$state" = "bound" ] || continue
    mkdir -p "${ENGAGEMENT_DIR}/adapters"
    tool="$(yq -r ".slots.\"${slot}\".binding.tool_name // \"\"" "$CONFIG" 2>/dev/null || printf '')"
    [ -n "$tool" ] && [ "$tool" != "null" ] || tool="(pointer binding — see client-service.yaml)"
    case "$slot" in
      crm)
        cat > "${ENGAGEMENT_DIR}/adapters/crm.md" <<CRM
# CRM mirror — pending

The firm's \`crm\` slot is **bound** (\`tool_name: ${tool}\`), so this engagement
has a mirror to keep. The CRM is a **derived mirror, never the source of truth**:
\`../engagement.md\` owns every engagement fact, including stage.

- **Dedupe key:** resolve it at call time, **for this slot**, with
  \`workers/client-services/scripts/engagement-layout.sh --firm ${FIRM} --engagement ${CLIENT} --slot crm\`.
  It is local and pure — no tool call resolves it — but it is resolved per
  (engagement, slot), because a firm's slots may join on different shapes of
  value. Do not reuse another slot's key here: a mismatched join value makes
  search-then-create fall through to create, which duplicates the record.
  If it resolves to \`state: declared-none\`, the key is **unresolved** — report
  that and make no write.
$(join_key_line "$CONFIG" "$CLIENT" crm)
- **Remote field carrying it:** see \`slots.crm.binding.mapping.dedupe_field\` in
  the firm's \`client-service.yaml\`. Absent there means undeclared — ask, do not
  guess a field name.

## Pending operations (none have run)

| Operation | Argument | State |
|---|---|---|
| \`upsert_company\` | company profile from \`../engagement.md\` | pending |
| \`upsert_deal\` | engagement summary from \`../engagement.md\` | pending |
| \`mirror_stage\` | the free-text stage in \`../engagement.md\` | pending — **optional capability**; skip if the binding does not declare it |

Mirrored content is assembled from the **client-visible** sections of
\`../engagement.md\` only. Firm-internal coordination never crosses into a CRM
field (policy \`client-service-internal-external-split\`).

A CRM failure is a warning. It never blocks the engagement and never changes the
state recorded in \`../engagement.md\`.
CRM
        CHANGES=$((CHANGES + 1))
        line "created" "${ENGAGEMENT_DIR}/adapters/crm.md" ;;
      portal)
        cat > "${ENGAGEMENT_DIR}/adapters/portal.md" <<PORTAL
# Client-facing surface — pending

The firm's \`portal\` slot is **bound** (\`tool_name: ${tool}\`), so this
engagement has a client-facing surface to register.

$(join_key_line "$CONFIG" "$CLIENT" portal)
- **Surface label:** see \`slots.portal.binding.mapping.defaults.surface_label\`.

## Pending operations (none have run)

| Operation | State | Gate |
|---|---|---|
| \`portal_status\` | **deferred — no pack skill implements it** | read — not gated |
| \`publish_update\` (kickoff note) | pending | **gated** — explicit human approval, every time |
| \`share_artifact\` | pending, as artifacts appear | **gated**, and \`visibility\` is set deliberately on every call |

Update copy is **assembled from the client-visible sections** of
\`../engagement.md\`, never produced by redacting the whole record. A deploy
hidden inside the binding is still a deploy and is still gated.

\`revoke_share\` matters at handover. If the binding does not declare it, removing
a share is a manual step — absent means undeclared, not "nothing to revoke".
PORTAL
        CHANGES=$((CHANGES + 1))
        line "created" "${ENGAGEMENT_DIR}/adapters/portal.md" ;;
    esac
  done

  # --- company-neutral handoff record for phase 2 --------------------------
  mkdir -p "$HANDOFF_DIR"
  HANDOFF_FILE="${HANDOFF_DIR}/${FIRM}--${CLIENT}.yaml"
  cat > "$HANDOFF_FILE" <<HANDOFF
# new-client handoff — company-neutral, written by phase 1 (firm-bound).
#
# Phase 2 (client-bound) reads THIS file and nothing else from the firm side.
# The firm and firm_name fields are PROVENANCE — a name, an audit fact. They are
# never dereferenced as a path, and engagement_path is recorded for a human
# operator, never opened by phase 2. That is what keeps the two phases inside the
# one-company-per-session rule instead of around it.
schema: hq.client-service.new-client-handoff
schema_version: 1
firm: ${FIRM}
firm_name: "${FIRM_NAME}"
client: ${CLIENT}
client_name: "${CLIENT_NAME}"
engagement_path: companies/${FIRM}/clients/${CLIENT}/engagement.md
cloud_requested: ${CLOUD_MODE}
created_at: $(now_iso)
HANDOFF
  CHANGES=$((CHANGES + 1))
  line "created" "$HANDOFF_FILE"

  # Existing engagements, for the operator. Leading-underscore pseudo-dirs are
  # excluded by the general rule.
  OTHERS=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$CLIENT" ] && continue
    OTHERS+=("$name")
  done <<< "$(list_selectable_dirs "$CLIENTS_DIR")"
  if [ "${#OTHERS[@]}" -gt 0 ]; then line "other engagements:" "${OTHERS[*]}"; fi

  say ""
  say "OK     ${CHANGES} change(s) — firm-internal home created."
  say "NEXT   phase 2 runs in a session bound to the CLIENT company:"
  say "         bash ${SCRIPT_DIR}/new-client.sh client-home --client ${CLIENT} \\"
  say "           --handoff ${HANDOFF_FILE} --invites declined   # or approved, after the gate"
  if [ "$CLOUD_MODE" = "local" ]; then
    say "NOTE   local-only: ${CLOUD_REASON}. Both file trees are still produced; every cloud step is skipped."
  fi
  exit 0
fi

# ===========================================================================
# VERB: client-home — CLIENT-bound phase
# ===========================================================================

# Handoff is optional. Its ABSENCE means the firm-side provenance is unknown —
# it never means "there is no firm" and never blocks the client-side tree.
HANDOFF_FIRM=""
HANDOFF_FIRM_NAME=""
if [ -z "$HANDOFF" ] && [ -n "$CLIENT" ] && [ -d "$HANDOFF_DIR" ]; then
  # Exactly one handoff record for this client is unambiguous; more than one is
  # ambiguity, which is an error, not a guess.
  CANDIDATES=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    CANDIDATES+=("$f")
  done <<< "$(find "$HANDOFF_DIR" -maxdepth 1 -type f -name "*--${CLIENT}.yaml" 2>/dev/null | LC_ALL=C sort || true)"
  if [ "${#CANDIDATES[@]}" -eq 1 ]; then
    HANDOFF="${CANDIDATES[0]}"
  elif [ "${#CANDIDATES[@]}" -gt 1 ]; then
    die_op "E_HANDOFF_AMBIGUOUS" \
      "${#CANDIDATES[@]} handoff records match client '${CLIENT}' in ${HANDOFF_DIR}. Pass --handoff <path> explicitly."
  fi
fi

if [ -n "$HANDOFF" ]; then
  [ -f "$HANDOFF" ] || die_op "E_HANDOFF_NOT_FOUND" "no handoff record at ${HANDOFF}"
  HANDOFF_CLIENT="$(yq -r '.client // ""' "$HANDOFF" 2>/dev/null || printf '')"
  HANDOFF_FIRM="$(yq -r '.firm // ""' "$HANDOFF" 2>/dev/null || printf '')"
  HANDOFF_FIRM_NAME="$(yq -r '.firm_name // ""' "$HANDOFF" 2>/dev/null || printf '')"
  HANDOFF_CLIENT_NAME="$(yq -r '.client_name // ""' "$HANDOFF" 2>/dev/null || printf '')"
  [ -n "$CLIENT" ] || CLIENT="$HANDOFF_CLIENT"
  if [ -n "$HANDOFF_CLIENT" ] && [ "$HANDOFF_CLIENT" != "$CLIENT" ]; then
    die_op "E_HANDOFF_MISMATCH" \
      "handoff record is for client '${HANDOFF_CLIENT}' but --client says '${CLIENT}'"
  fi
  [ -n "$CLIENT_NAME" ] || CLIENT_NAME="$HANDOFF_CLIENT_NAME"
  [ -n "$FIRM_NAME" ] || FIRM_NAME="$HANDOFF_FIRM_NAME"
fi

require_slug "$CLIENT" "client"
[ -n "$CLIENT_NAME" ] || CLIENT_NAME="$CLIENT"
if [ -z "$FIRM_NAME" ]; then
  FIRM_NAME="TODO: the firm's name (no handoff record was read, so it is unknown)"
fi

require_session_bound_to "$CLIENT" "client company"

CO_DIR="${COMPANIES_DIR}/${CLIENT}"
CHECKLIST="${CO_DIR}/handover-checklist.md"

[ -f "$CHECKLIST_TEMPLATE" ] || die_op "E_NO_CHECKLIST_TEMPLATE" \
  "no handover checklist template at ${CHECKLIST_TEMPLATE} — the pack install is incomplete"

COMPANY_EXISTED=1
if [ ! -d "$CO_DIR" ]; then
  COMPANY_EXISTED=0
  if [ "$COMPANY_SCAFFOLD" = "require" ]; then
    die_op "E_CLIENT_COMPANY_MISSING" \
"no company at ${CO_DIR} and --company-scaffold require was passed.
       Create it with /newcompany ${CLIENT} first (the fuller interview), then
       re-run this phase. Use --company-scaffold auto to write the minimal
       local scaffold instead."
  fi
fi

resolve_cloud_mode "$( [ -f "${CO_DIR}/company.yaml" ] && printf '%s' "${CO_DIR}/company.yaml" || printf '-' )"

# --- the invite gate ------------------------------------------------------
# Emission happens ONLY on an explicit `approved`. Everything else — declined,
# undecided, absent — emits nothing outward-facing.
INVITE_PLAN="${HANDOFF_DIR}/${CLIENT}-invites.txt"
case "$INVITES" in
  approved)
    if [ "${#INVITEES[@]}" -eq 0 ]; then
      INVITE_STATUS="approved, but no --invite recipients were given — nothing to send"
    else
      INVITE_STATUS="approved for ${#INVITEES[@]} recipient(s); commands staged for a human to run — this engine sends nothing itself"
    fi ;;
  declined)
    INVITE_STATUS="declined at the approval gate — no invite was sent or staged. Everything else completed. Re-run this phase with --invites approved when the firm is ready." ;;
  *)
    if [ "${#INVITEES[@]}" -gt 0 ]; then
      INVITE_STATUS="UNDECIDED — ${#INVITEES[@]} recipient(s) were supplied but no approval was given, so nothing was sent or staged. Undecided is not approval."
    else
      INVITE_STATUS="UNDECIDED — no approval was given and no recipients were supplied. Nobody has been invited."
    fi ;;
esac

say "new-client client-home — client company ${CLIENT}"
line "company dir:" "${CO_DIR}$( [ "$COMPANY_EXISTED" -eq 1 ] && printf ' (exists)' || printf ' (will be scaffolded)')"
line "checklist:" "$CHECKLIST"
line "cloud posture:" "${CLOUD_MODE} (${CLOUD_REASON})"
line "invites:" "$INVITE_STATUS"
if [ -n "$HANDOFF" ]; then
  line "handoff:" "${HANDOFF} (provenance only — the firm tree is never read from here)"
else
  line "handoff:" "none — firm provenance unknown, which is not 'no firm'. The checklist records it as TODO."
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "  --dry-run: nothing written"
  exit 0
fi

# --- scaffold the client company (local, deterministic) -------------------
# The preferred path is /newcompany, which runs the full interview. This is the
# mechanical fallback that guarantees the client tree exists even with no cloud
# identity and no interactive session.
if [ "$COMPANY_EXISTED" -eq 0 ]; then
  mkdir -p "${CO_DIR}/settings" "${CO_DIR}/data" "${CO_DIR}/knowledge" \
           "${CO_DIR}/skills" "${CO_DIR}/workers" "${CO_DIR}/policies" \
           "${CO_DIR}/projects" "${CO_DIR}/people" "${CO_DIR}/workspace"
  printf '# HQ workspace mirror — sessions are gitignored, index.jsonl is committed\nsessions/\n' \
    > "${CO_DIR}/workspace/.gitignore"
  : > "${CO_DIR}/workspace/index.jsonl"
  # cloud: false is the local default. /designate-team flips it to true; this
  # engine never does, because that is a cloud provisioning action.
  printf 'slug: %s\nname: "%s"\ncloud: false\n' "$CLIENT" "$CLIENT_NAME" > "${CO_DIR}/company.yaml"
  printf '{\n  "company": "%s",\n  "schema_version": 2,\n  "updated_at": "%s",\n  "objectives": [],\n  "initiatives": [],\n  "projects": []\n}\n' \
    "$CLIENT" "$(now_iso)" > "${CO_DIR}/board.json"
  printf '# %s Knowledge\n\nKnowledge base for %s.\n' "$CLIENT_NAME" "$CLIENT_NAME" > "${CO_DIR}/knowledge/README.md"
  CHANGES=$((CHANGES + 1))
  line "created" "${CO_DIR}/ (minimal scaffold)"
  note "The client company was scaffolded mechanically. /newcompany ${CLIENT} can still be run for the full discovery interview, brand packs, and integrations — it is additive over this tree."

  MANIFEST="${COMPANIES_DIR}/manifest.yaml"
  if [ "$WRITE_MANIFEST" -eq 1 ] && [ -f "$MANIFEST" ]; then
    if [ "$(yq -r ".companies // {} | has(\"${CLIENT}\")" "$MANIFEST" 2>/dev/null || printf 'true')" != "true" ]; then
      yq -i ".companies.${CLIENT}.name = \"${CLIENT_NAME}\"" "$MANIFEST"
      yq -i ".companies.${CLIENT}.goal = \"\"" "$MANIFEST"
      yq -i ".companies.${CLIENT}.path = \"companies/${CLIENT}\"" "$MANIFEST"
      yq -i ".companies.${CLIENT}.sources = []" "$MANIFEST"
      yq -i ".companies.${CLIENT}.repos = []" "$MANIFEST"
      yq -i ".companies.${CLIENT}.knowledge = \"companies/${CLIENT}/knowledge/\"" "$MANIFEST"
      yq -i ".companies.${CLIENT}.qmd_collections = [\"${CLIENT}\", \"${CLIENT}-projects\"]" "$MANIFEST"
      CHANGES=$((CHANGES + 1))
      line "registered" "${MANIFEST} (companies.${CLIENT})"
    fi
  elif [ "$WRITE_MANIFEST" -eq 1 ]; then
    note "No companies/manifest.yaml at ${MANIFEST}, so nothing was registered. The company tree exists; register it when the manifest does."
  fi
else
  line "kept" "${CO_DIR}/ (already existed — nothing in it was rewritten)"
fi

# --- stage the handover checklist ----------------------------------------
if [ -f "$CHECKLIST" ]; then
  line "kept" "${CHECKLIST} (already staged — an existing checklist is a human's working file and is never overwritten)"
else
  CHECKLIST_BODY="$(cat "$CHECKLIST_TEMPLATE")"
  render "$CHECKLIST_BODY" \
    "CLIENT_NAME=${CLIENT_NAME}" \
    "CLIENT_SLUG=${CLIENT}" \
    "FIRM_NAME=${FIRM_NAME}" \
    "TODAY=$(today)" \
    "INVITE_STATUS=${INVITE_STATUS}" > "$CHECKLIST"
  CHANGES=$((CHANGES + 1))
  line "created" "$CHECKLIST"
fi

# --- invites: emit ONLY on explicit approval ------------------------------
if [ "$INVITES" = "approved" ] && [ "${#INVITEES[@]}" -gt 0 ]; then
  mkdir -p "$HANDOFF_DIR"
  {
    printf '# Approved client-team invites for %s — staged %s\n' "$CLIENT" "$(now_iso)"
    printf '#\n# Emitted because an explicit in-session human approval was recorded\n'
    printf '# (--invites approved). NOTHING HAS BEEN SENT: new-client.sh makes no\n'
    printf '# external call. Run these yourself, or drive /new-hire, after checking\n'
    printf '# each address.\n'
    for who in "${INVITEES[@]}"; do
      email="${who%%:*}"
      role="${who#*:}"
      [ "$role" != "$who" ] || role=""
      if [ -n "$role" ]; then
        printf 'hq invite --company %s --email %s --role %s\n' "$CLIENT" "$email" "$role"
      else
        printf 'hq invite --company %s --email %s\n' "$CLIENT" "$email"
      fi
    done
  } > "$INVITE_PLAN"
  CHANGES=$((CHANGES + 1))
  line "staged" "${INVITE_PLAN} (commands only — nothing sent)"
elif [ "${#INVITEES[@]}" -gt 0 ]; then
  line "NOT staged" "invites — ${INVITE_STATUS}"
fi

# --- cloud steps ----------------------------------------------------------
if [ "$CLOUD_MODE" = "cloud" ]; then
  say ""
  say "CLOUD  this engine performs no cloud action. Run, in this client-bound session:"
  say "         /designate-team ${CLIENT}      # marks the company cloud-backed and provisions it"
  if [ -f "$INVITE_PLAN" ]; then
    say "       then the approved invites staged at ${INVITE_PLAN}"
  fi
else
  note "Local-only: ${CLOUD_REASON}. Both file trees were produced in full; /designate-team, cloud provisioning, and any invite delivery were skipped, not failed. Re-run with --cloud once a cloud identity is available."
fi

say ""
if [ "$CHANGES" -eq 0 ]; then
  say "OK     no changes — the client home and checklist were already in place (idempotent re-run)"
else
  say "OK     ${CHANGES} change(s) — client-facing home ready."
fi
for n in "${NOTES[@]:-}"; do
  [ -n "$n" ] || continue
  say "NOTE   ${n}"
done
exit 0
