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
# Summary
# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
