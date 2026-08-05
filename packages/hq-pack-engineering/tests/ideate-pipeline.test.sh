#!/bin/bash
# E2E test for the ideate pipeline script
# (skills/ideate/scripts/ideate-pipeline.mjs) run through the bundled workflow
# runner with a CANNED fake codex — no real Codex, no real HQ content.
#
# The fake codex answers each stage by prompt markers (capture / brainstorm /
# PRD / finalize) with schema-valid JSON, and the human gates are pre-answered
# as files (the durable-answer path), so the whole pipeline runs headless.
# Covered behaviors:
#   1. happy path: capture -> brainstorm (STRONG) -> approach gate -> PRD ->
#      open-question gate -> finalize, returning status prd_ready with the
#      gate choices baked into the flow (approach + decision reach the agents)
#   2. args contract: company/description required — missing args fail the run
#   3. weak-premise path: brainstorm verdict WEAK opens the premise gate; a
#      "park" answer ends the run with status parked and NO PRD/finalize
#      agents ever spawn
#   4. open questions are capped: overflow past maxQuestionGates is
#      auto-deferred (finalize agent receives it), not gated

set -uo pipefail

PACK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$PACK_ROOT/skills/ideate/scripts/codex-workflow.mjs"
PIPELINE="$PACK_ROOT/skills/ideate/scripts/ideate-pipeline.mjs"

pass=0
fail=0
check() { # check <name> <condition-exit-code>
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/ideate-pipeline-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
HQROOT="$TMP/hqroot"
mkdir -p "$HQROOT/.claude"
printf '{}\n' > "$HQROOT/.claude/settings.json"

# ---- canned fake codex: stage detected by prompt markers ---------------------
cat > "$TMP/bin/codex" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
n="$$-$RANDOM"
printf '%s\n' "$@" > "$rec/argv.$n"
last=""; prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) last="$2"; shift 2 ;;
    --output-schema|-C|-c|-m|--color) shift 2 ;;
    exec) shift ;;
    --*) shift ;;
    *) prompt="$1"; shift ;;
  esac
done
printf '%s\n' "$prompt" >> "$rec/prompts"
verdict="${FAKE_VERDICT:-STRONG}"
# order matters: the finalize prompt also mentions the PRD skill, so match the
# most specific marker first
case "$prompt" in
  *"decision-mode write-back"*)
    printf '{"decisionsApplied":1,"investigationStories":2,"storiesTotal":7}\n' > "$last" ;;
  *"skills/idea/SKILL.md"*)
    printf '{"boardId":"xx-proj-001","title":"Demo Title"}\n' > "$last" ;;
  *"skills/brainstorm/SKILL.md"*)
    printf '{"slug":"demo-slug","premiseVerdict":"%s","premiseSummary":"Premise summary here.","approaches":[{"name":"option-a","effort":"M","summary":"the safe one","whenToChoose":"default"},{"name":"option-b","effort":"L","summary":"the big one","whenToChoose":"scale"}],"recommended":"option-a","biggestRisk":"scope creep"}\n' "$verdict" > "$last" ;;
  *"Read the PRD skill at"*)
    printf '{"name":"demo-slug","prdPath":"projects/demo-slug/prd.json","stories":5,"openQuestions":[{"question":"Auth provider?","options":["existing","new"],"recommended":"existing","whyItMatters":"touches every story"},{"question":"Overflow question A?","options":[],"recommended":"","whyItMatters":"minor"},{"question":"Overflow question B?","options":[],"recommended":"","whyItMatters":"minor"}]}\n' > "$last" ;;
  *)
    printf 'echo:%s\n' "$prompt" > "$last" ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/codex"

# pre_answer <gates-dir> <id> <choice> — durable answer written before launch
pre_answer() {
  node -e '
    const fs = require("fs");
    const [, dir, id, choice] = process.argv;
    fs.mkdirSync(`${dir}/answered`, { recursive: true });
    fs.writeFileSync(`${dir}/answered/${id}.json`,
      JSON.stringify({ id, choice, answered_at: new Date().toISOString() }));
  ' "$1" "$2" "$3"
}

run_pipeline() { # run_pipeline <gates-dir> <rec-dir> <args-json> [env pairs...] -> $OUT, $RC
  local gates="$1" rec="$2" argsjson="$3"; shift 3
  mkdir -p "$rec"
  OUT="$(env "$@" CODEX_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$rec" \
    CODEX_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" CODEX_WORKFLOW_GATES_DIR="$gates" \
    CODEX_WORKFLOW_GATE_POLL_SECS=1 \
    node "$RUNNER" "$PIPELINE" --quiet --args "$argsjson" \
    --run-dir "$TMP/run-$RANDOM" 2>"$TMP/stderr.last")"
  RC=$?
}

# ---- 1: happy path -----------------------------------------------------------
G1="$TMP/g1"; R1="$TMP/r1"
pre_answer "$G1" demo-slug-approach option-b
pre_answer "$G1" demo-slug-q1 existing
run_pipeline "$G1" "$R1" '{"company":"demo","description":"a demo idea worth building","direction":"quality","maxQuestionGates":1}'
check "happy-path pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | grep -v 'GATE ' | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "prd_ready" && r.boardId === "xx-proj-001"
    && r.slug === "demo-slug" && r.chosenApproach === "option-b"
    && r.storiesTotal === 7 && r.decisionsApplied === 1
    && r.investigationStories === 2 ? 0 : 1);
'
check "final JSON: prd_ready with gate choices threaded through" "$?"
grep -q 'option-b' "$R1/prompts"
check "chosen approach (gate answer) reached the PRD agent prompt" "$?"
grep -q '"answer":"existing"' "$R1/prompts"
check "resolved decision reached the finalize agent" "$?"

# ---- 4: overflow questions auto-deferred (maxQuestionGates=1) ----------------
grep -q 'Overflow question A?' "$R1/prompts" && grep -q 'Overflow question B?' "$R1/prompts"
check "overflow questions were passed to finalize as deferred" "$?"
[ ! -f "$G1/pending/demo-slug-q2.json" ] && [ ! -f "$G1/answered/demo-slug-q2.json" ]
check "no gate opened for overflow questions" "$?"

# ---- 2: args contract --------------------------------------------------------
G2="$TMP/g2"; R2="$TMP/r2"
run_pipeline "$G2" "$R2" '{"description":"missing company"}'
[ "$RC" -ne 0 ] && grep -q 'needs args {company, description}' "$TMP/stderr.last"
check "missing company fails fast with a clear error" "$?"

# ---- 3: weak premise -> park -------------------------------------------------
G3="$TMP/g3"; R3="$TMP/r3"
pre_answer "$G3" demo-slug-premise park
run_pipeline "$G3" "$R3" '{"company":"demo","description":"a shaky idea"}' FAKE_VERDICT=WEAK
check "weak-premise pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | grep -v 'GATE ' | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "parked" && r.slug === "demo-slug" ? 0 : 1);
'
check "park answer ends the run with status parked" "$?"
grep -q 'PRD skill' "$R3/prompts" && prd_ran=1 || prd_ran=0
check "no PRD/finalize agents ran after park" "$prd_ran"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
