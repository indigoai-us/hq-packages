#!/usr/bin/env bash
# watch.sh <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [--check]
#
# Poll every channel a chosen bot is a member of for new @-mentions, and
# spawn one slack-mention-worker per new mention. Emits events on stdout
# so a parent Monitor task in Claude can stream them as notifications.
#
# Companion package: personal/packages/hq-slack-bot/ — see README.md.
#
# Secret resolution: <bot-slug> + <workspace> + scope → vault entry
#     HQ_SLACK_BOT_TOKEN_<UPPER_BOT>_<UPPER_WORKSPACE>
#       in  --personal  OR  --company <slug>
#
# Workspace = Slack team_domain (e.g. "indigo-ai"). The workspace
# component lets the same bot slug live in multiple workspaces without
# colliding on vault keys. Resolution order:
#   1. Explicit -w <workspace-slug>.
#   2. --personal scope fallback: parse `team_domain` out of the
#      personal vault's SLACK_CREDENTIALS_JSON (the vault owner's
#      Slack-CLI snapshot).
#   3. Otherwise: hard error.
#
# DM gate: the bot answers DM @-mentions ONLY from its creator. The
# creator's Slack user id is inferred (no explicit arg needed):
#   1. Companion vault secret HQ_SLACK_BOT_CREATOR_<UPPER_BOT>_<UPPER_WORKSPACE>
#      (written by hq-pro install-callback).
#   2. --personal scope fallback: SLACK_CREDENTIALS_JSON has a stable
#      baked-in user_id field (the vault owner).
#   3. If neither resolves: no DM gate — the bot ignores ALL DMs and
#      only responds to channel mentions.
# Channel mentions are unaffected by this gate.
#
# Workers are detached (nohup ... &). Killing this watcher does NOT kill
# in-flight workers — they own their thread until their own exit
# conditions fire. Worker logs land at $HQ_ROOT/workspace/workers/runs/<id>/.
#
# On first arm, per-channel cursors are initialized to "now" — backfilling
# the entire history on startup would spawn workers on long-resolved
# conversations across every channel the bot already belongs to.
#
# Channel list is re-polled every MENTION_CHANNEL_REFRESH_SECS (default
# 60s) and compared as a set — newly-joined channels start polling
# immediately, no restart needed.
#
# When a channel is newly joined MID-RUN (i.e. not present at first arm),
# the cursor is initialized to (now - MENTION_BACKFILL_SECS, default 600s)
# rather than "now". This catches @-mentions that landed in the gap
# between the bot being invited and the next channel-refresh tick.
# The spawn-dedupe sentinel ($SPAWN_DIR/<ts>.spawned) guarantees a message
# is never replied to twice across consecutive arms.

set -u
set -o pipefail

# ── Args ────────────────────────────────────────────────────────────────────
BOT_SLUG=""
COMPANY=""
USE_PERSONAL=0
CHECK_ONLY=0
WORKSPACE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c)
      [ "$#" -ge 2 ] || { echo "FATAL: -c requires a company slug (or 'personal')" >&2; exit 64; }
      COMPANY="$2"; shift 2 ;;
    --personal) USE_PERSONAL=1; shift ;;
    -w)
      [ "$#" -ge 2 ] || { echo "FATAL: -w requires a workspace slug (Slack team_domain)" >&2; exit 64; }
      WORKSPACE="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help)
      echo "usage: $0 <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [--check]" >&2
      exit 0 ;;
    -*) echo "FATAL: unknown flag: $1" >&2; exit 64 ;;
    *)
      if [ -z "$BOT_SLUG" ]; then BOT_SLUG="$1"; else
        echo "FATAL: unexpected positional arg: $1" >&2; exit 64
      fi
      shift ;;
  esac
done

if [ -z "$BOT_SLUG" ]; then
  echo "usage: $0 <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [--check]" >&2
  exit 64
fi

# Allow `-c personal` as an alias for --personal.
if [ "$COMPANY" = "personal" ]; then
  USE_PERSONAL=1
  COMPANY=""
fi
if [ "$USE_PERSONAL" -eq 1 ] && [ -n "$COMPANY" ]; then
  echo "FATAL: --personal and -c <company> are mutually exclusive" >&2
  exit 64
fi
if [ "$USE_PERSONAL" -eq 0 ] && [ -z "$COMPANY" ]; then
  echo "FATAL: must specify --personal or -c <company-slug>" >&2
  exit 64
fi

if [ "$USE_PERSONAL" -eq 1 ]; then
  HQ_SCOPE_ARGS=(--personal)
  SCOPE_LABEL="personal"
  # Token-scope hint we pass to the worker so it can re-fetch the same secret.
  WORKER_SCOPE_FLAGS="--personal"
else
  HQ_SCOPE_ARGS=(--company "$COMPANY")
  SCOPE_LABEL="company:$COMPANY"
  WORKER_SCOPE_FLAGS="--company $COMPANY"
fi

# ── Workspace resolution ──────────────────────────────────────────────────
# Personal-scope fallback: SLACK_CREDENTIALS_JSON is a snapshot of the
# vault owner's ~/.slack/credentials.json; team_domain inside is stable.
WORKSPACE_SRC=""
if [ -z "$WORKSPACE" ] && [ "$USE_PERSONAL" -eq 1 ]; then
  _creds_json="$(HQ_NO_UPDATE_CHECK=1 hq secrets --personal get --reveal SLACK_CREDENTIALS_JSON 2>/dev/null \
                  | sed -n '/^  Value:/,$p' | sed '1s/^  Value: *//')"
  if [ -n "$_creds_json" ]; then
    WORKSPACE="$(printf '%s' "$_creds_json" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    # SLACK_CREDENTIALS_JSON has team entries (dicts) mixed with scalar
    # metadata at the top level (e.g. user_id) — skip non-dict values
    # so a scalar appearing before any team entry does not blow up the
    # whole parse via .get() on a string.
    for team, v in d.items():
        if not isinstance(v, dict):
            continue
        td = v.get("team_domain") or ""
        if td:
            print(td); break
except Exception:
    pass
' 2>/dev/null)"
    [ -n "$WORKSPACE" ] && WORKSPACE_SRC="personal:SLACK_CREDENTIALS_JSON.team_domain"
  fi
  unset _creds_json
fi

if [ -z "$WORKSPACE" ]; then
  echo "FATAL: must specify -w <workspace> (or use --personal so it can be derived from SLACK_CREDENTIALS_JSON)" >&2
  exit 64
fi

# Slug + workspace → vault secret names. Mirrors botSecretKey() /
# botCreatorKey() in hq-pro src/slack-apps/normalize-name.ts — keep in sync.
_norm() { echo "$1" | tr '[:lower:]-.' '[:upper:]__' | tr -cd 'A-Z0-9_'; }
BOT_UC="$(_norm "$BOT_SLUG")"
WS_UC="$(_norm "$WORKSPACE")"
SECRET_NAME="HQ_SLACK_BOT_TOKEN_${BOT_UC}_${WS_UC}"
CREATOR_SECRET="HQ_SLACK_BOT_CREATOR_${BOT_UC}_${WS_UC}"

# ── Resolve paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HQ_ROOT="$(cd "$PACKAGE_DIR/../../.." && pwd)"
TEMPLATE_RUNNER="$HQ_ROOT/personal/tools/claude-worker-template.sh"
WORKER_TEMPLATE="slack-mention-worker"
TEMPLATE_DIR="$HQ_ROOT/personal/workers/$WORKER_TEMPLATE"
PARSE_MENTIONS="$SCRIPT_DIR/parse-mentions.py"

SPAWN_DIR="/tmp/hq-slack-bot.${BOT_SLUG}.spawned"
CURSOR_DIR="/tmp/hq-slack-bot.${BOT_SLUG}.cursors"
LOG_DIR="${MENTION_LOG_DIR:-$HQ_ROOT/workspace/logs/hq-slack-bot/$BOT_SLUG}"
WATCHER_ALIVE_FILE="${MENTION_WATCHER_ALIVE_FILE:-/tmp/hq-slack-bot.${BOT_SLUG}.alive}"

mkdir -p "$SPAWN_DIR" "$CURSOR_DIR" "$LOG_DIR"

# ── Pre-flight: file deps ──────────────────────────────────────────────────
for f in "$PARSE_MENTIONS"; do
  if [ ! -e "$f" ]; then echo "FATAL: missing $f" >&2; exit 1; fi
done
if [ ! -x "$PARSE_MENTIONS" ]; then
  chmod +x "$PARSE_MENTIONS" || { echo "FATAL: cannot chmod $PARSE_MENTIONS" >&2; exit 1; }
fi
if [ "$CHECK_ONLY" -eq 0 ]; then
  if [ ! -e "$TEMPLATE_RUNNER" ]; then
    echo "FATAL: missing $TEMPLATE_RUNNER (run: hq sync pull --all)" >&2
    exit 1
  fi
  if [ ! -x "$TEMPLATE_RUNNER" ]; then
    echo "FATAL: $TEMPLATE_RUNNER is not executable (chmod +x it first)" >&2
    exit 1
  fi
  if [ ! -e "$TEMPLATE_DIR/system-prompt.md" ]; then
    echo "FATAL: missing $TEMPLATE_DIR/system-prompt.md — worker symlink missing? See README." >&2
    exit 1
  fi
fi

# ── Load token from vault (scope picked by --personal or -c <slug>) ────────
# NOTE: do not use `source <(hq …)` — process substitution races with hq's
# (Node) stdout close and silently yields zero bytes. Capture then eval.
_hq_env="$(HQ_NO_UPDATE_CHECK=1 hq secrets "${HQ_SCOPE_ARGS[@]}" env --only "$SECRET_NAME" 2>/dev/null | grep '^export ')"
eval "$_hq_env" || true
unset _hq_env
TOKEN="$(eval "echo \${$SECRET_NAME:-}")"
if [ -z "$TOKEN" ]; then
  echo "FATAL: $SECRET_NAME not loadable from $SCOPE_LABEL vault" >&2
  echo "       try: hq secrets ${HQ_SCOPE_ARGS[*]} get $SECRET_NAME" >&2
  exit 1
fi

# ── auth.test → BOT_USER_ID ────────────────────────────────────────────────
AUTH_TEST="$(curl -fsS -X POST "https://slack.com/api/auth.test" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo '{}')"
BOT_USER_ID="$(printf '%s' "$AUTH_TEST" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("user_id") or "")' 2>/dev/null || echo "")"
if [ -z "$BOT_USER_ID" ]; then
  echo "FATAL: auth.test returned no user_id — token rotated or scope missing?" >&2
  echo "       response: $AUTH_TEST" >&2
  exit 1
fi

# ── Infer creator (for DM gate) ────────────────────────────────────────────
# 1. Companion vault secret HQ_SLACK_BOT_CREATOR_<NAME>_<WORKSPACE> if
#    hq-pro install-callback wrote one.
# 2. Personal scope: SLACK_CREDENTIALS_JSON has a stable user_id baked in.
# 3. Otherwise: empty → bot ignores all DMs.
# CREATOR_SECRET name is computed up at the workspace-resolution step.
CREATOR_ID=""
CREATOR_SRC=""

_creator_env="$(HQ_NO_UPDATE_CHECK=1 hq secrets "${HQ_SCOPE_ARGS[@]}" env --only "$CREATOR_SECRET" 2>/dev/null | grep '^export ')"
if [ -n "$_creator_env" ]; then
  eval "$_creator_env" || true
  CREATOR_ID="$(eval "echo \${$CREATOR_SECRET:-}")"
  [ -n "$CREATOR_ID" ] && CREATOR_SRC="vault:$CREATOR_SECRET"
fi
unset _creator_env

# Personal-scope fallback: vault owner's slack user_id baked into
# SLACK_CREDENTIALS_JSON. Multi-line value → use the `get --reveal` form
# (memory: reference_personal_vault_slack_credentials.md).
if [ -z "$CREATOR_ID" ] && [ "$USE_PERSONAL" -eq 1 ]; then
  _creds_json="$(HQ_NO_UPDATE_CHECK=1 hq secrets --personal get --reveal SLACK_CREDENTIALS_JSON 2>/dev/null \
                  | sed -n '/^  Value:/,$p' | sed '1s/^  Value: *//')"
  if [ -n "$_creds_json" ]; then
    CREATOR_ID="$(printf '%s' "$_creds_json" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    uid = d.get("user_id") or ""
    print(uid)
except Exception:
    pass
' 2>/dev/null)"
    [ -n "$CREATOR_ID" ] && CREATOR_SRC="personal:SLACK_CREDENTIALS_JSON.user_id"
  fi
  unset _creds_json
fi

# Validate creator id shape if we found something.
if [ -n "$CREATOR_ID" ]; then
  case "$CREATOR_ID" in
    [UW][A-Z0-9]*) ;;
    *)
      echo "WARN: inferred creator '$CREATOR_ID' from $CREATOR_SRC has unexpected shape — discarding" >&2
      CREATOR_ID=""
      CREATOR_SRC="" ;;
  esac
fi

# ── List bot's channels (paginated) ────────────────────────────────────────
# Returns rc=0 with channel ids on stdout (one per line, dedup+sorted).
# Returns rc=1 with empty stdout and LAST_LIST_ERR set when the Slack API
# returns ok=false (e.g. missing_scope, invalid_auth, ratelimited) or the
# HTTP response is unparseable. Callers MUST distinguish "no channels"
# from "API error" — silently arming with zero channels means @-mentions
# go undelivered while pre-flight still prints OK.
LAST_LIST_ERR=""
list_bot_channels() {
  local cursor=""
  local out=""
  LAST_LIST_ERR=""
  while :; do
    local url="https://slack.com/api/users.conversations?types=public_channel,private_channel,im,mpim&limit=200"
    if [ -n "$cursor" ]; then url="${url}&cursor=${cursor}"; fi
    local resp curl_rc
    resp="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null)"; curl_rc=$?
    if [ "$curl_rc" -ne 0 ] || [ -z "$resp" ]; then
      LAST_LIST_ERR="curl_failed:rc=$curl_rc"
      return 1
    fi
    local err_file page_ids py_rc
    err_file="$(mktemp)"
    page_ids="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.JSONDecoder(strict=False).decode(sys.stdin.read())
except Exception as e:
    sys.stderr.write("json_decode:" + str(e).split("\n",1)[0] + "\n")
    sys.exit(2)
if not d.get("ok"):
    sys.stderr.write((d.get("error") or "unknown") + "\n")
    sys.exit(2)
for c in d.get("channels") or []:
    if c.get("id"):
        print(c["id"])
' 2>"$err_file")"; py_rc=$?
    if [ "$py_rc" -ne 0 ]; then
      LAST_LIST_ERR="$(tr -d '\n' < "$err_file")"
      rm -f "$err_file"
      [ -n "$LAST_LIST_ERR" ] || LAST_LIST_ERR="parser_exit_${py_rc}"
      return 1
    fi
    rm -f "$err_file"
    if [ -n "$page_ids" ]; then
      out="${out}${page_ids}
"
    fi
    cursor="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.JSONDecoder(strict=False).decode(sys.stdin.read())
except Exception:
    sys.exit(0)
print((d.get("response_metadata") or {}).get("next_cursor") or "")
' 2>/dev/null || echo "")"
    [ -z "$cursor" ] && break
  done
  printf '%s' "$out" | awk 'NF' | sort -u
  return 0
}

# ── Config ─────────────────────────────────────────────────────────────────
POLL_INTERVAL="${MENTION_POLL_INTERVAL:-15}"
CHANNEL_REFRESH_SECS="${MENTION_CHANNEL_REFRESH_SECS:-60}"
WORKER_TIMEOUT_SECS="${MENTION_WORKER_TIMEOUT:-7200}"
SPAWN_PROBE_SECS="${MENTION_SPAWN_PROBE_SECS:-8}"
# Backfill window for channels the bot joins mid-run (NOT applied at first
# arm). Catches @-mentions that landed between invite and refresh tick.
BACKFILL_SECS="${MENTION_BACKFILL_SECS:-600}"

# ── Pre-flight: sample channel list call ───────────────────────────────────
# Surface Slack API failures (missing_scope, invalid_auth, ratelimited)
# loudly instead of arming with zero channels and silently dropping every
# subsequent @-mention.
if ! CHANNELS="$(list_bot_channels)"; then
  echo "FATAL: users.conversations failed: ${LAST_LIST_ERR:-unknown}" >&2
  echo "       (token scope or auth issue — bot would otherwise arm with 0 channels)" >&2
  exit 65
fi
CHANNEL_COUNT="$(printf '%s\n' "$CHANNELS" | awk 'NF' | wc -l)"

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "OK"
  echo "  bot_slug:     $BOT_SLUG"
  echo "  workspace:    $WORKSPACE${WORKSPACE_SRC:+ (source: $WORKSPACE_SRC)}"
  echo "  scope:        $SCOPE_LABEL"
  echo "  secret:       $SECRET_NAME"
  echo "  bot_user_id:  $BOT_USER_ID"
  echo "  channels:     $CHANNEL_COUNT"
  if [ -n "$CREATOR_ID" ]; then
    echo "  creator:      $CREATOR_ID (source: $CREATOR_SRC)"
  else
    echo "  creator:      <unresolved — bot will ignore ALL DM mentions>"
  fi
  exit 0
fi

# ── State ───────────────────────────────────────────────────────────────────
NOW_TS="$(date +%s).000000"
# Initialize per-channel cursors to "now" — backfilling old mentions
# would spawn workers on resolved threads.
while IFS= read -r ch; do
  [ -z "$ch" ] && continue
  cf="$CURSOR_DIR/$ch"
  [ -e "$cf" ] || printf '%s' "$NOW_TS" > "$cf"
done <<< "$CHANNELS"

PREV_ERR=""
PREV_LIST_ERR=""
LAST_CHANNEL_REFRESH="$(date +%s)"
SCRIPT_HASH="$(sha256sum "$0" 2>/dev/null | awk '{print substr($1,1,12)}')"

echo "WATCHER_ARMED bot=$BOT_SLUG workspace=$WORKSPACE scope=$SCOPE_LABEL user_id=$BOT_USER_ID channels=$CHANNEL_COUNT creator=${CREATOR_ID:-<none>} creator_src=${CREATOR_SRC:-none} hash=$SCRIPT_HASH"

# ── Helpers ────────────────────────────────────────────────────────────────
already_spawned() {
  [ -e "$SPAWN_DIR/$1.spawned" ]
}

mark_spawned() {
  : > "$SPAWN_DIR/$1.spawned"
}

# diff_channels <new> <old>  →  emits CHANNEL_JOINED / CHANNEL_LEFT events.
# Set-based, so add+remove combos with unchanged count still surface.
diff_channels() {
  local new="$1" old="$2"
  local added removed
  added="$(comm -23 <(printf '%s\n' "$new" | awk 'NF' | sort -u) \
                     <(printf '%s\n' "$old" | awk 'NF' | sort -u))"
  removed="$(comm -13 <(printf '%s\n' "$new" | awk 'NF' | sort -u) \
                       <(printf '%s\n' "$old" | awk 'NF' | sort -u))"
  while IFS= read -r ch; do
    [ -z "$ch" ] && continue
    echo "CHANNEL_JOINED channel=$ch"
  done <<< "$added"
  while IFS= read -r ch; do
    [ -z "$ch" ] && continue
    echo "CHANNEL_LEFT channel=$ch"
  done <<< "$removed"
}

# spawn_worker <channel> <ts> <user> <thread_ts> <text>
# Dispatches the template runner with per-spawn --var substitutions.
spawn_worker() {
  local channel="$1" ts="$2" user="$3" thread_ts="$4" text="$5"
  local agent_name="mention:${ts}"
  local log_file="$LOG_DIR/worker-${ts}.log"

  local initial_prompt
  initial_prompt="$(cat <<EOF
A new @-mention of bot ${BOT_USER_ID} was posted in Slack.

  channel:    ${channel}
  ts:         ${ts}
  thread_ts:  ${thread_ts}
  reporter:   ${user}
  text:
\`\`\`
${text}
\`\`\`

Follow your system-prompt protocol. Headline:
1. Read the mentioning message + the thread context if any.
2. Respond helpfully in the thread via Slack chat.postMessage.
3. Poll the thread for follow-up replies; respond in-thread until idle
   or the user posts a resolved keyword.
4. Exit per the exit conditions in your system prompt and emit the
   JSON envelope as your final message.

Do not call AskUserQuestion. The Slack thread is your only interaction surface.
EOF
)"

  (
    cd "$HQ_ROOT" || exit 1
    # Scrub host-managed Claude Code env vars before exec — same rationale
    # as monitor-liveops/watch.sh; detached grandchild can't talk back
    # to a desktop-app host's auth broker.
    unset CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST \
          CLAUDE_CODE_ENTRYPOINT \
          CLAUDE_CODE_SESSION_ID \
          CLAUDE_CODE_EXECPATH \
          CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH \
          CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES \
          CLAUDE_CODE_CLASSIFIER_SUMMARY \
          CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL \
          CLAUDE_CODE_NO_FLICKER \
          CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING \
          CLAUDE_CODE_DISABLE_CRON \
          CLAUDE_AUTOCOMPACT_PCT_OVERRIDE \
          CLAUDE_AGENT_SDK_VERSION \
          CLAUDE_EFFORT \
          CLAUDECODE \
          ANTHROPIC_BASE_URL \
          ANTHROPIC_API_KEY \
          AI_AGENT \
          BAGGAGE
    export CLAUDE_STREAM_IDLE_TIMEOUT_MS=600000
    nohup "$TEMPLATE_RUNNER" \
      -t "$WORKER_TEMPLATE" \
      -n "$agent_name" \
      --timeout "$WORKER_TIMEOUT_SECS" \
      --var BOT_SLUG="$BOT_SLUG" \
      --var BOT_USER_ID="$BOT_USER_ID" \
      --var BOT_TOKEN_SECRET="$SECRET_NAME" \
      --var BOT_TOKEN_SCOPE_FLAGS="$WORKER_SCOPE_FLAGS" \
      --var BOT_TOKEN_SCOPE_LABEL="$SCOPE_LABEL" \
      --var CREATOR_SLACK_USER_ID="${CREATOR_ID:-}" \
      --var CHANNEL="$channel" \
      --var THREAD_TS="$thread_ts" \
      --var MENTION_TS="$ts" \
      --var REPORTER="$user" \
      --var HQ_ROOT="$HQ_ROOT" \
      "$initial_prompt" \
      >"$log_file" 2>&1 &
    disown
    echo "SPAWN agent=$agent_name channel=$channel thread_ts=$thread_ts log=$log_file pid=$!"
  )

  # Post-spawn pty.log probe — same pattern as monitor-liveops.
  if [ "$SPAWN_PROBE_SECS" -gt 0 ]; then
    local probe_left="$SPAWN_PROBE_SECS"
    local run_dir=""
    while [ "$probe_left" -gt 0 ]; do
      sleep 1
      if grep -q "unresolved placeholders" "$log_file" 2>/dev/null; then
        echo "SPAWN_FAILED ts=$ts reason=template_placeholders_unresolved log=$log_file"
        rm -f "$SPAWN_DIR/$ts.spawned"
        return 1
      fi
      run_dir="$(grep -oE "$HQ_ROOT/workspace/workers/runs/[A-Za-z0-9_]+" "$log_file" 2>/dev/null | head -1)"
      if [ -n "$run_dir" ] && [ -s "$run_dir/pty.log" ]; then
        return 0
      fi
      probe_left=$((probe_left - 1))
    done
    echo "SPAWN_FAILED ts=$ts reason=pty_log_never_populated probe_secs=$SPAWN_PROBE_SECS run_dir=${run_dir:-unknown}"
    rm -f "$SPAWN_DIR/$ts.spawned"
    return 1
  fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
while true; do
  # Refresh channel list periodically — bot may have been added to (or
  # removed from) channels since startup. Set-diff so net-zero swaps still
  # surface, and newly-joined channels get a "now" cursor + start polling
  # on the very next pass.
  NOW_SEC="$(date +%s)"
  if [ $((NOW_SEC - LAST_CHANNEL_REFRESH)) -ge "$CHANNEL_REFRESH_SECS" ]; then
    NEW_CHANNELS="$(list_bot_channels)"; LIST_RC=$?
    if [ "$LIST_RC" -ne 0 ]; then
      # Slack API failed mid-run (token revoked, scope removed, ratelimit).
      # Emit a deduped event and keep polling existing channels — transient
      # errors recover on the next tick. Do NOT overwrite $CHANNELS so we
      # keep polling with last-known-good state.
      if [ "${LAST_LIST_ERR:-}" != "$PREV_LIST_ERR" ]; then
        echo "API_ERROR users.conversations:${LAST_LIST_ERR:-unknown}"
        PREV_LIST_ERR="$LAST_LIST_ERR"
      fi
    elif [ -n "$NEW_CHANNELS" ]; then
      if [ -n "$PREV_LIST_ERR" ]; then
        echo "RECOVERED users.conversations"
        PREV_LIST_ERR=""
      fi
      diff_channels "$NEW_CHANNELS" "$CHANNELS"
      NEW_COUNT="$(printf '%s\n' "$NEW_CHANNELS" | awk 'NF' | wc -l)"
      if [ "$NEW_COUNT" != "$CHANNEL_COUNT" ]; then
        echo "CHANNELS_REFRESHED count=$NEW_COUNT (was $CHANNEL_COUNT)"
      fi
      CHANNELS="$NEW_CHANNELS"
      CHANNEL_COUNT="$NEW_COUNT"
      # Initialize cursors for newly-joined channels. Set the cursor to
      # (now - BACKFILL_SECS) so any @-mention that landed in the gap
      # between the bot being invited and this refresh tick gets picked
      # up on the very next poll. Spawn-dedupe via $SPAWN_DIR ensures we
      # never reply to the same ts twice.
      BACKFILL_TS="$(awk -v now="$(date +%s)" -v back="$BACKFILL_SECS" 'BEGIN{printf "%d.000000", now-back}')"
      while IFS= read -r ch; do
        [ -z "$ch" ] && continue
        cf="$CURSOR_DIR/$ch"
        [ -e "$cf" ] || printf '%s' "$BACKFILL_TS" > "$cf"
      done <<< "$CHANNELS"
    fi
    LAST_CHANNEL_REFRESH="$NOW_SEC"
  fi

  # Poll each channel since its cursor.
  while IFS= read -r CHANNEL; do
    [ -z "$CHANNEL" ] && continue
    cf="$CURSOR_DIR/$CHANNEL"
    if [ -e "$cf" ]; then
      LAST_TS="$(cat "$cf")"
    else
      LAST_TS="$(date +%s).000000"
      printf '%s' "$LAST_TS" > "$cf"
    fi

    RESP="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
      "https://slack.com/api/conversations.history?channel=${CHANNEL}&oldest=${LAST_TS}&limit=50" 2>/dev/null || true)"

    PARSED="$(printf '%s' "$RESP" | "$PARSE_MENTIONS" --last-ts "$LAST_TS" --bot "$BOT_USER_ID" 2>/dev/null || true)"
    OK="$(printf '%s' "$PARSED" | sed -n 's/^OK=//p' | head -1)"
    ERR="$(printf '%s' "$PARSED" | sed -n 's/^ERR=//p' | head -1)"
    NEW_LAST="$(printf '%s' "$PARSED" | sed -n 's/^MAX_TS=//p' | head -1)"
    ROWS="$(printf '%s' "$PARSED" | awk 'p{print} /^$/{p=1}')"

    if [ "$OK" != "true" ]; then
      if [ "$ERR" != "$PREV_ERR" ]; then
        echo "API_ERROR ${ERR:-unknown} channel=$CHANNEL"
        PREV_ERR="$ERR"
      fi
      continue
    fi
    if [ -n "$PREV_ERR" ]; then
      echo "RECOVERED"
      PREV_ERR=""
    fi

    while IFS=$'\t' read -r TS SLACK_USER THREAD_TS TEXT; do
      [ -z "$TS" ] && continue
      if already_spawned "$TS"; then
        continue
      fi
      PREVIEW="$(printf '%s' "$TEXT" | tr '\n\r' '  ' | cut -c 1-200)"
      echo "MENTION channel=$CHANNEL ts=$TS user=$SLACK_USER text=$PREVIEW"
      mark_spawned "$TS"
      if ! spawn_worker "$CHANNEL" "$TS" "$SLACK_USER" "$THREAD_TS" "$TEXT"; then
        echo "SPAWN_FAILED ts=$TS reason=spawn_worker_returned_nonzero"
      fi
    done <<< "$ROWS"

    if [ -n "$NEW_LAST" ] && [ "$NEW_LAST" != "null" ]; then
      printf '%s' "$NEW_LAST" > "$cf"
    fi
  done <<< "$CHANNELS"

  touch "$WATCHER_ALIVE_FILE" 2>/dev/null || true
  sleep "$POLL_INTERVAL"
done
