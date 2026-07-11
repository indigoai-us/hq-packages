#!/usr/bin/env bash
# Offline tests for decisions-lib.sh + decision lifecycle via slack-ui.sh.
# No network, no Slack. Exit nonzero on failure. Deps: bash, jq.
#
# Mirrors test-slack-ui.sh harness style.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SLACK_UI="${SCRIPTS_DIR}/slack-ui.sh"
DECISIONS_LIB="${SCRIPTS_DIR}/decisions-lib.sh"
WATCH_SH="${SCRIPTS_DIR}/watch.sh"
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

[ -f "$SLACK_UI" ] || { red "missing $SLACK_UI"; exit 1; }
[ -f "$DECISIONS_LIB" ] || { red "missing $DECISIONS_LIB"; exit 1; }
[ -x "$SLACK_UI" ] || chmod +x "$SLACK_UI"

# ---------------------------------------------------------------------------
# 0. bash -n on the three scripts
# ---------------------------------------------------------------------------
assert_ok "bash -n decisions-lib.sh" bash -n "$DECISIONS_LIB"
assert_ok "bash -n slack-ui.sh" bash -n "$SLACK_UI"
assert_ok "bash -n watch.sh" bash -n "$WATCH_SH"

STATE="$(mktemp -d "${TMPDIR:-/tmp}/test-decisions.XXXXXX")"
SEEN_DIR="$STATE/.seen"
trap 'rm -rf "$STATE"' EXIT

# shellcheck source=../decisions-lib.sh
. "$DECISIONS_LIB"

ask_pending() {
  local id="$1"
  shift
  bash "$SLACK_UI" ask \
    --dry-run \
    --decision-id "$id" \
    --question "Ship to prod?" \
    --option "ship|Ship it" \
    --option "hold|Hold" \
    --option "abort|Abort" \
    --recommend ship \
    --abort abort \
    --fallback hold \
    --timeout 60 \
    --channel C1 \
    --thread 111.222 \
    --state-dir "$STATE" \
    "$@" \
    >/dev/null
}

# ---------------------------------------------------------------------------
# 1. Create pending via ask --dry-run; pending list; mark resolved clears it
# ---------------------------------------------------------------------------
DECISION_ID="TESTDECISION00000000000000A1"
ask_pending "$DECISION_ID"

PENDING_FILE="${STATE}/${DECISION_ID}.json"
assert "pending file exists" test -f "$PENDING_FILE"

LIST="$(decisions_pending_files "$STATE")"
assert_eq "decisions_pending_files lists the file" "$LIST" "$PENDING_FILE"

# missing dir → empty
assert_eq "decisions_pending_files missing dir is empty" \
  "$(decisions_pending_files "$STATE/does-not-exist")" ""

# empty dir → empty
EMPTY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-decisions-empty.XXXXXX")"
assert_eq "decisions_pending_files empty dir is empty" \
  "$(decisions_pending_files "$EMPTY_DIR")" ""
rmdir "$EMPTY_DIR"

NOW="$(date +%s)"
assert_ok "decision_mark_resolved first call" \
  decision_mark_resolved "$PENDING_FILE" "ship" "ship" "U9" "2026-01-15T12:00:00Z"

assert_eq "after mark_resolved pending list empty" \
  "$(decisions_pending_files "$STATE")" ""

assert_eq "resolved field true" \
  "$(jq -r '.resolved' "$PENDING_FILE")" "true"

# ---------------------------------------------------------------------------
# 2. decision_match_option
# ---------------------------------------------------------------------------
DECISION_ID2="TESTDECISION00000000000000A2"
ask_pending "$DECISION_ID2"
PF2="${STATE}/${DECISION_ID2}.json"

assert_eq 'match_option "hold" → hold' \
  "$(decision_match_option "$PF2" "hold")" "hold"

assert_fail 'match_option "  HOLD it? no —" fails' \
  decision_match_option "$PF2" "  HOLD it? no —"

assert_eq 'match_option "ship IT" (label, case-insensitive) → ship' \
  "$(decision_match_option "$PF2" "ship IT")" "ship"

assert_eq 'match_option "Ship it" → ship' \
  "$(decision_match_option "$PF2" "Ship it")" "ship"

assert_fail 'match_option "shi" substring fails' \
  decision_match_option "$PF2" "shi"

assert_fail 'match_option "nope" fails' \
  decision_match_option "$PF2" "nope"

# ---------------------------------------------------------------------------
# 3. decision_is_expired with injected now
# ---------------------------------------------------------------------------
EXPIRES="$(decision_field "$PF2" '.expires_at')"
assert_fail "not expired at expires_at-10" \
  decision_is_expired "$PF2" "$((EXPIRES - 10))"

assert_ok "expired at expires_at+10" \
  decision_is_expired "$PF2" "$((EXPIRES + 10))"

# ---------------------------------------------------------------------------
# 4. decision_mark_resolved idempotency
# ---------------------------------------------------------------------------
assert_ok "idempotency first mark" \
  decision_mark_resolved "$PF2" "hold" "hold" "U1" "2026-01-15T12:00:00Z"
ORIG_VALUE="$(jq -r '.value' "$PF2")"

assert_fail "idempotency second mark returns 1" \
  decision_mark_resolved "$PF2" "ship" "ship" "U2" "2026-01-15T13:00:00Z"

assert_eq "idempotency value unchanged" \
  "$(jq -r '.value' "$PF2")" "$ORIG_VALUE"

# ---------------------------------------------------------------------------
# 5. decision_event_seen / mark_seen round-trip
# ---------------------------------------------------------------------------
assert_fail "event not seen initially" \
  decision_event_seen "$SEEN_DIR" "$DECISION_ID2"

assert_ok "event mark_seen" \
  decision_event_mark_seen "$SEEN_DIR" "$DECISION_ID2"

assert_ok "event seen after mark" \
  decision_event_seen "$SEEN_DIR" "$DECISION_ID2"

# ---------------------------------------------------------------------------
# 6. decision_dispatch dumps env + path
# ---------------------------------------------------------------------------
DECISION_ID3="TESTDECISION00000000000000A3"
ask_pending "$DECISION_ID3"
PF3="${STATE}/${DECISION_ID3}.json"
assert_ok "mark PF3 resolved for dispatch" \
  decision_mark_resolved "$PF3" "ship" "ship" "U9" "2026-01-15T12:00:00Z"

STUB_OUT="$STATE/dispatch-out.txt"
STUB="$STATE/dispatch-stub.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
out="${DECISION_DISPATCH_OUT:?}"
{
  echo "DECISION_ID=${DECISION_ID:-}"
  echo "DECISION_QUESTION=${DECISION_QUESTION:-}"
  echo "DECISION_ANSWER_VALUE=${DECISION_ANSWER_VALUE:-}"
  echo "DECISION_ANSWER_LABEL=${DECISION_ANSWER_LABEL:-}"
  echo "DECISION_USER=${DECISION_USER:-}"
  echo "DECISION_CHANNEL=${DECISION_CHANNEL:-}"
  echo "DECISION_THREAD_TS=${DECISION_THREAD_TS:-}"
  echo "ARG1=${1:-}"
} >"$out"
EOF
chmod +x "$STUB"

export DECISION_DISPATCH_OUT="$STUB_OUT"
assert_ok "decision_dispatch runs stub" \
  decision_dispatch "$PF3" bash "$STUB"

assert_eq "dispatch DECISION_ID" \
  "$(grep '^DECISION_ID=' "$STUB_OUT" | cut -d= -f2-)" "$DECISION_ID3"
assert_eq "dispatch DECISION_ANSWER_VALUE" \
  "$(grep '^DECISION_ANSWER_VALUE=' "$STUB_OUT" | cut -d= -f2-)" "ship"
assert_eq "dispatch DECISION_ANSWER_LABEL" \
  "$(grep '^DECISION_ANSWER_LABEL=' "$STUB_OUT" | cut -d= -f2-)" "Ship it"
assert_eq "dispatch DECISION_CHANNEL" \
  "$(grep '^DECISION_CHANNEL=' "$STUB_OUT" | cut -d= -f2-)" "C1"
assert_eq "dispatch DECISION_THREAD_TS" \
  "$(grep '^DECISION_THREAD_TS=' "$STUB_OUT" | cut -d= -f2-)" "111.222"
assert_eq "dispatch ARG1 pending path" \
  "$(grep '^ARG1=' "$STUB_OUT" | cut -d= -f2-)" "$PF3"

# ---------------------------------------------------------------------------
# 7. End-to-end simulated poll event with seen-marker dedup
# ---------------------------------------------------------------------------
DECISION_ID4="TESTDECISION00000000000000A4"
ask_pending "$DECISION_ID4"
PF4="${STATE}/${DECISION_ID4}.json"
DISPATCH_COUNT_FILE="$STATE/dispatch-count"
: >"$DISPATCH_COUNT_FILE"
STUB_COUNT="$STATE/dispatch-count-stub.sh"
cat >"$STUB_COUNT" <<'EOF'
#!/usr/bin/env bash
echo 1 >>"${DECISION_DISPATCH_COUNT_FILE:?}"
EOF
chmod +x "$STUB_COUNT"
export DECISION_DISPATCH_COUNT_FILE="$DISPATCH_COUNT_FILE"

# Simulated poll processing (mirrors poll_decisions core logic).
simulate_poll_event() {
  local decision_id="$1" answered_at="$2" action="$3" value="$4" user="$5"
  local pf="${STATE}/${decision_id}.json"
  if decision_event_seen "$SEEN_DIR" "$decision_id"; then
    return 0
  fi
  decision_event_mark_seen "$SEEN_DIR" "$decision_id"
  if [ ! -f "$pf" ]; then
    return 0
  fi
  if [ "$(jq -r '.resolved // false' "$pf")" = "true" ]; then
    return 0
  fi
  if decision_mark_resolved "$pf" "$action" "$value" "$user" "$answered_at"; then
    decision_dispatch "$pf" bash "$STUB_COUNT"
  fi
}

simulate_poll_event "$DECISION_ID4" "2026-01-15T12:00:00Z" "ship" "ship" "U9"
simulate_poll_event "$DECISION_ID4" "2026-01-15T12:00:00Z" "ship" "ship" "U9"

DISPATCH_N="$(wc -l <"$DISPATCH_COUNT_FILE" | tr -d '[:space:]')"
assert_eq "poll event dispatch exactly once (dedup)" "$DISPATCH_N" "1"
assert_eq "poll event pending resolved" \
  "$(jq -r '.resolved' "$PF4")" "true"
assert_eq "poll event action ship" \
  "$(jq -r '.action' "$PF4")" "ship"

# ---------------------------------------------------------------------------
# 8. Timeout path: expired decision + resolve --timed-out dry-run
# ---------------------------------------------------------------------------
DECISION_ID5="TESTDECISION00000000000000A5"
ask_pending "$DECISION_ID5" --timeout 1
PF5="${STATE}/${DECISION_ID5}.json"

# Force expires_at into the past.
jq --argjson past "$(( $(date +%s) - 30 ))" '.expires_at = $past' "$PF5" >"${PF5}.tmp"
mv -f "${PF5}.tmp" "$PF5"

assert_ok "timeout decision is expired" decision_is_expired "$PF5"

TIMEOUT_OUT="$(
  bash "$SLACK_UI" resolve \
    --decision-id "$DECISION_ID5" \
    --channel C1 \
    --ts DRYRUN_TS \
    --question "Ship to prod?" \
    --timed-out \
    --fallback-label "Hold" \
    --answer-value hold \
    --state-dir "$STATE" \
    --dry-run
)"

assert_ok "timeout resolve: valid JSON" jq -e . <<<"$TIMEOUT_OUT"
assert_eq "timeout resolve: api chat.update" \
  "$(jq -r '.api' <<<"$TIMEOUT_OUT")" "chat.update"

assert_ok "timeout payload: fallback applied + label + zero actions" \
  python3 -c '
import json,sys
p=json.loads(sys.argv[1])["payload"]
blob=json.dumps(p).lower()
assert "fallback applied" in blob, blob
assert "hold" in blob, blob
assert all(b.get("type")!="actions" for b in p.get("blocks") or [])
' "$TIMEOUT_OUT"

assert_eq "timeout pending resolved true" \
  "$(jq -r '.resolved' "$PF5")" "true"
assert_eq "timeout pending action timeout" \
  "$(jq -r '.action' "$PF5")" "timeout"

# Also exercise mark_resolved timeout path independently on a fresh file
DECISION_ID6="TESTDECISION00000000000000A6"
ask_pending "$DECISION_ID6" --timeout 1
PF6="${STATE}/${DECISION_ID6}.json"
jq --argjson past "$(( $(date +%s) - 5 ))" '.expires_at = $past' "$PF6" >"${PF6}.tmp"
mv -f "${PF6}.tmp" "$PF6"
assert_ok "decision_is_expired on forced-past file" decision_is_expired "$PF6"
assert_ok "mark_resolved timeout action" \
  decision_mark_resolved "$PF6" "timeout" "hold" "" "2026-01-15T12:00:00Z"
assert_eq "mark timeout action field" \
  "$(jq -r '.action' "$PF6")" "timeout"
assert_eq "mark timeout value fallback" \
  "$(jq -r '.value' "$PF6")" "hold"

# ---------------------------------------------------------------------------
# 9. decisions_poll_url
# ---------------------------------------------------------------------------
assert_eq "poll url with bot" \
  "$(decisions_poll_url "https://api.example.com" "A123")" \
  "https://api.example.com/v1/slack/decisions?bot=A123"

assert_eq "poll url without bot" \
  "$(decisions_poll_url "https://api.example.com/" "")" \
  "https://api.example.com/v1/slack/decisions"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
