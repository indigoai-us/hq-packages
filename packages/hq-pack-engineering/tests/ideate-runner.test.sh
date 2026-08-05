#!/bin/bash
# Regression test for the ideate skill's bundled workflow runner
# (skills/ideate/scripts/codex-workflow.mjs) — the Workflow-tool-style
# orchestrator whose agent() calls spawn `codex exec`, plus its gate()
# human-pause primitive.
#
# Uses a FAKE codex binary (CODEX_WORKFLOW_CODEX_BIN) so no real Codex runs,
# and a synthetic HQ root in a temp dir (HQ_ROOT) so the suite is hermetic in
# pack CI. Covered behaviors:
#   1. every spawn carries the three mandated flags and stdin at /dev/null;
#      the prompt is separated from options with `--`
#   2. parallel(): a failing thunk resolves to null, siblings survive
#   3. soft timeout: a slow agent is NOT killed — repeating TIMEOUT WARNING on
#      stdout, result still returned
#   4. schema: --output-schema passed, JSON result parsed
#   5. tier is required (sol|terra) and selects the model; the
#      CODEX_WORKFLOW_MODEL_SOL / CODEX_WORKFLOW_MODEL_TERRA envs re-point a
#      tier's model
#   6. HQ root: HQ_ROOT env wins; without it, a cwd that carries
#      .claude/settings.json is auto-detected. Every spawn is anchored
#      -C <hq-root>; opts.cd is injected into the prompt, and a cd outside the
#      root throws
#   7. gate(): pause in place (pending file written, GATE OPEN on stdout, no
#      agents spawned while gated), resume on an answer file with the answer
#      flowing onward, instant GATE CACHED return for pre-answered ids, and
#      journal gate-open/gate-answered/gate-cached events

set -uo pipefail

PACK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$PACK_ROOT/skills/ideate/scripts/codex-workflow.mjs"

pass=0
fail=0
check() { # check <name> <condition-exit-code>
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/ideate-runner-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# canonicalize: on macOS /tmp is a symlink to /private/tmp, and the runner
# resolves real paths — compare like with like
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/bin" "$TMP/rec"

# synthetic HQ root the runner anchors agents to
HQROOT="$TMP/hqroot"
mkdir -p "$HQROOT/.claude" "$HQROOT/workspace"
printf '{}\n' > "$HQROOT/.claude/settings.json"
cd "$HQROOT" || exit 1

# ---- fake codex ------------------------------------------------------------
cat > "$TMP/bin/codex" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
n="$$-$RANDOM"
printf '%s\n' "$@" > "$rec/argv.$n"
{ readlink /proc/self/fd/0 2>/dev/null || lsof -a -p $$ -d 0 -Fn 2>/dev/null | sed -n 's/^n//p'; } > "$rec/stdin.$n"
[ -s "$rec/stdin.$n" ] || echo "unknown" > "$rec/stdin.$n"
last=""; schema=""; prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) last="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2 ;;
    -C|-c|-m|--color) shift 2 ;;
    exec) shift ;;
    --*) shift ;;
    *) prompt="$1"; shift ;;
  esac
done
case "$prompt" in
  *SLEEP=*)
    secs="$(printf '%s' "$prompt" | sed -n 's/.*SLEEP=\([0-9]*\).*/\1/p')"
    sleep "${secs:-0}"
    ;;
esac
case "$prompt" in
  *FAIL*) echo "fake codex: failing on purpose" >&2; exit 3 ;;
esac
if [ -n "$schema" ]; then
  printf '{"pong": 1, "sawSchema": true}\n' > "$last"
else
  printf 'echo:%s\n' "$prompt" > "$last"
fi
exit 0
FAKE
chmod +x "$TMP/bin/codex"

run_wf() { # run_wf <script-file> [extra runner args...] -> $OUT, $RC
  local script="$1"; shift
  OUT="$(CODEX_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$TMP/rec" \
    CODEX_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" \
    CODEX_WORKFLOW_GATES_DIR="$TMP/gates-default" \
    node "$RUNNER" "$script" --quiet --run-dir "$TMP/run-$RANDOM" "$@" 2>"$TMP/stderr.last")"
  RC=$?
}

# wait_for <timeout-secs> '<condition>' — string re-evaluated each tick
wait_for() {
  local budget=$(( $1 * 5 ))
  local cond="$2"
  while [ "$budget" -gt 0 ]; do
    eval "$cond" >/dev/null 2>&1 && return 0
    sleep 0.2
    budget=$((budget - 1))
  done
  return 1
}

# ---- 1 + 4: flags, stdin, --, schema, return JSON ---------------------------
cat > "$TMP/wf-basic.mjs" <<'WF'
export const meta = { name: 'basic', description: 'basic' }
phase('Basic')
const text = await agent('say hi', { label: 'hi', tier: 'sol', timeoutSecs: 30 })
const structured = await agent('SCHEMA please', {
  label: 'schema', tier: 'sol', timeoutSecs: 30,
  schema: { type: 'object', properties: { pong: { type: 'number' } } },
})
return { text, structured, argsEcho: args }
WF
run_wf "$TMP/wf-basic.mjs" --args '{"k":"v"}'
check "basic workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.text === "echo:say hi" && r.structured.pong === 1
    && r.structured.sawSchema === true && r.argsEcho.k === "v" ? 0 : 1);
'
check "return JSON on stdout (text + parsed schema + args)" "$?"

flags_ok=0
for f in "$TMP/rec"/argv.*; do
  for flag in --dangerously-bypass-hook-trust --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox; do
    grep -qx -- "$flag" "$f" || flags_ok=1
  done
  grep -qx '/dev/null' "${f/argv/stdin}" || flags_ok=1
  tail -2 "$f" | head -1 | grep -qx -- '--' || flags_ok=1
done
check "every spawn: mandated flags + stdin /dev/null + -- before prompt" "$flags_ok"

# ---- 2: parallel errors -> null ---------------------------------------------
cat > "$TMP/wf-parallel.mjs" <<'WF'
const r = await parallel([
  () => agent('p-one', { tier: 'terra', timeoutSecs: 30 }),
  () => agent('p-FAIL', { tier: 'terra', timeoutSecs: 30 }),
  () => { throw 'plain-string-throw' },
])
return r
WF
run_wf "$TMP/wf-parallel.mjs"
check "parallel workflow exits 0 despite failures" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.length === 3 && r[0] === "echo:p-one" && r[1] === null && r[2] === null ? 0 : 1);
'
check "failing thunks resolved to null, sibling survived" "$?"

# ---- 3: soft timeout never kills ---------------------------------------------
cat > "$TMP/wf-timeout.mjs" <<'WF'
const r = await agent('hang SLEEP=3', { tier: 'terra', timeoutSecs: 1 })
return { result: r }
WF
run_wf "$TMP/wf-timeout.mjs"
check "timed-out agent workflow exits 0" "$RC"
printf '%s\n' "$OUT" | grep -v 'TIMEOUT WARNING' | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.result === "echo:hang SLEEP=3" ? 0 : 1);
'
check "slow agent NOT killed — result intact" "$?"
warns="$(printf '%s\n' "$OUT" | grep -c 'TIMEOUT WARNING')"
[ "$warns" -ge 2 ]
check "TIMEOUT WARNING repeated on stdout (${warns} >= 2)" "$?"

# ---- 5: tier required; tier/env model selection ------------------------------
cat > "$TMP/wf-tier.mjs" <<'WF'
const missing = await (async () => {
  try { await agent('no tier', { timeoutSecs: 30 }); return false }
  catch (e) { return e.message.includes('opts.tier') }
})()
await agent('planner-prompt', { tier: 'sol', timeoutSecs: 30 })
await agent('doer-prompt', { tier: 'terra', timeoutSecs: 30 })
return { missing }
WF
run_wf "$TMP/wf-tier.mjs"
check "tier workflow exits 0" "$RC"
echo "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.missing === true ? 0 : 1);
'
check "missing tier throws with opts.tier marker" "$?"
sol_ok=1; terra_ok=1
for f in "$TMP/rec"/argv.*; do
  if grep -qx -- 'planner-prompt' "$f"; then grep -qx -- 'gpt-5.6-sol' "$f" && sol_ok=0; fi
  if grep -qx -- 'doer-prompt' "$f"; then grep -qx -- 'gpt-5.6-terra' "$f" && terra_ok=0; fi
done
check "sol -> gpt-5.6-sol, terra -> gpt-5.6-terra by default" "$(( sol_ok + terra_ok ))"

cat > "$TMP/wf-tier-env.mjs" <<'WF'
await agent('env-model-sol', { tier: 'sol', timeoutSecs: 30 })
await agent('env-model-terra', { tier: 'terra', timeoutSecs: 30 })
return 'ok'
WF
export CODEX_WORKFLOW_MODEL_SOL="custom-sol-model"
export CODEX_WORKFLOW_MODEL_TERRA="custom-terra-model"
run_wf "$TMP/wf-tier-env.mjs"
unset CODEX_WORKFLOW_MODEL_SOL CODEX_WORKFLOW_MODEL_TERRA
env_sol=1; env_terra=1
for f in "$TMP/rec"/argv.*; do
  if grep -qx -- 'env-model-sol' "$f"; then grep -qx -- 'custom-sol-model' "$f" && env_sol=0; fi
  if grep -qx -- 'env-model-terra' "$f"; then grep -qx -- 'custom-terra-model' "$f" && env_terra=0; fi
done
check "CODEX_WORKFLOW_MODEL_SOL/TERRA re-point tier models" "$(( env_sol + env_terra ))"

# ---- 6: HQ root anchoring ----------------------------------------------------
cat > "$TMP/wf-anchor.mjs" <<WF
await agent('anchor-default', { tier: 'terra', timeoutSecs: 30 })
await agent('anchor-worktree', {
  tier: 'terra', timeoutSecs: 30,
  cd: '$HQROOT/workspace/worktrees/demo',
})
return 'ok'
WF
run_wf "$TMP/wf-anchor.mjs"
check "anchor workflow exits 0" "$RC"
anchor_ok=0
for f in "$TMP/rec"/argv.*; do
  grep -qx -- '-C' "$f" || { anchor_ok=1; continue; }
  grep -A1 -x -- '-C' "$f" | tail -1 | grep -qx -- "$HQROOT" || anchor_ok=1
done
check "every spawn anchored -C <hq-root>" "$anchor_ok"
wt="$(grep -l -x -- 'anchor-worktree' "$TMP/rec"/argv.* 2>/dev/null | head -1)"
[ -n "$wt" ] && grep -q "Working directory for this task: $HQROOT/workspace/worktrees/demo" "$wt"
check "opts.cd injected as a prompt preamble" "$?"

cat > "$TMP/wf-anchor-escape.mjs" <<WF
await agent('anchor-escape', { tier: 'terra', timeoutSecs: 30, cd: '$TMP/elsewhere' })
return 'ok'
WF
run_wf "$TMP/wf-anchor-escape.mjs"
[ "$RC" -ne 0 ] && grep -q 'must resolve inside the HQ root' "$TMP/stderr.last"
check "opts.cd outside the HQ root throws" "$?"

# without HQ_ROOT env, a cwd carrying .claude/settings.json is auto-detected
cat > "$TMP/wf-detect.mjs" <<'WF'
return await agent('detect-root', { tier: 'sol', timeoutSecs: 30 })
WF
OUT="$(cd "$HQROOT" && CODEX_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$TMP/rec" \
  CODEX_WORKFLOW_CPU_CHECK=0 CODEX_WORKFLOW_GATES_DIR="$TMP/gates-default" \
  node "$RUNNER" "$TMP/wf-detect.mjs" --quiet --run-dir "$TMP/run-detect" 2>/dev/null)"
RC=$?
check "runner works without HQ_ROOT env from an HQ-shaped cwd" "$RC"
df="$(grep -l -x -- 'detect-root' "$TMP/rec"/argv.* 2>/dev/null | head -1)"
[ -n "$df" ] && grep -A1 -x -- '-C' "$df" | tail -1 | grep -qx -- "$HQROOT"
check "auto-detected root used for -C" "$?"

# ---- 7: gate() pause / resume / cache ---------------------------------------
GATES="$TMP/gates1"; REC2="$TMP/rec2"; mkdir -p "$REC2"
cat > "$TMP/wf-gate.mjs" <<'WF'
const a = await gate('pack-gate', 'Proceed how?', {
  options: [{ label: 'fast', description: 'ship it' }, { label: 'careful', description: 'slow lane' }],
  recommended: 'careful', pollSecs: 1,
})
const r = await agent('after:' + a.choice, { tier: 'terra', timeoutSecs: 30 })
return { choice: a.choice, r }
WF
OUTF="$TMP/gate-out"
CODEX_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$REC2" \
  CODEX_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" CODEX_WORKFLOW_GATES_DIR="$GATES" \
  node "$RUNNER" "$TMP/wf-gate.mjs" --quiet --run-dir "$TMP/run-gate" >"$OUTF" 2>/dev/null &
BGPID=$!
wait_for 15 'test -f "$GATES/pending/pack-gate.json"'
check "gate() wrote a pending file and paused" "$?"
node -e '
  const g = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(g.question === "Proceed how?" && g.options.length === 2
    && g.recommended === "careful" && g.status === "pending"
    && typeof g.answer_path === "string" ? 0 : 1);
' "$GATES/pending/pack-gate.json"
check "pending gate is self-contained" "$?"
grep -q 'GATE OPEN' "$OUTF"
check "GATE OPEN printed on stdout under --quiet" "$?"
[ -z "$(ls "$REC2"/argv.* 2>/dev/null)" ] && kill -0 "$BGPID" 2>/dev/null
check "no agents spawned while gated; process alive" "$?"
node -e 'require("fs").mkdirSync(process.argv[1] + "/answered", {recursive: true});
  require("fs").writeFileSync(process.argv[1] + "/answered/pack-gate.json",
  JSON.stringify({id: "pack-gate", choice: "fast", answered_at: new Date().toISOString()}))' "$GATES"
wait "$BGPID"; RC=$?
check "answer file resumed the same process (exit 0)" "$RC"
grep -v 'GATE ' "$OUTF" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.choice === "fast" && r.r === "echo:after:fast" ? 0 : 1);
'
check "answer flowed into the post-gate agent" "$?"
[ ! -f "$GATES/pending/pack-gate.json" ] && [ -f "$GATES/answered/pack-gate.json" ]
check "pending cleared, answered persists" "$?"
grep -q '"event":"gate-open"' "$TMP/run-gate/journal.jsonl" && grep -q '"event":"gate-answered"' "$TMP/run-gate/journal.jsonl"
check "journal has gate-open + gate-answered" "$?"

# cached: re-run returns instantly
start="$(date +%s)"
OUT="$(CODEX_WORKFLOW_CODEX_BIN="$TMP/bin/codex" FAKE_REC_DIR="$REC2" \
  CODEX_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" CODEX_WORKFLOW_GATES_DIR="$GATES" \
  node "$RUNNER" "$TMP/wf-gate.mjs" --quiet --run-dir "$TMP/run-gate2" 2>/dev/null)"
RC=$?
elapsed=$(( $(date +%s) - start ))
[ "$RC" -eq 0 ] && [ "$elapsed" -le 5 ] && printf '%s\n' "$OUT" | grep -q 'GATE CACHED'
check "pre-answered gate returns instantly with GATE CACHED (${elapsed}s)" "$?"
grep -q '"event":"gate-cached"' "$TMP/run-gate2/journal.jsonl"
check "journal has gate-cached on the re-run" "$?"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
