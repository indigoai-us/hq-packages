#!/usr/bin/env bash
# run-e2e.sh — the US-004 end-to-end test.
#
#   "Given a firm config with only the billing slot bound, when deal-pipeline is
#    invoked, then it reports the crm slot as not configured and makes no writes."
#
# Both halves are asserted mechanically:
#   1. the not-configured report — deal-pipeline's step 0 (the slot resolver)
#      must print a crm state that is not `bound`, in the tri-state's own words,
#      distinguishing `empty` from `undeclared`;
#   2. no writes — every file in the worker tree AND in a scratch firm workspace
#      (engagement folder + report folder, exactly where a rogue write would
#      land) is checksummed before and after. The manifests must be identical.
#
# Usage: bash run-e2e.sh        (from anywhere; paths resolve from this file)
# Exit:  0 all assertions passed, 1 an assertion failed, 2 environment problem.

set -euo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKER_DIR="$(cd -- "${TESTS_DIR}/.." && pwd -P)"
PACK_DIR="$(cd -- "${WORKER_DIR}/../.." && pwd -P)"
RESOLVER="${WORKER_DIR}/scripts/slot-state.sh"
LAYOUT="${WORKER_DIR}/scripts/engagement-layout.sh"
VALIDATOR="${PACK_DIR}/scripts/validate-config.sh"

FIXTURE_EMPTY="${TESTS_DIR}/firm-billing-only.yaml"
FIXTURE_UNDECLARED="${TESTS_DIR}/firm-billing-only-crm-undeclared.yaml"
FIXTURE_LAYOUT="${TESTS_DIR}/firm-layout-overrides.yaml"
FIXTURE_SLOTKEYS="${TESTS_DIR}/firm-slot-dedupe-keys.yaml"
FIXTURE_SLOTKEYS_BAD="${TESTS_DIR}/firm-slot-dedupe-keys-malformed.yaml"

command -v yq >/dev/null 2>&1 || { echo "E_ENV_YQ_MISSING: yq is required" >&2; exit 2; }
command -v shasum >/dev/null 2>&1 || { echo "E_ENV: shasum is required" >&2; exit 2; }

FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }

# --- scratch firm workspace: where a rogue write would actually land ---------
SCRATCH="$(mktemp -d -t client-services-e2e)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "${SCRATCH}/clients/example-client" "${SCRATCH}/reports"
cat > "${SCRATCH}/clients/example-client/engagement.md" <<'EOF'
# Engagement — Example Client

status: pre-signature
stage: Intro call done
contacts:
  - TODO:
EOF

manifest() { # checksum every file under the worker tree + the scratch workspace
  ( cd / && find "$WORKER_DIR" "$SCRATCH" -type f -print0 | sort -z | xargs -0 shasum -a 256 )
}

BEFORE="$(manifest)"

echo "US-004 E2E — deal-pipeline against a billing-only firm config"
echo "  worker:  ${WORKER_DIR}"
echo "  scratch: ${SCRATCH}"
echo

# --- 0. the fixtures must be valid configs ----------------------------------
echo "[0] fixtures validate against the frozen schema"
for f in "$FIXTURE_EMPTY" "$FIXTURE_UNDECLARED"; do
  if out="$(bash "$VALIDATOR" "$f" 2>&1)"; then
    pass "$(basename "$f") — $(printf '%s' "$out" | tail -1)"
  else
    fail "$(basename "$f") did not validate:"; printf '%s\n' "$out"
  fi
done
echo

# --- 1. deal-pipeline step 0, crm EMPTY -------------------------------------
echo "[1] deal-pipeline step 0 — crm slot resolution (crm: binding: null)"
OUT_EMPTY="$(bash "$RESOLVER" --config "$FIXTURE_EMPTY" --slot crm)"
printf '%s\n' "$OUT_EMPTY" | sed 's/^/      /'
grep -q '^state: empty$'            <<< "$OUT_EMPTY" && pass "crm resolves to empty (not bound)" || fail "crm did not resolve to empty"
grep -q 'crm slot is not configured' <<< "$OUT_EMPTY" && pass "reports the crm slot as NOT CONFIGURED" || fail "no not-configured report for crm"
grep -q '^writes: none$'            <<< "$OUT_EMPTY" && pass "declares writes: none" || fail "did not declare writes: none"
echo

# --- 2. deal-pipeline step 0, crm UNDECLARED --------------------------------
echo "[2] deal-pipeline step 0 — crm slot absent entirely (undeclared, NOT empty)"
OUT_UNDECL="$(bash "$RESOLVER" --config "$FIXTURE_UNDECLARED" --slot crm)"
printf '%s\n' "$OUT_UNDECL" | sed 's/^/      /'
grep -q '^state: undeclared$' <<< "$OUT_UNDECL" && pass "crm resolves to undeclared" || fail "crm did not resolve to undeclared"
grep -q 'UNKNOWN, not empty'  <<< "$OUT_UNDECL" && pass "undeclared is reported as distinct from empty" || fail "undeclared was collapsed into empty"
grep -q '^writes: none$'      <<< "$OUT_UNDECL" && pass "declares writes: none" || fail "did not declare writes: none"
echo

# --- 3. the one bound slot is still usable ----------------------------------
echo "[3] the billing slot is bound and reported as such"
OUT_ALL="$(bash "$RESOLVER" --config "$FIXTURE_EMPTY" --format kv)"
printf '%s\n' "$OUT_ALL" | sed 's/^/      /'
grep -q '^slot=billing state=bound' <<< "$OUT_ALL" && pass "billing is bound" || fail "billing is not bound"
[ "$(grep -c 'state=bound' <<< "$OUT_ALL")" -eq 1 ] && pass "exactly one slot is bound" || fail "more than one slot is bound"
echo

# --- 3b. engagement layout: overrides, declared-none, declared-none secret ---
# US-008 regression. The pack used to hard-code where an engagement record and
# its trackers live. A firm that files them anywhere else was silently pointed at
# the wrong path, so these assertions pin the three states the layout resolves.
echo "[3b] engagement_layout — per-engagement overrides resolve, absent falls back"
if out="$(bash "$VALIDATOR" "$FIXTURE_LAYOUT" 2>&1)"; then
  pass "$(basename "$FIXTURE_LAYOUT") — $(printf '%s' "$out" | tail -1)"
else
  fail "$(basename "$FIXTURE_LAYOUT") did not validate:"; printf '%s\n' "$out"
fi

OUT_PLAIN="$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement plain-client --format kv)"
printf '%s\n' "$OUT_PLAIN" | sed 's/^/      /'
grep -q '^engagement_path=companies/fixture-layout-firm/engagements/plain-client/record.md source=firm' <<< "$OUT_PLAIN" \
  && pass "no override -> firm-level path, with {firm}/{slug} substituted" || fail "firm-level engagement_path did not resolve"
grep -q '^dedupe_key=plain-client source=firm' <<< "$OUT_PLAIN" \
  && pass "no override -> dedupe key is the slug" || fail "dedupe key did not default to the slug"

OUT_ELSE="$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement elsewhere-client --format kv)"
grep -q '^engagement_path=repos/private/knowledge-elsewhere/record.md source=override' <<< "$OUT_ELSE" \
  && pass "override -> engagement record outside the firm tree" || fail "override engagement_path did not win"
grep -q '^dedupe_key=elsewhere-client source=firm' <<< "$OUT_ELSE" \
  && pass "override is per FIELD — unnamed fields still inherit" || fail "override replaced fields it did not name"

OUT_ALIAS="$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement alias-client --format kv)"
grep -q '^dedupe_key=legacy-alias source=override' <<< "$OUT_ALIAS" \
  && pass "override -> dedupe key is an alias, not the slug" || fail "dedupe key alias did not resolve"

OUT_UNTRACKED="$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement untracked-client --format kv)"
grep -q '^tracker_sources_state=declared-none' <<< "$OUT_UNTRACKED" \
  && pass "tracker_sources: [] is declared-none, not a fallback to the default glob" \
  || fail "explicitly empty tracker_sources was not reported as declared-none"
grep -q '^tracker_source=' <<< "$OUT_UNTRACKED" \
  && fail "declared-none still emitted a tracker source" || pass "declared-none emits no tracker source"

grep -q '^writes: none$' <<< "$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement plain-client)" \
  && pass "layout resolver declares writes: none" || fail "layout resolver did not declare writes: none"

OUT_SECRET="$(bash "$RESOLVER" --config "$FIXTURE_LAYOUT" --slot transcripts)"
grep -q 'declared-none' <<< "$OUT_SECRET" \
  && pass "secret_name: null is reported as declared-none, so nothing asks for a credential" \
  || fail "explicit null secret_name was not reported as declared-none"
echo

# --- 3c. per-slot join keys (D1) --------------------------------------------
# D1 regression. `mapping.dedupe_field` was always declared PER SLOT while the
# key that went into it was resolved per ENGAGEMENT, so the pack pushed one value
# into every slot's join field. A firm whose CRM joins on a differently shaped
# value than its ledger got a rejected read and — the reason this is P1 — a
# search-then-create write whose search could not match, which creates the
# duplicate record idempotency exists to prevent.
#
# Precedence under test, most specific first. Scope outranks slot; within a
# scope, a slot-named key outranks the general key:
#   1 overrides.<slug>.dedupe_keys.<slot>   source=override-slot
#   2 overrides.<slug>.dedupe_key           source=override
#   3 dedupe_keys.<slot>                    source=firm-slot
#   4 dedupe_key                            source=firm
#   5 {slug}                                source=default
#
# Every capture below tolerates a non-zero exit (`|| true`) so that a build in
# which the fix is absent FAILS THE ASSERTION instead of aborting the suite —
# an aborted suite is not a red test, it is no test.
echo "[3c] engagement_layout.dedupe_keys — one join value per (engagement, slot)"

if out="$(bash "$VALIDATOR" "$FIXTURE_SLOTKEYS" 2>&1)"; then
  pass "$(basename "$FIXTURE_SLOTKEYS") — $(printf '%s' "$out" | tail -1)"
else
  fail "$(basename "$FIXTURE_SLOTKEYS") did not validate:"; printf '%s\n' "$out"
fi

SK_ALL="$(bash "$LAYOUT" --config "$FIXTURE_SLOTKEYS" --engagement two-key-client --slot all --format kv 2>&1 || true)"
printf '%s\n' "$SK_ALL" | sed 's/^/      /'

# level 1 — this engagement, this slot
grep -q '^dedupe_key_for=crm value=two-key.example.org source=override-slot state=resolved$' <<< "$SK_ALL" \
  && pass "L1 override-slot: the CRM slot joins on its own declared value" \
  || fail "L1 override-slot did not win for the crm slot"
# level 2 — this engagement, every slot that names no key of its own
grep -q '^dedupe_key_for=billing value=legacy-alias source=override state=resolved$' <<< "$SK_ALL" \
  && pass "L2 override: a slot with no key of its own still gets the engagement alias" \
  || fail "L2 override did not reach the billing slot"
# the defect itself: the two slots must not receive the same value
[ "$(grep -c '^dedupe_key_for=.* value=legacy-alias ' <<< "$SK_ALL")" -ge 1 ] \
  && ! grep -q '^dedupe_key_for=crm value=legacy-alias' <<< "$SK_ALL" \
  && pass "D1: the crm slot and the billing slot resolve DIFFERENT join values" \
  || fail "D1: one value is still being pushed into every slot's join field"

SK_PLAIN="$(bash "$LAYOUT" --config "$FIXTURE_SLOTKEYS" --engagement plain-client --slot all --format kv 2>&1 || true)"
# level 3 — this firm, this slot (and {slug} still substitutes inside a slot key)
grep -q '^dedupe_key_for=crm value=plain-client.example source=firm-slot state=resolved$' <<< "$SK_PLAIN" \
  && pass "L3 firm-slot: firm-level per-slot key resolves, with {slug} substituted" \
  || fail "L3 firm-slot key did not resolve"
# level 4 — this firm, general
grep -q '^dedupe_key_for=billing value=plain-client source=firm state=resolved$' <<< "$SK_PLAIN" \
  && pass "L4 firm: the general firm key still serves every unnamed slot" \
  || fail "L4 firm-level general key did not resolve"
# declared-none at the firm level: unresolved, NOT a fallback to the general key
grep -q '^dedupe_key_for=portal value= source=firm-slot state=declared-none$' <<< "$SK_PLAIN" \
  && pass "declared-none (firm): an explicit null is UNRESOLVED, not a fallback" \
  || fail "an explicitly null firm-level slot key fell back to another value"

# level 5 — the pack default, from a config with no engagement_layout at all
SK_DEFAULT="$(bash "$LAYOUT" --config "$FIXTURE_EMPTY" --engagement any-client --slot crm --format kv 2>&1 || true)"
grep -q '^dedupe_key_for=crm value=any-client source=default state=resolved$' <<< "$SK_DEFAULT" \
  && pass "L5 default: no layout at all still resolves {slug}, unchanged from v1" \
  || fail "L5 pack default did not resolve to the slug"

# declared-none at the engagement level
SK_NONE="$(bash "$LAYOUT" --config "$FIXTURE_SLOTKEYS" --engagement unresolvable-crm-client --slot crm --format kv 2>&1 || true)"
grep -q '^dedupe_key_for=crm value= source=override-slot state=declared-none$' <<< "$SK_NONE" \
  && pass "declared-none (engagement): unresolved, so the caller writes nothing externally" \
  || fail "an explicitly null per-engagement slot key was resolved to a value anyway"

# --- backward compatibility, asserted in the suite and not only by eye -------
# A config that declares a single dedupe_key and no dedupe_keys anywhere can only
# reach levels 2, 4 and 5 — the three levels that existed before this key — so
# EVERY slot must resolve to exactly the value the old resolver produced.
SK_OLD="$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement alias-client --slot all --format kv 2>&1 || true)"
OLD_KEY="$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement alias-client --format kv 2>&1 | sed -n 's/^dedupe_key=\([^ ]*\) .*/\1/p' || true)"
if [ -n "$OLD_KEY" ] && [ "$(grep -c "^dedupe_key_for=.* value=${OLD_KEY} source=override state=resolved$" <<< "$SK_OLD")" -eq 5 ]; then
  pass "backward compat: a config with no dedupe_keys resolves all 5 slots to its one key (${OLD_KEY})"
else
  fail "backward compat: a pre-existing single-key config no longer resolves identically for every slot"
fi
# ...and its DEFAULT report is unchanged: no per-slot line is printed unless asked.
OUT_NOSLOT="$(bash "$LAYOUT" --config "$FIXTURE_LAYOUT" --engagement alias-client --format kv 2>&1 || true)"
grep -q '^dedupe_key_for' <<< "$OUT_NOSLOT" \
  && fail "the default report grew per-slot lines for a config that declares none" \
  || pass "backward compat: the default report is unchanged for a config with no dedupe_keys"

# forward compatibility: an unknown slot name warns and is ignored, never fails
VAL_SLOTKEYS="$(bash "$VALIDATOR" "$FIXTURE_SLOTKEYS" 2>&1 || true)"
grep -q 'W_LAYOUT_DEDUPE_KEY_SLOT_UNKNOWN' <<< "$VAL_SLOTKEYS" \
  && pass "forward compat: a dedupe_keys entry for an unknown slot WARNS, never fails" \
  || fail "an unknown slot name in dedupe_keys was not reported as a warning"

# the one ambiguous combination is named rather than left to be rediscovered
grep -q 'W_LAYOUT_DEDUPE_KEY_SHADOWS_SLOT.*alias-only-client' <<< "$VAL_SLOTKEYS" \
  && pass "the shadowing combination (L2 over L3) is warned about by name" \
  || fail "a general engagement key silently shadowing a firm per-slot key was not warned about"
# ...and declaring the slot key at level 1 silences it
grep -q 'W_LAYOUT_DEDUPE_KEY_SHADOWS_SLOT.*two-key-client.dedupe_key: .*slot crm' <<< "$VAL_SLOTKEYS" \
  && fail "the shadow warning still fires for a slot whose key IS declared" \
  || pass "declaring the slot key at level 1 silences the shadow warning for that slot"

# malformed declarations are NAMED errors, not parse failures
VAL_BAD="$(bash "$VALIDATOR" "$FIXTURE_SLOTKEYS_BAD" 2>&1 || true)"
grep -q 'E_LAYOUT_DEDUPE_KEYS_NOT_MAPPING' <<< "$VAL_BAD" \
  && pass "a dedupe_keys that is not a slot-keyed map is a named error" \
  || fail "a malformed dedupe_keys was not reported as E_LAYOUT_DEDUPE_KEYS_NOT_MAPPING"
grep -q 'E_LAYOUT_DEDUPE_KEY_NOT_SCALAR' <<< "$VAL_BAD" \
  && pass "a non-scalar join value is a named error" \
  || fail "a non-scalar dedupe_keys entry was not reported as E_LAYOUT_DEDUPE_KEY_NOT_SCALAR"

grep -q '^writes: none$' <<< "$(bash "$LAYOUT" --config "$FIXTURE_SLOTKEYS" --engagement two-key-client --slot all 2>&1 || true)" \
  && pass "per-slot resolution still declares writes: none (local and pure)" \
  || fail "per-slot resolution did not declare writes: none"
echo

# --- 4. no writes -----------------------------------------------------------
echo "[4] no writes occurred"
AFTER="$(manifest)"
if [ "$BEFORE" = "$AFTER" ]; then
  pass "checksum manifest identical before/after ($(printf '%s\n' "$AFTER" | grep -c . ) files under the worker tree + scratch workspace)"
else
  fail "files changed during the run:"
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") || true
fi
echo

if [ "$FAILED" -eq 0 ]; then
  echo "E2E PASS — crm reported as not configured, and zero writes."
  exit 0
fi
echo "E2E FAIL"
exit 1
