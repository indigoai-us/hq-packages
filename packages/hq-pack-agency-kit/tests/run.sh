#!/usr/bin/env bash
# Tests for hq-pack-agency-kit scripts. Runs against a throwaway HQ root in a temp dir.
# Usage: bash tests/run.sh
set -uo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$PACK_DIR/scripts/agency-setup.sh"
PRACTICE="$PACK_DIR/scripts/practice-client.sh"
WORKSPACE="$PACK_DIR/scripts/client-workspace.sh"
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

new_root() {
  local r; r="$(mktemp -d)"
  mkdir -p "$r/companies/acme-agency"
  printf '%s' "$r"
}

# --- agency-setup ---------------------------------------------------------
R="$(new_root)"
P="$R/companies/acme-agency/knowledge/agency-playbook"

bash "$SETUP" --firm acme-agency --name "Acme & Co / Growth" --services "Paid ads" --root "$R" >/dev/null 2>&1
check "setup writes six playbook files" '[ "$(ls "$P" | wc -l | tr -d " ")" = 6 ]'
check "setup fills agency name with special characters" 'grep -q "Acme & Co / Growth" "$P/agency-profile.md"'
check "setup fills services" 'grep -q "Paid ads" "$P/agency-profile.md"'
check "setup marks unanswered fields" 'grep -q "Not answered yet" "$P/agency-profile.md"'
check "setup leaves no unfilled placeholders" '! grep -rq "{{" "$P"'
check "setup defaults client workspace to folder" 'grep -q "^Default client workspace: folder$" "$P/agency-profile.md"'
bash "$SETUP" --firm acme-agency --name X --root "$R" --client-mode sideways >/dev/null 2>&1; rc=$?
check "setup refuses an unknown client mode (exit 1)" '[ "$rc" = 1 ]'

printf 'EDITED BY AGENCY\n' > "$P/scope-rules.md"
rm "$P/learnings.md"
out="$(bash "$SETUP" --firm acme-agency --name "Other" --root "$R" 2>&1)"
check "rerun keeps an edited file" 'grep -q "EDITED BY AGENCY" "$P/scope-rules.md"'
check "rerun restores a missing file" '[ -f "$P/learnings.md" ]'
check "rerun reports kept files" 'printf "%s" "$out" | grep -q "written=1 kept=5"'

bash "$SETUP" --firm no-such-firm --name X --root "$R" >/dev/null 2>&1; rc=$?
check "setup refuses a missing company (exit 2)" '[ "$rc" = 2 ]'
bash "$SETUP" --firm "../evil" --name X --root "$R" >/dev/null 2>&1; rc=$?
check "setup refuses a path-like slug (exit 1)" '[ "$rc" = 1 ]'

R2="$(new_root)"
bash "$SETUP" --firm acme-agency --name X --root "$R2" --dry-run >/dev/null 2>&1
check "dry run writes nothing" '[ ! -d "$R2/companies/acme-agency/knowledge/agency-playbook" ]'

# --- practice-client ------------------------------------------------------
bash "$PRACTICE" --firm acme-agency --agency-name "Acme" --root "$R" >/dev/null 2>&1; rc=$?
check "practice refuses without an engagement folder (exit 2)" '[ "$rc" = 2 ]'

mkdir -p "$R/companies/acme-agency/clients/practice-northwind"
I="$R/companies/acme-agency/clients/practice-northwind/onboarding/inputs"
bash "$PRACTICE" --firm acme-agency --agency-name "Acme & Co" --root "$R" >/dev/null 2>&1
check "practice loads seven files" '[ "$(ls "$I" | wc -l | tr -d " ")" = 7 ]'
check "practice fills the agency name" 'grep -q "Acme & Co" "$I/contract.md"'
check "practice strips the answer key" '! grep -q "For instructors" "$I/README.md"'
check "practice csvs are intact" '[ "$(wc -l < "$I/crm-outcomes.csv" | tr -d " ")" = 14 ]'

printf 'student work\n' > "$I/contract.md"
bash "$PRACTICE" --firm acme-agency --agency-name "Acme" --root "$R" >/dev/null 2>&1; rc=$?
check "practice refuses to overwrite existing inputs" '[ "$rc" = 1 ] && grep -q "student work" "$I/contract.md"'

# --- client-workspace -----------------------------------------------------
bash "$WORKSPACE" --firm acme-agency --client atlas --root "$R" >/dev/null 2>&1; rc=$?
check "workspace refuses without an engagement folder (exit 2)" '[ "$rc" = 2 ]'
bash "$WORKSPACE" --firm acme-agency --client "../x" --root "$R" >/dev/null 2>&1; rc=$?
check "workspace refuses a path-like client slug (exit 1)" '[ "$rc" = 1 ]'

C="$R/companies/acme-agency/clients/atlas"
mkdir -p "$C" && printf 'engagement\n' > "$C/engagement.md"
out="$(bash "$WORKSPACE" --firm acme-agency --client atlas --client-name "Atlas & Sons" --root "$R" 2>&1)"
check "workspace writes five template files" 'printf "%s" "$out" | grep -q "written=5 kept=0"'
check "workspace creates nested folders" '[ -f "$C/onboarding/inputs/README.md" ] && [ -f "$C/reports/README.md" ]'
check "workspace fills the client name with special characters" 'grep -q "Atlas & Sons" "$C/client-profile.md"'
check "workspace fills the agency name from the playbook" 'grep -q "Acme & Co / Growth" "$C/README.md"'
check "workspace takes folder mode from the playbook" 'grep -q "in \*\*folder\*\* mode" "$C/README.md"'
check "workspace leaves no unfilled placeholders" '! grep -rq "{{" "$C"'
check "workspace leaves engagement.md alone" 'grep -q "^engagement$" "$C/engagement.md"'

printf 'EDITED BY AGENCY\n' > "$C/client-profile.md"
rm "$C/access-and-assets.md"
out="$(bash "$WORKSPACE" --firm acme-agency --client atlas --root "$R" 2>&1)"
check "workspace rerun keeps an edited file" 'grep -q "EDITED BY AGENCY" "$C/client-profile.md"'
check "workspace rerun restores a missing file" '[ -f "$C/access-and-assets.md" ]'
check "workspace rerun reports kept files" 'printf "%s" "$out" | grep -q "written=1 kept=4"'

mkdir -p "$R/companies/acme-agency/clients/beta" && : > "$R/companies/acme-agency/clients/beta/engagement.md"
out="$(bash "$WORKSPACE" --firm acme-agency --client beta --mode company --root "$R" 2>&1)"
check "workspace company mode prints the next steps" 'printf "%s" "$out" | grep -q "hq-session.sh add company beta"'
check "workspace company mode records the mode" 'grep -q "in \*\*company\*\* mode" "$R/companies/acme-agency/clients/beta/README.md"'
check "workspace company mode writes nothing outside the firm" '[ ! -d "$R/companies/beta" ]'
bash "$WORKSPACE" --firm acme-agency --client beta --mode sideways --root "$R" >/dev/null 2>&1; rc=$?
check "workspace refuses an unknown mode (exit 1)" '[ "$rc" = 1 ]'

mkdir -p "$R/companies/acme-agency/clients/gamma"
bash "$WORKSPACE" --firm acme-agency --client gamma --root "$R" --dry-run >/dev/null 2>&1
check "workspace dry run writes nothing" '[ ! -f "$R/companies/acme-agency/clients/gamma/README.md" ]'

# --- package consistency --------------------------------------------------
for s in $(awk '/^  skills:/{f=1;next} /^  [a-z]+:/{f=0} f && /- /{print $2}' "$PACK_DIR/package.yaml"); do
  check "skill $s has SKILL.md with matching name" 'grep -q "^name: $s$" "$PACK_DIR/skills/$s/SKILL.md"'
done
for p in $(awk '/^  policies:/{f=1;next} /^  [a-z]+:/{f=0} f && /- /{print $2}' "$PACK_DIR/package.yaml"); do
  check "policy $p exists with matching id" 'grep -q "^id: $p$" "$PACK_DIR/policies/$p.md"'
done

# --- answer key matches the data -----------------------------------------
E="$PACK_DIR/examples/practice-client/inputs"
spend_total="$(awk -F, 'NR>1{s+=$5} END{print s}' "$E/campaign-export.csv")"
trial_share="$(awk -F, 'NR>1{s+=$5} $2 ~ /Free Trial/{t=$5} END{printf "%d", t*100/s}' "$E/campaign-export.csv")"
ent_opps="$(awk -F, 'NR>1 && $3=="500+"{s+=$5} END{print s}' "$E/crm-outcomes.csv")"
ent_opps_target="$(awk -F, 'NR>1 && $3=="500+" && ($2 ~ /Enterprise|LinkedIn/){s+=$5} END{print s}' "$E/crm-outcomes.csv")"
trial_ent="$(awk -F, 'NR>1 && $3=="500+" && $2 ~ /Free Trial/{s+=$5} END{print s+0}' "$E/crm-outcomes.csv")"
check "spend total is 40000" '[ "$spend_total" = 40000 ]'
check "free trial is 46% of spend" '[ "$trial_share" = 46 ]'
check "11 enterprise opportunities in total" '[ "$ent_opps" = 11 ]'
check "7 enterprise opportunities from enterprise search and LinkedIn" '[ "$ent_opps_target" = 7 ]'
check "free trial produced 0 enterprise opportunities" '[ "$trial_ent" = 0 ]'

rm -rf "$R" "$R2"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
