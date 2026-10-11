#!/usr/bin/env bash
# Tests for hq-pack-agency-kit scripts. Runs against a throwaway HQ root in a temp dir.
# Usage: bash tests/run.sh
set -uo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$PACK_DIR/scripts/agency-setup.sh"
PRACTICE="$PACK_DIR/scripts/practice-client.sh"
WORKSPACE="$PACK_DIR/scripts/client-workspace.sh"
GRADE="$PACK_DIR/scripts/grade-practice.sh"
WORKER="$PACK_DIR/workers/agency-guide"
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

# --- setup block (build contract, section 1) -----------------------------
PKG="$PACK_DIR/package.yaml"
setup_block() { awk '/^setup:/{f=1;next} f && /^[a-z]/{f=0} f' "$PKG"; }
bot_name="$(setup_block | awk '/^  bot:/{f=1;next} f && /^  [a-z]/{f=0} f && $1=="name:"{print $2; exit}')"
bot_display="$(setup_block | awk '/^  bot:/{f=1;next} f && /^  [a-z]/{f=0} f && $1=="display_name:"{sub(/^[^:]*:[[:space:]]*/,""); print; exit}')"
check "setup block is present" '[ -n "$(setup_block)" ]'
check "setup.bot.name is agency-guide" '[ "$bot_name" = agency-guide ]'
check "setup.bot.name matches ^[a-z0-9-]{2,32}$" 'printf "%s" "$bot_name" | grep -qE "^[a-z0-9-]{2,32}$"'
check "setup.bot.display_name is Agency Guide" '[ "$bot_display" = "Agency Guide" ]'
check "setup.bot.name is listed under contributes.workers" 'awk "/^  workers:/{f=1;next} /^  [a-z]+:/{f=0} f" "$PKG" | grep -q "^    - $bot_name$"'
check "setup.takeover_setup is true" 'setup_block | grep -q "^  takeover_setup: true"'
qids="$(setup_block | awk '/^  questions:/{f=1;next} f && /^  [a-z]/{f=0} f && $1=="-" && $2=="id:"{print $3}')"
check "setup has six questions" '[ "$(printf "%s\n" "$qids" | wc -l | tr -d " ")" = 6 ]'
check "question ids are unique" '[ "$(printf "%s\n" "$qids" | sort | uniq -d | wc -l | tr -d " ")" = 0 ]'
check "question ids match ^[a-z_]+$" '! printf "%s\n" "$qids" | grep -qvE "^[a-z_]+$"'
check "first question is agency_name with default_from company_display_name" 'setup_block | awk "/^  questions:/{f=1;next} f" | grep -m1 -A4 "id: agency_name" | grep -q "default_from: company_display_name"'
check "every question has an options list" '[ "$(setup_block | awk "/^  questions:/{f=1;next} f && /^  [a-z]/{f=0} f" | grep -c "^      options: \[")" = 6 ]'
check "agency_name is not skippable" 'setup_block | awk "/id: agency_name/{f=1} f && /skippable/{print; exit}" | grep -q "skippable: false"'
run_script="$(setup_block | awk '/^  run:/{f=1;next} f && /^  [a-z]/{f=0} f && $1=="script:"{print $2; exit}')"
check "run.script is scripts/agency-setup.sh and exists" '[ "$run_script" = scripts/agency-setup.sh ] && [ -f "$PACK_DIR/$run_script" ]'
arg_keys="$(setup_block | awk '/^  run:/{f=1;next} f && /^  [a-z]/{f=0} f' | awk '/^    args:/{a=1;next} a && /^    [a-z]/{a=0} a && /^      [a-z_]+:/{sub(/:.*/,""); sub(/^ +/,""); print}')"
check "run.args has one key per question" '[ "$(printf "%s\n" "$arg_keys" | sort)" = "$(printf "%s\n" "$qids" | sort)" ]'
for k in $arg_keys; do
  flag="$(setup_block | grep -m1 "^      $k: " | awk '{print $2}')"
  check "run.args.$k flag $flag is accepted by agency-setup.sh" 'grep -q -- "    $flag)" "$SETUP"'
done
then_entries="$(setup_block | awk '/^  run:/{f=1;next} f && /^  [a-z]/{f=0} f' | awk '/^    then:/{t=1;next} t && /^    [a-z]/{t=0} t && /^      - /{sub(/^      - /,""); print}')"
check "run.then is empty: the guide runs the later stages itself" '[ -z "$then_entries" ]'
check "setup skill summary names where things are in Files" 'grep -q "in Files under Knowledge, Agency Playbook" "$WORKER/skills/setup.md" && grep -q "in Files under Clients" "$WORKER/skills/setup.md"'
NW_SUGGESTION='Onboard a client'
check "done.suggestion is Onboard a client" 'setup_block | grep -qF -- "    suggestion: \"$NW_SUGGESTION\""'
check "done.suggestion is offered by the setup skill" 'grep -qF -- "$NW_SUGGESTION" "$WORKER/skills/setup.md"'
check "setup skill asks every question with its id" 'for q in $qids; do grep -q "\*\*[0-9]\. $q\*\*" "$WORKER/skills/setup.md" || exit 1; done'
check "practice-setup.sh runs onboard-firm.sh with every slot empty" 'grep -q -- "--empty crm --empty billing --empty agreements --empty portal --empty transcripts" "$PACK_DIR/scripts/practice-setup.sh"'
check "setup skill imports clients, links tools, and keeps the practice client as a fallback" 'grep -q "scripts/import-clients.sh" "$WORKER/skills/setup.md" && grep -q "scripts/firm-setup.sh" "$WORKER/skills/setup.md" && grep -q "## No clients yet" "$WORKER/skills/setup.md" && grep -q "scripts/practice-setup.sh" "$WORKER/skills/setup.md"'
check "every setup question has a goal" '[ "$(grep -c "^      goal: " "$PACK_DIR/package.yaml")" = 6 ]'
check "setup skill interviews tools by kind, then connects each" 'grep -q "## Stage 2: your tools" "$WORKER/skills/setup.md" && grep -q "Which tools do you use for email" "$WORKER/skills/setup.md" && grep -q -- "--link-only" "$WORKER/skills/setup.md" && ! grep -q -- "--no-browser" "$WORKER/skills/setup.md"'
check "setup lists email, CRM, team chat, docs and project management as sources" 'for k in email CRM "team chat" docs "project management"; do grep -A60 "^  sources:" "$PACK_DIR/package.yaml" | grep -q "kind: $k$" || exit 1; done'
check "setup skill reads connected apps before asking, read-only" 'grep -q "hq integrations list --usable --json --company {firm}" "$WORKER/skills/setup.md" && grep -q "read-only tools only" "$WORKER/skills/setup.md"'
check "the practice offer says Northwind is made up" 'grep -q "made-up company" "$WORKER/skills/setup.md"'
check "firm-setup.sh never forces slots empty" '! grep -q -- "--empty" "$PACK_DIR/scripts/firm-setup.sh" && grep -q -- "--no-auto" "$PACK_DIR/scripts/firm-setup.sh"'
check "setup skill writes SOPs into the agency brain" 'grep -q "agency-playbook/sops/" "$WORKER/skills/setup.md"'
check "setup lists documents to ask for" 'grep -A1 "^  documents:" "$PACK_DIR/package.yaml" | grep -q "rate card"'
check "setup skill follows up on variable pricing" 'grep -q "always gets a follow-up" "$WORKER/skills/setup.md"' 

# --- agency-guide worker ------------------------------------------------
for f in worker.yaml skills/setup.md skills/onboarding.md skills/clients.md; do
  check "worker file $f exists" '[ -s "$WORKER/$f" ]'
done
check "worker id matches setup.bot.name" 'grep -q "^  id: $bot_name$" "$WORKER/worker.yaml"'
check "worker name matches setup.bot.display_name" 'grep -q "^  name: \"$bot_display\"$" "$WORKER/worker.yaml"'
check "worker is a conversational PersonaWorker" 'grep -q "^  type: PersonaWorker$" "$WORKER/worker.yaml" && grep -q "^  mode: conversational$" "$WORKER/worker.yaml"'
for d in $(awk '/^skills:/{f=1;next} f && /^[a-z]/{f=0} f && $1=="doc:"{print $2}' "$WORKER/worker.yaml"); do
  check "worker skill doc $d exists" '[ -f "$WORKER/$d" ]'
done
check "worker lists three skills" '[ "$(awk "/^skills:/{f=1;next} f && /^[a-z]/{f=0} f && \$1==\"-\" && \$2==\"name:\"" "$WORKER/worker.yaml" | wc -l | tr -d " ")" = 3 ]'
for ctx in $(awk '/^context:/{f=1;next} f && /^[a-z]/{f=0} f && /^  base:/{b=1;next} f && /^  [a-z]/{b=0} f && b && /^    - /{print $2}' "$WORKER/worker.yaml"); do
  check "worker context $ctx is a pack file" '[ -f "$PACK_DIR/${ctx#core/packages/hq-pack-agency-kit/}" ]'
done
check "worker instructions forbid terminal and Claude Code" 'grep -q "Never ask the person to open a terminal or Claude Code" "$WORKER/worker.yaml"'
check "worker instructions speak Files-tab locations" 'grep -q "Every file location is a Files-tab location" "$WORKER/worker.yaml"'
check "worker instructions use the hq-block suggestions envelope" 'grep -q "\"kind\":\"suggestions\"" "$WORKER/worker.yaml"'
check "worker instructions resolve the firm from Owner context" 'grep -q "Owner context" "$WORKER/worker.yaml"'
check "worker instructions run scripts from the pack roots" 'grep -q "core/packages/hq-pack-agency-kit/" "$WORKER/worker.yaml" && grep -q "core/packages/hq-pack-client-service/" "$WORKER/worker.yaml"'
check "worker files contain no em dashes" '! grep -rq -- "—" "$WORKER"'
check "onboarding skill gates with Approve and Needs changes" 'grep -q "\[\"Approve\",\"Needs changes\"\]" "$WORKER/skills/onboarding.md"'
check "onboarding skill records approver and date" 'grep -q "approved_by: {Display Name}" "$WORKER/skills/onboarding.md"'
check "onboarding skill runs the grader" 'grep -q "scripts/grade-practice.sh --firm" "$WORKER/skills/onboarding.md"'
check "clients skill covers the four triggers" 'for t in "new client" "onboard {client}" "is this in scope" "weekly update for"; do grep -q "\"$t" "$WORKER/skills/clients.md" || exit 1; done'
check "clients skill runs new-client.sh engagement --local-only then client-workspace.sh" 'grep -q "new-client.sh engagement" "$WORKER/skills/clients.md" && grep -q -- "--local-only" "$WORKER/skills/clients.md" && grep -q "client-workspace.sh" "$WORKER/skills/clients.md"'
check "clients skill saves approved drafts under reports/" 'grep -q "reports/{YYYY-MM-DD}-scope-check.md" "$WORKER/skills/clients.md" && grep -q "reports/{YYYY-MM-DD}-weekly-update.md" "$WORKER/skills/clients.md"'
check "worker skills never send" 'grep -qi "never send" "$WORKER/skills/clients.md" && grep -q "Nothing is sent to anyone" "$WORKER/skills/onboarding.md"'

# --- grade-practice ------------------------------------------------------
FIX="$PACK_DIR/tests/fixtures/practice-graded"
out="$(bash "$GRADE" --dir "$FIX" 2>&1)"; rc=$?
check "grader passes on the graded fixture (exit 0)" '[ "$rc" = 0 ]'
check "grader reports all eight found" 'printf "%s" "$out" | grep -q "found=8 missing=0 of 8"'
check "grader names every issue from the answer key" '[ "$(printf "%s\n" "$out" | grep -c "^found ")" = 8 ]'
G="$(mktemp -d)"
cp "$FIX"/*.md "$G/"
for f in "$G"/*.md; do grep -vi "demo" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
out="$(bash "$GRADE" --dir "$G" 2>&1)"; rc=$?
check "grader fails when the landing page issue is removed (exit 1)" '[ "$rc" = 1 ]'
check "grader names the missing issue" 'printf "%s" "$out" | grep -q "^MISSING 7  Landing page"'
check "grader still finds the other seven" 'printf "%s" "$out" | grep -q "found=7 missing=1 of 8"'
cp "$FIX"/*.md "$G/"
for f in "$G"/*.md; do grep -v "46" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
out="$(bash "$GRADE" --dir "$G" 2>&1)"; rc=$?
check "grader fails when the spend finding is removed" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "^MISSING 4  Where the money goes"'
rm "$G/03-audit.md"
bash "$GRADE" --dir "$G" >/dev/null 2>&1; rc=$?
check "grader refuses when an output file is missing (exit 2)" '[ "$rc" = 2 ]'
bash "$GRADE" --firm acme-agency --root "$R" >/dev/null 2>&1; rc=$?
check "grader refuses when onboarding has not run (exit 2)" '[ "$rc" = 2 ]'
mkdir -p "$R/companies/acme-agency/clients/practice-northwind/onboarding" && cp "$FIX"/*.md "$R/companies/acme-agency/clients/practice-northwind/onboarding/"
check "grader resolves --firm against the HQ root" 'bash "$GRADE" --firm acme-agency --root "$R" >/dev/null 2>&1'
rm -rf "$G"

# --- package consistency --------------------------------------------------
for s in $(awk '/^  skills:/{f=1;next} /^  [a-z]+:/{f=0} f && /- /{print $2}' "$PACK_DIR/package.yaml"); do
  check "skill $s has SKILL.md with matching name" 'grep -q "^name: $s$" "$PACK_DIR/skills/$s/SKILL.md"'
done
for p in $(awk '/^  policies:/{f=1;next} /^  [a-z]+:/{f=0} f && /- /{print $2}' "$PACK_DIR/package.yaml"); do
  check "policy $p exists with matching id" 'grep -q "^id: $p$" "$PACK_DIR/policies/$p.md"'
done
for w in $(awk '/^  workers:/{f=1;next} /^  [a-z]+:/{f=0} f && /- /{print $2}' "$PACK_DIR/package.yaml"); do
  check "worker $w has worker.yaml with matching id" 'grep -q "^  id: $w$" "$PACK_DIR/workers/$w/worker.yaml"'
done
check "package version is 0.4.2" 'grep -q "^version: 0.4.2$" "$PACK_DIR/package.yaml"'
check "changelog has a 0.4.2 entry" 'grep -q "^## 0.4.2" "$PACK_DIR/CHANGELOG.md"'
check "requires client-service through requires.packs" 'grep -A2 "^  packs:" "$PACK_DIR/package.yaml" | grep -q "name: hq-pack-client-service"'
check "no legacy requires.packages list" '! grep -q "^  packages:" "$PACK_DIR/package.yaml"'
check "readme describes the chat door" 'grep -q "Agency Guide" "$PACK_DIR/README.md"'
check "package.yaml parses as YAML when python3 has yaml" 'python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$PACK_DIR/package.yaml" 2>/dev/null || ! python3 -c "import yaml" 2>/dev/null'
check "worker.yaml parses as YAML when python3 has yaml" 'python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$WORKER/worker.yaml" 2>/dev/null || ! python3 -c "import yaml" 2>/dev/null'

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

# --- import-clients (needs the sibling client-service pack) ----------------
CS_PACK="$PACK_DIR/../hq-pack-client-service"
if [ -d "$CS_PACK/scripts" ]; then
  R3="$(new_root)"
  mkdir -p "$R3/core/packages"
  ln -s "$PACK_DIR" "$R3/core/packages/hq-pack-agency-kit"
  ln -s "$(cd "$CS_PACK" && pwd)" "$R3/core/packages/hq-pack-client-service"
  printf 'brightside\tBrightside Coffee\n# a comment\n\nnorth-peak\tNorth Peak Outdoors\n' > "$R3/clients.tsv"
  imp1="$(cd "$R3" && bash "$PACK_DIR/scripts/import-clients.sh" --firm acme-agency --file clients.tsv --agency-name "Acme" --root "$R3" 2>&1)"
  check "import-clients creates every client home" 'printf "%s" "$imp1" | grep -q "created=2 existing=0 failed=0"'
  check "each imported client has a record and a workspace" '[ -f "$R3/companies/acme-agency/clients/brightside/engagement.md" ] && [ -f "$R3/companies/acme-agency/clients/north-peak/client-profile.md" ]'
  imp2="$(cd "$R3" && bash "$PACK_DIR/scripts/import-clients.sh" --firm acme-agency --file clients.tsv --root "$R3" 2>&1)"
  check "import-clients is safe to re-run" 'printf "%s" "$imp2" | grep -q "created=0 existing=2 failed=0"'
  printf 'Bad Slug\tNope\n' > "$R3/bad.tsv"
  check "import-clients refuses a bad slug" '! (cd "$R3" && bash "$PACK_DIR/scripts/import-clients.sh" --firm acme-agency --file bad.tsv --root "$R3" >/dev/null 2>&1)'
  rm -rf "$R3"
else
  ok "import-clients (skipped: client-service pack not next to this one)"
fi

rm -rf "$R" "$R2"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
