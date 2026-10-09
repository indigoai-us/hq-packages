#!/usr/bin/env bash
# validate-config.sh — validate a firm's client-service.yaml against the pack schema.
#
#   validate-config.sh [--strict] [--schema <path>] [--quiet] <config.yaml>
#
# Exit codes
#   0  valid (warnings may have been printed; --strict promotes them to errors)
#   1  invalid — one or more NAMED errors, each with a code and a path
#   2  environment/usage problem (also named: E_ENV_YQ_MISSING, E_USAGE, ...)
#
# Design notes
#   * The schema file is the source of truth. Connectors, slot names, field
#     lists, denylists and the error catalogue are all READ FROM IT, so the
#     contract and the checker cannot drift.
#   * Policy hq-absent-field-never-means-constraining-value: presence and value
#     are read separately everywhere. `has(key)` decides presence; the value is
#     only consulted afterwards. An absent key is `undeclared` (warn, unknown),
#     never silently resolved into `empty` or any other decision.
#   * Compatibility runs in BOTH directions: unknown slots/fields/capabilities
#     warn instead of failing, so a config from a newer pack version still loads
#     here, and a config from an older one still loads under a newer validator.
#   * Policy hq-bash-set-e-status-returns: functions that return non-zero as a
#     status signal are never called bare under `set -e`. They are called either
#     inside an `if`/`&&` condition (where `set -e` is suspended) or with the
#     `|| rc=$?` capture idiom.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCHEMA_DEFAULT="${PACK_DIR}/knowledge/client-service/client-service.schema.yaml"

STRICT=0
QUIET=0
SCHEMA=""
CONFIG=""

ERR_COUNT=0
WARN_COUNT=0

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# describe <CODE> -> the catalogue line for a code, or an empty string.
describe() {
  local code="$1" out rc=0
  [ -n "${SCHEMA:-}" ] && [ -f "${SCHEMA:-}" ] || { printf ''; return 0; }
  out="$(yq -r ".errors.\"${code}\" // .warnings.\"${code}\" // \"\"" "$SCHEMA" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || out=""
  [ "$out" = "null" ] && out=""
  printf '%s' "$out"
}

emit() { # emit <LEVEL> <CODE> <PATH> [detail]
  local level="$1" code="$2" path="$3" detail="${4:-}" desc
  desc="$(describe "$code")"
  local line="${level}  ${code}  at ${path}"
  [ -n "$desc" ] && line="${line}: ${desc}"
  [ -n "$detail" ] && line="${line} (${detail})"
  printf '%s\n' "$line"
}

fail() { # fail <CODE> <PATH> [detail]
  ERR_COUNT=$((ERR_COUNT + 1))
  emit "ERROR" "$@"
}

warn() { # warn <CODE> <PATH> [detail]
  WARN_COUNT=$((WARN_COUNT + 1))
  emit "WARN " "$@"
}

die_env() { # die_env <CODE> <message>
  local desc
  desc="$(describe "$1")"
  printf 'ERROR  %s  %s%s\n' "$1" "$2" "${desc:+ — $desc}" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# yq helpers — never abort the script, always answer
# ---------------------------------------------------------------------------

# q <expr> <file> -> stdout (empty when the query fails)
q() {
  local out rc=0
  out="$(yq -r "$1" "$2" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$out"
  return 0
}

# ql <expr> <file> -> stdout, newline-separated list (empty when the query fails)
ql() {
  local out rc=0
  out="$(yq -r "$1" "$2" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out"
  return 0
}

# has_key <parent-expr> <key> <file>  — PRESENCE only, value irrelevant.
has_key() {
  [ "$(q "${1} | has(\"${2}\")" "$3")" = "true" ]
}

# tag_of <expr> <file> -> yaml tag of the value (!!map, !!null, !!str, ...)
tag_of() { q "${1} | tag" "$2"; }

# in_list <needle> <newline-separated haystack>
in_list() {
  local needle="$1" item
  while IFS= read -r item; do
    [ "$item" = "$needle" ] && return 0
  done <<< "$2"
  return 1
}

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    --schema) SCHEMA="${2:-}"; shift 2 ;;
    -h|--help)
      printf 'usage: validate-config.sh [--strict] [--quiet] [--schema <path>] <config.yaml>\n'
      exit 0 ;;
    -*) die_env "E_USAGE" "unknown option: $1" ;;
    *)
      [ -z "$CONFIG" ] || die_env "E_USAGE" "more than one config path given"
      CONFIG="$1"; shift ;;
  esac
done

SCHEMA="${SCHEMA:-$SCHEMA_DEFAULT}"

command -v yq >/dev/null 2>&1 || die_env "E_ENV_YQ_MISSING" "yq (mikefarah v4) is required"
[ -f "$SCHEMA" ] || die_env "E_ENV_SCHEMA_MISSING" "no schema at ${SCHEMA}"
[ -n "$CONFIG" ] || die_env "E_USAGE" "no config path given"

# ---------------------------------------------------------------------------
# load the contract out of the schema
# ---------------------------------------------------------------------------

SUPPORTED_MAJOR="$(q '.supported_schema_major // 1' "$SCHEMA")"
SCHEMA_NAME="$(q '.top_level.fields.schema.const' "$SCHEMA")"
FIRM_PATTERN="$(q '.top_level.fields.firm.pattern' "$SCHEMA")"
SECRET_PATTERN="$(q '.top_level.fields.secret_name.pattern // .binding.fields.secret_name.pattern' "$SCHEMA")"

TOP_REQUIRED="$(ql '.top_level.required[]' "$SCHEMA")"
TOP_OPTIONAL="$(ql '.top_level.optional[]' "$SCHEMA")"
CONNECTORS="$(ql '.binding.connectors[]' "$SCHEMA")"
BINDING_REQ="$(ql '.binding.required_fields[]' "$SCHEMA")"
BINDING_OPT="$(ql '.binding.optional_fields[]' "$SCHEMA")"
POINTER_REQ="$(ql '.pointer.required_fields[]' "$SCHEMA")"
POINTER_OPT="$(ql '.pointer.optional_fields[]' "$SCHEMA")"
POINTER_KINDS="$(ql '.pointer.kinds[]' "$SCHEMA")"
LAYOUT_REQ="$(ql '.engagement_layout.required_fields[]' "$SCHEMA")"
LAYOUT_OPT="$(ql '.engagement_layout.optional_fields[]' "$SCHEMA")"
LAYOUT_OVERRIDE_OPT="$(ql '.engagement_layout.fields.overrides.entry_optional_fields[]' "$SCHEMA")"
REC_REQ="$(ql '.recommendation.required_fields[]' "$SCHEMA")"
REC_OPT="$(ql '.recommendation.optional_fields[]' "$SCHEMA")"
DENYLIST="$(ql '.credentials.inline_key_denylist[]' "$SCHEMA")"
VALUE_PATTERNS="$(ql '.credentials.value_shape_warning_patterns[]' "$SCHEMA")"
KNOWN_SLOTS="$(ql '.slots | keys | .[]' "$SCHEMA")"
SLOT_FIELDS="binding
pointer
recommended
notes
note"

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

check_top_level() {
  local key val tag

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! has_key '.' "$key" "$CONFIG"; then
      fail "E_SCHEMA_KEY_MISSING" ".${key}" "required"
    fi
  done <<< "$TOP_REQUIRED"

  if has_key '.' "schema" "$CONFIG"; then
    val="$(q '.schema' "$CONFIG")"
    [ "$val" = "$SCHEMA_NAME" ] || fail "E_SCHEMA_NAME_WRONG" ".schema" "got: ${val}"
  fi

  if has_key '.' "schema_version" "$CONFIG"; then
    tag="$(tag_of '.schema_version' "$CONFIG")"
    if [ "$tag" != "!!int" ]; then
      fail "E_SCHEMA_VERSION_NOT_INT" ".schema_version" "tag: ${tag}"
    else
      val="$(q '.schema_version' "$CONFIG")"
      if [ "$val" -gt "$SUPPORTED_MAJOR" ]; then
        # Newer major: named, actionable, and NOT a parse failure.
        fail "E_SCHEMA_VERSION_UNSUPPORTED_MAJOR" ".schema_version" \
             "config is v${val}, this validator understands up to v${SUPPORTED_MAJOR}"
      fi
    fi
  fi

  if has_key '.' "firm" "$CONFIG"; then
    val="$(q '.firm' "$CONFIG")"
    if ! printf '%s' "$val" | grep -Eq "$FIRM_PATTERN"; then
      fail "E_FIRM_SLUG_INVALID" ".firm" "got: ${val}"
    fi
  fi

  # Unknown top-level keys warn — a newer pack version may have added them.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! in_list "$key" "$TOP_REQUIRED" && ! in_list "$key" "$TOP_OPTIONAL"; then
      warn "W_TOP_LEVEL_KEY_UNKNOWN" ".${key}" "ignored"
    fi
  done <<< "$(ql 'keys | .[]' "$CONFIG")"
}

# `dedupe_keys` is a map keyed by SLOT NAME, legal at the firm level and inside
# any override entry. Present means it must be well-formed; an unknown slot name
# warns (forward compatibility) and an explicit null entry is DECLARED-NONE,
# which is legal and load-bearing, not a missing value.
check_dedupe_keys() { # check_dedupe_keys <base-expr> <display-path>
  local base="$1" disp="$2" tag s stag

  has_key "$base" "dedupe_keys" "$CONFIG" || return 0

  tag="$(tag_of "${base}.dedupe_keys" "$CONFIG")"
  if [ "$tag" != "!!map" ]; then
    fail "E_LAYOUT_DEDUPE_KEYS_NOT_MAPPING" "${disp}.dedupe_keys" "tag: ${tag}"
    return 0
  fi

  while IFS= read -r s; do
    [ -n "$s" ] || continue
    stag="$(tag_of "${base}.dedupe_keys.\"${s}\"" "$CONFIG")"
    case "$stag" in
      '!!str'|'!!null') ;;
      *) fail "E_LAYOUT_DEDUPE_KEY_NOT_SCALAR" "${disp}.dedupe_keys.${s}" "tag: ${stag}" ;;
    esac
    in_list "$s" "$KNOWN_SLOTS" || \
      warn "W_LAYOUT_DEDUPE_KEY_SLOT_UNKNOWN" "${disp}.dedupe_keys.${s}" \
           "not a slot this pack version knows — ignored"
  done <<< "$(ql "${base}.dedupe_keys | keys | .[]" "$CONFIG")"
}

# The one dangerous interaction in the join-key precedence order. Scope outranks
# slot, so a per-engagement general `dedupe_key` sits at level 2 and a firm-level
# per-slot key sits at level 3 — meaning the engagement's general key WINS for a
# slot the firm gave its own key. That is the layout block's existing rule ("an
# override entry, then the firm-level layout") and it is not being reversed for
# one field, but it is also the exact combination that silently reintroduces the
# defect this key exists to fix. So it is named. Warning, never an error: the
# config is legal and its behaviour is defined.
check_dedupe_key_shadowing() {
  local base=".engagement_layout" slug s obase

  has_key '.' "engagement_layout" "$CONFIG" || return 0
  has_key "$base" "dedupe_keys" "$CONFIG" || return 0
  has_key "$base" "overrides" "$CONFIG" || return 0
  [ "$(tag_of "${base}.dedupe_keys" "$CONFIG")" = "!!map" ] || return 0
  [ "$(tag_of "${base}.overrides" "$CONFIG")" = "!!map" ] || return 0

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    obase="${base}.overrides.\"${slug}\""
    [ "$(tag_of "$obase" "$CONFIG")" = "!!map" ] || continue
    has_key "$obase" "dedupe_key" "$CONFIG" || continue
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if has_key "$obase" "dedupe_keys" "$CONFIG" && has_key "${obase}.dedupe_keys" "$s" "$CONFIG"; then
        continue   # the engagement named this slot's key at level 1 — unambiguous
      fi
      warn "W_LAYOUT_DEDUPE_KEY_SHADOWS_SLOT" "${base}.overrides.${slug}.dedupe_key" \
           "slot ${s} — declare ${base}.overrides.${slug}.dedupe_keys.${s} to say which value this slot joins on"
    done <<< "$(ql "${base}.dedupe_keys | keys | .[]" "$CONFIG")"
  done <<< "$(ql "${base}.overrides | keys | .[]" "$CONFIG")"
}

# engagement_layout is wholly optional. Absent means "this firm declared no
# layout", which resolves to the pack defaults and constrains nothing. Present
# means it must be well-formed, because a malformed path template would silently
# point the lifecycle skills at the wrong file.
check_engagement_layout() {
  local base=".engagement_layout" tag f slug obase

  has_key '.' "engagement_layout" "$CONFIG" || return 0

  tag="$(tag_of "$base" "$CONFIG")"
  if [ "$tag" != "!!map" ]; then
    fail "E_LAYOUT_NOT_MAPPING" "$base" "tag: ${tag}"
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    has_key "$base" "$f" "$CONFIG" || fail "E_SCHEMA_KEY_MISSING" "${base}.${f}" "required"
  done <<< "$LAYOUT_REQ"

  # PRESENT -> validate the shape. `tracker_sources: []` is legal and means
  # "declared, none": the firm tracks projects somewhere this pack does not read.
  if has_key "$base" "tracker_sources" "$CONFIG"; then
    tag="$(tag_of "${base}.tracker_sources" "$CONFIG")"
    [ "$tag" = "!!seq" ] || fail "E_LAYOUT_TRACKER_SOURCES_NOT_LIST" "${base}.tracker_sources" "tag: ${tag}"
  fi

  check_dedupe_keys "$base" "$base"

  if has_key "$base" "overrides" "$CONFIG"; then
    tag="$(tag_of "${base}.overrides" "$CONFIG")"
    if [ "$tag" != "!!map" ]; then
      fail "E_LAYOUT_OVERRIDES_NOT_MAPPING" "${base}.overrides" "tag: ${tag}"
    else
      while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        obase="${base}.overrides.\"${slug}\""
        tag="$(tag_of "$obase" "$CONFIG")"
        if [ "$tag" != "!!map" ]; then
          fail "E_LAYOUT_OVERRIDE_NOT_MAPPING" "${base}.overrides.${slug}" "tag: ${tag}"
          continue
        fi
        if has_key "$obase" "tracker_sources" "$CONFIG"; then
          tag="$(tag_of "${obase}.tracker_sources" "$CONFIG")"
          [ "$tag" = "!!seq" ] || \
            fail "E_LAYOUT_TRACKER_SOURCES_NOT_LIST" "${base}.overrides.${slug}.tracker_sources" "tag: ${tag}"
        fi
        check_dedupe_keys "$obase" "${base}.overrides.${slug}"
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          in_list "$f" "$LAYOUT_OVERRIDE_OPT" || \
            warn "W_LAYOUT_FIELD_UNKNOWN" "${base}.overrides.${slug}.${f}" "ignored"
        done <<< "$(ql "${obase} | keys | .[]" "$CONFIG")"
      done <<< "$(ql "${base}.overrides | keys | .[]" "$CONFIG")"
    fi
  fi

  # Unknown layout fields warn rather than fail (forward compatibility, same as
  # bindings): a newer pack may have added a layout field this one cannot use.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! in_list "$f" "$LAYOUT_REQ" && ! in_list "$f" "$LAYOUT_OPT"; then
      warn "W_LAYOUT_FIELD_UNKNOWN" "${base}.${f}" "ignored"
    fi
  done <<< "$(ql "${base} | keys | .[]" "$CONFIG")"

  check_dedupe_key_shadowing
}

check_binding() { # check_binding <slot>
  local slot="$1" base=".slots.${slot}.binding" f val tag caps_tag cap
  local known_caps
  known_caps="$(ql ".slots.\"${slot}\".optional_capabilities[]" "$SCHEMA")"

  tag="$(tag_of "$base" "$CONFIG")"
  if [ "$tag" != "!!map" ]; then
    fail "E_BINDING_NOT_MAPPING" "$base" "tag: ${tag}"
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    has_key "$base" "$f" "$CONFIG" || fail "E_BINDING_FIELD_MISSING" "${base}.${f}" "required"
  done <<< "$BINDING_REQ"

  if has_key "$base" "tool_name" "$CONFIG"; then
    val="$(q "${base}.tool_name" "$CONFIG")"
    if [ -z "$val" ] || [ "$val" = "null" ] || [ "$(tag_of "${base}.tool_name" "$CONFIG")" != "!!str" ]; then
      fail "E_BINDING_TOOL_NAME_INVALID" "${base}.tool_name" "got: ${val}"
    fi
  fi

  if has_key "$base" "connector" "$CONFIG"; then
    val="$(q "${base}.connector" "$CONFIG")"
    if ! in_list "$val" "$CONNECTORS"; then
      fail "E_BINDING_CONNECTOR_INVALID" "${base}.connector" \
           "got: ${val}; allowed: $(printf '%s' "$CONNECTORS" | tr '\n' '|' | sed 's/|$//')"
    fi
  fi

  if has_key "$base" "mapping" "$CONFIG"; then
    tag="$(tag_of "${base}.mapping" "$CONFIG")"
    if [ "$tag" != "!!map" ]; then
      fail "E_BINDING_MAPPING_NOT_MAPPING" "${base}.mapping" "tag: ${tag}"
    elif has_key "${base}.mapping" "capabilities" "$CONFIG"; then
      # PRESENT: validate it. ABSENT: undeclared — no warning, no constraint,
      # the skills probe and degrade. `capabilities: []` means declared-none.
      caps_tag="$(tag_of "${base}.mapping.capabilities" "$CONFIG")"
      if [ "$caps_tag" != "!!seq" ]; then
        fail "E_CAPABILITIES_NOT_LIST" "${base}.mapping.capabilities" "tag: ${caps_tag}"
      else
        while IFS= read -r cap; do
          [ -n "$cap" ] || continue
          in_list "$cap" "$known_caps" || \
            warn "W_CAPABILITY_UNKNOWN" "${base}.mapping.capabilities" "${cap} — not known to this pack version"
        done <<< "$(ql "${base}.mapping.capabilities[]" "$CONFIG")"
      fi
    fi
  fi

  # PRESENCE first. `secret_name: null` written explicitly is DECLARED-NONE —
  # the binding needs no vault credential — and is deliberately not pattern
  # checked. Absent stays undeclared, which is a different thing entirely.
  if has_key "$base" "secret_name" "$CONFIG"; then
    if [ "$(tag_of "${base}.secret_name" "$CONFIG")" != "!!null" ]; then
      val="$(q "${base}.secret_name" "$CONFIG")"
      if ! printf '%s' "$val" | grep -Eq "$SECRET_PATTERN"; then
        fail "E_BINDING_SECRET_NAME_INVALID" "${base}.secret_name" "got: ${val}"
      fi
    fi
  fi

  # Unknown binding fields warn rather than fail (forward compatibility).
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! in_list "$f" "$BINDING_REQ" && ! in_list "$f" "$BINDING_OPT"; then
      warn "W_SLOT_FIELD_UNKNOWN" "${base}.${f}" "ignored"
    fi
  done <<< "$(ql "${base} | keys | .[]" "$CONFIG")"
}

check_pointer() { # check_pointer <slot>
  local slot="$1" base=".slots.${slot}.pointer" f val tag

  tag="$(tag_of "$base" "$CONFIG")"
  if [ "$tag" != "!!map" ]; then
    fail "E_POINTER_NOT_MAPPING" "$base" "tag: ${tag}"
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    has_key "$base" "$f" "$CONFIG" || fail "E_POINTER_FIELD_MISSING" "${base}.${f}" "required"
  done <<< "$POINTER_REQ"

  if has_key "$base" "kind" "$CONFIG"; then
    val="$(q "${base}.kind" "$CONFIG")"
    in_list "$val" "$POINTER_KINDS" || fail "E_POINTER_KIND_INVALID" "${base}.kind" "got: ${val}"
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! in_list "$f" "$POINTER_REQ" && ! in_list "$f" "$POINTER_OPT"; then
      warn "W_SLOT_FIELD_UNKNOWN" "${base}.${f}" "ignored"
    fi
  done <<< "$(ql "${base} | keys | .[]" "$CONFIG")"
}

check_recommendation() { # check_recommendation <slot> <state>
  local slot="$1" state="$2" base=".slots.${slot}.recommended" f val

  if [ "$state" = "bound" ]; then
    fail "E_RECOMMENDATION_ON_BOUND_SLOT" "$base" "slot is already bound"
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! has_key "$base" "$f" "$CONFIG" && [ "$f" = "tool" ]; then
      fail "E_RECOMMENDATION_TOOL_MISSING" "${base}.${f}" "required"
    fi
  done <<< "$REC_REQ"

  # `required` ABSENT resolves to false — the non-constraining direction — and
  # `required: true` is rejected so a recommendation can never become mandatory.
  if has_key "$base" "required" "$CONFIG"; then
    val="$(q "${base}.required" "$CONFIG")"
    if [ "$val" = "true" ]; then
      fail "E_RECOMMENDATION_REQUIRED_TRUE" "${base}.required" "a recommendation is never required"
    fi
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! in_list "$f" "$REC_REQ" && ! in_list "$f" "$REC_OPT"; then
      warn "W_SLOT_FIELD_UNKNOWN" "${base}.${f}" "ignored"
    fi
  done <<< "$(ql "${base} | keys | .[]" "$CONFIG")"
}

# Resolve a slot to bound | empty | undeclared, reading PRESENCE first.
resolve_slot_state() { # resolve_slot_state <slot> -> prints state
  local slot="$1" tag
  if has_key '.slots' "$slot" "$CONFIG"; then
    if has_key ".slots.\"${slot}\"" "pointer" "$CONFIG"; then
      printf 'bound'; return 0
    fi
    if has_key ".slots.\"${slot}\"" "binding" "$CONFIG"; then
      tag="$(tag_of ".slots.${slot}.binding" "$CONFIG")"
      if [ "$tag" = "!!null" ]; then printf 'empty'; else printf 'bound'; fi
      return 0
    fi
    printf 'undeclared'; return 0
  fi
  printf 'undeclared'
}

check_slots() {
  local slot state tag f

  if ! has_key '.' "slots" "$CONFIG"; then
    return 0   # already reported as E_SCHEMA_KEY_MISSING
  fi
  tag="$(tag_of '.slots' "$CONFIG")"
  if [ "$tag" != "!!map" ]; then
    fail "E_SLOTS_NOT_MAPPING" ".slots" "tag: ${tag}"
    return 0
  fi

  # Slots this pack version knows about.
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    state="$(resolve_slot_state "$slot")"

    if [ "$state" = "undeclared" ]; then
      if has_key '.slots' "$slot" "$CONFIG"; then
        warn "W_SLOT_BINDING_UNDECLARED" ".slots.${slot}" "no binding key — unknown, NOT empty"
      else
        warn "W_SLOT_UNDECLARED" ".slots.${slot}" "absent — unknown, NOT empty"
        continue
      fi
    fi

    tag="$(tag_of ".slots.${slot}" "$CONFIG")"
    if [ "$tag" != "!!map" ]; then
      fail "E_SLOT_NOT_MAPPING" ".slots.${slot}" "tag: ${tag}"
      continue
    fi

    if has_key ".slots.\"${slot}\"" "binding" "$CONFIG" && has_key ".slots.\"${slot}\"" "pointer" "$CONFIG"; then
      fail "E_SLOT_DUAL_BINDING" ".slots.${slot}" "binding and pointer are alternatives, not layers"
    fi

    if has_key ".slots.\"${slot}\"" "pointer" "$CONFIG"; then
      check_pointer "$slot"
    fi
    if has_key ".slots.\"${slot}\"" "binding" "$CONFIG" && [ "$state" != "empty" ]; then
      check_binding "$slot"
    fi
    if has_key ".slots.\"${slot}\"" "recommended" "$CONFIG"; then
      check_recommendation "$slot" "$state"
    fi

    while IFS= read -r f; do
      [ -n "$f" ] || continue
      in_list "$f" "$SLOT_FIELDS" || warn "W_SLOT_FIELD_UNKNOWN" ".slots.${slot}.${f}" "ignored"
    done <<< "$(ql ".slots.\"${slot}\" | keys | .[]" "$CONFIG")"
  done <<< "$KNOWN_SLOTS"

  # Slots this pack version does NOT know about: warn, never fail. A config
  # written by a newer pack must still load here.
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    in_list "$slot" "$KNOWN_SLOTS" || \
      warn "W_SLOT_UNKNOWN" ".slots.${slot}" "not known to this pack version — ignored"
  done <<< "$(ql '.slots | keys | .[]' "$CONFIG")"
}

check_credentials() {
  local path leaf key val pat

  # Enforcing check: credential-shaped KEY NAMES anywhere in the config.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    leaf="${path##*.}"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if [ "$leaf" = "$key" ]; then
        fail "E_INLINE_CREDENTIAL_KEY" ".${path}" \
             "reference the vault by name in secret_name instead"
        break
      fi
    done <<< "$DENYLIST"
  done <<< "$(ql '.. | path | join(".")' "$CONFIG")"

  # Advisory check: values that LOOK like credential literals.
  while IFS= read -r val; do
    [ -n "$val" ] || continue
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      if printf '%s' "$val" | grep -Eq -- "$pat"; then
        warn "W_SECRET_VALUE_SHAPE" ".<value>" "matches ${pat}"
        break
      fi
    done <<< "$VALUE_PATTERNS"
  done <<< "$(ql '.. | select(tag == "!!str")' "$CONFIG")"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

[ -f "$CONFIG" ] && [ -r "$CONFIG" ] || die_env "E_CONFIG_NOT_FOUND" "cannot read ${CONFIG}"

if ! yq -e '.' "$CONFIG" >/dev/null 2>&1; then
  printf 'ERROR  E_CONFIG_NOT_YAML  at %s: %s\n' "$CONFIG" "$(describe E_CONFIG_NOT_YAML)"
  exit 1
fi
if [ "$(tag_of '.' "$CONFIG")" != "!!map" ]; then
  printf 'ERROR  E_CONFIG_NOT_MAPPING  at %s: %s\n' "$CONFIG" "$(describe E_CONFIG_NOT_MAPPING)"
  exit 1
fi

say "validate-config.sh — ${CONFIG}"
say "  schema: ${SCHEMA}"

check_top_level
check_engagement_layout
check_slots
check_credentials

# Slot-state summary: the operator sees empty and undeclared as distinct states,
# never collapsed together.
if [ "$QUIET" -eq 0 ] && has_key '.' "slots" "$CONFIG"; then
  say "  slot states:"
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    say "    $(printf '%-12s' "$slot") $(resolve_slot_state "$slot")"
  done <<< "$KNOWN_SLOTS"
fi

if [ "$STRICT" -eq 1 ] && [ "$WARN_COUNT" -gt 0 ]; then
  say "  --strict: promoting ${WARN_COUNT} warning(s) to errors"
  ERR_COUNT=$((ERR_COUNT + WARN_COUNT))
fi

if [ "$ERR_COUNT" -gt 0 ]; then
  say "FAIL   ${ERR_COUNT} error(s), ${WARN_COUNT} warning(s) — ${CONFIG}"
  exit 1
fi

say "PASS   0 errors, ${WARN_COUNT} warning(s) — ${CONFIG}"
exit 0
