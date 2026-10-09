#!/usr/bin/env bash
# client-pack-verify.sh — fixture-only regression suite for client-pack.sh.
#
#   client-pack-verify.sh [--keep]
#
# Builds a throwaway HQ root under $TMPDIR with a fixture firm and fixture client
# companies. It NEVER touches a real company tree, and every name in it is
# invented.
#
# Scenarios
#   0  scaffold builds packs/{name}/ from firm assets and stages a portable bundle;
#      a client-bound session may not scaffold in the firm
#   1  apply writes a manifest whose sha256 values match the copied bytes
#   2  re-apply of the same version is a no-op
#   3  update rewrites an unmodified manifest-owned file
#   4  FORK SURVIVAL ON UPDATE   — a client-edited file is byte-preserved + reported
#   5  FORK SURVIVAL ON REMOVE   — fork and client-created file survive; clean files go
#   6  absent-field safety       — a manifest entry with NO sha256 is preserved by
#                                  both update and remove; a missing manifest and an
#                                  unbound/mismatched session are refused
#
# Discrimination check
#   Scenarios 4 and 5 are re-run against a deliberately broken copy of
#   client-pack.sh whose fork detection always answers "clean". They MUST fail
#   there. A fork test that passes with fork detection disabled proves nothing.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CP="${SCRIPT_DIR}/client-pack.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d)"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

TOTAL_FAILS=0
SCEN_FAILS=0

hdr()  { printf '\n=== %s\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; SCEN_FAILS=$((SCEN_FAILS + 1)); TOTAL_FAILS=$((TOTAL_FAILS + 1)); }

assert_eq() { # assert_eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert_exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_absent() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (still present: $2)"; fi; }
assert_has()    { # assert_has <label> <text> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in output)" ;; esac
}

sha_of() { shasum -a 256 -- "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------------------
# fixture construction — invented names only
# ---------------------------------------------------------------------------

FIRM="northgate-partners"
CLIENT="atlas-widgets"
PACKNAME="service-kit"

new_root() { # new_root <tag> -> prints the fixture HQ root
  local root="${WORK}/$1/hq"
  mkdir -p "${root}/companies/${FIRM}" "${root}/companies/${CLIENT}" "${root}/workspace"
  printf '%s' "$root"
}

seed_pack() { # seed_pack <root> <version>
  local root="$1" ver="$2" p="${root}/companies/${FIRM}/packs/${PACKNAME}"
  mkdir -p "${p}/skills/status-report" "${p}/knowledge" "${p}/_drafts"
  printf 'house status report skill — v%s\n' "$ver" > "${p}/skills/status-report/SKILL.md"
  printf 'checklist body v%s\n' "$ver"                > "${p}/skills/status-report/checklist.md"
  printf 'house tone and formatting rules v%s\n' "$ver" > "${p}/knowledge/house-style.md"
  # A `_`-prefixed pseudo-dir at the pack root must never be auto-selected as a pack.
  printf 'not a pack\n' > "${p}/_drafts/scratch.md"
}

stage_pack() { # stage_pack <script> <root> <version>
  local s="$1" root="$2" ver="$3"
  sed -i.bak "s/^version: .*/version: ${ver}/" "${root}/companies/${FIRM}/packs/${PACKNAME}/pack.yaml"
  rm -f "${root}/companies/${FIRM}/packs/${PACKNAME}/pack.yaml.bak"
  "$s" scaffold --hq-root "$root" --session-company "$FIRM" \
       --firm "$FIRM" --pack "$PACKNAME" --stage-only
}

bootstrap() { # bootstrap <script> <tag> <version> -> prints root
  local s="$1" root; root="$(new_root "$2")"
  "$s" scaffold --hq-root "$root" --session-company "$FIRM" \
       --firm "$FIRM" --pack "$PACKNAME" >/dev/null
  seed_pack "$root" "$3"
  stage_pack "$s" "$root" "$3" >/dev/null
  printf '%s' "$root"
}

MAN_REL=".hq-packs/${PACKNAME}/.hq-pack-manifest.json"

# ---------------------------------------------------------------------------
# Scenario 0 — scaffold builds the firm pack dir from firm assets
# ---------------------------------------------------------------------------

scenario_0() {
  hdr "Scenario 0 — scaffold creates packs/{name}/ from firm assets"
  local root out p
  root="$(new_root s0)"
  mkdir -p "${root}/companies/${FIRM}/skills/firm-brief"
  printf 'the firm house brief\n' > "${root}/companies/${FIRM}/skills/firm-brief/SKILL.md"
  out="$("$CP" scaffold --hq-root "$root" --session-company "$FIRM" \
        --firm "$FIRM" --pack "$PACKNAME" --include skills/firm-brief 2>&1)"
  printf '%s\n' "$out"
  p="${root}/companies/${FIRM}/packs/${PACKNAME}"
  assert_exists "pack.yaml created" "${p}/pack.yaml"
  assert_exists "content subdirs created" "${p}/knowledge"
  assert_exists "firm asset seeded into the pack via --include" "${p}/skills/firm-brief/SKILL.md"
  assert_exists "portable bundle staged in workspace/ (company-neutral)" \
    "${root}/workspace/pack-staging/${FIRM}/${PACKNAME}/pack.json"
  assert_exists "bundle carries the seeded asset" \
    "${root}/workspace/pack-staging/${FIRM}/${PACKNAME}/content/skills/firm-brief/SKILL.md"

  hdr "Scenario 0b — a client-bound session may not scaffold in the firm"
  local rc=0
  out="$("$CP" scaffold --hq-root "$root" --session-company "$CLIENT" \
        --firm "$FIRM" --pack "$PACKNAME" --stage-only 2>&1)" || rc=$?
  printf '%s\n' "$out"
  assert_eq "cross-company scaffold refused (exit 1)" "1" "$rc"
}

# ---------------------------------------------------------------------------
# Scenario 1 — apply + manifest integrity
# ---------------------------------------------------------------------------

scenario_1() {
  hdr "Scenario 1 — apply writes a manifest whose sha256 values match the bytes"
  local root out man rel recorded actual n=0 mism=0
  root="$(bootstrap "$CP" s1 1.0.0)"
  out="$("$CP" apply --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME" 2>&1)"
  printf '%s\n' "$out"
  man="${root}/companies/${CLIENT}/${MAN_REL}"
  assert_exists "manifest written at .hq-packs/${PACKNAME}/.hq-pack-manifest.json" "$man"
  [ -f "$man" ] || return 0
  printf -- '--- manifest ---\n'
  cat "$man"
  printf -- '--- sha cross-check (recomputed from the copied files) ---\n'
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    recorded="$(jq -r --arg p "$rel" '.files[] | select(.path==$p) | .sha256' "$man")"
    actual="$(sha_of "${root}/companies/${CLIENT}/${rel}")"
    n=$((n + 1))
    if [ "$recorded" = "$actual" ]; then
      printf '  match  %s  %s\n' "${actual:0:16}…" "$rel"
    else
      printf '  MISMATCH %s recorded=%s actual=%s\n' "$rel" "$recorded" "$actual"
      mism=$((mism + 1))
    fi
  done <<< "$(jq -r '.files[].path' "$man")"
  assert_eq "all 3 pack files copied and recorded" "3" "$n"
  assert_eq "0 sha mismatches" "0" "$mism"
  assert_eq "sourceFirm recorded" "$FIRM" "$(jq -r .sourceFirm "$man")"
  assert_eq "packName recorded" "$PACKNAME" "$(jq -r .packName "$man")"
  assert_eq "version recorded" "1.0.0" "$(jq -r .version "$man")"
  assert_eq "grantedVia.kind present (forward-compat with the entitlement record)" \
    "local-copy" "$(jq -r '.grantedVia.kind' "$man")"
  [ -n "$(jq -r '.appliedAt' "$man")" ] && ok "appliedAt recorded" || bad "appliedAt missing"
  assert_absent "the pack's _drafts pseudo-dir was not staged as content" \
    "${root}/companies/${CLIENT}/_drafts"

  hdr "Scenario 2 — re-apply of the same version is a no-op"
  out="$("$CP" apply --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME" 2>&1)"
  printf '%s\n' "$out"
  assert_has "re-apply reports no-op" "$out" "no-op"
  assert_has "re-apply wrote nothing" "$out" "0 written, 0 removed"
}

# ---------------------------------------------------------------------------
# Scenario 3 — update rewrites an unmodified manifest-owned file
# ---------------------------------------------------------------------------

scenario_3() {
  hdr "Scenario 3 — update rewrites an unmodified manifest-owned file"
  local root out target before after man
  root="$(bootstrap "$CP" s3 1.0.0)"
  "$CP" apply --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME" >/dev/null 2>&1
  target="${root}/companies/${CLIENT}/skills/status-report/SKILL.md"
  before="$(cat "$target")"
  seed_pack "$root" 1.1.0
  stage_pack "$CP" "$root" 1.1.0 >/dev/null
  out="$("$CP" update --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --pack "$PACKNAME" 2>&1)"
  printf '%s\n' "$out"
  after="$(cat "$target")"
  printf '  client file before: %s\n' "$before"
  printf '  client file after : %s\n' "$after"
  assert_eq "unmodified file now carries the new pack content" \
    "house status report skill — v1.1.0" "$after"
  assert_has "reported as updated" "$out" "updated"
  man="${root}/companies/${CLIENT}/${MAN_REL}"
  assert_eq "manifest sha follows the rewritten bytes" \
    "$(sha_of "$target")" \
    "$(jq -r '.files[] | select(.path=="skills/status-report/SKILL.md") | .sha256' "$man")"
  assert_eq "manifest version bumped" "1.1.0" "$(jq -r .version "$man")"
}

# ---------------------------------------------------------------------------
# Scenarios 4 + 5 — fork survival (also used for the discrimination check)
# ---------------------------------------------------------------------------

fork_scenarios() { # fork_scenarios <script-under-test> <tag>
  local s="$1" tag="$2"
  local root out fork_file fork_before fork_sha_before fork_sha_after man clean_file client_file

  hdr "Scenario 4 — FORK SURVIVAL ON UPDATE  [$tag]"
  root="$(bootstrap "$s" "$tag" 1.0.0)"
  "$s" apply --hq-root "$root" --session-company "$CLIENT" \
       --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME" >/dev/null 2>&1

  fork_file="${root}/companies/${CLIENT}/skills/status-report/checklist.md"
  clean_file="${root}/companies/${CLIENT}/skills/status-report/SKILL.md"
  client_file="${root}/companies/${CLIENT}/knowledge/atlas-only-note.md"

  # The client edits a manifest-owned file, and writes one of their own.
  printf 'checklist body v1.0.0\nATLAS EDIT: add the safety sign-off step\n' > "$fork_file"
  mkdir -p "$(dirname "$client_file")"
  printf 'a note the client wrote themselves\n' > "$client_file"
  fork_before="$(cat "$fork_file")"
  fork_sha_before="$(sha_of "$fork_file")"

  # The firm ships a new version that changes the very file the client forked.
  seed_pack "$root" 1.2.0
  stage_pack "$s" "$root" 1.2.0 >/dev/null
  out="$("$s" update --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --pack "$PACKNAME" 2>&1)"
  printf '%s\n' "$out"

  fork_sha_after="$(sha_of "$fork_file")"
  printf '  fork sha before update: %s\n' "$fork_sha_before"
  printf '  fork sha after  update: %s\n' "$fork_sha_after"
  printf '  fork content after    : %s\n' "$(tr '\n' '|' < "$fork_file")"
  assert_eq "client's forked bytes are byte-identical after update" "$fork_sha_before" "$fork_sha_after"
  assert_eq "client's forked text is unchanged" "$fork_before" "$(cat "$fork_file")"
  assert_has "fork is REPORTED, not silently skipped" "$out" "FORK-skipped"
  assert_has "fork report names the file" "$out" "skills/status-report/checklist.md"
  assert_eq "unforked sibling did update" "house status report skill — v1.2.0" "$(cat "$clean_file")"
  man="${root}/companies/${CLIENT}/${MAN_REL}"
  assert_eq "manifest keeps the ORIGINAL applied sha for the fork (never adopts the edit)" \
    "false" \
    "$(jq -r --arg s "$fork_sha_after" '[.files[] | select(.path=="skills/status-report/checklist.md") | .sha256 == $s][0]' "$man")"
  assert_eq "manifest marks it forked" "true" \
    "$(jq -r '[.files[] | select(.path=="skills/status-report/checklist.md") | .forked][0]' "$man")"

  hdr "Scenario 5 — FORK SURVIVAL ON REMOVE  [$tag]"
  out="$("$s" remove --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --pack "$PACKNAME" 2>&1)"
  printf '%s\n' "$out"
  assert_exists "forked file survives remove" "$fork_file"
  assert_exists "client-created file survives remove" "$client_file"
  assert_absent "unforked manifest-owned file is gone" "$clean_file"
  assert_absent "other unforked manifest-owned file is gone" \
    "${root}/companies/${CLIENT}/knowledge/house-style.md"
  assert_has "fork is reported as kept" "$out" "FORK-kept"
  if [ -e "$fork_file" ]; then
    assert_eq "forked bytes still byte-identical after remove" "$fork_sha_before" "$(sha_of "$fork_file")"
  fi
  printf '  surviving client tree:\n'
  ( cd "${root}/companies/${CLIENT}" && find . -type f | LC_ALL=C sort | sed 's/^/    /' )
}

# ---------------------------------------------------------------------------
# Scenario 6 — absent-field safety
# ---------------------------------------------------------------------------

scenario_6() {
  hdr "Scenario 6 — a manifest entry with NO sha256 is preserved by update and remove"
  local root out man target before
  root="$(bootstrap "$CP" s6 1.0.0)"
  "$CP" apply --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME" >/dev/null 2>&1
  man="${root}/companies/${CLIENT}/${MAN_REL}"
  target="${root}/companies/${CLIENT}/knowledge/house-style.md"

  # Strip the sha256 key entirely from one entry, and null another. Neither may
  # be read as "unchanged" or "safe to delete".
  jq '(.files[] | select(.path=="knowledge/house-style.md")) |= del(.sha256)
      | (.files[] | select(.path=="skills/status-report/checklist.md")).sha256 = null' \
     "$man" > "${man}.tmp" && mv "${man}.tmp" "$man"
  printf -- '--- manifest entries under test ---\n'
  jq -c '.files[] | select(.path=="knowledge/house-style.md" or .path=="skills/status-report/checklist.md")' "$man"

  before="$(sha_of "$target")"
  seed_pack "$root" 1.3.0
  stage_pack "$CP" "$root" 1.3.0 >/dev/null
  out="$("$CP" update --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --pack "$PACKNAME" 2>&1)"
  printf '%s\n' "$out"
  assert_eq "entry with ABSENT sha was not overwritten by update" "$before" "$(sha_of "$target")"
  assert_has "absent sha reported as unknown, not as clean" "$out" "unknown-sha"

  out="$("$CP" remove --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --pack "$PACKNAME" 2>&1)"
  printf '%s\n' "$out"
  assert_exists "entry with ABSENT sha survives remove" "$target"
  assert_exists "entry with NULL sha survives remove" \
    "${root}/companies/${CLIENT}/skills/status-report/checklist.md"
  assert_absent "the one entry with a valid matching sha was removed" \
    "${root}/companies/${CLIENT}/skills/status-report/SKILL.md"

  hdr "Scenario 6b — a MISSING manifest is refused, not treated as 'nothing owned'"
  rm -rf "${root}/companies/${CLIENT}/.hq-packs"
  local rc=0
  out="$("$CP" remove --hq-root "$root" --session-company "$CLIENT" \
        --client "$CLIENT" --pack "$PACKNAME" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  assert_eq "remove without a manifest exits 1 (refused)" "1" "$rc"
  assert_exists "client files untouched by the refusal" "$target"

  hdr "Scenario 6c — writing into a client the session is not bound to is refused"
  rc=0
  out="$("$CP" apply --hq-root "$root" --session-company "$FIRM" \
        --client "$CLIENT" --firm "$FIRM" --pack "$PACKNAME" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  assert_eq "firm-bound session may not write into the client (exit 1)" "1" "$rc"
  assert_has "error explains materialize-not-mount" "$out" "E_SESSION_SCOPE"
}

# ---------------------------------------------------------------------------
# discrimination check — break fork detection, the fork tests MUST fail
# ---------------------------------------------------------------------------

make_broken() { # prints path to a client-pack.sh with fork detection disabled
  local broken="${WORK}/broken-client-pack.sh"
  sed 's|if \[ "$cur" = "$msha" \]; then printf .clean.; else printf .fork.; fi|printf '"'"'clean'"'"'|' \
    "$CP" > "$broken"
  chmod +x "$broken"
  if grep -q "printf 'fork'" "$broken"; then
    printf 'BROKEN-COPY-FAILED'
    return 0
  fi
  printf '%s' "$broken"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 2; }

printf 'client-pack-verify — fixture root: %s\n' "$WORK"
printf 'firm=%s client=%s pack=%s (all invented; no real company tree is touched)\n' \
  "$FIRM" "$CLIENT" "$PACKNAME"

scenario_0
scenario_1
scenario_3
fork_scenarios "$CP" real
scenario_6

REAL_FAILS="$TOTAL_FAILS"

hdr "DISCRIMINATION CHECK — re-run scenarios 4 and 5 with fork detection DISABLED"
BROKEN="$(make_broken)"
if [ "$BROKEN" = "BROKEN-COPY-FAILED" ]; then
  printf '  FAIL  could not build the broken copy — discrimination check is inconclusive\n'
  TOTAL_FAILS=$((TOTAL_FAILS + 1))
else
  printf '  patched classify() so every manifest-owned file answers "clean"\n'
  SCEN_FAILS=0
  BEFORE_TOTAL="$TOTAL_FAILS"
  fork_scenarios "$BROKEN" broken
  BROKEN_FAILS=$((TOTAL_FAILS - BEFORE_TOTAL))
  TOTAL_FAILS="$BEFORE_TOTAL"   # failures under the broken build are EXPECTED
  hdr "DISCRIMINATION RESULT"
  if [ "$BROKEN_FAILS" -gt 0 ]; then
    printf '  PASS  fork tests failed %d assertion(s) with detection disabled — they discriminate\n' "$BROKEN_FAILS"
  else
    printf '  FAIL  fork tests still passed with detection disabled — they prove nothing\n'
    TOTAL_FAILS=$((TOTAL_FAILS + 1))
  fi
fi

hdr "SUMMARY"
printf '  real-build assertion failures : %d\n' "$REAL_FAILS"
printf '  total failures                : %d\n' "$TOTAL_FAILS"
if [ "$TOTAL_FAILS" -eq 0 ]; then
  printf 'ALL GREEN\n'
  exit 0
fi
printf 'FAILURES: %d\n' "$TOTAL_FAILS"
exit 1
