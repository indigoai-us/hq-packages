#!/usr/bin/env bash
# Regression test for the "listen to threads the bot started" capability.
#
# Covers the parse-mentions.py contract the watcher depends on:
#   1. A bot-authored thread parent emits a T-row with bot_owned=1.
#   2. A human-authored thread parent emits a T-row with bot_owned=0.
#   3. A bot-authored parent carrying the bot_message subtype STILL emits a
#      T-row with bot_owned=1 (the subtype filter must not drop it, or the
#      bot would never hear replies to threads it opened via a webhook-style
#      post).
#   4. A non-bot parent with a structural subtype (channel_join) emits NO
#      T-row (the subtype filter still applies to non-bot parents).
#   5. In --all-messages (firehose) mode, a plain human reply with NO
#      @-mention IS matched as an M-row — this is exactly what the watcher
#      runs for bot-started threads so any reply wakes a worker.
#   6. WITHOUT --all-messages, that same un-tagged reply is NOT matched —
#      proving the gap this feature closes (mention-only is the default for
#      every other thread).
#
# Pure stdin->stdout, no Slack API, no network. Run:
#   bash tests/parse-mentions-bot-owned.test.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSE="$SCRIPT_DIR/../scripts/parse-mentions.py"
BOT="UBOT"

fails=0
pass() { printf '  ok   - %s\n' "$1"; }
fail() { printf '  FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# assert_contains <label> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1 (missing: $3)"; printf '         got:\n%s\n' "$2" | sed 's/^/         | /' ;;
  esac
}
# assert_absent <label> <haystack> <needle>
assert_absent() {
  case "$2" in
    *"$3"*) fail "$1 (unexpected: $3)"; printf '         got:\n%s\n' "$2" | sed 's/^/         | /' ;;
    *) pass "$1" ;;
  esac
}

echo "parse-mentions bot-owned thread detection"

# ── 1 + 2: channel-history emit-threads, bot vs human parent ────────────────
HISTORY='{"ok":true,"messages":[
  {"ts":"100.000001","user":"UBOT","text":"I started this thread","reply_count":2,"latest_reply":"100.000050","thread_ts":"100.000001"},
  {"ts":"100.000002","user":"UHUMAN","text":"a human top-level message","reply_count":1,"latest_reply":"100.000060","thread_ts":"100.000002"}
]}'
OUT="$(printf '%s' "$HISTORY" | "$PARSE" --last-ts 0 --bot "$BOT" --emit-threads 2>&1)"
assert_contains "bot-authored parent -> bot_owned=1" "$OUT" "T	100.000001	2	100.000050	1"
assert_contains "human-authored parent -> bot_owned=0" "$OUT" "T	100.000002	1	100.000060	0"
# Neither should be an M-row: bot's own post is skipped, human post has no @-mention.
assert_absent "no spurious M-row for un-tagged human top-level" "$OUT" "M	100.000002"

# ── 3: bot parent with bot_message subtype still tagged bot_owned=1 ──────────
BOTSUB='{"ok":true,"messages":[
  {"ts":"200.000001","user":"UBOT","bot_id":"BXXX","subtype":"bot_message","text":"posted as bot","reply_count":1,"latest_reply":"200.000010","thread_ts":"200.000001"}
]}'
OUT="$(printf '%s' "$BOTSUB" | "$PARSE" --last-ts 0 --bot "$BOT" --emit-threads 2>&1)"
assert_contains "bot_message-subtype bot parent still emits bot_owned=1" "$OUT" "T	200.000001	1	200.000010	1"

# ── 4: non-bot parent with structural subtype emits no T-row ────────────────
JOINSUB='{"ok":true,"messages":[
  {"ts":"300.000001","user":"UHUMAN","subtype":"channel_join","text":"joined","reply_count":1,"latest_reply":"300.000010","thread_ts":"300.000001"}
]}'
OUT="$(printf '%s' "$JOINSUB" | "$PARSE" --last-ts 0 --bot "$BOT" --emit-threads 2>&1)"
assert_absent "structural-subtype non-bot parent emits no T-row" "$OUT" "T	300.000001"

# ── 5 + 6: replies payload, firehose vs mention-only ────────────────────────
REPLIES='{"ok":true,"messages":[
  {"ts":"100.000001","user":"UBOT","text":"I started this thread","thread_ts":"100.000001"},
  {"ts":"100.000050","user":"UHUMAN","text":"thanks, that helps","thread_ts":"100.000001"}
]}'
# Firehose (what the watcher runs for an own thread): un-tagged reply matches.
OUT="$(printf '%s' "$REPLIES" | "$PARSE" --last-ts 100.000001 --bot "$BOT" --all-messages 2>&1)"
assert_contains "firehose: un-tagged human reply -> M-row" "$OUT" "M	100.000050	UHUMAN	100.000001	thanks, that helps"
assert_absent "firehose: bot's own message never echoes as M-row" "$OUT" "M	100.000001"
# Mention-only (default for non-own threads): same reply does NOT match.
OUT="$(printf '%s' "$REPLIES" | "$PARSE" --last-ts 100.000001 --bot "$BOT" 2>&1)"
assert_absent "mention-only: un-tagged human reply is NOT matched" "$OUT" "M	100.000050"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$fails FAILURE(S)"
  exit 1
fi
