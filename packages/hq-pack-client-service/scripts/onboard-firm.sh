#!/usr/bin/env bash
# onboard-firm.sh — the deterministic engine behind the /onboard-firm skill.
#
#   onboard-firm.sh --company <slug> [--root <path>] [--non-interactive]
#                   [--bind <slot>=<tool>:<connector>[:<SECRET_NAME>]]...
#                   [--empty <slot>]... [--skip <slot>]... [--no-auto]
#                   [--secret-names-file <path>] [--mcp-config <path>]...
#                   [--dry-run] [--quiet]
#
# Exit codes
#   0  onboarding applied (or --dry-run completed) and the config validates
#   1  the resulting config failed validate-config.sh
#   2  environment/usage problem
#
# What it does
#   1. Runs detect-tools.sh to propose candidates from settings/, MCP servers
#      and vault secret NAMES.
#   2. Resolves each of the five slots to bound / empty / left-undeclared.
#   3. Writes companies/{firm}/client-service.yaml — by EDITING an existing file
#      in place, never by rewriting one that already answers the question.
#   4. Scaffolds companies/{firm}/clients/ and clients/_templates/engagement.template.md.
#   5. Validates its own output with scripts/validate-config.sh.
#
# This script NEVER prompts. Interactive onboarding is the skill's job: it asks,
# then calls this with explicit --bind/--empty flags. Anything not decided on the
# command line is auto-resolved from detection unless --no-auto is passed.
#
# Idempotency contract
#   A slot that is already `bound` or already `empty` is PRESERVED byte for byte.
#   Only `undeclared` slots are ever written. A second run with the same inputs
#   makes zero edits, so the file is unchanged rather than regenerated. Nothing
#   written here carries a timestamp, for exactly that reason.
#
# Credential hygiene
#   Secret NAMES flow through this script; secret VALUES never do. Nothing here
#   resolves, reads, prints or stores a credential value.
#
# Policy hq-absent-field-never-means-constraining-value
#   `empty` is written positively as `binding: null`. A slot this run could not
#   decide is LEFT ABSENT and reported as needing a decision — it is never
#   downgraded to `empty`, because "nobody asked yet" is not "the firm said no".
#
# Policy hq-auto-select-skips-underscore-pseudo-dirs
#   Every directory listing excludes `_`-prefixed pseudo-dirs by a general rule.
#   This script creates `clients/_templates/`, so the trap is live here.
#
# Policy hq-bash-set-e-status-returns
#   Functions returning non-zero as a status signal are called inside `if` or
#   with `|| rc=$?`, never bare under `set -e`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DETECT="${SCRIPT_DIR}/detect-tools.sh"
VALIDATE="${SCRIPT_DIR}/validate-config.sh"
SCHEMA="${PACK_DIR}/knowledge/client-service/client-service.schema.yaml"

COMPANY=""
ROOT=""
AUTO=1
DRY_RUN=0
QUIET=0
SECRET_NAMES_FILE=""
MCP_EXTRA=()

SLOTS='crm
billing
agreements
portal
transcripts'

# The ONLY vendor names this pack emits, and only ever as an optional hint on an
# EMPTY slot. `required` is written as false and may never be true (the schema
# rejects it). Deleting a line here removes a suggestion and nothing else.
RECOMMENDATIONS='crm|attio|No CRM was detected. Attio is one low-lift option if the firm ever wants a pipeline mirror; the slot is fully supported empty.
billing|stripe|No billing tool was detected. Stripe is one option if the firm ever wants issued invoices; drafts are written locally until then.'

die_env() { printf 'ERROR  %s  %s\n' "$1" "$2" >&2; exit 2; }
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
DECISIONS="$(mktemp -t cs-onboard-dec.XXXXXX)"
REPORT="$(mktemp -t cs-onboard-rep.XXXXXX)"
PLAN="$(mktemp -t cs-onboard-plan.XXXXXX)"
cleanup() { rm -f "$DECISIONS" "$REPORT" "$PLAN"; }
trap cleanup EXIT

is_known_slot() { grep -Fxq -- "$1" <<< "$SLOTS"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --company) COMPANY="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --non-interactive) AUTO=1; shift ;;   # accepted for clarity; auto is the default
    --no-auto) AUTO=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --secret-names-file) SECRET_NAMES_FILE="${2:-}"; shift 2 ;;
    --mcp-config) MCP_EXTRA+=("${2:-}"); shift 2 ;;
    --bind)
      spec="${2:-}"; shift 2
      slot="${spec%%=*}"; rest="${spec#*=}"
      tool="${rest%%:*}"; rest2="${rest#*:}"
      conn="${rest2%%:*}"
      if [ "$rest2" = "$conn" ]; then sec="-"; else sec="${rest2#*:}"; fi
      [ -n "$slot" ] && [ "$slot" != "$spec" ] || die_env "E_USAGE" "--bind needs <slot>=<tool>:<connector>[:<SECRET_NAME>]"
      if ! is_known_slot "$slot"; then die_env "E_USAGE" "--bind: unknown slot: ${slot}"; fi
      [ -n "$tool" ] || die_env "E_USAGE" "--bind: empty tool name for ${slot}"
      case "$conn" in mcp|cli|api) : ;; *) die_env "E_USAGE" "--bind: connector must be mcp|cli|api, got: ${conn}" ;; esac
      printf '%s\tbind\t%s\t%s\t%s\n' "$slot" "$tool" "$conn" "$sec" >> "$DECISIONS" ;;
    --empty)
      slot="${2:-}"; shift 2
      if ! is_known_slot "$slot"; then die_env "E_USAGE" "--empty: unknown slot: ${slot}"; fi
      printf '%s\tempty\t-\t-\t-\n' "$slot" >> "$DECISIONS" ;;
    --skip)
      slot="${2:-}"; shift 2
      if ! is_known_slot "$slot"; then die_env "E_USAGE" "--skip: unknown slot: ${slot}"; fi
      printf '%s\tskip\t-\t-\t-\n' "$slot" >> "$DECISIONS" ;;
    -h|--help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die_env "E_USAGE" "unknown argument: $1" ;;
  esac
done

[ -n "$COMPANY" ] || die_env "E_USAGE" "--company <slug> is required"
command -v yq >/dev/null 2>&1 || die_env "E_ENV_YQ_MISSING" "yq (mikefarah v4) is required"
[ -x "$DETECT" ] || [ -f "$DETECT" ] || die_env "E_ENV_DETECT_MISSING" "no detect-tools.sh at ${DETECT}"
[ -f "$VALIDATE" ] || die_env "E_ENV_VALIDATOR_MISSING" "no validate-config.sh at ${VALIDATE}"

if [ -z "$ROOT" ]; then
  ROOT="$(cd -- "${PACK_DIR}/../../.." && pwd)"
  [ -d "${ROOT}/companies" ] || ROOT="$PWD"
fi
CO_DIR="${ROOT}/companies/${COMPANY}"
[ -d "$CO_DIR" ] || die_env "E_COMPANY_NOT_FOUND" \
  "no company at ${CO_DIR} — onboarding binds the pack to an EXISTING company and never creates a tenant"

CONFIG="${CO_DIR}/client-service.yaml"
CLIENTS_DIR="${CO_DIR}/clients"
TEMPLATES_DIR="${CLIENTS_DIR}/_templates"
TEMPLATE="${TEMPLATES_DIR}/engagement.template.md"

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
detect_args=(--company "$COMPANY" --root "$ROOT" --format tsv --quiet)
if [ -n "$SECRET_NAMES_FILE" ]; then detect_args+=(--secret-names-file "$SECRET_NAMES_FILE"); fi
if [ "${#MCP_EXTRA[@]}" -gt 0 ]; then
  for f in "${MCP_EXTRA[@]}"; do detect_args+=(--mcp-config "$f"); done
fi

drc=0
bash "$DETECT" "${detect_args[@]}" > "$REPORT" || drc=$?
[ "$drc" -eq 0 ] || die_env "E_DETECT_FAILED" "detect-tools.sh exited ${drc}"

# ---------------------------------------------------------------------------
# existing config state — the tri-state, read exactly as the schema defines it
# ---------------------------------------------------------------------------
yq_q() { yq -r "$1" "$CONFIG" 2>/dev/null || true; }

# The schema owns the shape of a writable secret_name; this script reads it out
# rather than restating it, so the two cannot drift.
SECRET_PATTERN="$(yq -r '.binding.fields.secret_name.pattern // ""' "$SCHEMA" 2>/dev/null || true)"
if [ -z "$SECRET_PATTERN" ] || [ "$SECRET_PATTERN" = "null" ]; then
  SECRET_PATTERN='^[A-Za-z][A-Za-z0-9_.-]{0,63}(/[A-Za-z][A-Za-z0-9_.-]{0,63})*$'
fi

# Returns non-zero as a status signal — only ever called inside `if`.
# Slash-scoped vault names (SCOPE/KEY) are admitted by the schema, so the common
# HQ shape writes straight through. A name the pattern still rejects is NOT
# written and the operator is told to record it by hand: omitting it leaves
# secret_name UNDECLARED, which per the contract means "unknown, ask" — not
# "no auth needed".
secret_name_writable() {
  [ -n "$1" ] && [ "$1" != "-" ] || return 1
  grep -Eq -- "$SECRET_PATTERN" <<< "$1"
}

slot_state() { # slot_state <slot> -> bound | empty | undeclared
  local slot="$1" tag
  [ -f "$CONFIG" ] || { printf 'undeclared'; return 0; }
  if [ "$(yq_q ".slots // {} | has(\"${slot}\")")" != "true" ]; then
    printf 'undeclared'; return 0
  fi
  if [ "$(yq_q ".slots.${slot} | has(\"pointer\")")" = "true" ]; then
    printf 'bound'; return 0
  fi
  if [ "$(yq_q ".slots.${slot} | has(\"binding\")")" = "true" ]; then
    tag="$(yq_q ".slots.${slot}.binding | tag")"
    if [ "$tag" = "!!null" ]; then printf 'empty'; else printf 'bound'; fi
    return 0
  fi
  printf 'undeclared'
}

decision_for() { # decision_for <slot> -> "<action>\t<tool>\t<conn>\t<secret>" or empty
  awk -F'\t' -v s="$1" '$1 == s { print $2 "\t" $3 "\t" $4 "\t" $5; exit }' "$DECISIONS"
}

candidates_for() { # candidates_for <slot> -> auto-bindable rows only
  awk -F'\t' -v s="$2" '$1 == "CANDIDATE" && $2 == s && $7 == "true" { print $3 "\t" $4 "\t" $5 }' "$1"
}

candidates_all() { # candidates_all <report> <slot>
  awk -F'\t' -v s="$2" '$1 == "CANDIDATE" && $2 == s { print $3 }' "$1"
}

recommendation_for() { # recommendation_for <slot> -> "<tool>\t<reason>" or empty
  awk -F'|' -v s="$1" '$1 == s { print $2 "\t" $3; exit }' <<< "$RECOMMENDATIONS"
}

# ---------------------------------------------------------------------------
# plan — decide every slot before touching disk
# PLAN rows: slot \t action \t tool \t connector \t secret \t why
# actions: preserve-bound | preserve-empty | bind | empty | undecided
# ---------------------------------------------------------------------------
while IFS= read -r slot; do
  [ -n "$slot" ] || continue
  state="$(slot_state "$slot")"
  case "$state" in
    bound) printf '%s\tpreserve-bound\t-\t-\t-\t%s\n' "$slot" "already bound in the existing config" >> "$PLAN"; continue ;;
    empty) printf '%s\tpreserve-empty\t-\t-\t-\t%s\n' "$slot" "already declared empty in the existing config" >> "$PLAN"; continue ;;
  esac

  dec="$(decision_for "$slot")"
  if [ -n "$dec" ]; then
    IFS=$'\t' read -r action dtool dconn dsec <<< "$dec"
    case "$action" in
      bind)  printf '%s\tbind\t%s\t%s\t%s\t%s\n' "$slot" "$dtool" "$dconn" "$dsec" "bound by an explicit operator decision" >> "$PLAN"; continue ;;
      empty) printf '%s\tempty\t-\t-\t-\t%s\n' "$slot" "left empty by an explicit operator decision" >> "$PLAN"; continue ;;
      skip)  printf '%s\tundecided\t-\t-\t-\t%s\n' "$slot" "explicitly skipped — stays undeclared, which is unknown, not empty" >> "$PLAN"; continue ;;
    esac
  fi

  if [ "$AUTO" -eq 0 ]; then
    printf '%s\tundecided\t-\t-\t-\t%s\n' "$slot" "--no-auto: nothing decided this run" >> "$PLAN"
    continue
  fi

  rows="$(candidates_for "$REPORT" "$slot")"
  n=0
  if [ -n "$rows" ]; then n="$(wc -l <<< "$rows" | tr -d ' ')"; fi
  if [ "$n" -eq 1 ]; then
    IFS=$'\t' read -r ctool cconn csec <<< "$rows"
    printf '%s\tbind\t%s\t%s\t%s\t%s\n' "$slot" "$ctool" "$cconn" "$csec" "one detected candidate with a known transport" >> "$PLAN"
  elif [ "$n" -gt 1 ]; then
    printf '%s\tundecided\t-\t-\t-\t%s\n' "$slot" \
      "${n} detected candidates — ambiguous, so nothing is assumed; stays undeclared" >> "$PLAN"
  else
    allc="$(candidates_all "$REPORT" "$slot")"
    if [ -n "$allc" ]; then
      printf '%s\tundecided\t-\t-\t-\t%s\n' "$slot" \
        "candidate(s) detected but the transport is unknown — ask, never guess" >> "$PLAN"
    else
      printf '%s\tempty\t-\t-\t-\t%s\n' "$slot" "nothing detected; default is an explicitly empty slot" >> "$PLAN"
    fi
  fi
done <<< "$SLOTS"

# ---------------------------------------------------------------------------
# report the plan
# ---------------------------------------------------------------------------
say "onboard-firm — companies/${COMPANY}"
say "  config:   ${CONFIG}"
say "  detection sources:"
while IFS=$'\t' read -r kind name status detail; do
  [ "${kind:-}" = "SOURCE" ] || continue
  say "    $(printf '%-20s' "$name") ${status}  (${detail})"
done < "$REPORT"
say "  plan:"
while IFS=$'\t' read -r slot action tool conn sec why; do
  [ -n "${slot:-}" ] || continue
  case "$action" in
    bind)
      secnote=""
      if secret_name_writable "$sec"; then
        secnote=", secret_name=${sec}"
      elif [ "$sec" != "-" ] && [ -n "$sec" ]; then
        secnote=", secret_name NOT written (${sec} is not a schema-valid vault name — record it by hand)"
      fi
      say "    $(printf '%-12s' "$slot") bind -> ${tool} (${conn}${secnote}) — ${why}" ;;
    *)    say "    $(printf '%-12s' "$slot") ${action} — ${why}" ;;
  esac
done < "$PLAN"

if [ "$DRY_RUN" -eq 1 ]; then
  say "  --dry-run: nothing written"
  exit 0
fi

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
CHANGES=0

if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<YAML
# client-service.yaml — this firm's adapter-slot bindings.
#
# Written by /onboard-firm. Safe to hand-edit; re-running onboarding only fills
# slots that are still UNDECLARED and never rewrites a slot you have answered.
#
# Slot states (knowledge/client-service/adapter-contracts.md):
#   bound       slot present with a \`binding:\` mapping (or a \`pointer:\`)
#   empty       slot present with \`binding: null\` written explicitly — a decision
#   undeclared  slot key absent — unknown, NOT empty; onboarding asks about it
#
# Secrets are referenced by VAULT NAME ONLY. A credential value in this file is
# a validation error, not a style problem.
schema: hq.client-service.config
schema_version: 1
firm: ${COMPANY}
description: Client-service adapter bindings for ${COMPANY}.
YAML
  CHANGES=$((CHANGES + 1))
  say "  created ${CONFIG}"
else
  # Backfill required top-level keys only when ABSENT. Presence is checked
  # first; an existing value is never overwritten.
  for key in schema schema_version firm; do
    if [ "$(yq_q "has(\"${key}\")")" != "true" ]; then
      case "$key" in
        schema)         yq -i '.schema = "hq.client-service.config"' "$CONFIG" ;;
        schema_version) yq -i '.schema_version = 1' "$CONFIG" ;;
        firm)           yq -i ".firm = \"${COMPANY}\"" "$CONFIG" ;;
      esac
      CHANGES=$((CHANGES + 1))
      say "  backfilled missing top-level key: ${key}"
    fi
  done
fi

# `slots` is a required top-level key. A run that decides nothing (--no-auto, or
# every slot deferred) must still leave a VALID config behind, so the key is
# created empty when absent. An empty `slots` mapping declares nothing: all five
# slots resolve to `undeclared`, which is unknown — not empty.
if [ "$(yq_q 'has("slots")')" != "true" ]; then
  yq -i '.slots = {}' "$CONFIG"
  CHANGES=$((CHANGES + 1))
fi

while IFS=$'\t' read -r slot action tool conn sec why; do
  [ -n "${slot:-}" ] || continue
  case "$action" in
    bind)
      yq -i ".slots.${slot}.binding.tool_name = \"${tool}\"" "$CONFIG"
      yq -i ".slots.${slot}.binding.connector = \"${conn}\"" "$CONFIG"
      if secret_name_writable "$sec"; then
        # NAME ONLY. Resolved through the HQ secret workflow at call time.
        yq -i ".slots.${slot}.binding.secret_name = \"${sec}\"" "$CONFIG"
      elif [ "$sec" != "-" ] && [ -n "$sec" ]; then
        say "  NOTE  ${slot}: detected credential name '${sec}' does not match the schema's secret_name pattern, so it was NOT written. Add it by hand once the name is schema-valid; the slot is bound either way."
      fi
      # `mapping` is deliberately not written: an absent capabilities list means
      # UNDECLARED, so the lifecycle skills probe and degrade rather than
      # treating silence as "unsupported".
      CHANGES=$((CHANGES + 1))
      ;;
    empty)
      # Empty written positively. Absence could never express this.
      yq -i ".slots.${slot}.binding = null" "$CONFIG"
      rec="$(recommendation_for "$slot")"
      if [ -n "$rec" ]; then
        IFS=$'\t' read -r rtool rreason <<< "$rec"
        yq -i ".slots.${slot}.recommended.tool = \"${rtool}\"" "$CONFIG"
        yq -i ".slots.${slot}.recommended.reason = \"${rreason}\"" "$CONFIG"
        # Never true. The schema rejects `required: true` outright.
        yq -i ".slots.${slot}.recommended.required = false" "$CONFIG"
        yq -i ".slots.${slot}.notes = \"Optional suggestion above was surfaced at onboarding and not taken. Recorded so it is offered once, not every run. Lifecycle skills degrade to the documented local behaviour for this slot.\"" "$CONFIG"
      else
        yq -i ".slots.${slot}.notes = \"Empty by decision at onboarding. Lifecycle skills degrade to the documented local behaviour for this slot.\"" "$CONFIG"
      fi
      CHANGES=$((CHANGES + 1))
      ;;
    *) : ;;   # preserve-* and undecided touch nothing
  esac
done < "$PLAN"

# ---------------------------------------------------------------------------
# scaffold clients/ and the de-branded engagement template
# ---------------------------------------------------------------------------
if [ ! -d "$CLIENTS_DIR" ]; then
  mkdir -p "$CLIENTS_DIR"
  CHANGES=$((CHANGES + 1))
  say "  created ${CLIENTS_DIR}/"
fi
if [ ! -d "$TEMPLATES_DIR" ]; then
  mkdir -p "$TEMPLATES_DIR"
  CHANGES=$((CHANGES + 1))
  say "  created ${TEMPLATES_DIR}/"
fi
if [ ! -f "$TEMPLATE" ]; then
  cat > "$TEMPLATE" <<'TEMPLATE_EOF'
---
# Ontology entities — leave empty on creation. If this HQ runs an ontology
# gardener it reconciles this block; otherwise it stays empty and harmless.
entities: []
---
# {{CLIENT_NAME}} — Engagement State (canonical)

> **This file is the source of truth for the {{CLIENT_NAME}} engagement.** Every
> other surface — a CRM record, a client portal, a deck, an invoice — is a
> derived view. Update this file first, then mirror outward. A mirror that
> disagrees with this file is wrong, and nothing that fails to mirror may change
> the state recorded here.
>
> **Never invent engagement facts.** Anything not yet confirmed stays an explicit
> `TODO:` line until a real source — a call, an email, a signed document — fills
> it. Public research about the client is allowed but must be labelled as
> research, never asserted as engagement state.
>
> **Client-visible vs firm-internal.** Everything above "Firm-internal
> coordination" may reach the client. Nothing below it ever does.

- **Client:** {{CLIENT_NAME}} — TODO: one line on who they are and what they do
- **Engagement:** {{FIRM_NAME}} — TODO: what this firm is delivering
- **Stage:** TODO: free text, this firm's own words (e.g. `intro`, `proposal`,
  `active`, `paused`, `closed`). Not an enum, and not owned by any external tool.
- **Cadence:** TODO: how often, with whom, on what channel
- **First target:** TODO: the first concrete deliverable

## Client context (research — NOT engagement state)

> Background pulled from public or shared sources to orient the team. Context,
> not commitments. Cite the source.

- TODO: industry, product, size
- TODO: notable facts + where each came from

## Contacts

| Name | Role | Email | Side |
|---|---|---|---|
| TODO | TODO | TODO | client |
| TODO | TODO | TODO | firm |

## Commercials

> Amounts and dates recorded here whether or not a billing tool is bound. With
> an empty billing slot this section is the only record, and invoice drafts are
> written into this engagement folder rather than sent.

- **Agreement:** TODO: which agreement governs this, and where the executed copy lives
- **Fee / rate:** TODO
- **Billing schedule:** TODO
- **Outstanding:** TODO: what is owed, as of when

## Decisions

- TODO: dated decisions as they happen — **YYYY-MM-DD** decision + why

## Anchor — current state

TODO: one paragraph on where the engagement stands right now and whose court the
ball is in. Rewrite this in place; do not append.

## Awaiting client (owner-tagged)

- TODO: **Name:** the ask, and since when

## Timeline (most recent first)

- **{{TODAY}}** Engagement scaffolded from the client-service engagement
  template. No engagement facts yet — see the TODOs above.

## Deliverables and shared artifacts

> References only — a link, a path, a document id. Work product lives in
> whatever tool made it; this file records that it exists and where.

| Date | Artifact | Where it lives | Client-visible |
|---|---|---|---|
| TODO | TODO | TODO | yes / no |

## Calls

> With a bound transcripts source, entries link to captured calls. With an empty
> or pointer-bound slot, they are whatever a human pastes in.

- TODO: **YYYY-MM-DD** call, who attended, link or note

## Firm-internal coordination (NEVER client-visible)

- TODO: back-channel notes, prep, access and credential work, and anything that
  must not reach a client surface.
- Research provenance: where the "Client context" facts came from, who pulled
  them, and when, so a teammate can re-verify.
TEMPLATE_EOF
  CHANGES=$((CHANGES + 1))
  say "  created ${TEMPLATE}"
fi

# Existing client engagements, for the operator's benefit. Leading-underscore
# pseudo-dirs (this pack just created `_templates/`) are excluded by a general
# rule — never a named special case for the directory that exists today.
EXISTING=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  base="$(basename -- "$entry")"
  case "$base" in
    _*|.*) continue ;;
  esac
  EXISTING+=("$base")
done <<< "$(find "$CLIENTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort || true)"

if [ "${#EXISTING[@]}" -eq 0 ]; then
  say "  existing client engagements: none"
else
  say "  existing client engagements: ${EXISTING[*]}"
fi

# ---------------------------------------------------------------------------
# validate our own output
# ---------------------------------------------------------------------------
vrc=0
VOUT="$(bash "$VALIDATE" "$CONFIG" 2>&1)" || vrc=$?
say "$VOUT"

src=0
bash "$VALIDATE" --strict --quiet "$CONFIG" >/dev/null 2>&1 || src=$?

if [ "$vrc" -ne 0 ]; then
  say "FAIL   onboarding wrote a config that does not validate — nothing else was changed"
  exit 1
fi

if [ "$CHANGES" -eq 0 ]; then
  say "OK     no changes — every slot was already declared and the scaffold already existed (idempotent re-run)"
else
  say "OK     ${CHANGES} change(s) applied"
fi
if [ "$src" -eq 0 ]; then
  say "OK     --strict clean: every slot is declared (bound or explicitly empty)"
else
  say "NOTE   --strict is not clean: at least one slot is still UNDECLARED (unknown, not empty). Re-run /onboard-firm and answer it."
fi
exit 0
