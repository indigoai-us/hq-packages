#!/usr/bin/env bash
# slot-state.sh — resolve a firm's adapter slots to bound | empty | undeclared.
#
#   slot-state.sh --config <client-service.yaml> [--slot <name>|all] [--format text|kv]
#   slot-state.sh --firm <slug> [--slot <name>|all] [--format text|kv]
#
# This script is READ-ONLY BY CONSTRUCTION. It opens the config, prints a state
# report, and exits. It creates no files, no directories and no temp files, and
# it never calls a firm's tooling. Every lifecycle skill calls it (or reads the
# config the same way) BEFORE touching an external system, so the tri-state is
# resolved once, in one place, with the same semantics as
# ../../../scripts/validate-config.sh.
#
# The tri-state is the whole point (see adapter-contracts.md):
#   bound      slot key present, `binding:` present with a mapping, or `pointer:`
#   empty      slot key present, `binding: null` written EXPLICITLY — a decision
#   undeclared slot key absent, or present with no `binding` key — unknown
# `empty` is NEVER inferred from absence. Policy:
# hq-absent-field-never-means-constraining-value.
#
# Exit codes
#   0  the config was read and every requested slot reported (whatever its state)
#   2  environment or usage problem (named, on stderr)
#
# A non-bound slot is NOT an error condition. It is a supported, permanent end
# state, and it exits 0 so a caller under `set -e` degrades instead of aborting.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"
SCHEMA_DEFAULT="${PACK_DIR}/knowledge/client-service/client-service.schema.yaml"

# Built-in fallback slot list for this pack version, used only when the schema
# file cannot be found. Kept in sync with the schema by the pack, never by hand
# at a call site.
BUILTIN_SLOTS="crm
billing
agreements
portal
transcripts"

CONFIG=""
FIRM=""
WANT_SLOT="all"
FORMAT="text"
SCHEMA=""

die_env() { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --firm)   FIRM="${2:-}";   shift 2 ;;
    --slot)   WANT_SLOT="${2:-all}"; shift 2 ;;
    --format) FORMAT="${2:-text}"; shift 2 ;;
    --schema) SCHEMA="${2:-}"; shift 2 ;;
    -h|--help)
      printf 'usage: slot-state.sh (--config <file> | --firm <slug>) [--slot <name>|all] [--format text|kv]\n'
      exit 0 ;;
    *) die_env "E_USAGE" "unknown argument: $1" ;;
  esac
done

command -v yq >/dev/null 2>&1 || die_env "E_ENV_YQ_MISSING" "yq (mikefarah v4) is required to read the firm config"

if [ -z "$CONFIG" ]; then
  [ -n "$FIRM" ] || die_env "E_USAGE" "one of --config or --firm is required"
  CONFIG="companies/${FIRM}/client-service.yaml"
fi

case "$FORMAT" in text|kv) ;; *) die_env "E_USAGE" "--format must be text or kv" ;; esac

if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
  # A missing firm config is not a crash: it means the firm never onboarded, so
  # EVERY slot is undeclared. Report that and exit 0 so callers degrade.
  printf 'config: %s\n' "$CONFIG"
  printf 'config_state: missing\n'
  printf 'note: no firm config was found, so every slot is UNDECLARED (unknown, not empty). Run /onboard-firm to declare the firm'"'"'s slots.\n'
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ "$WANT_SLOT" != "all" ] && [ "$WANT_SLOT" != "$s" ]; then continue; fi
    if [ "$FORMAT" = "kv" ]; then
      printf 'slot=%s state=undeclared writes=none\n' "$s"
    else
      printf '\nslot: %s\nstate: undeclared\nmessage: %s slot is not configured — this firm has no client-service.yaml, so the question was never answered. No writes were made.\nwrites: none\n' "$s" "$s"
    fi
  done <<< "$BUILTIN_SLOTS"
  exit 0
fi

yq -e '.' "$CONFIG" >/dev/null 2>&1 || die_env "E_CONFIG_NOT_YAML" "not parseable YAML: ${CONFIG}"

SCHEMA="${SCHEMA:-$SCHEMA_DEFAULT}"
if [ -f "$SCHEMA" ]; then
  SLOTS="$(yq -r '.slots | keys | .[]' "$SCHEMA" 2>/dev/null || printf '%s' "$BUILTIN_SLOTS")"
  SCHEMA_NOTE="$SCHEMA"
else
  SLOTS="$BUILTIN_SLOTS"
  SCHEMA_NOTE="(not found at ${SCHEMA}; using this pack version's built-in slot list)"
fi
[ -n "$SLOTS" ] || SLOTS="$BUILTIN_SLOTS"

q() { yq -r "$1" "$CONFIG" 2>/dev/null || printf ''; }

has_key() { # has_key <parent-expr> <key>  — PRESENCE only, value irrelevant
  [ "$(q "${1} | has(\"${2}\")")" = "true" ]
}

resolve_slot_state() { # -> bound | empty | undeclared
  local slot="$1" tag
  if has_key '.slots' "$slot"; then
    if has_key ".slots.\"${slot}\"" "pointer"; then printf 'bound'; return 0; fi
    if has_key ".slots.\"${slot}\"" "binding"; then
      tag="$(q ".slots.\"${slot}\".binding | tag")"
      if [ "$tag" = "!!null" ]; then printf 'empty'; else printf 'bound'; fi
      return 0
    fi
    printf 'undeclared'; return 0
  fi
  printf 'undeclared'
}

message_for() { # message_for <slot> <state>
  local slot="$1" state="$2"
  case "$state" in
    bound)
      printf '%s slot is configured. Call the contract operations for this slot.' "$slot" ;;
    empty)
      printf '%s slot is not configured: the firm has explicitly declared it runs no %s tool (binding: null). Taking the documented degrade path for this slot. No external writes were made.' "$slot" "$slot" ;;
    undeclared)
      printf '%s slot is not configured: this config never declared a %s binding, so the state is UNKNOWN, not empty. No external writes were made. Run /onboard-firm to declare it, or write `binding: null` to record that the firm runs no %s tool.' "$slot" "$slot" "$slot" ;;
  esac
}

FIRM_SLUG="$(q '.firm')"
[ "$FIRM_SLUG" = "null" ] && FIRM_SLUG=""

if [ "$FORMAT" = "text" ]; then
  printf 'config: %s\n' "$CONFIG"
  [ -n "$FIRM_SLUG" ] && printf 'firm: %s\n' "$FIRM_SLUG"
  printf 'schema: %s\n' "$SCHEMA_NOTE"
fi

FOUND=0
while IFS= read -r slot; do
  [ -n "$slot" ] || continue
  if [ "$WANT_SLOT" != "all" ] && [ "$WANT_SLOT" != "$slot" ]; then continue; fi
  FOUND=1
  state="$(resolve_slot_state "$slot")"

  if [ "$FORMAT" = "kv" ]; then
    printf 'slot=%s state=%s writes=none\n' "$slot" "$state"
    continue
  fi

  printf '\nslot: %s\n' "$slot"
  printf 'state: %s\n' "$state"
  printf 'message: %s\n' "$(message_for "$slot" "$state")"

  if [ "$state" = "bound" ]; then
    tool="$(q ".slots.\"${slot}\".binding.tool_name")"
    conn="$(q ".slots.\"${slot}\".binding.connector")"
    if [ -n "$tool" ] && [ "$tool" != "null" ]; then
      printf 'binding: tool_name=%s connector=%s\n' "$tool" "$conn"
    fi
    if has_key ".slots.\"${slot}\"" "pointer"; then
      printf 'binding: pointer kind=%s location=%s (list_calls and other polling operations are UNSUPPORTED here — say so, never fabricate)\n' \
        "$(q ".slots.\"${slot}\".pointer.kind")" "$(q ".slots.\"${slot}\".pointer.location")"
    fi
    if has_key ".slots.\"${slot}\".binding" "secret_name"; then
      if [ "$(q ".slots.\"${slot}\".binding.secret_name | tag")" = "!!null" ]; then
        printf 'secret: declared-none (secret_name: null) — this binding needs no vault credential; do not ask for one\n'
      else
        printf 'secret: referenced by vault NAME only — resolve it through the HQ secret workflow at call time\n'
      fi
    fi
  elif [ "$state" = "empty" ] && has_key ".slots.\"${slot}\"" "recommended"; then
    printf 'recommendation: %s — %s (surface ONCE, as an option; never required; record the decline)\n' \
      "$(q ".slots.\"${slot}\".recommended.tool")" "$(q ".slots.\"${slot}\".recommended.reason")"
  fi

  printf 'writes: none\n'
done <<< "$SLOTS"

if [ "$FOUND" -eq 0 ]; then
  die_env "E_USAGE" "unknown slot '${WANT_SLOT}' — known slots: $(printf '%s' "$SLOTS" | tr '\n' ' ')"
fi

exit 0
