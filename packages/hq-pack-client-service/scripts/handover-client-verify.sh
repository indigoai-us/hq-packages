#!/usr/bin/env bash
# handover-client-verify.sh — fixture-only regression suite for handover-client.sh (US-011).
#
#   handover-client-verify.sh [--keep]
#
# Builds a throwaway HQ root under $TMPDIR containing invented fixture companies.
# It NEVER touches a real company tree, never creates a real company, and never
# reaches a live or staging stack.
#
# TWO INDEPENDENT SAFETY NETS, both mechanical:
#
#   1. PATH SHIMS. Every invocation runs with PATH prefixed by a shim directory
#      in which `curl`, `wget`, `hq`, `gh`, `aws`, `ssh`, `scp`, `nc` and `open`
#      are recording stubs that log and exit non-zero. "No external call was
#      made" is asserted from that log, not from reading the source.
#   2. A MOCKED TRANSFER SURFACE. `--hq-bin` points at a fake `hq` that records
#      its exact argv and replays canned `members list` / `company transfer`
#      responses. The gate, the execution and the read-back are therefore
#      exercised end to end without a single real request.
#
# Scenarios
#   0  fixtures build
#   1  a COMPLETE checklist verifies READY
#   2  an INCOMPLETE item BLOCKS (and blocks the transfer)
#   3  an UNVERIFIABLE item is UNKNOWN and blocks just as hard
#   3b undeclared firm identity is UNKNOWN — a checked box is a claim, not evidence
#   4  firm packs must be in their declared end state (stay/remove/undeclared)
#   5  THE APPROVAL GATE — declined and undecided change NOTHING (checksum-proved)
#   6  APPROVED executes the US-010 transfer through the mocked surface
#   7  POST-TRANSFER READ-BACK matches the checklist end state ...
#   7b ... and DETECTS a seeded mismatch (both "still there" and "wrong role")
#   8  local-only firms get a clear message and exit 0, not a failure
#   9  the live-roster seam works (roster read through the mock, not a file)
#  10  no credential-shaped string in anything this story wrote
#  11  static check — the engine invokes no network-facing binary of its own
#
# Discrimination checks
#   Scenario 2/3 are re-run against a copy of handover-client.sh with the
#   checklist-blocking guard disabled, and scenario 5 against a copy with the
#   approval gate disabled. Both MUST fail there. A guard test that still passes
#   with the guard removed proves nothing.
#
# Exit: 0 all green, 1 an assertion failed, 2 environment problem.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PACK="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
HC="${SCRIPT_DIR}/handover-client.sh"
TEMPLATE="${PACK}/templates/handover-checklist.md"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

for bin in jq python3 shasum; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'E_ENV: %s is required\n' "$bin" >&2; exit 2; }
done

WORK="$(mktemp -d -t handover-client-verify)"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

SHIMS="${WORK}/shims"
EXTLOG="${WORK}/external-calls.log"
MOCKLOG="${WORK}/mock-hq-calls.log"
MOCK_HQ="${WORK}/mock-hq"
: > "$EXTLOG"
: > "$MOCKLOG"

mkdir -p "$SHIMS"
for cmd in curl wget hq gh aws ssh scp nc open; do
  cat > "${SHIMS}/${cmd}" <<SHIM
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "${EXTLOG}"
exit 97
SHIM
  chmod +x "${SHIMS}/${cmd}"
done

# ---------------------------------------------------------------------------
# the MOCKED transfer surface — a fake `hq`, recording every argv
# ---------------------------------------------------------------------------
# MOCK_ROSTER : file replayed for `members list`
# MOCK_FAIL   : when 1, `company transfer` fails (rc 3)
cat > "$MOCK_HQ" <<'MOCK'
#!/usr/bin/env bash
printf 'hq %s\n' "$*" >> "$MOCK_LOG"
case "$1 ${2:-}" in
  "members list")
    if [ -n "${MOCK_ROSTER:-}" ] && [ -f "${MOCK_ROSTER}" ]; then
      cat "$MOCK_ROSTER"; exit 0
    fi
    printf 'Not authorized — only company members can list members\n' >&2
    exit 1 ;;
  "company transfer")
    if [ "${MOCK_FAIL:-0}" = "1" ]; then
      printf 'Error: OWNERSHIP_TRANSFER_CONFLICT\n' >&2; exit 3
    fi
    printf 'Ownership transfer — nomination\n'
    printf 'Nominated %s as owner.\n' "${6:-the nominee}"
    printf '  Transfer id: otr_fixture_0001\n'
    exit 0 ;;
esac
printf 'mock-hq: unhandled %s\n' "$*" >&2
exit 64
MOCK
chmod +x "$MOCK_HQ"

TOTAL_FAILS=0
hdr() { printf '\n=== %s\n' "$*"; }
ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; TOTAL_FAILS=$((TOTAL_FAILS + 1)); }

assert_eq()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
assert_has()    { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)" ;; esac; }
assert_lacks()  { case "$2" in *"$3"*) bad "$1 (found '$3' in output)" ;; *) ok "$1" ;; esac; }
assert_exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
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
  OUT="$(PATH="${SHIMS}:${PATH}" MOCK_LOG="$MOCKLOG" MOCK_ROSTER="${MOCK_ROSTER:-}" \
        MOCK_FAIL="${MOCK_FAIL:-0}" bash "$script" "$@" 2>&1)" || RC=$?
}

tree_manifest() { # tree_manifest <dir>
  ( cd "$1" 2>/dev/null && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 ) 2>/dev/null
}

CLIENT="atlas-fixture"
FIRM_DOMAIN="northwindfixture.test"

# ---------------------------------------------------------------------------
# fixture checklists — rendered from the REAL template, then filled in
# ---------------------------------------------------------------------------
render_complete_checklist() { # render_complete_checklist <dest>
  CHK_TEMPLATE="$TEMPLATE" python3 - "$1" <<'PY'
import os, re, sys
src = open(os.environ["CHK_TEMPLATE"]).read()
src = (src.replace("{{CLIENT_NAME}}", "Atlas Fixture Ltd")
          .replace("{{CLIENT_SLUG}}", "atlas-fixture")
          .replace("{{FIRM_NAME}}", "Northwind Fixture Partners")
          .replace("{{TODAY}}", "2026-08-05")
          .replace("{{INVITE_STATUS}}", "approved and accepted (fixture)"))
# every box: done and verified
src = src.replace("- [ ]", "- [x]")
# the two four-column TODO tables are distinguished by the header above them
src = src.replace("| Pack | Decision (stay / remove) | Run | Forks kept |\n|---|---|---|---|\n| TODO | TODO | TODO | TODO |",
                  "| Pack | Decision (stay / remove) | Run | Forks kept |\n|---|---|---|---|\n| none | remove | n/a | none |")
src = src.replace("| Secret name | Owned by after handover | Rotated / deleted | Date |\n|---|---|---|---|\n| TODO | TODO | TODO | TODO |",
                  "| Secret name | Owned by after handover | Rotated / deleted | Date |\n|---|---|---|---|\n| none | n/a | n/a | 2026-08-05 |")
src = src.replace("| Firm sign-off | TODO | TODO | TODO |",
                  "| Firm sign-off | Dana Fixture | Partner | 2026-08-05 |")
src = src.replace("| Client sign-off | TODO | TODO | TODO |",
                  "| Client sign-off | Sam Fixture | COO | 2026-08-05 |")
src = src.replace('**Access the firm deliberately retains after handover (must be empty, or agreed):**\nTODO',
                  '**Access the firm deliberately retains after handover (must be empty, or agreed):**\nnone')
src = src.replace("**Open threads at handover:**\n- TODO",
                  "**Open threads at handover:**\n- none recorded (fixture)")
src = src.replace('**Residual firm access after sign-off (should be "none"):** TODO',
                  '**Residual firm access after sign-off (should be "none"):** none')
if "TODO" in src:
    sys.stderr.write("fixture checklist still contains TODO:\n%s\n" %
                     "\n".join(l for l in src.splitlines() if "TODO" in l))
    sys.exit(3)
open(sys.argv[1], "w").write(src)
PY
}

patch_file() { # patch_file <file> <exact-old> <exact-new>
  P_OLD="$2" P_NEW="$3" python3 - "$1" <<'PY'
import os, sys
p = sys.argv[1]
s = open(p).read()
old, new = os.environ["P_OLD"], os.environ["P_NEW"]
if s.count(old) != 1:
    sys.stderr.write("expected exactly 1 occurrence of %r, found %d\n" % (old, s.count(old)))
    sys.exit(3)
open(p, "w").write(s.replace(old, new))
PY
}

write_roster() { # write_roster <dest> <json>
  printf '%s\n' "$2" > "$1"
}

ROSTER_BEFORE_JSON='[
  {"personUid":"prs_c1","personEmail":"ops@atlasfixture.test","role":"owner","status":"active"},
  {"personUid":"prs_c2","personEmail":"lead@atlasfixture.test","role":"admin","status":"active"},
  {"personUid":"prs_f1","personEmail":"partner@northwindfixture.test","role":"owner","status":"active"}
]'
ROSTER_AFTER_CLEAN_JSON='[
  {"personUid":"prs_c1","personEmail":"ops@atlasfixture.test","role":"owner","status":"active"},
  {"personUid":"prs_c2","personEmail":"lead@atlasfixture.test","role":"admin","status":"active"}
]'
ROSTER_AFTER_DIRTY_JSON='[
  {"personUid":"prs_c1","personEmail":"ops@atlasfixture.test","role":"owner","status":"active"},
  {"personUid":"prs_f1","personEmail":"partner@northwindfixture.test","role":"admin","status":"active"}
]'

build_fixture() { # build_fixture <root> [cloud:true|false]
  local R="$1" cloud="${2:-true}" co="${1}/companies"
  mkdir -p "${co}/${CLIENT}/settings" "${co}/${CLIENT}/knowledge"
  printf 'companies:\n  %s:\n    name: Atlas Fixture Ltd\n    path: companies/%s\n' "$CLIENT" "$CLIENT" \
    > "${co}/manifest.yaml"
  printf 'slug: %s\nname: Atlas Fixture Ltd\ncloud: %s\n' "$CLIENT" "$cloud" \
    > "${co}/${CLIENT}/company.yaml"
  render_complete_checklist "${co}/${CLIENT}/handover-checklist.md" || return 1
  mkdir -p "${R}/rosters"
  write_roster "${R}/rosters/before.json" "$ROSTER_BEFORE_JSON"
  write_roster "${R}/rosters/after-clean.json" "$ROSTER_AFTER_CLEAN_JSON"
  write_roster "${R}/rosters/after-dirty.json" "$ROSTER_AFTER_DIRTY_JSON"
  return 0
}

CHK() { printf '%s/companies/%s/handover-checklist.md' "$1" "$CLIENT"; }

# Common argument tail used by nearly every invocation.
common_args() { # common_args <root>
  printf '%s\n' --pack-dir "$PACK" --hq-root "$1" --session-company "$CLIENT" \
    --client "$CLIENT" --hq-bin "$MOCK_HQ" --firm-domain "$FIRM_DOMAIN"
}
ARGS=()
set_args() { ARGS=(); while IFS= read -r a; do ARGS+=("$a"); done <<< "$(common_args "$1")"; }

# ===========================================================================
ROOT1="${WORK}/root1"
hdr "0  fixtures"
if build_fixture "$ROOT1"; then ok "fixture HQ root built at ${ROOT1}"; else bad "fixture build failed"; fi
assert_exists "a handover checklist is staged in the fixture client company" "$(CHK "$ROOT1")"
assert_lacks "the COMPLETE fixture checklist has no unchecked box" "$(cat "$(CHK "$ROOT1")")" "- [ ]"
assert_no_external_call "fixture construction made no external call"

set_args "$ROOT1"

# ===========================================================================
hdr "1  a COMPLETE checklist verifies READY"
: > "$EXTLOG"
run "$HC" verify "${ARGS[@]}" --roster "${ROOT1}/rosters/before.json"
assert_eq "verify exits 0" "0" "$RC"
assert_has "  ... verdict READY" "$OUT" "VERDICT  READY"
assert_has "  ... the client team is verified from the roster, not the box" "$OUT" "active client-side member(s)"
assert_has "  ... a client-side owner/admin exists" "$OUT" "client-side owner/admin"
assert_has "  ... the declared end state is read off the checklist" "$OUT" "the firm retains NO access after sign-off"
assert_eq "  ... zero incomplete/unknown" "0" \
  "$(printf '%s\n' "$OUT" | grep -cE '^  (INCOMPLETE|UNKNOWN) ' || true)"
assert_no_external_call "verify made no external call"

# ===========================================================================
scenario_incomplete_blocks() { # scenario_incomplete_blocks <script> <tag>
  local script="$1"
  local tag="$2"
  local R="${WORK}/incomplete-${tag}"
  local before after
  build_fixture "$R" || { bad "[${tag}] fixture build failed"; return 0; }
  patch_file "$(CHK "$R")" \
    "- [x] At least one **client-side** person has an accepted, active membership in" \
    "- [ ] At least one **client-side** person has an accepted, active membership in"
  local A=(); while IFS= read -r a; do A+=("$a"); done <<< "$(common_args "$R")"

  run "$script" verify "${A[@]}" --roster "${R}/rosters/before.json"
  assert_eq "[${tag}] verify still exits 0 (a verdict is not a failure)" "0" "$RC"
  assert_has "[${tag}]  ... verdict BLOCKED" "$OUT" "VERDICT  BLOCKED"
  assert_has "[${tag}]  ... and names the unchecked item" "$OUT" "unchecked: At least one **client-side** person"

  run "$script" verify "${A[@]}" --roster "${R}/rosters/before.json" --strict
  assert_eq "[${tag}] verify --strict exits 1 when blocked" "1" "$RC"

  : > "$MOCKLOG"
  before="$(tree_manifest "$R")"
  run "$script" transfer "${A[@]}" --roster "${R}/rosters/before.json" \
    --to ops@atlasfixture.test --approval approved --initiator-role remove \
    --roster-after "${R}/rosters/after-clean.json"
  after="$(tree_manifest "$R")"
  assert_eq "[${tag}] transfer REFUSES on an incomplete checklist (exit 1)" "1" "$RC"
  assert_has "[${tag}]  ... with a named error" "$OUT" "E_CHECKLIST_BLOCKED"
  if [ -s "$MOCKLOG" ]; then
    bad "[${tag}]  ... but the transfer surface was called anyway: $(tr '\n' '; ' < "$MOCKLOG")"
  else
    ok "[${tag}]  ... and the transfer surface was never called"
  fi
  if [ "$before" = "$after" ]; then
    ok "[${tag}]  ... and the fixture tree is byte-identical"
  else
    bad "[${tag}]  ... but the fixture tree CHANGED"
  fi
}

scenario_unknown_blocks() { # scenario_unknown_blocks <script> <tag>
  local script="$1"
  local tag="$2"
  local R="${WORK}/unknown-${tag}"
  build_fixture "$R" || { bad "[${tag}] fixture build failed"; return 0; }
  # Every box stays CHECKED. Only the mechanical evidence is missing: the secret
  # table's disposition is unfilled, so the claim cannot be corroborated.
  patch_file "$(CHK "$R")" \
    "| none | n/a | n/a | 2026-08-05 |" \
    "| shared-api-token | TODO | TODO | TODO |"
  local A=(); while IFS= read -r a; do A+=("$a"); done <<< "$(common_args "$R")"

  run "$script" verify "${A[@]}" --roster "${R}/rosters/before.json"
  assert_lacks "[${tag}] no box is unchecked in this fixture" "$(cat "$(CHK "$R")")" "- [ ]"
  assert_has "[${tag}] an unverifiable item is reported UNKNOWN" "$OUT" "UNKNOWN    §3"
  assert_has "[${tag}]  ... and UNKNOWN blocks" "$OUT" "VERDICT  BLOCKED"
  assert_has "[${tag}]  ... with the reason spelled out" "$OUT" "unverifiable claim cannot"

  : > "$MOCKLOG"
  run "$script" transfer "${A[@]}" --roster "${R}/rosters/before.json" \
    --to ops@atlasfixture.test --approval approved \
    --roster-after "${R}/rosters/after-clean.json"
  assert_eq "[${tag}] transfer REFUSES on an UNKNOWN item (exit 1)" "1" "$RC"
  assert_has "[${tag}]  ... named error" "$OUT" "E_CHECKLIST_BLOCKED"
  if [ -s "$MOCKLOG" ]; then
    bad "[${tag}]  ... but the transfer surface was called: $(tr '\n' '; ' < "$MOCKLOG")"
  else
    ok "[${tag}]  ... and the transfer surface was never called"
  fi
}

hdr "2  an INCOMPLETE item blocks (real engine)"
scenario_incomplete_blocks "$HC" real

hdr "3  an UNVERIFIABLE item is UNKNOWN and blocks (real engine)"
scenario_unknown_blocks "$HC" real

# ===========================================================================
hdr "3b undeclared firm identity is UNKNOWN — a checked box is a claim, not evidence"
run "$HC" verify --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "$CLIENT" \
  --client "$CLIENT" --hq-bin "$MOCK_HQ" --roster "${ROOT1}/rosters/before.json"
assert_eq "exits 0" "0" "$RC"
assert_has "  ... §1 is UNKNOWN with no firm identity declared" "$OUT" "which members are firm-side is UNDECLARED"
assert_has "  ... and that blocks" "$OUT" "VERDICT  BLOCKED"

hdr "3c an unreadable roster is UNKNOWN, never an empty roster"
run "$HC" verify "${ARGS[@]}" --roster "${WORK}/does-not-exist.json"
assert_has "  ... roster state is unknown" "$OUT" "unknown (no roster file at"
assert_has "  ... §1 says so explicitly" "$OUT" "No roster is not an empty roster"
assert_has "  ... and blocks" "$OUT" "VERDICT  BLOCKED"

hdr "3d a membership row with no status field is UNKNOWN, not active"
write_roster "${WORK}/roster-nostatus.json" '[
  {"personUid":"prs_c1","personEmail":"ops@atlasfixture.test","role":"owner"}
]'
run "$HC" verify "${ARGS[@]}" --roster "${WORK}/roster-nostatus.json"
assert_has "  ... absent status is reported as unknown" "$OUT" "has no status field — absent is not 'active'"
assert_has "  ... and blocks" "$OUT" "VERDICT  BLOCKED"

# ===========================================================================
hdr "4  firm packs must be in their DECLARED end state"
ROOT_P="${WORK}/root-packs"
build_fixture "$ROOT_P" || bad "pack fixture build failed"
PACKDIR="${ROOT_P}/companies/${CLIENT}/.hq-packs/service-kit"
mkdir -p "$PACKDIR" "${ROOT_P}/companies/${CLIENT}/skills/status-report"
printf 'a firm-authored skill\n' > "${ROOT_P}/companies/${CLIENT}/skills/status-report/SKILL.md"
PACK_SHA="$(shasum -a 256 "${ROOT_P}/companies/${CLIENT}/skills/status-report/SKILL.md" | awk '{print $1}')"
jq -n --arg sha "$PACK_SHA" '{
  schema:"hq-pack-manifest", schemaVersion:1, sourceFirm:"northwind-fixture",
  packName:"service-kit", version:"1.0.0", appliedAt:"2026-07-01T00:00:00Z",
  files:[{path:"skills/status-report/SKILL.md", sha256:$sha}] }' \
  > "${PACKDIR}/.hq-pack-manifest.json"
PA=(); while IFS= read -r a; do PA+=("$a"); done <<< "$(common_args "$ROOT_P")"

run "$HC" verify "${PA[@]}" --roster "${ROOT_P}/rosters/before.json"
assert_has "an applied pack with NO decision row is UNKNOWN" "$OUT" "has no row in the checklist's decision table"
assert_has "  ... 'nobody said' is not 'keep'" "$OUT" "'nobody said' is not 'keep'"
assert_has "  ... and blocks" "$OUT" "VERDICT  BLOCKED"

patch_file "$(CHK "$ROOT_P")" "| none | remove | n/a | none |" "| service-kit | remove | pending | none |"
run "$HC" verify "${PA[@]}" --roster "${ROOT_P}/rosters/before.json"
assert_has "decision=remove but the files are still there -> INCOMPLETE" "$OUT" "decision=remove but 1 manifest-owned file(s) are still present"
assert_has "  ... and blocks" "$OUT" "VERDICT  BLOCKED"

patch_file "$(CHK "$ROOT_P")" "| service-kit | remove | pending | none |" "| service-kit | stay | update | none |"
run "$HC" verify "${PA[@]}" --roster "${ROOT_P}/rosters/before.json"
assert_has "decision=stay with every file present -> DONE" "$OUT" "decision=stay and every manifest-owned file is present"
assert_has "  ... and the verdict clears" "$OUT" "VERDICT  READY"

rm -f "${ROOT_P}/companies/${CLIENT}/skills/status-report/SKILL.md"
run "$HC" verify "${PA[@]}" --roster "${ROOT_P}/rosters/before.json"
assert_has "decision=stay with a missing file -> INCOMPLETE" "$OUT" "decision=stay but manifest-owned file(s) are missing"
assert_no_external_call "pack verification made no external call"

# ===========================================================================
scenario_approval_gate() { # scenario_approval_gate <script> <tag>
  local script="$1"
  local tag="$2"
  local R="${WORK}/gate-${tag}"
  local before after
  build_fixture "$R" || { bad "[${tag}] fixture build failed"; return 0; }
  local A=(); while IFS= read -r a; do A+=("$a"); done <<< "$(common_args "$R")"

  # (a) DECLINED — a full, READY checklist, an explicit no.
  : > "$MOCKLOG"
  before="$(tree_manifest "$R")"
  run "$script" transfer "${A[@]}" --roster "${R}/rosters/before.json" \
    --to ops@atlasfixture.test --approval declined --initiator-role remove \
    --roster-after "${R}/rosters/after-clean.json"
  after="$(tree_manifest "$R")"
  assert_eq "[${tag}] declining completes cleanly (exit 0)" "0" "$RC"
  assert_has "[${tag}]  ... and says nothing was changed" "$OUT" "NOTHING was changed"
  assert_has "[${tag}]  ... the gate stated the irreversibility first" "$OUT" "IRREVERSIBLE"
  assert_has "[${tag}]  ... and who becomes owner" "$OUT" "Becomes owner:  ops@atlasfixture.test"
  if [ "$before" = "$after" ]; then
    ok "[${tag}] DECLINED -> the tree is byte-identical (checksum manifest before == after)"
  else
    bad "[${tag}] DECLINED -> the tree CHANGED: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5 | tr '\n' ' ')"
  fi
  if [ -s "$MOCKLOG" ]; then
    bad "[${tag}] DECLINED -> the transfer surface was called: $(tr '\n' '; ' < "$MOCKLOG")"
  else
    ok "[${tag}] DECLINED -> the transfer surface was never called"
  fi

  # (b) UNDECIDED — no --approval at all. Absent is not approval.
  : > "$MOCKLOG"
  before="$(tree_manifest "$R")"
  run "$script" transfer "${A[@]}" --roster "${R}/rosters/before.json" \
    --to ops@atlasfixture.test --roster-after "${R}/rosters/after-clean.json"
  after="$(tree_manifest "$R")"
  assert_eq "[${tag}] undecided completes cleanly (exit 0)" "0" "$RC"
  assert_has "[${tag}]  ... reported as not-approval" "$OUT" "Absent is not approval"
  if [ "$before" = "$after" ]; then
    ok "[${tag}] UNDECIDED -> the tree is byte-identical"
  else
    bad "[${tag}] UNDECIDED -> the tree CHANGED"
  fi
  if [ -s "$MOCKLOG" ]; then
    bad "[${tag}] UNDECIDED -> the transfer surface was called: $(tr '\n' '; ' < "$MOCKLOG")"
  else
    ok "[${tag}] UNDECIDED -> the transfer surface was never called"
  fi
}

hdr "5  THE APPROVAL GATE (real engine)"
scenario_approval_gate "$HC" real

# ===========================================================================
hdr "6  APPROVED executes the US-010 transfer through the mocked surface"
ROOT_T="${WORK}/root-transfer"
build_fixture "$ROOT_T" || bad "transfer fixture build failed"
TA=(); while IFS= read -r a; do TA+=("$a"); done <<< "$(common_args "$ROOT_T")"
: > "$MOCKLOG"; : > "$EXTLOG"

run "$HC" transfer "${TA[@]}" --roster "${ROOT_T}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved --initiator-role remove \
  --reason "handover fixture" --roster-after "${ROOT_T}/rosters/after-clean.json"
assert_eq "approved transfer exits 0" "0" "$RC"
assert_has "  ... the gate said the firm would be REMOVED" "$OUT" "be REMOVED from the company entirely"
assert_has "  ... the nomination was submitted" "$OUT" "Ownership moves when ops@atlasfixture.test accepts"
assert_has "  ... the US-010 command shape is exactly the CLI's" \
  "$(cat "$MOCKLOG")" "hq company transfer initiate --company atlas-fixture --to ops@atlasfixture.test --initiator-role remove --reason handover fixture --yes"
assert_eq "  ... exactly one transfer call was made" "1" \
  "$(grep -c 'company transfer initiate' "$MOCKLOG" || true)"
assert_no_external_call "the approved transfer used the mock, never a real binary"

hdr "6b a --dry-run approval plans the call and does NOT make it"
: > "$MOCKLOG"
run "$HC" transfer "${TA[@]}" --roster "${ROOT_T}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved --dry-run \
  --roster-after "${ROOT_T}/rosters/after-clean.json"
assert_eq "exits 0" "0" "$RC"
assert_has "  ... prints the plan" "$OUT" "--dry-run: the approved transfer was NOT executed"
assert_eq "  ... and calls nothing" "0" "$(wc -l < "$MOCKLOG" | tr -d ' ')"

hdr "6c a FAILING transfer is reported as UNKNOWN state, not as unchanged"
: > "$MOCKLOG"
MOCK_FAIL=1 run "$HC" transfer "${TA[@]}" --roster "${ROOT_T}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved \
  --roster-after "${ROOT_T}/rosters/after-clean.json"
MOCK_FAIL=0
assert_eq "exits 1" "1" "$RC"
assert_has "  ... named error" "$OUT" "E_TRANSFER_FAILED"
assert_has "  ... and refuses to call it unchanged" "$OUT" "Treat the state as UNKNOWN, not"

# ===========================================================================
hdr "7  POST-TRANSFER READ-BACK matches the checklist end state"
: > "$MOCKLOG"
run "$HC" transfer "${TA[@]}" --roster "${ROOT_T}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved --initiator-role remove \
  --roster-after "${ROOT_T}/rosters/after-clean.json"
assert_eq "exits 0" "0" "$RC"
assert_has "  ... the read-back is explicit that exit codes are not evidence" "$OUT" "the transfer's exit code is not evidence"
assert_has "  ... firm access matches the declared end state" "$OUT" "firm access matches the checklist's declared end state"

hdr "7b the read-back DETECTS a seeded mismatch"
# Seeded: the firm partner is STILL an active admin, but the checklist says the
# firm retains nothing.
: > "$MOCKLOG"
run "$HC" transfer "${TA[@]}" --roster "${ROOT_T}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved --initiator-role remove \
  --roster-after "${ROOT_T}/rosters/after-dirty.json"
assert_eq "a mismatch exits 1" "1" "$RC"
assert_has "  ... named error" "$OUT" "E_ACCESS_MISMATCH"
assert_has "  ... naming the exact residual membership" "$OUT" "partner@northwindfixture.test is STILL an active admin"
assert_eq "  ... and the transfer really was submitted first (this is a read-back failure, not a gate failure)" "1" \
  "$(grep -c 'company transfer initiate' "$MOCKLOG" || true)"

hdr "7c a WRONG-ROLE residual is a mismatch too"
ROOT_R="${WORK}/root-residual"
build_fixture "$ROOT_R" || bad "residual fixture build failed"
patch_file "$(CHK "$ROOT_R")" \
  '**Residual firm access after sign-off (should be "none"):** none' \
  '**Residual firm access after sign-off (should be "none"):** partner@northwindfixture.test:guest'
RA=(); while IFS= read -r a; do RA+=("$a"); done <<< "$(common_args "$ROOT_R")"
run "$HC" verify-access "${RA[@]}" --roster-after "${ROOT_R}/rosters/after-dirty.json"
assert_eq "exits 1" "1" "$RC"
assert_has "  ... the agreed role is enforced" "$OUT" "is 'admin' but the checklist agreed 'guest'"

hdr "7d an agreed grant that is NOT present is also a mismatch"
run "$HC" verify-access "${RA[@]}" --roster-after "${ROOT_R}/rosters/after-clean.json"
assert_eq "exits 1" "1" "$RC"
assert_has "  ... the missing agreed grant is named" "$OUT" "no active membership for them was read back"

hdr "7e an unreadable post-transfer roster is UNVERIFIED, never 'clean'"
run "$HC" verify-access "${RA[@]}" --roster-after "${WORK}/nope.json"
assert_eq "exits 1" "1" "$RC"
assert_has "  ... says so plainly" "$OUT" "Not-read is not not-present"

# ===========================================================================
hdr "8  local-only firms get a clear message, not a failure"
ROOT_L="${WORK}/root-local"
build_fixture "$ROOT_L" false || bad "local fixture build failed"
LA=(); while IFS= read -r a; do LA+=("$a"); done <<< "$(common_args "$ROOT_L")"
: > "$MOCKLOG"; : > "$EXTLOG"
run "$HC" transfer "${LA[@]}" --roster "${ROOT_L}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved --initiator-role remove \
  --roster-after "${ROOT_L}/rosters/after-clean.json"
assert_eq "local-only exits 0 — a clear answer, not an error" "0" "$RC"
assert_has "  ... with the required message" "$OUT" "ownership transfer requires a cloud-backed company"
assert_has "  ... explains why there is nothing to move" "$OUT" "no owner row, no vault custody"
assert_has "  ... and points at the fix" "$OUT" "/designate-team atlas-fixture"
assert_lacks "  ... and never claims to have transferred anything" "$OUT" "EXEC"
assert_eq "  ... the transfer surface was never called" "0" "$(wc -l < "$MOCKLOG" | tr -d ' ')"

hdr "8b an UNDECLARED cloud key is local, not cloud (absent is unknown)"
ROOT_U="${WORK}/root-undeclared"
build_fixture "$ROOT_U" || bad "undeclared fixture build failed"
printf 'slug: %s\nname: Atlas Fixture Ltd\n' "$CLIENT" > "${ROOT_U}/companies/${CLIENT}/company.yaml"
UA=(); while IFS= read -r a; do UA+=("$a"); done <<< "$(common_args "$ROOT_U")"
run "$HC" transfer "${UA[@]}" --roster "${ROOT_U}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved
assert_eq "exits 0" "0" "$RC"
assert_has "  ... treated as local because the key is UNDECLARED" "$OUT" "no 'cloud' key — UNDECLARED"

# ===========================================================================
hdr "9  the live-roster seam — read through --hq-bin, not a file"
: > "$MOCKLOG"
MOCK_ROSTER="${ROOT_T}/rosters/before.json" run "$HC" verify "${TA[@]}"
assert_eq "verify with a live roster exits 0" "0" "$RC"
assert_has "  ... roster provenance is the live read" "$OUT" "read live via"
assert_has "  ... verdict READY" "$OUT" "VERDICT  READY"
assert_eq "  ... exactly one members-list call" "1" "$(grep -c 'members list --company atlas-fixture' "$MOCKLOG" || true)"

hdr "9b a live roster read that FAILS is unknown, not empty"
: > "$MOCKLOG"
MOCK_ROSTER="" run "$HC" verify "${TA[@]}"
assert_has "  ... reported as unknown with the reason" "$OUT" "failed (rc=1) — unknown, not empty"
assert_has "  ... and blocks" "$OUT" "VERDICT  BLOCKED"

hdr "9c session scope — a session bound elsewhere is refused"
run "$HC" verify --pack-dir "$PACK" --hq-root "$ROOT1" --session-company "northwind-fixture" \
  --client "$CLIENT" --hq-bin "$MOCK_HQ" --firm-domain "$FIRM_DOMAIN" \
  --roster "${ROOT1}/rosters/before.json"
assert_eq "exits 1" "1" "$RC"
assert_has "  ... named error" "$OUT" "E_SESSION_SCOPE"

hdr "9d an UNKNOWN session binding is refused, not assumed"
run "$HC" verify --pack-dir "$PACK" --hq-root "$ROOT1" --client "$CLIENT" \
  --hq-bin "$MOCK_HQ" --firm-domain "$FIRM_DOMAIN" --roster "${ROOT1}/rosters/before.json"
assert_eq "exits 1" "1" "$RC"
assert_has "  ... unknown is not authorization" "$OUT" "E_SESSION_UNKNOWN"

hdr "9e --initiator-role owner is refused outright"
run "$HC" transfer "${TA[@]}" --roster "${ROOT_T}/rosters/before.json" \
  --to ops@atlasfixture.test --approval approved --initiator-role owner
assert_eq "exits 2" "2" "$RC"
assert_has "  ... because keeping owner is not a handover" "$OUT" "is not a handover"

# ===========================================================================
hdr "10 credential-shaped strings in everything US-011 wrote"
SECRET_HITS="$(grep -riE 'sk_|xox|AKIA|BEGIN .*PRIVATE KEY' \
  "$HC" "${PACK}/skills/handover-client/SKILL.md" 2>/dev/null || true)"
if [ -z "$SECRET_HITS" ]; then ok "clean"; else bad "credential-shaped strings found: ${SECRET_HITS}"; fi
if grep -qE '(--reveal|secrets[[:space:]]+(get|show|cat))' "$HC"; then
  bad "the engine reaches for a secret VALUE"
else
  ok "the engine never invokes a secret-reveal path (names only)"
fi

hdr "11 static check — the engine invokes no network-facing binary of its own"
STATIC_HITS="$(grep -nE '^[[:space:]]*(hq|curl|wget|gh|aws|ssh|scp|nc|open)[[:space:]]' "$HC" || true)"
if [ -z "$STATIC_HITS" ]; then
  ok "no line executes hq/curl/wget/gh/aws/ssh/scp/nc/open directly"
else
  bad "the engine executes a network-facing binary: ${STATIC_HITS}"
fi
assert_eq "there is exactly ONE outward seam, and it is \$HQ_BIN in hq_call" "1" \
  "$(grep -c '^  HQ_OUT="\$("\$HQ_BIN"' "$HC" || true)"

REAL_FAILS="$TOTAL_FAILS"

# ===========================================================================
# DISCRIMINATION — the guards must be the reason those tests pass
# ===========================================================================
ORIG_SHA="$(shasum -a 256 "$HC" | awk '{print $1}')"

make_broken() { # make_broken <name> <exact-old> <exact-new> -> path or BROKEN-FAILED
  local name="$1"
  local old="$2"
  local new="$3"
  local out="${WORK}/broken-${name}.sh"
  local rc=0
  BROKEN_OLD="$old" BROKEN_NEW="$new" python3 - "$HC" "$out" <<'PY' || rc=$?
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
  # The broken copy must still RUN, otherwise the scenario would fail because
  # the file is broken rather than because the guard is gone.
  bash -n "$out" >/dev/null 2>&1 || { printf 'BROKEN-FAILED'; return 0; }
  PATH="${SHIMS}:${PATH}" bash "$out" --help >/dev/null 2>&1 || { printf 'BROKEN-FAILED'; return 0; }
  printf '%s' "$out"
}

run_discrimination() { # run_discrimination <label> <broken> <fn> <tag>
  local label="$1"
  local broken="$2"
  local fn="$3"
  local tag="$4"
  local before after failed
  hdr "DISCRIMINATION — ${label}"
  if [ "$broken" = "BROKEN-FAILED" ] || [ -z "$broken" ] || [ ! -s "$broken" ]; then
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

BROKEN_BLOCK="$(make_broken checklistblock \
  'if [ "$VERDICT" != "READY" ]; then' \
  'if false; then')"
run_discrimination "checklist-blocking guard removed — scenario 2 MUST fail" \
  "$BROKEN_BLOCK" scenario_incomplete_blocks brokenblock
run_discrimination "checklist-blocking guard removed — scenario 3 MUST fail too" \
  "$BROKEN_BLOCK" scenario_unknown_blocks brokenblock2

BROKEN_GATE="$(make_broken approvalgate \
  'case "$APPROVAL" in
  approved) ;;
  declined)' \
  'case "approved" in
  approved) ;;
  declined)')"
run_discrimination "approval gate removed — scenario 5 MUST fail" \
  "$BROKEN_GATE" scenario_approval_gate brokengate

hdr "DISCRIMINATION — the real engine was restored byte-identically"
NOW_SHA="$(shasum -a 256 "$HC" | awk '{print $1}')"
assert_eq "handover-client.sh sha256 is unchanged by this suite" "$ORIG_SHA" "$NOW_SHA"
printf '        %s  %s\n' "$NOW_SHA" "$HC"

# ===========================================================================
hdr "SUMMARY"
assert_no_external_call "ACROSS THE WHOLE SUITE — no external call was ever made"
printf '  real-engine assertion failures : %d\n' "$REAL_FAILS"
printf '  total failures                 : %d\n' "$TOTAL_FAILS"
printf '  fixture root                   : %s%s\n' "$WORK" "$( [ "$KEEP" -eq 1 ] && printf ' (kept)' || printf ' (removed)')"
if [ "$TOTAL_FAILS" -eq 0 ]; then
  printf 'ALL GREEN\n'
  exit 0
fi
printf 'FAILURES: %d\n' "$TOTAL_FAILS"
exit 1
