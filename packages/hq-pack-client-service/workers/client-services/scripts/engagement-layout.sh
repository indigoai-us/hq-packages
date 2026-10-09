#!/usr/bin/env bash
# engagement-layout.sh — resolve WHERE one engagement's canonical record and its
# project trackers live, and what its local dedupe key is.
#
#   engagement-layout.sh (--config <client-service.yaml> | --firm <slug>) \
#                        --engagement <slug> [--slot <name>|all] [--expand] \
#                        [--format text|kv]
#
# Companion to slot-state.sh. slot-state.sh answers "which tools does this firm
# run"; this answers "which files is this engagement made of". Both are READ-ONLY
# BY CONSTRUCTION: they open the config, print a report, and exit. No files, no
# directories, no temp files, and no call to any firm tooling.
#
# Resolution order, most specific first, presence read before value:
#   1. engagement_layout.overrides.<slug>.<field>   — this engagement is special
#   2. engagement_layout.<field>                    — this firm's own convention
#   3. the pack default                             — v1 behaviour, unchanged
#
# Absent at every level is UNDECLARED, and undeclared resolves to the pack
# default, which is the non-constraining direction: it names a path, it does not
# assert that the firm keeps anything there. `tracker_sources: []` written
# explicitly is different — that is DECLARED-NONE, and callers must report "no
# tracker" rather than searching the default glob.
# Policy: hq-absent-field-never-means-constraining-value.
#
# --------------------------------------------------------------------------
# Per-slot join keys (D1)
# --------------------------------------------------------------------------
# `mapping.dedupe_field` is declared PER SLOT, but the key that went into it used
# to be resolved per ENGAGEMENT — one value pushed into every slot's join field.
# A firm whose slots join on different shapes of value (a short alias for the
# ledger and the agreements tool, a registrable domain for the CRM) could not say
# so. The read symptom is a rejected lookup; the write consequence is worse,
# because a search-then-create write whose search cannot match creates a
# DUPLICATE record.
#
# `engagement_layout.dedupe_keys` is a map keyed by SLOT NAME, allowed at the
# firm level and inside any override entry. Exactly ONE value is still resolved
# per (engagement, slot), locally and purely — no tool call, ever. Five declaring
# levels, SCOPE first and then SLOT-specificity within a scope:
#
#   1  overrides.<slug>.dedupe_keys.<slot>   source=override-slot
#   2  overrides.<slug>.dedupe_key           source=override
#   3  dedupe_keys.<slot>                    source=firm-slot
#   4  dedupe_key                            source=firm
#   5  {slug}                                source=default
#
# A config with no `dedupe_keys` anywhere can only reach 2, 4 and 5 — the exact
# three levels that existed before — so its resolution is unchanged.
#
# A `dedupe_keys` entry written EXPLICITLY as null is DECLARED-NONE: this slot
# has no join value derivable at this level, so the caller reports the key as
# unresolved and makes NO external write, rather than sending a value the slot
# cannot join on. Absent is undeclared and falls through to the next level. The
# two are never collapsed.
#
# Per-slot lines are printed only when --slot is given, so the report for a
# caller that does not ask is byte-identical to what it was before this existed.
#
# Exit codes
#   0  the layout was resolved and printed (whatever it resolved to)
#   2  environment or usage problem (named, on stderr)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"
SCHEMA_DEFAULT="${PACK_DIR}/knowledge/client-service/client-service.schema.yaml"

DEFAULT_ENGAGEMENT_PATH='companies/{firm}/clients/{slug}/engagement.md'
DEFAULT_TRACKER_SOURCE='companies/{firm}/clients/{slug}/projects/*/prd.json'
DEFAULT_DEDUPE_KEY='{slug}'

# Fallback slot list for this pack version, used only when the schema file
# cannot be found. Kept in sync with the schema by the pack, never by hand at a
# call site. Same idiom as slot-state.sh.
BUILTIN_SLOTS="crm
billing
agreements
portal
transcripts"

CONFIG=""
FIRM=""
ENGAGEMENT=""
FORMAT="text"
EXPAND=0
WANT_SLOT=""
SCHEMA=""

die_env() { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --config)     CONFIG="${2:-}"; shift 2 ;;
    --firm)       FIRM="${2:-}"; shift 2 ;;
    --engagement) ENGAGEMENT="${2:-}"; shift 2 ;;
    --format)     FORMAT="${2:-text}"; shift 2 ;;
    --slot)       WANT_SLOT="${2:-all}"; shift 2 ;;
    --schema)     SCHEMA="${2:-}"; shift 2 ;;
    --expand)     EXPAND=1; shift ;;
    -h|--help)
      printf 'usage: engagement-layout.sh (--config <file> | --firm <slug>) --engagement <slug> [--slot <name>|all] [--expand] [--format text|kv]\n'
      exit 0 ;;
    *) die_env "E_USAGE" "unknown argument: $1" ;;
  esac
done

command -v yq >/dev/null 2>&1 || die_env "E_ENV_YQ_MISSING" "yq (mikefarah v4) is required to read the firm config"
[ -n "$ENGAGEMENT" ] || die_env "E_USAGE" "--engagement <slug> is required"

if [ -z "$CONFIG" ]; then
  [ -n "$FIRM" ] || die_env "E_USAGE" "one of --config or --firm is required"
  CONFIG="companies/${FIRM}/client-service.yaml"
fi

CONFIG_STATE="present"
if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
  # A missing firm config is not a crash. It means the firm never onboarded, so
  # the layout is wholly undeclared and every field takes the pack default.
  CONFIG_STATE="missing"
else
  yq -e '.' "$CONFIG" >/dev/null 2>&1 || die_env "E_CONFIG_NOT_YAML" "not parseable YAML: ${CONFIG}"
fi

case "$FORMAT" in text|kv) ;; *) die_env "E_USAGE" "--format must be text or kv" ;; esac

q() { [ "$CONFIG_STATE" = "present" ] || { printf ''; return 0; }; yq -r "$1" "$CONFIG" 2>/dev/null || printf ''; }
has_key() { # has_key <parent-expr> <key> — PRESENCE only, value irrelevant
  [ "$(q "${1} | has(\"${2}\")")" = "true" ]
}

if [ -n "$FIRM" ]; then
  FIRM_SLUG="$FIRM"
else
  FIRM_SLUG="$(q '.firm')"
  [ "$FIRM_SLUG" = "null" ] && FIRM_SLUG=""
fi

LAYOUT='.engagement_layout'
OVERRIDE=".engagement_layout.overrides.\"${ENGAGEMENT}\""
LAYOUT_DK='.engagement_layout.dedupe_keys'
OVERRIDE_DK="${OVERRIDE}.dedupe_keys"

has_layout()   { has_key '.' "engagement_layout"; }
has_override() {
  has_layout || return 1
  has_key "$LAYOUT" "overrides" || return 1
  has_key "${LAYOUT}.overrides" "$ENGAGEMENT"
}
has_layout_dk()   { has_layout   && has_key "$LAYOUT"   "dedupe_keys"; }
has_override_dk() { has_override && has_key "$OVERRIDE" "dedupe_keys"; }

# where_field <field> -> prints "override" | "firm" | "default"
where_field() {
  local f="$1"
  if has_override && has_key "$OVERRIDE" "$f"; then printf 'override'; return 0; fi
  if has_layout   && has_key "$LAYOUT"   "$f"; then printf 'firm';     return 0; fi
  printf 'default'
}

expand_tpl() { # expand_tpl <template>
  printf '%s' "$1" | sed -e "s|{firm}|${FIRM_SLUG}|g" -e "s|{slug}|${ENGAGEMENT}|g"
}

# ---------------------------------------------------------------------------
# engagement_path
# ---------------------------------------------------------------------------
EP_SRC="$(where_field engagement_path)"
case "$EP_SRC" in
  override) EP_TPL="$(q "${OVERRIDE}.engagement_path")" ;;
  firm)     EP_TPL="$(q "${LAYOUT}.engagement_path")" ;;
  *)        EP_TPL="$DEFAULT_ENGAGEMENT_PATH" ;;
esac
ENGAGEMENT_PATH="$(expand_tpl "$EP_TPL")"

# ---------------------------------------------------------------------------
# dedupe_key — still local and pure. No tool call, ever.
# ---------------------------------------------------------------------------
DK_SRC="$(where_field dedupe_key)"
case "$DK_SRC" in
  override) DK_TPL="$(q "${OVERRIDE}.dedupe_key")" ;;
  firm)     DK_TPL="$(q "${LAYOUT}.dedupe_key")" ;;
  *)        DK_TPL="$DEFAULT_DEDUPE_KEY" ;;
esac
DEDUPE_KEY="$(expand_tpl "$DK_TPL")"

# ---------------------------------------------------------------------------
# Per-slot join keys — still local and pure, still exactly one value per
# (engagement, slot). Precedence: scope first, then slot-specificity within a
# scope. See the header block and the schema's `dedupe_key_precedence`.
# ---------------------------------------------------------------------------

# where_slot_key <slot> -> override-slot | override | firm-slot | firm | default
where_slot_key() {
  local s="$1"
  if has_override_dk && has_key "$OVERRIDE_DK" "$s"; then printf 'override-slot'; return 0; fi
  if has_override    && has_key "$OVERRIDE" 'dedupe_key';  then printf 'override';  return 0; fi
  if has_layout_dk   && has_key "$LAYOUT_DK" "$s";         then printf 'firm-slot'; return 0; fi
  if has_layout      && has_key "$LAYOUT" 'dedupe_key';    then printf 'firm';      return 0; fi
  printf 'default'
}

# resolve_slot_key <slot> — sets SK_SRC, SK_VALUE, SK_STATE
SK_SRC=""; SK_VALUE=""; SK_STATE=""
resolve_slot_key() {
  local s="$1" expr=""
  SK_SRC="$(where_slot_key "$s")"
  case "$SK_SRC" in
    override-slot) expr="${OVERRIDE_DK}.\"${s}\"" ;;
    override)      expr="${OVERRIDE}.dedupe_key" ;;
    firm-slot)     expr="${LAYOUT_DK}.\"${s}\"" ;;
    firm)          expr="${LAYOUT}.dedupe_key" ;;
    *)             expr="" ;;
  esac
  if [ -z "$expr" ]; then
    SK_VALUE="$(expand_tpl "$DEFAULT_DEDUPE_KEY")"; SK_STATE="resolved"; return 0
  fi
  # PRESENCE was decided above; the VALUE is only consulted now. An explicit
  # null is DECLARED-NONE — the firm said this slot has no join value here, so
  # the caller must report it unresolved and write nothing externally.
  if [ "$(q "${expr} | tag")" = "!!null" ]; then
    SK_VALUE=""; SK_STATE="declared-none"; return 0
  fi
  SK_VALUE="$(expand_tpl "$(q "$expr")")"; SK_STATE="resolved"
}

# Which slots name a key of their own, at any level that applies here. Used only
# to advise a caller that did not ask for a slot; empty for every config that
# declares no `dedupe_keys`, so no line is printed and nothing changes for them.
declared_key_slots() {
  local raw="" s out=""
  if has_override_dk; then raw="${raw}$(q "${OVERRIDE_DK} | keys | .[]")
"; fi
  if has_layout_dk;   then raw="${raw}$(q "${LAYOUT_DK} | keys | .[]")
"; fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case ",${out}," in *",${s},"*) continue ;; esac
    out="${out:+${out},}${s}"
  done <<< "$raw"
  printf '%s' "$out"
}

# The slot list is only needed for --slot all.
slot_list() {
  local schema="${SCHEMA:-$SCHEMA_DEFAULT}" out
  if [ -f "$schema" ]; then
    out="$(yq -r '.slots | keys | .[]' "$schema" 2>/dev/null || printf '')"
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  fi
  printf '%s' "$BUILTIN_SLOTS"
}

# ---------------------------------------------------------------------------
# tracker_sources — a LIST, and an explicitly empty list is declared-none
# ---------------------------------------------------------------------------
TS_SRC="$(where_field tracker_sources)"
case "$TS_SRC" in
  override) TS_RAW="$(q "${OVERRIDE}.tracker_sources[]")" ;;
  firm)     TS_RAW="$(q "${LAYOUT}.tracker_sources[]")" ;;
  *)        TS_RAW="$DEFAULT_TRACKER_SOURCE" ;;
esac

TS_STATE="declared"
if [ "$TS_SRC" = "default" ]; then
  TS_STATE="undeclared-default"
elif [ -z "$TS_RAW" ]; then
  TS_STATE="declared-none"
fi

TRACKER_SOURCES=""
if [ -n "$TS_RAW" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    TRACKER_SOURCES="${TRACKER_SOURCES}$(expand_tpl "$t")
"
  done <<< "$TS_RAW"
fi

# ---------------------------------------------------------------------------
# which slots to report a join key for
# ---------------------------------------------------------------------------
SLOTS_TO_REPORT=""
if [ -n "$WANT_SLOT" ]; then
  if [ "$WANT_SLOT" = "all" ]; then
    SLOTS_TO_REPORT="$(slot_list)"
  else
    SLOTS_TO_REPORT="$WANT_SLOT"
  fi
fi
DECLARED_KEY_SLOTS="$(declared_key_slots)"

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
engagement_exists="no"
[ -f "$ENGAGEMENT_PATH" ] && engagement_exists="yes"

if [ "$FORMAT" = "kv" ]; then
  printf 'config_state=%s\n' "$CONFIG_STATE"
  printf 'firm=%s\n' "$FIRM_SLUG"
  printf 'engagement=%s\n' "$ENGAGEMENT"
  printf 'engagement_path=%s source=%s exists=%s\n' "$ENGAGEMENT_PATH" "$EP_SRC" "$engagement_exists"
  printf 'dedupe_key=%s source=%s\n' "$DEDUPE_KEY" "$DK_SRC"
  if [ -n "$SLOTS_TO_REPORT" ]; then
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      resolve_slot_key "$s"
      printf 'dedupe_key_for=%s value=%s source=%s state=%s\n' "$s" "$SK_VALUE" "$SK_SRC" "$SK_STATE"
    done <<< "$SLOTS_TO_REPORT"
  elif [ -n "$DECLARED_KEY_SLOTS" ]; then
    printf 'dedupe_keys_declared=%s\n' "$DECLARED_KEY_SLOTS"
  fi
  printf 'tracker_sources_state=%s source=%s\n' "$TS_STATE" "$TS_SRC"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    printf 'tracker_source=%s\n' "$t"
  done <<< "$TRACKER_SOURCES"
else
  printf 'config: %s (%s)\n' "$CONFIG" "$CONFIG_STATE"
  [ -n "$FIRM_SLUG" ] && printf 'firm: %s\n' "$FIRM_SLUG"
  printf 'engagement: %s\n' "$ENGAGEMENT"
  printf '\nengagement_path: %s\n' "$ENGAGEMENT_PATH"
  printf 'engagement_path_source: %s\n' "$EP_SRC"
  printf 'engagement_path_exists: %s\n' "$engagement_exists"
  printf '\ndedupe_key: %s\n' "$DEDUPE_KEY"
  printf 'dedupe_key_source: %s (local and pure — derived from the config and the slug, never from a tool call)\n' "$DK_SRC"
  if [ -n "$SLOTS_TO_REPORT" ]; then
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      resolve_slot_key "$s"
      if [ "$SK_STATE" = "declared-none" ]; then
        printf 'dedupe_key_for_%s: (none — declared-none at the %s level: this slot has no join value here. Report the key as UNRESOLVED and make no external write; do not fall back to a value this slot cannot join on)\n' "$s" "$SK_SRC"
      else
        printf 'dedupe_key_for_%s: %s\n' "$s" "$SK_VALUE"
      fi
      printf 'dedupe_key_for_%s_source: %s\n' "$s" "$SK_SRC"
      printf 'dedupe_key_for_%s_state: %s\n' "$s" "$SK_STATE"
    done <<< "$SLOTS_TO_REPORT"
  elif [ -n "$DECLARED_KEY_SLOTS" ]; then
    printf 'dedupe_keys_declared: %s (this engagement resolves a different join key for these slots — call with --slot <name> to get the value that slot actually joins on)\n' "$DECLARED_KEY_SLOTS"
  fi
  printf '\ntracker_sources_state: %s\n' "$TS_STATE"
  printf 'tracker_sources_source: %s\n' "$TS_SRC"
  if [ "$TS_STATE" = "declared-none" ]; then
    printf 'tracker_sources: (none — the firm declared it keeps no project trackers this pack can read; report "no tracker", never a guessed percentage)\n'
  else
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf 'tracker_source: %s\n' "$t"
    done <<< "$TRACKER_SOURCES"
  fi
fi

if [ "$EXPAND" -eq 1 ] && [ "$TS_STATE" != "declared-none" ]; then
  matched=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Word-splitting is intended here: the template is a glob, not a filename.
    # shellcheck disable=SC2086
    for f in $t; do
      [ -f "$f" ] || continue
      matched=$((matched + 1))
      if [ "$FORMAT" = "kv" ]; then printf 'tracker_file=%s\n' "$f"; else printf 'tracker_file: %s\n' "$f"; fi
    done
  done <<< "$TRACKER_SOURCES"
  if [ "$FORMAT" = "kv" ]; then printf 'tracker_file_count=%s\n' "$matched"; else printf 'tracker_file_count: %s\n' "$matched"; fi
fi

printf 'writes: none\n'
exit 0
