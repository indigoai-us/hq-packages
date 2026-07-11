#!/usr/bin/env bash
# Offline tests for scripts/slack-ui.sh (always --dry-run; never hits Slack).
# Exit nonzero on first failure. Deps: bash, jq, python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SLACK_UI="${SCRIPT_DIR}/../slack-ui.sh"
PASS=0
FAIL=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

assert() {
  local name="$1"
  shift
  if "$@"; then
    green "PASS: $name"
    PASS=$((PASS + 1))
  else
    red "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    green "PASS: $name"
    PASS=$((PASS + 1))
  else
    red "FAIL: $name (got=$(printf '%q' "$got") want=$(printf '%q' "$want"))"
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  local name="$1"
  shift
  # Command inherits any stdin redirection on the assert_ok call; swallow its stdout.
  if "$@" >/dev/null; then
    green "PASS: $name"
    PASS=$((PASS + 1))
  else
    red "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    red "FAIL: $name (expected nonzero exit)"
    FAIL=$((FAIL + 1))
  else
    green "PASS: $name"
    PASS=$((PASS + 1))
  fi
}

[ -x "$SLACK_UI" ] || chmod +x "$SLACK_UI"
[ -f "$SLACK_UI" ] || { red "missing $SLACK_UI"; exit 1; }

# ---------------------------------------------------------------------------
# 1. basic post: header, fields section, context; channel + thread_ts
# ---------------------------------------------------------------------------
BASIC_OUT="$(
  bash "$SLACK_UI" post \
    --title "Deploy complete" \
    --body "web-front preview is live." \
    --field "Env|preview" \
    --field "SHA|abc1234" \
    --field "By|alice" \
    --context "triggered by CI" \
    --context "run 42" \
    --channel C01234567 \
    --thread 1710000000.000100 \
    --dry-run
)"

assert_eq "basic: single payload line" \
  "$(printf '%s\n' "$BASIC_OUT" | wc -l | tr -d '[:space:]')" "1"

assert_ok "basic: valid JSON" \
  jq -e . <<<"$BASIC_OUT"

assert_eq "basic: blocks[0].type == header" \
  "$(jq -r '.blocks[0].type' <<<"$BASIC_OUT")" "header"

assert_eq "basic: header text" \
  "$(jq -r '.blocks[0].text.text' <<<"$BASIC_OUT")" "Deploy complete"

assert_eq "basic: channel" \
  "$(jq -r '.channel' <<<"$BASIC_OUT")" "C01234567"

assert_eq "basic: thread_ts" \
  "$(jq -r '.thread_ts' <<<"$BASIC_OUT")" "1710000000.000100"

assert_ok "basic: has top-level text fallback" \
  jq -e '.text | type == "string" and length > 0' <<<"$BASIC_OUT"

# Find the section that has .fields
FIELD_COUNT="$(jq '[.blocks[] | select(.fields != null) | .fields[]] | length' <<<"$BASIC_OUT")"
assert_eq "basic: three fields" "$FIELD_COUNT" "3"

assert_eq "basic: field 0 content" \
  "$(jq -r '[.blocks[] | select(.fields != null) | .fields[0].text][0]' <<<"$BASIC_OUT")" \
  $'*Env*\npreview'

assert_eq "basic: field 1 content" \
  "$(jq -r '[.blocks[] | select(.fields != null) | .fields[1].text][0]' <<<"$BASIC_OUT")" \
  $'*SHA*\nabc1234'

assert_eq "basic: field 2 content" \
  "$(jq -r '[.blocks[] | select(.fields != null) | .fields[2].text][0]' <<<"$BASIC_OUT")" \
  $'*By*\nalice'

assert_ok "basic: has context block with 2 elements" \
  jq -e '
    ([.blocks[] | select(.type == "context")] | length) == 1
    and (([.blocks[] | select(.type == "context")][0].elements | length) == 2)
    and ([.blocks[] | select(.type == "context")][0].elements[0].type == "mrkdwn")
    and ([.blocks[] | select(.type == "context")][0].elements[0].text == "triggered by CI")
    and ([.blocks[] | select(.type == "context")][0].elements[1].text == "run 42")
  ' <<<"$BASIC_OUT"

assert_ok "basic: body section present" \
  jq -e '
    [.blocks[] | select(.type == "section" and .text.text == "web-front preview is live.")]
    | length == 1
  ' <<<"$BASIC_OUT"
# ---------------------------------------------------------------------------
# 2. >4 fields errors
# ---------------------------------------------------------------------------
set +e
ERR_OUT="$(
  bash "$SLACK_UI" post \
    --field "A|1" --field "B|2" --field "C|3" --field "D|4" --field "E|5" \
    --channel C1 --dry-run 2>&1
)"
ERR_RC=$?
set -e
assert_ok "too many fields: nonzero exit" [ "$ERR_RC" -ne 0 ]
assert_ok "too many fields: mentions max/4" \
  python3 -c 'import sys; t=sys.argv[1].lower(); assert ("max" in t or "too many" in t) and "4" in t' "$ERR_OUT"

# ---------------------------------------------------------------------------
# 3. ~7000-char body: every section text <=3000; continuation has "(continued)"
# ---------------------------------------------------------------------------
LONG_BODY="$(python3 -c 'print("B"*7000)')"
LONG_OUT="$(
  bash "$SLACK_UI" post \
    --title "Long body" \
    --body "$LONG_BODY" \
    --channel C1 \
    --dry-run
)"

assert_ok "long body: valid JSON" jq -e . <<<"$LONG_OUT"

assert_ok "long body: every section text <=3000 + has continued" \
  python3 - <<'PY' "$LONG_OUT"
import json, sys
payload = json.loads(sys.argv[1])
sections = [b for b in payload["blocks"] if b.get("type") == "section" and "text" in b and "fields" not in b]
assert len(sections) >= 2, f"expected >=2 section blocks, got {len(sections)}"
for s in sections:
    t = s["text"]["text"]
    assert len(t) <= 3000, f"section text len {len(t)} > 3000"
continued = [s for s in sections if "(continued)" in s["text"]["text"]]
assert continued, "no section contains '(continued)'"
# first section should be pure body start (no continued prefix required)
assert sections[0]["text"]["text"].startswith("B"), "first section should start with body"
assert all("(continued)" in s["text"]["text"] for s in sections[1:]), "later sections need (continued)"
print("ok")
PY

# ---------------------------------------------------------------------------
# 4. force >50 blocks → multiple payloads, each <=50 blocks
# ---------------------------------------------------------------------------
# 1 header + N body sections. Need N such that 1+N > 50 ⇒ N >= 50.
# First section holds 3000 chars; each next holds 3000-12=2988 body chars.
# For 50 body sections: 3000 + 49*2988 body chars.
HUGE_BODY="$(python3 -c 'print("X" * (3000 + 49 * 2988))')"
HUGE_OUT="$(
  bash "$SLACK_UI" post \
    --title "Many blocks" \
    --body "$HUGE_BODY" \
    --channel C99 \
    --thread 123.456 \
    --dry-run
)"

assert_ok "multi-message: >1 payload lines" \
  python3 -c 'import sys; lines=[l for l in sys.argv[1].splitlines() if l.strip()]; assert len(lines)>=2, len(lines)' "$HUGE_OUT"

assert_ok "multi-message: each payload <=50 blocks, channel/thread reused, continued" \
  python3 - <<'PY' "$HUGE_OUT"
import json, sys
lines = [l for l in sys.argv[1].splitlines() if l.strip()]
assert len(lines) >= 2, f"expected >=2 payloads, got {len(lines)}"
total_blocks = 0
for i, line in enumerate(lines):
    p = json.loads(line)
    n = len(p["blocks"])
    total_blocks += n
    assert n <= 50, f"payload {i} has {n} blocks"
    assert p.get("channel") == "C99", p.get("channel")
    assert p.get("thread_ts") == "123.456", p.get("thread_ts")
    assert "text" in p and p["text"], "missing fallback text"
    if i > 0:
        first = p["blocks"][0]
        blob = json.dumps(first)
        assert "(continued)" in blob, f"payload {i} first block missing (continued): {blob[:200]}"
assert total_blocks > 50, f"total blocks {total_blocks} not >50"
print("ok", len(lines), "payloads,", total_blocks, "blocks")
PY

# ---------------------------------------------------------------------------
# 5. --text-only: no blocks key, non-empty text
# ---------------------------------------------------------------------------
TEXT_OUT="$(
  bash "$SLACK_UI" post \
    --title "Ping" \
    --body "still here" \
    --field "Status|ok" \
    --context "note" \
    --channel C1 \
    --text-only \
    --dry-run
)"

assert_ok "text-only: valid JSON" jq -e . <<<"$TEXT_OUT"
assert_ok "text-only: no blocks key" \
  jq -e 'has("blocks") | not' <<<"$TEXT_OUT"
assert_ok "text-only: non-empty text" \
  jq -e '.text | type == "string" and length > 0' <<<"$TEXT_OUT"
assert_eq "text-only: channel set" \
  "$(jq -r '.channel' <<<"$TEXT_OUT")" "C1"
assert_ok "text-only: text includes title and body" \
  python3 -c 'import json,sys; t=json.loads(sys.argv[1])["text"]; assert "Ping" in t and "still here" in t and "Status" in t' "$TEXT_OUT"

# ---------------------------------------------------------------------------
# 6. help documents flags
# ---------------------------------------------------------------------------
HELP_OUT="$(bash "$SLACK_UI" post --help)"
for flag in --title --body --field --context --channel --thread --text-only --dry-run; do
  assert_ok "help mentions $flag" \
    python3 -c 'import sys; assert sys.argv[1] in sys.argv[2]' "$flag" "$HELP_OUT"
done

# ---------------------------------------------------------------------------
# 7. report create mode dry-run: 2 JSON lines (canvases.create + chat.postMessage)
# ---------------------------------------------------------------------------
REPORT_MD="$(mktemp "${TMPDIR:-/tmp}/slack-ui-report.XXXXXX.md")"
printf '%s\n' '# Hello' '' 'Body paragraph with **bold**.' >"$REPORT_MD"
MD_CONTENTS="$(cat "$REPORT_MD")"

REPORT_CREATE_OUT="$(
  bash "$SLACK_UI" report \
    --file "$REPORT_MD" \
    --title "Incident write-up" \
    --tldr "Root cause found; mitigated." \
    --channel C01234567 \
    --thread 1710000000.000100 \
    --dry-run
)"

assert_eq "report create: two JSON lines" \
  "$(printf '%s\n' "$REPORT_CREATE_OUT" | wc -l | tr -d '[:space:]')" "2"

LINE1="$(printf '%s\n' "$REPORT_CREATE_OUT" | sed -n '1p')"
LINE2="$(printf '%s\n' "$REPORT_CREATE_OUT" | sed -n '2p')"

assert_ok "report create: line1 valid JSON" jq -e . <<<"$LINE1"
assert_ok "report create: line2 valid JSON" jq -e . <<<"$LINE2"

assert_eq "report create: line1 api" \
  "$(jq -r '.api' <<<"$LINE1")" "canvases.create"

assert_eq "report create: payload.title" \
  "$(jq -r '.payload.title' <<<"$LINE1")" "Incident write-up"

assert_eq "report create: markdown equals file" \
  "$(jq -r '.payload.document_content.markdown' <<<"$LINE1")" "$MD_CONTENTS"

assert_eq "report create: document type" \
  "$(jq -r '.payload.document_content.type' <<<"$LINE1")" "markdown"

assert_eq "report create: line2 api" \
  "$(jq -r '.api' <<<"$LINE2")" "chat.postMessage"

assert_eq "report create: channel" \
  "$(jq -r '.payload.channel' <<<"$LINE2")" "C01234567"

assert_eq "report create: thread_ts" \
  "$(jq -r '.payload.thread_ts' <<<"$LINE2")" "1710000000.000100"

assert_ok "report create: text contains tldr and dryrun canvas id" \
  python3 -c 'import json,sys; t=json.loads(sys.argv[1])["payload"]["text"]; assert "Root cause found; mitigated." in t and "F_DRYRUN_CANVAS" in t' "$LINE2"

# ---------------------------------------------------------------------------
# 8. report update mode dry-run: canvases.edit + replace
# ---------------------------------------------------------------------------
REPORT_UPDATE_OUT="$(
  bash "$SLACK_UI" report \
    --file "$REPORT_MD" \
    --title "Incident write-up" \
    --tldr "Updated notes." \
    --channel C99 \
    --update F0123CANVAS \
    --dry-run
)"

assert_eq "report update: two JSON lines" \
  "$(printf '%s\n' "$REPORT_UPDATE_OUT" | wc -l | tr -d '[:space:]')" "2"

U1="$(printf '%s\n' "$REPORT_UPDATE_OUT" | sed -n '1p')"
U2="$(printf '%s\n' "$REPORT_UPDATE_OUT" | sed -n '2p')"

assert_eq "report update: line1 api" \
  "$(jq -r '.api' <<<"$U1")" "canvases.edit"

assert_eq "report update: canvas_id" \
  "$(jq -r '.payload.canvas_id' <<<"$U1")" "F0123CANVAS"

assert_eq "report update: operation replace" \
  "$(jq -r '.payload.changes[0].operation' <<<"$U1")" "replace"

assert_eq "report update: line2 api" \
  "$(jq -r '.api' <<<"$U2")" "chat.postMessage"

assert_ok "report update: message links given canvas id" \
  python3 -c 'import json,sys; t=json.loads(sys.argv[1])["payload"]["text"]; assert "F0123CANVAS" in t' "$U2"

# ---------------------------------------------------------------------------
# 9. report force-fallback dry-run: single chat.postMessage + stderr notice
# ---------------------------------------------------------------------------
set +e
FB_OUT="$(
  bash "$SLACK_UI" report \
    --file "$REPORT_MD" \
    --title "T" \
    --tldr "Fallback TLDR here." \
    --channel C1 \
    --force-fallback \
    --dry-run \
    2>/tmp/slack-ui-fb-err.$$
)"
FB_RC=$?
FB_ERR="$(cat /tmp/slack-ui-fb-err.$$)"
rm -f /tmp/slack-ui-fb-err.$$
set -e

assert_eq "report fallback: exit 0" "$FB_RC" "0"
assert_eq "report fallback: one JSON line" \
  "$(printf '%s\n' "$FB_OUT" | wc -l | tr -d '[:space:]')" "1"
assert_eq "report fallback: api chat.postMessage" \
  "$(jq -r '.api' <<<"$FB_OUT")" "chat.postMessage"
assert_ok "report fallback: text contains tldr" \
  python3 -c 'import json,sys; t=json.loads(sys.argv[1])["payload"]["text"]; assert "Fallback TLDR here." in t' "$FB_OUT"
assert_ok "report fallback: stderr mentions falling back / deploy-and-link" \
  python3 -c 'import sys; t=sys.argv[1].lower(); assert "falling back" in t and "deploy-and-link" in t' "$FB_ERR"

set +e
FB_URL_OUT="$(
  bash "$SLACK_UI" report \
    --file "$REPORT_MD" \
    --title "T" \
    --tldr "With URL TLDR." \
    --channel C1 \
    --force-fallback \
    --fallback-url "https://example.com/report" \
    --dry-run \
    2>/dev/null
)"
FB_URL_RC=$?
set -e
assert_eq "report fallback-url: exit 0" "$FB_URL_RC" "0"
assert_ok "report fallback-url: text contains url" \
  python3 -c 'import json,sys; t=json.loads(sys.argv[1])["payload"]["text"]; assert "https://example.com/report" in t and "With URL TLDR." in t' "$FB_URL_OUT"

# ---------------------------------------------------------------------------
# 10. report validation: missing --file or --tldr exits nonzero
# ---------------------------------------------------------------------------
assert_fail "report missing --file" \
  bash "$SLACK_UI" report \
    --title "T" --tldr "x" --channel C1 --dry-run

assert_fail "report missing --tldr" \
  bash "$SLACK_UI" report \
    --file "$REPORT_MD" --title "T" --channel C1 --dry-run

rm -f "$REPORT_MD"

# ---------------------------------------------------------------------------
# 11. ask dry-run: 2 JSON lines, register + postMessage, buttons, pending file
# ---------------------------------------------------------------------------
ASK_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slack-ui-ask-state.XXXXXX")"
ASK_DECISION_ID="TESTDECISION0000000000000001"
ASK_TIMEOUT=120
ASK_NOW="$(date +%s)"
ASK_EXPIRES_LO=$((ASK_NOW + ASK_TIMEOUT - 5))
ASK_EXPIRES_HI=$((ASK_NOW + ASK_TIMEOUT + 5))

ASK_OUT="$(
  bash "$SLACK_UI" ask \
    --question "Ship to prod?" \
    --option "yes|Yes, ship" \
    --option "no|No, hold" \
    --option "later|Defer" \
    --recommend yes \
    --abort no \
    --fallback later \
    --timeout "$ASK_TIMEOUT" \
    --channel C01234567 \
    --thread 1710000000.000100 \
    --decision-id "$ASK_DECISION_ID" \
    --state-dir "$ASK_STATE_DIR" \
    --context "from CI" \
    --dry-run
)"

assert_eq "ask dry-run: two JSON lines" \
  "$(printf '%s\n' "$ASK_OUT" | wc -l | tr -d '[:space:]')" "2"

ASK_L1="$(printf '%s\n' "$ASK_OUT" | sed -n '1p')"
ASK_L2="$(printf '%s\n' "$ASK_OUT" | sed -n '2p')"

assert_ok "ask dry-run: line1 valid JSON" jq -e . <<<"$ASK_L1"
assert_ok "ask dry-run: line2 valid JSON" jq -e . <<<"$ASK_L2"

assert_eq "ask dry-run: line1 api" \
  "$(jq -r '.api' <<<"$ASK_L1")" "hq.decisions.register"

assert_eq "ask dry-run: line2 api" \
  "$(jq -r '.api' <<<"$ASK_L2")" "chat.postMessage"

assert_eq "ask register: decision_id override" \
  "$(jq -r '.payload.decision_id' <<<"$ASK_L1")" "$ASK_DECISION_ID"

assert_eq "ask register: fallback" \
  "$(jq -r '.payload.fallback' <<<"$ASK_L1")" "later"

assert_eq "ask register: three options" \
  "$(jq -r '.payload.options | length' <<<"$ASK_L1")" "3"

ASK_EXPIRES="$(jq -r '.payload.expires_at' <<<"$ASK_L1")"
assert_ok "ask register: expires_at within ±5s of now+timeout" \
  python3 -c 'import sys; e=int(sys.argv[1]); lo=int(sys.argv[2]); hi=int(sys.argv[3]); assert lo<=e<=hi, (e,lo,hi)' \
  "$ASK_EXPIRES" "$ASK_EXPIRES_LO" "$ASK_EXPIRES_HI"

assert_ok "ask message: 3 buttons, action_ids, styles" \
  python3 - <<'PY' "$ASK_L2" "$ASK_DECISION_ID"
import json, sys
payload = json.loads(sys.argv[1])["payload"]
did = sys.argv[2]
actions = [b for b in payload["blocks"] if b.get("type") == "actions"]
assert len(actions) == 1, actions
els = actions[0]["elements"]
assert len(els) == 3, els
assert all(e.get("type") == "button" for e in els), els
prefix = f"hqd:{did}:"
assert all(e["action_id"].startswith(prefix) for e in els), [e["action_id"] for e in els]
by_val = {e["value"]: e for e in els}
assert by_val["yes"].get("style") == "primary", by_val["yes"]
assert by_val["no"].get("style") == "danger", by_val["no"]
assert "style" not in by_val["later"], by_val["later"]
print("ok")
PY

assert_ok "ask message: context mentions fallback" \
  python3 -c '
import json,sys
p=json.loads(sys.argv[1])["payload"]
ctx=[b for b in p["blocks"] if b.get("type")=="context"]
assert ctx, "no context"
texts=" ".join(e.get("text","") for e in ctx[0]["elements"])
assert "fallback" in texts.lower() and "Defer" in texts, texts
' "$ASK_L2"

assert_ok "ask pending file: decision_id + DRYRUN_TS" \
  python3 -c '
import json,sys,os
path=os.path.join(sys.argv[1], sys.argv[2]+".json")
assert os.path.isfile(path), path
d=json.load(open(path))
assert d["decision_id"]==sys.argv[2]
assert d["message_ts"]=="DRYRUN_TS"
' "$ASK_STATE_DIR" "$ASK_DECISION_ID"

# ---------------------------------------------------------------------------
# 12. ask: 4 options without --multi fails; --multi emits multi_static_select
# ---------------------------------------------------------------------------
assert_fail "ask 4 options without --multi fails" \
  bash "$SLACK_UI" ask \
    --question "Pick" \
    --option "a|A" --option "b|B" --option "c|C" --option "d|D" \
    --fallback a \
    --timeout 60 \
    --channel C1 \
    --dry-run

MULTI_OUT="$(
  bash "$SLACK_UI" ask \
    --question "Pick many" \
    --option "a|A" --option "b|B" --option "c|C" --option "d|D" \
    --fallback a \
    --timeout 60 \
    --channel C1 \
    --multi \
    --decision-id "TESTDECISION0000000000000002" \
    --state-dir "$ASK_STATE_DIR" \
    --dry-run
)"

MULTI_L2="$(printf '%s\n' "$MULTI_OUT" | sed -n '2p')"
assert_ok "ask --multi: multi_static_select with confirm, no buttons" \
  python3 -c '
import json,sys
p=json.loads(sys.argv[1])["payload"]
actions=[b for b in p["blocks"] if b.get("type")=="actions"]
assert len(actions)==1
els=actions[0]["elements"]
assert len(els)==1 and els[0]["type"]=="multi_static_select"
assert "confirm" in els[0] and isinstance(els[0]["confirm"], dict)
assert not any(e.get("type")=="button" for e in els)
assert els[0]["action_id"].endswith(":submit")
' "$MULTI_L2"

# ---------------------------------------------------------------------------
# 13. ask: --fallback not among options fails
# ---------------------------------------------------------------------------
assert_fail "ask fallback not in options fails" \
  bash "$SLACK_UI" ask \
    --question "Q" \
    --option "a|A" --option "b|B" \
    --fallback z \
    --timeout 60 \
    --channel C1 \
    --dry-run

# ---------------------------------------------------------------------------
# 14. resolve dry-run (answered): chat.update, no actions, answer + user
# ---------------------------------------------------------------------------
RESOLVE_OUT="$(
  bash "$SLACK_UI" resolve \
    --decision-id "$ASK_DECISION_ID" \
    --channel C01234567 \
    --ts 1710000000.000100 \
    --question "Ship to prod?" \
    --answer-label "Yes, ship" \
    --answer-value yes \
    --user U0123ABC \
    --answered-at "2026-01-15T12:00:00Z" \
    --state-dir "$ASK_STATE_DIR" \
    --dry-run
)"

assert_eq "resolve answered: one JSON line" \
  "$(printf '%s\n' "$RESOLVE_OUT" | wc -l | tr -d '[:space:]')" "1"

assert_ok "resolve answered: valid JSON" jq -e . <<<"$RESOLVE_OUT"

assert_eq "resolve answered: api chat.update" \
  "$(jq -r '.api' <<<"$RESOLVE_OUT")" "chat.update"

assert_ok "resolve answered: zero actions blocks, answer label, user in context" \
  python3 -c '
import json,sys
p=json.loads(sys.argv[1])["payload"]
assert all(b.get("type")!="actions" for b in p["blocks"])
blob=json.dumps(p)
assert "Yes, ship" in blob
assert "U0123ABC" in blob
sec=[b for b in p["blocks"] if b.get("type")=="section"]
assert sec and "Yes, ship" in sec[0]["text"]["text"]
ctx=[b for b in p["blocks"] if b.get("type")=="context"]
assert ctx and "U0123ABC" in ctx[0]["elements"][0]["text"]
' "$RESOLVE_OUT"

assert_ok "resolve answered: pending resolved true + action" \
  python3 -c '
import json,sys,os
path=os.path.join(sys.argv[1], sys.argv[2]+".json")
d=json.load(open(path))
assert d.get("resolved") is True, d
assert d.get("action")=="yes", d
' "$ASK_STATE_DIR" "$ASK_DECISION_ID"

# ---------------------------------------------------------------------------
# 15. resolve --timed-out: fallback applied text; mutual exclusion with --user
# ---------------------------------------------------------------------------
TIMEOUT_OUT="$(
  bash "$SLACK_UI" resolve \
    --decision-id "TESTDECISION0000000000000002" \
    --channel C1 \
    --ts 99.001 \
    --timed-out \
    --fallback-label "Defer" \
    --state-dir "$ASK_STATE_DIR" \
    --dry-run
)"

assert_ok "resolve timed-out: contains fallback applied + label" \
  python3 -c '
import json,sys
p=json.loads(sys.argv[1])["payload"]
blob=json.dumps(p)
assert "fallback applied" in blob.lower()
assert "Defer" in blob
' "$TIMEOUT_OUT"

assert_fail "resolve timed-out + user mutually exclusive" \
  bash "$SLACK_UI" resolve \
    --decision-id X \
    --channel C1 \
    --ts 1.0 \
    --timed-out \
    --fallback-label "X" \
    --user U1 \
    --dry-run

rm -rf "$ASK_STATE_DIR"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
