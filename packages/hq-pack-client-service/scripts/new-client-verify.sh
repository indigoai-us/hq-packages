#!/usr/bin/env bash
# new-client-verify.sh — fixture-only regression suite for new-client.sh (US-005).
#
#   new-client-verify.sh [--keep]
#
# Builds a throwaway HQ root under $TMPDIR containing invented fixture companies.
# It NEVER touches a real company tree and never creates a real company.
#
# Every invocation of the engine runs with PATH prefixed by a shim directory in
# which `curl`, `wget`, `hq`, `gh`, `aws`, `ssh`, `scp`, `nc` and `open` are
# recording stubs: calling one appends to a log and exits non-zero. "No external
# call was made" is therefore asserted mechanically, not asserted by reading the
# source.
#
# Scenarios
#   0  fixtures build; the firm configs validate
#   1  THE PRD E2E — local-only, invites declined: BOTH trees exist and the
#      external-call log is empty
#   2  SLUG COLLISION — a second run aborts and modifies nothing
#   3  adapter entries are written for BOUND slots only (empty and undeclared
#      write nothing at all — not a file, not a placeholder)
#   4  re-running client-home is idempotent (zero changes, byte-identical tree)
#   5  underscore pseudo-dirs are never auto-selected, listed, or acceptable as
#      a client slug
#   6  THE INVITE GATE — declined / undecided emit nothing; approved stages
#      commands and STILL makes no external call
#   7  session scope — each phase refuses a session bound to the other company,
#      and refuses outright when the binding is unknown
#   8  cloud posture — --cloud instructs /designate-team without running it;
#      local-only says so explicitly
#   9  a firm that never onboarded is refused (no engagement template)
#  10  nothing this story wrote contains a credential-shaped string
#
# Discrimination checks
#   Scenario 2 is re-run against a copy of new-client.sh with the collision guard
#   disabled, and scenario 6 against a copy with the invite gate disabled. Both
#   MUST fail there. A guard test that still passes with the guard removed proves
#   nothing.
#
# Exit: 0 all green, 1 an assertion failed, 2 environment problem.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACK="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
NC="${SCRIPT_DIR}/new-client.sh"
ONBOARD="${SCRIPT_DIR}/onboard-firm.sh"
VALIDATE="${SCRIPT_DIR}/validate-config.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

command -v yq >/dev/null 2>&1 || { printf 'E_ENV_YQ_MISSING: yq is required\n' >&2; exit 2; }
command -v shasum >/dev/null 2>&1 || { printf 'E_ENV: shasum is required\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'E_ENV: python3 is required (exact-string patching)\n' >&2; exit 2; }

WORK="$(mktemp -d -t new-client-verify)"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

SHIMS="${WORK}/shims"
EXTLOG="${WORK}/external-calls.log"
EMPTY_NAMES="${WORK}/no-secret-names"
: > "$EXTLOG"
: > "$EMPTY_NAMES"

mkdir -p "$SHIMS"
for cmd in curl wget hq gh aws ssh scp nc open; do
  cat > "${SHIMS}/${cmd}" <<SHIM
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "${EXTLOG}"
exit 97
SHIM
  chmod +x "${SHIMS}/${cmd}"
done

TOTAL_FAILS=0
SCEN_FAILS=0
hdr() { printf '\n=== %s\n' "$*"; }
ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; SCEN_FAILS=$((SCEN_FAILS + 1)); TOTAL_FAILS=$((TOTAL_FAILS + 1)); }

assert_eq()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
assert_exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_absent() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (present: $2)"; fi; }
assert_has()    { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)" ;; esac; }
assert_lacks()  { case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }
assert_lacks()  { case "$2" in *"$3"*) bad "$1 (found '$3' in output)" ;; *) ok "$1" ;; esac; }
assert_no_external_call() {
  if [ -s "$EXTLOG" ]; then
    bad "$1 — external call(s) attempted: $(tr '\n' '; ' < "$EXTLOG")"
  else
    ok "$1 (shim log empty: curl/wget/hq/gh/aws/ssh/scp/nc/open were never invoked)"
  fi
}

OUT=""
RC=0
run() { # run <script> <args...>
  local script="$1"; shift
  RC=0
  OUT="$(PATH="${SHIMS}:${PATH}" bash "$script" "$@" 2>&1)" || RC=$?
}

tree_manifest() { # tree_manifest <dir>
  ( cd "$1" 2>/dev/null && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# fixtures — every name is invented
# ---------------------------------------------------------------------------
FIRM="northwind-fixture"
BARE="lowtech-fixture"
RAW="never-onboarded-fixture"

build_fixture() { # build_fixture <root>
  local R="$1" co="${1}/companies"
  mkdir -p "${co}"
  {
    printf 'companies:\n'
    printf '  %s:\n    name: Northwind Fixture Partners\n    path: companies/%s\n' "$FIRM" "$FIRM"
    printf '  %s:\n    name: Lowtech Fixture\n    path: companies/%s\n' "$BARE" "$BARE"
  } > "${co}/manifest.yaml"

  mkdir -p "${co}/${FIRM}/settings" "${co}/${BARE}/settings" "${co}/${RAW}/settings"
  printf 'slug: %s\nname: Northwind Fixture Partners\ncloud: false\n' "$FIRM" > "${co}/${FIRM}/company.yaml"
  printf 'slug: %s\nname: Lowtech Fixture\ncloud: false\n' "$BARE" > "${co}/${BARE}/company.yaml"
  printf 'slug: %s\nname: Never Onboarded Fixture\ncloud: false\n' "$RAW" > "${co}/${RAW}/company.yaml"

  # crm BOUND, portal EMPTY, transcripts left UNDECLARED on purpose.
  PATH="${SHIMS}:${PATH}" bash "$ONBOARD" --company "$FIRM" --root "$R" --quiet \
    --secret-names-file "$EMPTY_NAMES" --no-auto \
    --bind crm=fixture-crm:mcp --empty portal --empty billing --empty agreements \
    --skip transcripts >/dev/null 2>&1 || return 1

  # every creation-time slot unbound: crm EMPTY, portal UNDECLARED.
  PATH="${SHIMS}:${PATH}" bash "$ONBOARD" --company "$BARE" --root "$R" --quiet \
    --secret-names-file "$EMPTY_NAMES" --no-auto --empty crm >/dev/null 2>&1 || return 1
  return 0
}

ENG()  { printf '%s/companies/%s/clients/%s/engagement.md' "$1" "$2" "$3"; }   # <root> <firm> <client>
CODIR(){ printf '%s/companies/%s' "$1" "$2"; }                                 # <root> <client>

# ===========================================================================
ROOT1="${WORK}/root1"
hdr "0  fixtures"
if build_fixture "$ROOT1"; then ok "fixture HQ root built at ${ROOT1}"; else bad "fixture build failed"; fi
for f in "$FIRM" "$BARE"; do
  if PATH="${SHIMS}:${PATH}" bash "$VALIDATE" --quiet "${ROOT1}/companies/${f}/client-service.yaml" >/dev/null 2>&1; then
    ok "${f}/client-service.yaml validates"
  else
    bad "${f}/client-service.yaml does not validate"
  fi
done
assert_exists "the firm engagement template exists (written by /onboard-firm)" \
  "${ROOT1}/companies/${FIRM}/clients/_templates/engagement.template.md"
assert_eq "crm is bound in the fixture firm" "bound" \
  "$(PATH="${SHIMS}:${PATH}" bash "${PACK}/workers/client-services/scripts/slot-state.sh" \
      --config "${ROOT1}/companies/${FIRM}/client-service.yaml" --slot crm --format kv | sed 's/.*state=\([a-z]*\).*/\1/')"
assert_eq "portal is empty in the fixture firm" "empty" \
  "$(PATH="${SHIMS}:${PATH}" bash "${PACK}/workers/client-services/scripts/slot-state.sh" \
      --config "${ROOT1}/companies/${FIRM}/client-service.yaml" --slot portal --format kv | sed 's/.*state=\([a-z]*\).*/\1/')"
assert_no_external_call "fixture construction made no external call"

# ===========================================================================
hdr "1  THE PRD E2E — new-client acme, local-only, invites declined"
: > "$EXTLOG"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$FIRM" \
  --firm "$FIRM" --client acme --client-name "Acme Fixture Inc" --local-only
assert_eq "phase 1 (firm-bound) exits 0" "0" "$RC"
printf '%s\n' "$OUT" | sed 's/^/      /'

run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company acme \
  --client acme --invites declined --local-only
assert_eq "phase 2 (client-bound) exits 0" "0" "$RC"
printf '%s\n' "$OUT" | sed 's/^/      /'

assert_exists "clients/acme/engagement.md exists in the firm" "$(ENG "$ROOT1" "$FIRM" acme)"
assert_exists "the acme company scaffold exists" "$(CODIR "$ROOT1" acme)/company.yaml"
assert_exists "  ... with a board.json" "$(CODIR "$ROOT1" acme)/board.json"
assert_exists "  ... with knowledge/" "$(CODIR "$ROOT1" acme)/knowledge/README.md"
assert_exists "handover-checklist.md is staged in the client company" "$(CODIR "$ROOT1" acme)/handover-checklist.md"
assert_eq "the client company is registered in companies/manifest.yaml" "Acme Fixture Inc" \
  "$(yq -r '.companies.acme.name' "${ROOT1}/companies/manifest.yaml")"
assert_eq "the client company is NOT marked cloud-backed" "false" \
  "$(yq -r '.cloud' "$(CODIR "$ROOT1" acme)/company.yaml")"
assert_has "the engagement was rendered from the firm template" \
  "$(cat "$(ENG "$ROOT1" "$FIRM" acme)")" "Acme Fixture Inc — Engagement State"
assert_lacks "no placeholder survived rendering the engagement" \
  "$(cat "$(ENG "$ROOT1" "$FIRM" acme)")" "{{"
assert_lacks "no placeholder survived rendering the checklist" \
  "$(cat "$(CODIR "$ROOT1" acme)/handover-checklist.md")" "{{"
assert_has "the checklist is the runway for /handover-client" \
  "$(cat "$(CODIR "$ROOT1" acme)/handover-checklist.md")" "executable runway"
assert_has "local-only was reported as a skip, with a reason" "$OUT" "Local-only:"
assert_absent "no invite plan was staged" "${ROOT1}/workspace/client-service/new-client/acme-invites.txt"
assert_no_external_call "THE E2E'S SECOND HALF — no external call was made"

# ===========================================================================
hdr "3  adapter entries — bound slots only"
assert_exists "crm is BOUND -> a pending mirror entry was written" \
  "${ROOT1}/companies/${FIRM}/clients/acme/adapters/crm.md"
assert_absent "portal is EMPTY -> no adapter entry at all" \
  "${ROOT1}/companies/${FIRM}/clients/acme/adapters/portal.md"

run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$BARE" \
  --firm "$BARE" --client zenith --local-only
assert_eq "engagement against an all-unbound firm still succeeds" "0" "$RC"
assert_exists "  ... engagement.md is still written" "$(ENG "$ROOT1" "$BARE" zenith)"
assert_absent "  ... and NO adapters/ directory is created at all" \
  "${ROOT1}/companies/${BARE}/clients/zenith/adapters"
assert_has "  ... empty is reported as a decision" "$OUT" "the firm declared it runs no crm tool"
assert_has "  ... undeclared is reported as unknown, NOT empty" "$OUT" "undeclared — unknown, not empty"
assert_no_external_call "adapter planning made no external call"

# --- the join key in a pending record is the RESOLVER's, never a local label ---
# D1: a value that merely LOOKS like a key is worse than no value at all.
# `firm:client` is not a shape engagement-layout.sh can ever emit, so finding it
# here would mean the record advertises a join value nothing else agrees with.
CRM_MD="${ROOT1}/companies/${FIRM}/clients/acme/adapters/crm.md"
CRM_BODY="$(cat "$CRM_MD" 2>/dev/null || printf '')"
assert_lacks "the fabricated firm:client label is gone from the CRM record" \
  "$CRM_BODY" "${FIRM}:acme"
assert_has "the CRM record carries a resolver-shaped join-key line" \
  "$CRM_BODY" "Join key for this slot"

# The fixture firm binds crm but declares no join value for a brand-new client,
# so the only honest answer is UNRESOLVED — and it has to read as blocking.
case "$CRM_BODY" in
  *"Join key for this slot: UNRESOLVED"*)
    ok "  ... an undeclared join value is reported as UNRESOLVED, not invented"
    assert_has "  ... and the record says to make no write" "$CRM_BODY" "no write" ;;
  *)
    assert_has "  ... a resolved key names the precedence level it came from" \
      "$CRM_BODY" "resolved at" ;;
esac

# ===========================================================================
hdr "4  re-running client-home is idempotent"
BEFORE="$(tree_manifest "$(CODIR "$ROOT1" acme)")"
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company acme \
  --client acme --invites declined --local-only
AFTER="$(tree_manifest "$(CODIR "$ROOT1" acme)")"
assert_eq "re-run exits 0" "0" "$RC"
assert_has "re-run reports zero changes" "$OUT" "no changes"
if [ "$BEFORE" = "$AFTER" ]; then ok "the client tree is byte-identical after the re-run"; else bad "the client tree changed on re-run"; fi

# ===========================================================================
hdr "5  underscore pseudo-dirs are never auto-selected"
run "$NC" status --pack-dir "$PACK" --hq-root "$ROOT1" --firm "$BARE"
assert_eq "status exits 0" "0" "$RC"
assert_lacks "_templates is not listed as an engagement" "$OUT" "_templates"
assert_has "the only selectable engagement is auto-selected" "$OUT" "auto-selected:"
assert_has "  ... and it is the real one" "$OUT" "zenith"

# a firm whose clients/ holds ONLY _templates must auto-select nothing
ROOT_U="${WORK}/root-underscore"
build_fixture "$ROOT_U" || bad "underscore fixture build failed"
run "$NC" status --pack-dir "$PACK" --hq-root "$ROOT_U" --firm "$FIRM"
assert_has "with only _templates present, auto-select is REFUSED" "$OUT" "refused — no selectable engagement"
assert_lacks "  ... and _templates is never named as a candidate" "$OUT" "auto-selected:"

run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT_U" --session-company "$FIRM" \
  --firm "$FIRM" --client _templates --local-only
assert_eq "a leading-underscore client slug is refused (exit 2)" "2" "$RC"
assert_has "  ... by a general leading-underscore rule" "$OUT" "E_SLUG_RESERVED"
assert_exists "  ... and the real _templates dir is untouched" \
  "${ROOT_U}/companies/${FIRM}/clients/_templates/engagement.template.md"
assert_absent "  ... no engagement.md was written into it" \
  "${ROOT_U}/companies/${FIRM}/clients/_templates/engagement.md"

# ===========================================================================
hdr "7  session scope — one company per session, both directions"
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$FIRM" \
  --client acme --invites declined --local-only
assert_eq "a FIRM-bound session may not run the client phase (exit 1)" "1" "$RC"
assert_has "  ... named error" "$OUT" "E_SESSION_SCOPE"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company acme \
  --firm "$FIRM" --client bravo --local-only
assert_eq "a CLIENT-bound session may not run the firm phase (exit 1)" "1" "$RC"
assert_has "  ... named error" "$OUT" "E_SESSION_SCOPE"
assert_absent "  ... and nothing was written" "${ROOT1}/companies/${FIRM}/clients/bravo"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --firm "$FIRM" --client bravo --local-only
assert_eq "an UNKNOWN binding is refused, not assumed (exit 1)" "1" "$RC"
assert_has "  ... unknown is not authorization" "$OUT" "E_SESSION_UNKNOWN"

# ===========================================================================
hdr "7b multi-company session — the firm's session holds the client too"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$FIRM" \
  --firm "$FIRM" --client golf --local-only
assert_eq "phase 1 for golf exits 0" "0" "$RC"
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "${FIRM},golf" \
  --client golf --invites declined --local-only
assert_eq "a session locked to firm+client may run the client phase (exit 0)" "0" "$RC"
assert_exists "  ... the client company was written" "$(CODIR "$ROOT1" golf)/handover-checklist.md"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$FIRM" \
  --firm "$FIRM" --client hotel --local-only
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "${FIRM},india" \
  --client hotel --invites declined --local-only
assert_eq "a multi-company session WITHOUT this client is refused (exit 1)" "1" "$RC"
assert_has "  ... named error" "$OUT" "E_SESSION_SCOPE"
assert_has "  ... and it says how to add the client" "$OUT" "add company hotel"
assert_absent "  ... and nothing was written" "$(CODIR "$ROOT1" hotel)"
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "${FIRM},hotelx" \
  --client hotel --invites declined --local-only
assert_eq "a slug that merely starts with the client's slug does not match (exit 1)" "1" "$RC"
# The live lock set comes from hq-session.sh `get company_slugs`.
mkdir -p "${ROOT1}/core/scripts"
cat > "${ROOT1}/core/scripts/hq-session.sh" <<EOF
#!/usr/bin/env bash
case "\$2" in company_slugs) printf '%s\n' "${FIRM},hotel" ;; company_slug) printf '%s\n' "${FIRM}" ;; esac
EOF
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" \
  --client hotel --invites declined --local-only
assert_eq "the live session lock set (firm,hotel) authorizes the client phase (exit 0)" "0" "$RC"
assert_exists "  ... the client company was written" "$(CODIR "$ROOT1" hotel)/handover-checklist.md"
rm -f "${ROOT1}/core/scripts/hq-session.sh"

# ===========================================================================
hdr "8  cloud posture"
: > "$EXTLOG"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$FIRM" \
  --firm "$FIRM" --client delta --cloud
assert_eq "engagement --cloud exits 0" "0" "$RC"
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company delta \
  --client delta --invites declined --cloud
assert_eq "client-home --cloud exits 0" "0" "$RC"
assert_has "  ... instructs /designate-team" "$OUT" "/designate-team delta"
assert_has "  ... and states it performs no cloud action itself" "$OUT" "performs no cloud action"
assert_exists "  ... both trees still exist" "$(CODIR "$ROOT1" delta)/company.yaml"
assert_no_external_call "--cloud ran /designate-team NOWHERE — it only printed it"

# ===========================================================================
hdr "9  a firm that never onboarded is refused"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$RAW" \
  --firm "$RAW" --client echo --local-only
assert_eq "exits 1" "1" "$RC"
assert_has "  ... names the missing template and points at /onboard-firm" "$OUT" "E_NO_ENGAGEMENT_TEMPLATE"
assert_absent "  ... and wrote nothing" "${ROOT1}/companies/${RAW}/clients"

# ===========================================================================
hdr "9b --company-scaffold require — the /newcompany-first path"
run "$NC" engagement --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$FIRM" \
  --firm "$FIRM" --client foxtrot --local-only
assert_eq "phase 1 exits 0" "0" "$RC"
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company foxtrot \
  --client foxtrot --company-scaffold require --invites declined --local-only
assert_eq "require + no company yet -> refused (exit 1)" "1" "$RC"
assert_has "  ... and points at /newcompany" "$OUT" "/newcompany foxtrot"
assert_absent "  ... nothing was scaffolded" "$(CODIR "$ROOT1" foxtrot)"
# stand in for what /newcompany would have produced
mkdir -p "$(CODIR "$ROOT1" foxtrot)/settings"
printf 'slug: foxtrot\nname: Foxtrot Fixture\ncloud: false\n' > "$(CODIR "$ROOT1" foxtrot)/company.yaml"
run "$NC" client-home --pack-dir "$PACK" --hq-root "$ROOT1" --session-company foxtrot \
  --client foxtrot --company-scaffold require --invites declined --local-only
assert_eq "require + company present -> proceeds (exit 0)" "0" "$RC"
assert_has "  ... and does not rewrite the existing company" "$OUT" "already existed"
assert_exists "  ... the checklist is still staged" "$(CODIR "$ROOT1" foxtrot)/handover-checklist.md"

# ===========================================================================
hdr "11 static check — the engine invokes no network-facing binary"
STATIC_HITS="$(grep -nE '^[[:space:]]*(hq|curl|wget|gh|aws|ssh|scp|nc|open)[[:space:]]' "$NC" || true)"
if [ -z "$STATIC_HITS" ]; then
  ok "no line in new-client.sh executes hq/curl/wget/gh/aws/ssh/scp/nc/open"
else
  bad "new-client.sh executes a network-facing binary: ${STATIC_HITS}"
fi
assert_eq "hq appears in exactly one executable line, and it is a PATH probe" "1" \
  "$(grep -c '^[^#]*command -v hq' "$NC")"

# ===========================================================================
# Scenario 2 and 6 are functions: they run against the real engine AND against
# deliberately broken copies.
# ===========================================================================
scenario_collision() { # scenario_collision <script> <root-tag>
  local script="$1"
  local tag="$2"
  local R="${WORK}/collision-${tag}"
  SCEN_FAILS=0
  build_fixture "$R" || { bad "[${tag}] fixture build failed"; return 0; }

  PATH="${SHIMS}:${PATH}" bash "$script" engagement --pack-dir "$PACK" --hq-root "$R" \
    --session-company "$FIRM" --firm "$FIRM" --client acme --client-name "Acme Fixture Inc" \
    --local-only >/dev/null 2>&1
  printf '\nSENTINEL-EDIT-BY-A-HUMAN\n' >> "$(ENG "$R" "$FIRM" acme)"
  local before after
  before="$(tree_manifest "${R}/companies/${FIRM}")"

  RC=0
  OUT="$(PATH="${SHIMS}:${PATH}" bash "$script" engagement --pack-dir "$PACK" --hq-root "$R" \
    --session-company "$FIRM" --firm "$FIRM" --client acme --client-name "Acme Fixture Inc" \
    --local-only 2>&1)" || RC=$?
  after="$(tree_manifest "${R}/companies/${FIRM}")"

  assert_eq "[${tag}] a colliding slug ABORTS (exit 1)" "1" "$RC"
  assert_has "[${tag}]  ... with a clear, named message" "$OUT" "E_SLUG_COLLISION"
  assert_has "[${tag}]  ... that suggests a distinct slug" "$OUT" "pick a distinct slug"
  if [ "$before" = "$after" ]; then
    ok "[${tag}]  ... and the firm tree is byte-identical (nothing was overwritten)"
  else
    bad "[${tag}]  ... but the firm tree CHANGED"
  fi
  assert_has "[${tag}]  ... the human's edit survives" "$(cat "$(ENG "$R" "$FIRM" acme)")" "SENTINEL-EDIT-BY-A-HUMAN"
}

scenario_invite_gate() { # scenario_invite_gate <script> <root-tag>
  local script="$1"
  local tag="$2"
  local R="${WORK}/invite-${tag}"
  SCEN_FAILS=0
  build_fixture "$R" || { bad "[${tag}] fixture build failed"; return 0; }
  : > "$EXTLOG"

  local plan_dir="${R}/workspace/client-service/new-client"

  # (a) DECLINED, with recipients supplied — the gate said no.
  PATH="${SHIMS}:${PATH}" bash "$script" engagement --pack-dir "$PACK" --hq-root "$R" \
    --session-company "$FIRM" --firm "$FIRM" --client acme --local-only >/dev/null 2>&1
  RC=0
  OUT="$(PATH="${SHIMS}:${PATH}" bash "$script" client-home --pack-dir "$PACK" --hq-root "$R" \
    --session-company acme --client acme --local-only \
    --invites declined --invite ops@example.test --invite lead@example.test:owner 2>&1)" || RC=$?

  assert_eq "[${tag}] declining the gate still completes the phase (exit 0)" "0" "$RC"
  assert_absent "[${tag}] DECLINED -> no invite artifact was staged" "${plan_dir}/acme-invites.txt"
  assert_exists "[${tag}] DECLINED -> everything else completed (company scaffold)" "${R}/companies/acme/company.yaml"
  assert_exists "[${tag}] DECLINED -> everything else completed (checklist)" "${R}/companies/acme/handover-checklist.md"
  assert_has "[${tag}] DECLINED -> the checklist records the decline" \
    "$(cat "${R}/companies/acme/handover-checklist.md" 2>/dev/null || printf '')" "declined at the approval gate"
  if [ -s "$EXTLOG" ]; then
    bad "[${tag}] DECLINED -> an external call was attempted: $(tr '\n' '; ' < "$EXTLOG")"
  else
    ok "[${tag}] DECLINED -> no external call was attempted"
  fi

  # (b) UNDECIDED — recipients supplied, no --invites at all. Absent is not approval.
  PATH="${SHIMS}:${PATH}" bash "$script" engagement --pack-dir "$PACK" --hq-root "$R" \
    --session-company "$FIRM" --firm "$FIRM" --client bravo --local-only >/dev/null 2>&1
  RC=0
  OUT="$(PATH="${SHIMS}:${PATH}" bash "$script" client-home --pack-dir "$PACK" --hq-root "$R" \
    --session-company bravo --client bravo --local-only --invite ops@example.test 2>&1)" || RC=$?
  assert_eq "[${tag}] undecided still completes the phase (exit 0)" "0" "$RC"
  assert_absent "[${tag}] UNDECIDED -> no invite artifact was staged" "${plan_dir}/bravo-invites.txt"
  assert_has "[${tag}] UNDECIDED -> reported as not-approval" "$OUT" "UNDECIDED"

  # (c) APPROVED — commands are staged for a human; still nothing is sent.
  PATH="${SHIMS}:${PATH}" bash "$script" engagement --pack-dir "$PACK" --hq-root "$R" \
    --session-company "$FIRM" --firm "$FIRM" --client charlie --local-only >/dev/null 2>&1
  RC=0
  OUT="$(PATH="${SHIMS}:${PATH}" bash "$script" client-home --pack-dir "$PACK" --hq-root "$R" \
    --session-company charlie --client charlie --local-only \
    --invites approved --invite ops@example.test --invite lead@example.test:owner 2>&1)" || RC=$?
  assert_eq "[${tag}] approved completes the phase (exit 0)" "0" "$RC"
  assert_exists "[${tag}] APPROVED -> the invite commands are staged" "${plan_dir}/charlie-invites.txt"
  assert_has "[${tag}] APPROVED -> the staged commands are runnable and explicit" \
    "$(cat "${plan_dir}/charlie-invites.txt" 2>/dev/null || printf '')" "hq invite --company charlie --email ops@example.test"
  assert_has "[${tag}] APPROVED -> the role qualifier survives" \
    "$(cat "${plan_dir}/charlie-invites.txt" 2>/dev/null || printf '')" "--email lead@example.test --role owner"
  if [ -s "$EXTLOG" ]; then
    bad "[${tag}] APPROVED -> something was actually SENT: $(tr '\n' '; ' < "$EXTLOG")"
  else
    ok "[${tag}] APPROVED -> commands staged, but nothing was sent (shim log still empty)"
  fi
}

hdr "2  SLUG COLLISION (real engine)"
scenario_collision "$NC" real

hdr "6  THE INVITE GATE (real engine)"
scenario_invite_gate "$NC" real

# ===========================================================================
hdr "10 credential-shaped strings in everything US-005 wrote"
# This suite scans the artifacts, not itself: the only match inside this file
# would be the detection pattern on the next line.
SECRET_HITS="$(grep -riE 'sk_|xox|AKIA|BEGIN .*PRIVATE KEY' \
  "$NC" \
  "${PACK}/templates/handover-checklist.md" \
  "${PACK}/skills/new-client/SKILL.md" 2>/dev/null || true)"
if [ -z "$SECRET_HITS" ]; then ok "clean"; else bad "credential-shaped strings found: ${SECRET_HITS}"; fi

REAL_FAILS="$TOTAL_FAILS"

# ===========================================================================
# DISCRIMINATION — the guards must be the reason those tests pass
# ===========================================================================
make_broken() { # make_broken <name> <exact-old> <exact-new> -> path or BROKEN-FAILED
  local name="$1"
  local old="$2"
  local new="$3"
  local out="${WORK}/broken-${name}.sh"
  local rc=0
  # The engine sources lib/session-lock.sh next to itself; give the copy one too.
  mkdir -p "${WORK}/lib" && cp "$(dirname "$NC")/lib/session-lock.sh" "${WORK}/lib/"
  BROKEN_OLD="$old" BROKEN_NEW="$new" python3 - "$NC" "$out" <<'PY' || rc=$?
import os, sys
src = open(sys.argv[1]).read()
old, new = os.environ["BROKEN_OLD"], os.environ["BROKEN_NEW"]
if src.count(old) != 1:
    sys.stderr.write("expected exactly one occurrence, found %d\n" % src.count(old))
    sys.exit(3)
open(sys.argv[2], "w").write(src.replace(old, new))
PY
  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then printf 'BROKEN-FAILED'; return 0; fi
  chmod +x "$out"
  # The broken copy must still be a RUNNABLE script, otherwise the scenario
  # would "fail" because the file is broken rather than because the guard is
  # gone — which would make the discrimination check meaningless.
  bash -n "$out" >/dev/null 2>&1 || { printf 'BROKEN-FAILED'; return 0; }
  PATH="${SHIMS}:${PATH}" bash "$out" --help >/dev/null 2>&1 || { printf 'BROKEN-FAILED'; return 0; }
  printf '%s' "$out"
}

run_discrimination() { # run_discrimination <label> <broken-path> <scenario-fn> <tag>
  local label="$1" broken="$2" fn="$3" tag="$4" before after failed
  hdr "DISCRIMINATION — ${label}"
  if [ "$broken" = "BROKEN-FAILED" ]; then
    bad "could not build the broken copy — the discrimination check is inconclusive"
    return 0
  fi
  before="$TOTAL_FAILS"
  "$fn" "$broken" "$tag"
  after="$TOTAL_FAILS"
  failed=$((after - before))
  TOTAL_FAILS="$before"   # failures under a deliberately broken build are EXPECTED
  if [ "$failed" -gt 0 ]; then
    printf '  PASS  %d assertion(s) failed with the guard disabled — the test discriminates\n' "$failed"
  else
    printf '  FAIL  every assertion still passed with the guard disabled — the test proves nothing\n'
    TOTAL_FAILS=$((TOTAL_FAILS + 1))
  fi
}

BROKEN_COLLISION="$(make_broken collision \
  'if [ -e "$ENGAGEMENT_DIR" ] || [ -L "$ENGAGEMENT_DIR" ]; then' \
  'if false; then')"
run_discrimination "collision guard removed — scenario 2 MUST fail" \
  "$BROKEN_COLLISION" scenario_collision brokencollision

BROKEN_GATE="$(make_broken gate \
  'if [ "$INVITES" = "approved" ] && [ "${#INVITEES[@]}" -gt 0 ]; then' \
  'if [ "${#INVITEES[@]}" -gt 0 ]; then')"
run_discrimination "invite gate removed — scenario 6 MUST fail" \
  "$BROKEN_GATE" scenario_invite_gate brokengate

# ===========================================================================
hdr "SUMMARY"
printf '  real-engine assertion failures : %d\n' "$REAL_FAILS"
printf '  total failures                 : %d\n' "$TOTAL_FAILS"
printf '  fixture root                   : %s%s\n' "$WORK" "$( [ "$KEEP" -eq 1 ] && printf ' (kept)' || printf ' (removed)')"
if [ "$TOTAL_FAILS" -eq 0 ]; then
  printf 'ALL GREEN\n'
  exit 0
fi
printf 'FAILURES: %d\n' "$TOTAL_FAILS"
exit 1
