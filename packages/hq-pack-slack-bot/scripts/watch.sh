#!/usr/bin/env bash
# watch.sh <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [--check]
#
# Poll every channel a chosen bot is a member of for new @-mentions, and
# spawn one slack-mention-worker per new mention. Emits events on stdout
# so a parent Monitor task in Claude can stream them as notifications.
#
# Package: hq-pack-slack-bot (self-contained; bundles its own
# claude-worker-template.sh, claude-worker.sh, claude-pty-spawn.py
# under scripts/, and the worker template under workers/). See README.md.
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
# The spawn-dedupe sentinel ($SPAWN_DIR/<thread_ts>.spawned) is keyed
# on thread_ts (not the individual message ts), so subsequent @-mentions
# in the same thread are handled by the in-flight worker rather than
# spawning a duplicate.
#
# Creator-presence enforcement: every refresh tick, the watcher confirms
# the creator is still a member of each non-DM channel via
# conversations.members. If absent — and MENTION_LEAVE_ON_CREATOR_ABSENT
# is on (default) — the bot leaves the channel via conversations.leave.
# The check is cached for MENTION_MEMBERSHIP_CHECK_SECS (default 300s).
# Requires channels:leave / groups:leave / mpim:leave scopes on the
# Slack app; without them the watcher emits LEAVE_FAILED and keeps the
# channel in the polling set.

set -u
set -o pipefail

# ── Args ────────────────────────────────────────────────────────────────────
BOT_SLUG=""
COMPANY=""
USE_PERSONAL=0
CHECK_ONLY=0
WORKSPACE=""
# Operator's HQ personUid (`prs_*`). Optional — when omitted, we
# auto-derive from `~/.hq/secrets-cache/prs_*/` (the directory `hq`
# creates the first time you touch a personal-vault secret; its name
# IS the operator's personUid). Pass `-u prs_…` explicitly to
# override (e.g. when running a watcher for a bot created by someone
# else in a shared company vault, or on a machine where the cache
# directory doesn't exist yet).
PERSON_UID=""
PERSON_UID_SRC=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c)
      [ "$#" -ge 2 ] || { echo "FATAL: -c requires a company slug (or 'personal')" >&2; exit 64; }
      COMPANY="$2"; shift 2 ;;
    --personal) USE_PERSONAL=1; shift ;;
    -w)
      [ "$#" -ge 2 ] || { echo "FATAL: -w requires a workspace slug (Slack team_domain)" >&2; exit 64; }
      WORKSPACE="$2"; shift 2 ;;
    -u)
      [ "$#" -ge 2 ] || { echo "FATAL: -u requires an HQ personUid (prs_…)" >&2; exit 64; }
      PERSON_UID="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help)
      echo "usage: $0 <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [-u <prs_personUid>] [--check]" >&2
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
  echo "usage: $0 <bot-slug> { -c <company-slug> | --personal } [-w <workspace>] [-u <prs_personUid>] [--check]" >&2
  exit 64
fi

# Auto-derive personUid from the operator's `hq` CLI secrets cache when
# `-u` wasn't passed. The `~/.hq/secrets-cache/<scopeUid>/` directories
# are created on first vault touch; the personal-scope one is named
# exactly with the operator's `prs_*` personUid (the SSM-hierarchy
# scope prefix). Fall back to a clear error with override hint if
# nothing's there (fresh machine that's never touched personal vault).
if [ -z "$PERSON_UID" ]; then
  PERSON_UID="$(ls -d "$HOME"/.hq/secrets-cache/prs_* 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null || true)"
  [ -n "$PERSON_UID" ] && PERSON_UID_SRC="cache:~/.hq/secrets-cache/$PERSON_UID/"
fi
if [ -z "$PERSON_UID" ]; then
  echo "FATAL: could not auto-derive your HQ personUid from ~/.hq/secrets-cache/" >&2
  echo "       Run any personal-vault command once (e.g. \`hq secrets --personal list\`) and retry," >&2
  echo "       or pass -u <prs_personUid> explicitly." >&2
  exit 64
fi
case "$PERSON_UID" in
  prs_*) ;;
  *)
    echo "FATAL: personUid '$PERSON_UID' has unexpected shape (expected prs_…)" >&2
    exit 64 ;;
esac
[ -n "$PERSON_UID_SRC" ] || PERSON_UID_SRC="arg:-u"

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
  # /startwork accepts `personal` as a company slug — the worker's first
  # turn boots HQ session context (manifest, threads, smart options)
  # before responding to Slack.
  STARTWORK_COMPANY="personal"
else
  HQ_SCOPE_ARGS=(--company "$COMPANY")
  SCOPE_LABEL="company:$COMPANY"
  WORKER_SCOPE_FLAGS="--company $COMPANY"
  STARTWORK_COMPANY="$COMPANY"
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

# Slug + workspace + personUid → vault secret names. Mirrors
# botSecretKey() / botCreatorKey() in hq-pro
# src/slack-apps/normalize-name.ts — keep in sync.
_norm() { echo "$1" | tr '[:lower:]-.' '[:upper:]__' | tr -cd 'A-Z0-9_'; }
BOT_UC="$(_norm "$BOT_SLUG")"
WS_UC="$(_norm "$WORKSPACE")"
# `<prs_…>/HQ_SLACK_BOT_TOKEN_<NAME>_<WORKSPACE>` — slash is the SSM
# hierarchy separator so multiple operators can share a company vault
# without colliding. personUid passes through verbatim (HQ uids
# include lowercase + underscores, both SSM-legal).
SECRET_NAME="${PERSON_UID}/HQ_SLACK_BOT_TOKEN_${BOT_UC}_${WS_UC}"
# xoxp- user token written by hq-pro install-callback when the OAuth
# flow requested user_scope (added 2026-05). Optional — older bots
# don't have one; the watcher disables the search backstop gracefully
# when absent. Used ONLY for the search.messages call (a user-token-
# only API even when bot scopes claim to support it).
USER_TOKEN_SECRET="${PERSON_UID}/HQ_SLACK_USER_TOKEN_${BOT_UC}_${WS_UC}"
CREATOR_SECRET="${PERSON_UID}/HQ_SLACK_BOT_CREATOR_${BOT_UC}_${WS_UC}"

# ── Resolve paths ──────────────────────────────────────────────────────────
# Everything the watcher dispatches is vendored inside the pack — no
# personal/tools/ or personal/workers/ symlink dance. HQ_ROOT is still
# computed (worker spawn cd's into it so relative `hq` invocations from
# inside the worker land in HQ's tree) but it's no longer a resolution
# path for the runner or template. Override with `HQ_ROOT=…` if the
# pack lives at a non-default depth.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$PACKAGE_DIR/../../.." && pwd)}"
TEMPLATE_RUNNER="$SCRIPT_DIR/claude-worker-template.sh"
WORKER_TEMPLATE="slack-mention-worker"
TEMPLATE_DIR="$PACKAGE_DIR/workers/$WORKER_TEMPLATE"
PARSE_MENTIONS="$SCRIPT_DIR/parse-mentions.py"
PARSE_SEARCH="$SCRIPT_DIR/parse-search.py"

SPAWN_DIR="/tmp/hq-slack-bot.${BOT_SLUG}.spawned"
CURSOR_DIR="/tmp/hq-slack-bot.${BOT_SLUG}.cursors"
# Workspace-wide search.messages cursor — high-water-mark across ALL
# @-mentions of the bot found via the search index. Backstops the
# channel-poll + thread-poll loops: catches in-thread mentions whose
# parent message predates arm time (so the parent never appears in
# conversations.history → no T-row → thread never tracked → reply
# invisible). Search has ~30-60s indexing lag, so this is a secondary
# (not primary) detection path.
SEARCH_CURSOR_FILE="/tmp/hq-slack-bot.${BOT_SLUG}.search-cursor"
# Sentinel touched when search.messages returns missing_scope / not_allowed_token_type
# so we skip further attempts for the lifetime of this watcher. Cleared
# on a fresh arm (e.g. after re-installing the bot with new scopes).
SEARCH_DISABLED_FILE="/tmp/hq-slack-bot.${BOT_SLUG}.search-disabled"
# THREAD_DIR holds per-thread reply cursors for top-level messages with
# reply_count > 0 that the watcher is actively polling for in-thread
# @-mentions. One file per thread: <channel>:<thread_ts>. The file
# content is the reply cursor (numeric ts). mtime tracks the last poll;
# GC drops threads whose cursor is older than $THREAD_GC_SECS.
THREAD_DIR="/tmp/hq-slack-bot.${BOT_SLUG}.threads"
# Per-channel creator-membership cache: mtime = last successful check
# (creator confirmed present). Re-checked when older than
# MEMBERSHIP_CHECK_SECS, leaving the channel via conversations.leave
# if the creator is no longer a member.
MEMBERSHIP_DIR="/tmp/hq-slack-bot.${BOT_SLUG}.membership"
LOG_DIR="${MENTION_LOG_DIR:-$HQ_ROOT/workspace/logs/hq-slack-bot/$BOT_SLUG}"
WATCHER_ALIVE_FILE="${MENTION_WATCHER_ALIVE_FILE:-/tmp/hq-slack-bot.${BOT_SLUG}.alive}"

mkdir -p "$SPAWN_DIR" "$CURSOR_DIR" "$THREAD_DIR" "$MEMBERSHIP_DIR" "$LOG_DIR"

# ── Pre-flight: file deps ──────────────────────────────────────────────────
for f in "$PARSE_MENTIONS" "$PARSE_SEARCH"; do
  if [ ! -e "$f" ]; then echo "FATAL: missing $f" >&2; exit 1; fi
done
if [ ! -x "$PARSE_MENTIONS" ]; then
  chmod +x "$PARSE_MENTIONS" || { echo "FATAL: cannot chmod $PARSE_MENTIONS" >&2; exit 1; }
fi
if [ ! -x "$PARSE_SEARCH" ]; then
  chmod +x "$PARSE_SEARCH" || { echo "FATAL: cannot chmod $PARSE_SEARCH" >&2; exit 1; }
fi
if [ "$CHECK_ONLY" -eq 0 ]; then
  if [ ! -e "$TEMPLATE_RUNNER" ]; then
    echo "FATAL: missing $TEMPLATE_RUNNER — pack install incomplete (scripts/ not synced)?" >&2
    exit 1
  fi
  if [ ! -x "$TEMPLATE_RUNNER" ]; then
    chmod +x "$TEMPLATE_RUNNER" || { echo "FATAL: cannot chmod $TEMPLATE_RUNNER" >&2; exit 1; }
  fi
  if [ ! -e "$TEMPLATE_DIR/system-prompt.md" ]; then
    echo "FATAL: missing $TEMPLATE_DIR/system-prompt.md — pack workers/ tree corrupt?" >&2
    exit 1
  fi
fi

# ── Load token from vault (scope picked by --personal or -c <slug>) ────────
# `hq secrets env --only <name>` exports `<name>=…` — but slash chars in
# the name (the SSM-hierarchy `<U…>/…` prefix introduced for multi-
# operator vaults) aren't valid POSIX env-var characters. Use the
# `get --reveal` form + parse the `Value:` line out of the output,
# same pattern as the SLACK_CREDENTIALS_JSON read below.
TOKEN="$(HQ_NO_UPDATE_CHECK=1 hq secrets "${HQ_SCOPE_ARGS[@]}" get --reveal "$SECRET_NAME" 2>/dev/null \
          | sed -n '/^  Value:/,$p' | sed '1s/^  Value: *//' | head -n 1)"
# xoxp- user token — best-effort load. Empty = older bot pre-user_scope
# rollout; poll_search() detects this at the first tick and disables.
USER_TOKEN="$(HQ_NO_UPDATE_CHECK=1 hq secrets "${HQ_SCOPE_ARGS[@]}" get --reveal "$USER_TOKEN_SECRET" 2>/dev/null \
              | sed -n '/^  Value:/,$p' | sed '1s/^  Value: *//' | head -n 1)"
if [ -z "$TOKEN" ]; then
  echo "FATAL: $SECRET_NAME not loadable from $SCOPE_LABEL vault" >&2
  echo "       try: hq secrets ${HQ_SCOPE_ARGS[*]} get --reveal $SECRET_NAME" >&2
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
# 1. Companion vault secret `<U…>/HQ_SLACK_BOT_CREATOR_<NAME>_<WORKSPACE>`
#    if hq-pro install-callback wrote one.
# 2. Personal scope: SLACK_CREDENTIALS_JSON has a stable user_id baked in.
# 3. Otherwise: empty → bot ignores all DMs.
# CREATOR_SECRET name is computed up at the operator-resolution step.
# Same `--reveal` fetch pattern as the token — env-var form can't
# carry slashes.
CREATOR_ID=""
CREATOR_SRC=""

CREATOR_ID="$(HQ_NO_UPDATE_CHECK=1 hq secrets "${HQ_SCOPE_ARGS[@]}" get --reveal "$CREATOR_SECRET" 2>/dev/null \
              | sed -n '/^  Value:/,$p' | sed '1s/^  Value: *//' | head -n 1)"
if [ -n "$CREATOR_ID" ]; then
  CREATOR_SRC="vault:$CREATOR_SECRET"
fi

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
    local url="https://slack.com/api/users.conversations?types=public_channel,private_channel&limit=200"
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
SPAWN_PROBE_SECS="${MENTION_SPAWN_PROBE_SECS:-12}"
# Backfill window for channels the bot joins mid-run (NOT applied at first
# arm). Catches @-mentions that landed between invite and refresh tick.
BACKFILL_SECS="${MENTION_BACKFILL_SECS:-600}"
# Drop tracked threads (replies-without-mention-yet) from the watch list
# once their reply cursor is this old. 24h default.
THREAD_GC_SECS="${MENTION_THREAD_GC_SECS:-86400}"
# Per-loop cap on threads polled (sorted by cursor mtime, freshest first).
# Bounds the work each tick at scale; rarely hit in practice.
THREAD_POLL_CAP="${MENTION_THREAD_POLL_CAP:-50}"
# Membership verification: every MENTION_MEMBERSHIP_CHECK_SECS, the
# watcher confirms the creator is still a member of each channel the
# bot is in. If not — and MENTION_LEAVE_ON_CREATOR_ABSENT is on — the
# bot leaves the channel via conversations.leave. Skipped for DMs (the
# bot can't leave an IM and the DM gate already silences non-creator
# DMs) and when the creator id is unresolved.
MEMBERSHIP_CHECK_SECS="${MENTION_MEMBERSHIP_CHECK_SECS:-300}"
LEAVE_ON_CREATOR_ABSENT="${MENTION_LEAVE_ON_CREATOR_ABSENT:-1}"
# Workspace-wide search.messages poll. Backstops the channel + thread
# pollers — catches in-thread @-mentions whose parent thread isn't in
# the channel-history window, or arrived during a watcher restart.
# Disable with MENTION_SEARCH_POLL_ENABLE=0. Indexing lag (~30–60s)
# means this is a slower fallback, not a primary path.
SEARCH_POLL_ENABLE="${MENTION_SEARCH_POLL_ENABLE:-1}"
SEARCH_POLL_INTERVAL="${MENTION_SEARCH_POLL_INTERVAL:-30}"
# How far back to look on first arm when the search cursor file doesn't
# exist yet. Default 1h catches @-mentions that landed during a short
# watcher outage. Set to 0 to start "from now" (only future mentions).
SEARCH_INITIAL_BACKFILL_SECS="${MENTION_SEARCH_INITIAL_BACKFILL_SECS:-3600}"
# How many results to fetch per search call. Capped by Slack at 100.
SEARCH_RESULT_LIMIT="${MENTION_SEARCH_RESULT_LIMIT:-50}"

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
  echo "  person_uid:   $PERSON_UID (source: $PERSON_UID_SRC)"
  echo "  secret:       $SECRET_NAME"
  if [ -n "${USER_TOKEN:-}" ]; then
    echo "  user_token:   $USER_TOKEN_SECRET (loaded; search backstop available)"
  else
    echo "  user_token:   $USER_TOKEN_SECRET (NOT found — re-install bot to grant user_scope=search:read.*)"
  fi
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

# Initialize search.messages cursor on first arm: now - SEARCH_INITIAL_BACKFILL_SECS.
# Subsequent watcher restarts resume from the existing file so we don't
# re-process the same mentions every restart.
if [ ! -e "$SEARCH_CURSOR_FILE" ]; then
  SEARCH_INIT_TS="$(awk -v now="$(date +%s)" -v back="$SEARCH_INITIAL_BACKFILL_SECS" 'BEGIN{printf "%d.000000", now-back}')"
  printf '%s' "$SEARCH_INIT_TS" > "$SEARCH_CURSOR_FILE"
fi
# Clear any stale "disabled" sentinel from a previous arm; we re-probe
# the search endpoint on each arm so a re-installed bot with new scopes
# activates without manual intervention.
rm -f "$SEARCH_DISABLED_FILE"
LAST_SEARCH_POLL=0

PREV_ERR=""
PREV_SEARCH_ERR=""
PREV_LIST_ERR=""
PREV_MEMBERSHIP_ERR=""
# Force the first main-loop iteration to enter the refresh branch
# immediately, so the creator-presence check runs at arm time instead
# of waiting a full CHANNEL_REFRESH_SECS interval. The check is cheap
# (cached for MEMBERSHIP_CHECK_SECS) and gives the bot a chance to
# leave wrong-room channels before workers can be dispatched.
LAST_CHANNEL_REFRESH=0
SCRIPT_HASH="$(sha256sum "$0" 2>/dev/null | awk '{print substr($1,1,12)}')"

SEARCH_INIT_TS_DISPLAY="$(cat "$SEARCH_CURSOR_FILE" 2>/dev/null || echo "<unset>")"
SEARCH_STATE_DISPLAY="enabled"
[ "$SEARCH_POLL_ENABLE" = "1" ] || SEARCH_STATE_DISPLAY="disabled-by-config"
[ -n "${USER_TOKEN:-}" ] || SEARCH_STATE_DISPLAY="no-user-token"
echo "WATCHER_ARMED bot=$BOT_SLUG workspace=$WORKSPACE scope=$SCOPE_LABEL person_uid=$PERSON_UID user_id=$BOT_USER_ID channels=$CHANNEL_COUNT creator=${CREATOR_ID:-<none>} creator_src=${CREATOR_SRC:-none} search=${SEARCH_STATE_DISPLAY} search_cursor=${SEARCH_INIT_TS_DISPLAY} hash=$SCRIPT_HASH"

# ── Helpers ────────────────────────────────────────────────────────────────
# Spawn dedupe is keyed on the THREAD's ts (the parent message's ts for
# replies, the message's own ts for top-level posts). One LIVE worker per
# thread — subsequent @-mentions in the same thread are handled by that
# worker via its own poll loop, not by spawning another instance.
#
# Liveness check: the dedupe sentinel ($SPAWN_DIR/<thread_ts>.spawned)
# carries the worker's PID once spawn_worker has forked. already_spawned
# reads the PID and verifies the process is still alive via `kill -0`.
# When the worker exits (resolved-keyword, idle, time-cap, etc.), the
# next @-mention in the same thread finds a dead PID, GCs the sentinel,
# and a fresh worker spawns.
#
# Before the PID is written (the few ms between mark_spawned and the
# fork completing), the file is empty — treated as "spawn in progress,
# don't double-spawn". If a spawn crashes before writing its PID, the
# stale empty sentinel is GC'd after $STALE_MARK_SECS (default 300s)
# so the thread isn't permanently silenced.
STALE_MARK_SECS="${STALE_MARK_SECS:-300}"

already_spawned() {
  local f="$SPAWN_DIR/$1.spawned"
  [ -e "$f" ] || return 1
  local pid
  pid="$(cat "$f" 2>/dev/null | tr -d '[:space:]')"
  # Numeric PID present → check liveness.
  if [ -n "$pid" ] && [ "$pid" -eq "$pid" ] 2>/dev/null; then
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    # Worker process is gone → GC sentinel, allow respawn for a new
    # @-mention landing in this thread after the worker exited.
    rm -f "$f"
    return 1
  fi
  # Empty / non-numeric sentinel — spawn in flight, OR a crashed spawn
  # left a stale empty stub. Treat as deduped until $STALE_MARK_SECS,
  # then GC so the thread isn't permanently silenced.
  local mtime now age
  mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$(( now - mtime ))
  if [ "$age" -gt "$STALE_MARK_SECS" ]; then
    rm -f "$f"
    return 1
  fi
  return 0
}

mark_spawned() {
  : > "$SPAWN_DIR/$1.spawned"
}

# Called from inside spawn_worker's subshell once the worker PID is
# known. Atomically replaces the empty sentinel from mark_spawned with
# the PID, so subsequent already_spawned calls can check liveness.
record_spawn_pid() {
  printf '%s\n' "$2" > "$SPAWN_DIR/$1.spawned"
}

# track_thread <channel> <thread_ts> <latest_reply>
# Ensure we have a reply-cursor file for this thread. First-sight cursor
# is the parent ts itself (oldest=parent_ts in conversations.replies
# returns ALL replies, which is exactly the backfill we want — Slack
# threads are short-lived and this catches the "@-mention landed in a
# reply seconds before we noticed the parent" case).
track_thread() {
  local channel="$1" thread_ts="$2" latest_reply="$3"
  if already_spawned "$thread_ts"; then
    return 0
  fi
  local f="$THREAD_DIR/${channel}:${thread_ts}"
  if [ ! -e "$f" ]; then
    printf '%s' "$thread_ts" > "$f"
  fi
}

# channel_has_creator <channel>
#   Returns 0 (true)  — creator is a member, cache touched
#           1 (false) — creator is not a member; channel should be left
#           2 (skip)  — API error or unresolved creator; do nothing
# Cache-aware: a fresh sentinel under $MEMBERSHIP_DIR (mtime within
# MEMBERSHIP_CHECK_SECS) short-circuits the API call.
channel_has_creator() {
  local channel="$1"
  if [ -z "$CREATOR_ID" ]; then
    return 2
  fi
  local sentinel="$MEMBERSHIP_DIR/$channel"
  if [ -e "$sentinel" ]; then
    local mtime now
    mtime="$(stat -c %Y "$sentinel" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ "$((now - mtime))" -lt "$MEMBERSHIP_CHECK_SECS" ]; then
      return 0
    fi
  fi
  local cursor="" found=0 err=""
  while :; do
    local url="https://slack.com/api/conversations.members?channel=${channel}&limit=200"
    if [ -n "$cursor" ]; then url="${url}&cursor=${cursor}"; fi
    local resp
    resp="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null)" || resp=""
    if [ -z "$resp" ]; then
      err="curl_failed"
      break
    fi
    local res
    res="$(printf '%s' "$resp" | CREATOR="$CREATOR_ID" python3 -c '
import json, os, sys
try:
    d = json.JSONDecoder(strict=False).decode(sys.stdin.read())
except Exception as e:
    print("err=parse:" + str(e).split("\n",1)[0]); sys.exit(0)
if not d.get("ok"):
    print("err=" + (d.get("error") or "unknown")); sys.exit(0)
creator = os.environ.get("CREATOR", "")
members = d.get("members") or []
if creator and creator in members:
    print("found=1")
else:
    print("found=0")
print("next=" + ((d.get("response_metadata") or {}).get("next_cursor") or ""))
' 2>/dev/null || echo "err=python_failed")"
    if echo "$res" | grep -q '^err='; then
      err="$(echo "$res" | sed -n 's/^err=//p' | head -1)"
      break
    fi
    if echo "$res" | grep -q '^found=1$'; then
      found=1
      break
    fi
    cursor="$(echo "$res" | sed -n 's/^next=//p' | head -1)"
    [ -z "$cursor" ] && break
  done
  if [ -n "$err" ]; then
    # Be conservative: surface error but don't leave on a transient
    # failure (a network blip would otherwise evict the bot).
    if [ "$err" != "$PREV_MEMBERSHIP_ERR" ]; then
      echo "API_ERROR conversations.members:${err} channel=$channel"
      PREV_MEMBERSHIP_ERR="$err"
    fi
    return 2
  fi
  if [ "$found" -eq 1 ]; then
    touch "$sentinel"
    if [ -n "$PREV_MEMBERSHIP_ERR" ]; then
      echo "RECOVERED conversations.members"
      PREV_MEMBERSHIP_ERR=""
    fi
    return 0
  fi
  # Creator confirmed absent. Remove any stale sentinel so a re-invite
  # forces a fresh check on the next refresh tick.
  rm -f "$sentinel"
  return 1
}

# leave_channel <channel>  → 0 on success, 1 on API failure.
# Emits LEFT_CHANNEL on success and LEAVE_FAILED with the Slack error
# code (likely `missing_scope` if the app lacks channels:leave /
# groups:leave / mpim:leave).
leave_channel() {
  local channel="$1"
  local resp
  resp="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -X POST \
    --data "channel=${channel}" \
    "https://slack.com/api/conversations.leave" 2>/dev/null)" || resp=""
  local ok err
  ok="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.JSONDecoder(strict=False).decode(sys.stdin.read())
    print("true" if d.get("ok") else "false")
except Exception:
    print("false")
' 2>/dev/null)"
  if [ "$ok" = "true" ]; then
    echo "LEFT_CHANNEL channel=$channel reason=creator_absent"
    # Clean up channel-scoped state so a future re-invite starts fresh
    # rather than resuming a stale cursor.
    rm -f "$CURSOR_DIR/$channel" "$MEMBERSHIP_DIR/$channel"
    # Drop any thread cursors anchored to this channel.
    if [ -d "$THREAD_DIR" ]; then
      rm -f "$THREAD_DIR/${channel}:"*
    fi
    return 0
  fi
  err="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.JSONDecoder(strict=False).decode(sys.stdin.read())
    print(d.get("error") or "unknown")
except Exception as e:
    print("parse:" + str(e).split("\n",1)[0])
' 2>/dev/null)"
  echo "LEAVE_FAILED channel=$channel error=${err:-unknown}"
  return 1
}

# gc_threads — remove tracked threads whose cursor is stale or whose
# thread has since been spawned-for. Cheap: stat + arithmetic.
gc_threads() {
  local now cutoff
  now="$(date +%s)"
  cutoff=$((now - THREAD_GC_SECS))
  local f base channel thread_ts mtime
  for f in "$THREAD_DIR"/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    channel="${base%%:*}"
    thread_ts="${base#*:}"
    if [ "$channel" = "$base" ] || [ -z "$thread_ts" ]; then
      # Malformed name — drop it rather than crash later.
      rm -f "$f"
      continue
    fi
    if already_spawned "$thread_ts"; then
      rm -f "$f"
      continue
    fi
    mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    if [ "$mtime" -lt "$cutoff" ]; then
      rm -f "$f"
    fi
  done
}

# poll_search — workspace-wide search.messages backstop. Catches
# in-thread @-mentions whose parent thread the watcher has never seen
# (parent predates arm time, never appears in conversations.history, so
# no T-row → thread never tracked → reply invisible to channel + thread
# pollers). Run on its own cadence (SEARCH_POLL_INTERVAL_SECS) since
# search has ~30–60s indexing lag.
#
# Slack `search.messages` is a USER-token-only API at runtime — even when
# the bot manifest declares the granular `search:read.*` scopes, calls
# with a bot xoxb- token return `not_allowed_token_type`. So this helper
# uses the companion xoxp- USER_TOKEN written by the install-callback
# when the OAuth flow requested `user_scope`. To keep the bot's
# effective reach unchanged, results are POST-FILTERED to channels the
# bot is a member of ($CHANNELS, the same set the channel-poll uses).
#
# Returns 0 on success (or skipped), 1 on transient API error.
# On missing_scope / not_allowed_token_type / etc. → touches
# $SEARCH_DISABLED_FILE and never retries until the next arm.
poll_search() {
  [ "$SEARCH_POLL_ENABLE" = "1" ] || return 0
  [ -e "$SEARCH_DISABLED_FILE" ] && return 0

  # No user token in vault → search backstop unavailable. Touch the
  # sentinel so we don't probe Slack every tick; emit a single line so
  # the operator can spot it. Re-installing the bot (which now requests
  # `user_scope=search:read.*` at OAuth time) populates the secret and
  # the next watcher arm picks it up automatically.
  if [ -z "${USER_TOKEN:-}" ]; then
    touch "$SEARCH_DISABLED_FILE"
    echo "SEARCH_DISABLED reason=no_user_token (re-install bot to grant search:read.* via user_scope)"
    return 0
  fi

  local cursor
  cursor="$(cat "$SEARCH_CURSOR_FILE" 2>/dev/null || echo 0)"
  # Slack search query — literal `<@U…>` token gets indexed as-is.
  # URL-encode the angle brackets so they survive the GET line.
  local raw_q="<@${BOT_USER_ID}>"
  local q="%3C%40${BOT_USER_ID}%3E"
  local resp
  # sort=timestamp + sort_dir=desc gives newest-first; we paginate only
  # within the first page (count up to SEARCH_RESULT_LIMIT) — beyond
  # that the search index isn't reliable for liveness anyway.
  resp="$(curl -fsS -H "Authorization: Bearer $USER_TOKEN" \
    "https://slack.com/api/search.messages?query=${q}&sort=timestamp&sort_dir=desc&count=${SEARCH_RESULT_LIMIT}" \
    2>/dev/null || echo "")"
  if [ -z "$resp" ]; then
    if [ "transport_failure" != "$PREV_SEARCH_ERR" ]; then
      echo "API_ERROR search.messages:transport_failure"
      PREV_SEARCH_ERR="transport_failure"
    fi
    return 1
  fi

  local parsed ok err new_last body
  parsed="$(printf '%s' "$resp" | "$PARSE_SEARCH" --last-ts "$cursor" --bot "$BOT_USER_ID" 2>/dev/null || true)"
  ok="$(printf '%s' "$parsed" | sed -n 's/^OK=//p' | head -1)"
  err="$(printf '%s' "$parsed" | sed -n 's/^ERR=//p' | head -1)"
  new_last="$(printf '%s' "$parsed" | sed -n 's/^MAX_TS=//p' | head -1)"
  body="$(printf '%s' "$parsed" | awk 'p{print} /^$/{p=1}')"

  if [ "$ok" != "true" ]; then
    case "$err" in
      missing_scope|not_allowed_token_type|invalid_auth|not_authed|token_revoked)
        # Permanent — user token doesn't carry search scopes or got
        # revoked. Stop trying for the lifetime of this watcher; channel
        # + thread pollers continue to work.
        touch "$SEARCH_DISABLED_FILE"
        echo "SEARCH_DISABLED reason=${err} (re-install bot with user_scope=search:read.* to re-enable)"
        return 0
        ;;
      *)
        if [ "$err" != "$PREV_SEARCH_ERR" ]; then
          echo "API_ERROR search.messages:${err:-unknown}"
          PREV_SEARCH_ERR="$err"
        fi
        return 1
        ;;
    esac
  fi
  if [ -n "$PREV_SEARCH_ERR" ]; then
    echo "RECOVERED search.messages"
    PREV_SEARCH_ERR=""
  fi

  # Each row: M\t<ts>\t<channel>\t<user>\t<thread_ts>\t<text>
  # Post-filter to the bot's channel set. The xoxp- user token sees the
  # installer's full workspace view — channels the bot is NOT in are
  # silently dropped here so the search grant doesn't widen the bot's
  # effective reach beyond rooms it's been invited into.
  #
  # Fetch a FRESH channel list right before filtering. The main loop's
  # channel-refresh runs on a 60s cadence; search runs on 30s. Without
  # this, a channel the bot was just invited to may not be in $CHANNELS
  # yet when an @-mention in it lands in the search index — filter
  # drops the hit, cursor advances past it, the mention is permanently
  # lost. One extra users.conversations call per 30s is negligible cost
  # and the only reliable way to close the race.
  local CHANNELS_FRESH
  CHANNELS_FRESH="$(list_bot_channels 2>/dev/null || true)"
  if [ -z "$CHANNELS_FRESH" ]; then
    # API blip — fall back to the cached set so we don't lose all hits
    # on a transient failure.
    CHANNELS_FRESH="$CHANNELS"
  fi
  while IFS=$'\t' read -r S_PFX S_TS S_CHANNEL S_USER S_THREAD_TS S_TEXT; do
    [ "$S_PFX" = "M" ] || continue
    [ -z "$S_TS" ] && continue
    if ! printf '%s\n' "$CHANNELS_FRESH" | awk 'NF' | grep -qxF "$S_CHANNEL"; then
      # Channel the BOT isn't in — drop the hit (installer can see it,
      # bot can't act in it).
      continue
    fi
    if already_spawned "$S_THREAD_TS"; then
      continue
    fi
    PREVIEW="$(printf '%s' "$S_TEXT" | tr '\n\r' '  ' | cut -c 1-200)"
    echo "MENTION channel=$S_CHANNEL ts=$S_TS thread_ts=$S_THREAD_TS user=$S_USER text=$PREVIEW (via search)"
    mark_spawned "$S_THREAD_TS"
    # Drop any in-flight thread-tracker — the worker now owns this thread.
    rm -f "$THREAD_DIR/${S_CHANNEL}:${S_THREAD_TS}"
    if ! spawn_worker "$S_CHANNEL" "$S_TS" "$S_USER" "$S_THREAD_TS" "$S_TEXT"; then
      echo "SPAWN_FAILED ts=$S_TS reason=spawn_worker_returned_nonzero source=search"
    fi
  done <<< "$body"

  if [ -n "$new_last" ] && [ "$new_last" != "null" ]; then
    printf '%s' "$new_last" > "$SEARCH_CURSOR_FILE"
  fi
  # Reference unused locals to keep `set -u` happy if no rows were emitted.
  : "${raw_q}"
  return 0
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

  # The worker's first user-turn MUST begin with /startwork so the
  # session boots HQ context (manifest, project routes, credentials)
  # before doing anything Slack-side. The /startwork skill consumes
  # only its own first line; the body that follows is the actual
  # per-mention briefing.
  local initial_prompt
  initial_prompt="$(cat <<EOF
/startwork -c ${STARTWORK_COMPANY}

A new @-mention of bot ${BOT_USER_ID} was posted in Slack.

  channel:    ${channel}
  ts:         ${ts}
  thread_ts:  ${thread_ts}
  reporter:   ${user}
  text:
\`\`\`
${text}
\`\`\`

Once /startwork has resolved your HQ context, follow your
system-prompt protocol. Headline:
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
    worker_pid=$!
    disown
    # Stamp the PID into the dedupe sentinel so already_spawned can
    # check liveness on future @-mentions in this thread. Without this,
    # the sentinel is permanent and the thread silently rejects every
    # follow-up mention after the worker exits (resolved-keyword / idle
    # / timeout).
    record_spawn_pid "$thread_ts" "$worker_pid"
    echo "SPAWN agent=$agent_name channel=$channel thread_ts=$thread_ts log=$log_file pid=$worker_pid"
  )

  # Post-spawn pty.log probe — same pattern as monitor-liveops.
  if [ "$SPAWN_PROBE_SECS" -gt 0 ]; then
    local probe_left="$SPAWN_PROBE_SECS"
    local run_dir=""
    while [ "$probe_left" -gt 0 ]; do
      sleep 1
      if grep -q "unresolved placeholders" "$log_file" 2>/dev/null; then
        echo "SPAWN_FAILED ts=$ts reason=template_placeholders_unresolved log=$log_file"
        # Unmark the THREAD sentinel (keyed by thread_ts, not ts) so the
        # failure doesn't permanently silence the thread. For an in-thread
        # mention ts != thread_ts, so removing "$ts.spawned" would miss the
        # real sentinel and poison the thread until the stale-GC window.
        rm -f "$SPAWN_DIR/$thread_ts.spawned"
        return 1
      fi
      run_dir="$(grep -oE "$HQ_ROOT/workspace/workers/runs/[A-Za-z0-9_]+" "$log_file" 2>/dev/null | head -1)"
      if [ -n "$run_dir" ] && [ -s "$run_dir/pty.log" ]; then
        return 0
      fi
      probe_left=$((probe_left - 1))
    done
    # Probe window elapsed without pty.log output. A slow TUI cold start is
    # NOT a failure: if the worker process is still alive, treat the spawn as
    # successful (it will post when ready) — logging SPAWN_FAILED here and
    # unmarking would both lie in the log and risk a double-spawn next tick.
    # Only a dead worker is a genuine failure worth unmarking + retrying.
    local _sp
    _sp="$(cat "$SPAWN_DIR/$thread_ts.spawned" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$_sp" ] && [ "$_sp" -eq "$_sp" ] 2>/dev/null && kill -0 "$_sp" 2>/dev/null; then
      return 0
    fi
    echo "SPAWN_FAILED ts=$ts reason=pty_log_never_populated probe_secs=$SPAWN_PROBE_SECS run_dir=${run_dir:-unknown}"
    rm -f "$SPAWN_DIR/$thread_ts.spawned"
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

      # ── Creator-presence enforcement ───────────────────────────────────
      # For each non-DM channel, confirm the creator is still a member.
      # If not, leave the channel — the bot represents the creator's
      # identity and shouldn't operate in rooms they've left or were
      # never in. DMs are always kept (the worker's DM gate already
      # silences non-creator DMs, and conversations.leave doesn't apply
      # to IMs anyway). Skipped when the creator id is unresolved or
      # MENTION_LEAVE_ON_CREATOR_ABSENT=0.
      if [ "$LEAVE_ON_CREATOR_ABSENT" = "1" ] && [ -n "$CREATOR_ID" ]; then
        KEEP_LIST=""
        while IFS= read -r ch; do
          [ -z "$ch" ] && continue
          case "$ch" in
            D*) KEEP_LIST="${KEEP_LIST}${ch}"$'\n'; continue ;;
          esac
          channel_has_creator "$ch"
          mrc=$?
          case "$mrc" in
            0) KEEP_LIST="${KEEP_LIST}${ch}"$'\n' ;;
            1)
              # Creator absent — leave.
              if ! leave_channel "$ch"; then
                # Leave failed (likely missing scope). Keep polling
                # rather than churn the channel state on transient
                # errors; user can add channels:leave/groups:leave/
                # mpim:leave scopes and the next tick will succeed.
                KEEP_LIST="${KEEP_LIST}${ch}"$'\n'
              fi
              ;;
            *)
              # API error or unresolved creator — leave the channel
              # in the polling set; we'll re-check next tick.
              KEEP_LIST="${KEEP_LIST}${ch}"$'\n'
              ;;
          esac
        done <<< "$CHANNELS"
        CHANNELS="$(printf '%s' "$KEEP_LIST" | awk 'NF')"
        CHANNEL_COUNT="$(printf '%s\n' "$CHANNELS" | awk 'NF' | wc -l)"
      fi
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

    # --emit-threads asks the parser to also surface T-rows for top-level
    # messages with reply_count > 0, so we can schedule per-thread polling
    # for in-thread @-mentions (mentions that land in REPLIES, not the
    # parent — invisible to conversations.history).
    PARSED="$(printf '%s' "$RESP" | "$PARSE_MENTIONS" --last-ts "$LAST_TS" --bot "$BOT_USER_ID" --emit-threads 2>/dev/null || true)"
    OK="$(printf '%s' "$PARSED" | sed -n 's/^OK=//p' | head -1)"
    ERR="$(printf '%s' "$PARSED" | sed -n 's/^ERR=//p' | head -1)"
    NEW_LAST="$(printf '%s' "$PARSED" | sed -n 's/^MAX_TS=//p' | head -1)"
    BODY="$(printf '%s' "$PARSED" | awk 'p{print} /^$/{p=1}')"

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

    # Two row types interleave in BODY:
    #   M\t<ts>\t<user>\t<thread_ts>\t<text>   → @-mention to dispatch
    #   T\t<thread_ts>\t<reply_count>\t<latest_reply>  → thread to track
    M_ROWS="$(printf '%s\n' "$BODY" | awk -F'\t' '$1=="M"{sub(/^M\t/,""); print}')"
    T_ROWS="$(printf '%s\n' "$BODY" | awk -F'\t' '$1=="T"{sub(/^T\t/,""); print}')"

    while IFS=$'\t' read -r TS SLACK_USER THREAD_TS TEXT; do
      [ -z "$TS" ] && continue
      # Dedupe on THREAD_TS (one worker per thread). If the parent
      # message itself contains an @-mention, parent_ts == thread_ts so
      # this still spawns exactly once.
      if already_spawned "$THREAD_TS"; then
        continue
      fi
      PREVIEW="$(printf '%s' "$TEXT" | tr '\n\r' '  ' | cut -c 1-200)"
      echo "MENTION channel=$CHANNEL ts=$TS thread_ts=$THREAD_TS user=$SLACK_USER text=$PREVIEW"
      mark_spawned "$THREAD_TS"
      # Parent had a mention → no need to track this thread for replies;
      # the worker now owns it. Remove any tracker file we may have set
      # earlier from a previous reply-count tick.
      rm -f "$THREAD_DIR/${CHANNEL}:${THREAD_TS}"
      if ! spawn_worker "$CHANNEL" "$TS" "$SLACK_USER" "$THREAD_TS" "$TEXT"; then
        echo "SPAWN_FAILED ts=$TS reason=spawn_worker_returned_nonzero"
      fi
    done <<< "$M_ROWS"

    # Track every thread with replies that we haven't spawned for. The
    # next loop iteration's thread-poll pass will look for @-mentions in
    # those replies.
    while IFS=$'\t' read -r T_THREAD_TS T_REPLY_COUNT T_LATEST_REPLY; do
      [ -z "$T_THREAD_TS" ] && continue
      track_thread "$CHANNEL" "$T_THREAD_TS" "$T_LATEST_REPLY"
    done <<< "$T_ROWS"

    if [ -n "$NEW_LAST" ] && [ "$NEW_LAST" != "null" ]; then
      printf '%s' "$NEW_LAST" > "$cf"
    fi
  done <<< "$CHANNELS"

  # ── Thread polling pass ─────────────────────────────────────────────────
  # For every thread we're actively tracking, fetch its replies since
  # our cursor and run the same mention parser against them. Spawn dedupe
  # is keyed on thread_ts so we'll still only ever spawn once per thread,
  # whether the mention lands in the parent or a reply.
  #
  # GC first to keep state bounded; ordering doesn't matter — newly
  # tracked threads were added in this very iteration above and will
  # not be expired here.
  gc_threads
  THREAD_COUNT=0
  for tf in $(ls -t "$THREAD_DIR" 2>/dev/null); do
    [ "$THREAD_COUNT" -ge "$THREAD_POLL_CAP" ] && break
    THREAD_COUNT=$((THREAD_COUNT + 1))
    T_CHANNEL="${tf%%:*}"
    T_THREAD_TS="${tf#*:}"
    [ "$T_CHANNEL" = "$tf" ] && continue
    [ -z "$T_THREAD_TS" ] && continue
    # Belt-and-suspenders: if the thread was spawned-for between gc and
    # now, skip it.
    if already_spawned "$T_THREAD_TS"; then
      rm -f "$THREAD_DIR/$tf"
      continue
    fi
    T_CURSOR_FILE="$THREAD_DIR/$tf"
    T_CURSOR="$(cat "$T_CURSOR_FILE" 2>/dev/null || echo "$T_THREAD_TS")"

    T_RESP="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
      "https://slack.com/api/conversations.replies?channel=${T_CHANNEL}&ts=${T_THREAD_TS}&oldest=${T_CURSOR}&limit=50" 2>/dev/null || true)"
    T_PARSED="$(printf '%s' "$T_RESP" | "$PARSE_MENTIONS" --last-ts "$T_CURSOR" --bot "$BOT_USER_ID" 2>/dev/null || true)"
    T_OK="$(printf '%s' "$T_PARSED" | sed -n 's/^OK=//p' | head -1)"
    T_ERR="$(printf '%s' "$T_PARSED" | sed -n 's/^ERR=//p' | head -1)"
    T_NEW_LAST="$(printf '%s' "$T_PARSED" | sed -n 's/^MAX_TS=//p' | head -1)"
    T_BODY="$(printf '%s' "$T_PARSED" | awk 'p{print} /^$/{p=1}')"

    if [ "$T_OK" != "true" ]; then
      if [ "$T_ERR" = "thread_not_found" ]; then
        # Thread was deleted; stop tracking.
        rm -f "$T_CURSOR_FILE"
      fi
      # Non-fatal — keep polling next tick. Errors get surfaced once via
      # the existing PREV_ERR dedupe.
      if [ "$T_ERR" != "$PREV_ERR" ]; then
        echo "API_ERROR thread:${T_ERR:-unknown} channel=$T_CHANNEL thread_ts=$T_THREAD_TS"
        PREV_ERR="$T_ERR"
      fi
      continue
    fi

    while IFS=$'\t' read -r T_PFX T_TS T_USER T_INNER_THREAD T_TEXT; do
      [ "$T_PFX" = "M" ] || continue
      [ -z "$T_TS" ] && continue
      if already_spawned "$T_THREAD_TS"; then
        break
      fi
      PREVIEW="$(printf '%s' "$T_TEXT" | tr '\n\r' '  ' | cut -c 1-200)"
      echo "MENTION channel=$T_CHANNEL ts=$T_TS thread_ts=$T_THREAD_TS user=$T_USER text=$PREVIEW (thread-reply)"
      mark_spawned "$T_THREAD_TS"
      if ! spawn_worker "$T_CHANNEL" "$T_TS" "$T_USER" "$T_THREAD_TS" "$T_TEXT"; then
        echo "SPAWN_FAILED ts=$T_TS reason=spawn_worker_returned_nonzero"
      fi
      rm -f "$T_CURSOR_FILE"
      break
    done <<< "$T_BODY"

    # Advance the thread cursor (and touch the file for liveness/GC)
    # even if no mentions found — that's the whole point of tracking,
    # otherwise we'd re-fetch the same replies every tick forever.
    if [ -n "$T_NEW_LAST" ] && [ "$T_NEW_LAST" != "null" ] && [ -e "$T_CURSOR_FILE" ]; then
      printf '%s' "$T_NEW_LAST" > "$T_CURSOR_FILE"
    elif [ -e "$T_CURSOR_FILE" ]; then
      touch "$T_CURSOR_FILE"
    fi
  done

  # ── Workspace-wide search backstop ──────────────────────────────────────
  # Catches in-thread @-mentions whose parent thread isn't (yet) being
  # tracked by the channel/thread pollers — typically because the parent
  # predates arm time and never appears in conversations.history. Runs on
  # its own cadence (slower than channel poll; search has indexing lag).
  NOW_SEC="$(date +%s)"
  if [ $((NOW_SEC - LAST_SEARCH_POLL)) -ge "$SEARCH_POLL_INTERVAL" ]; then
    poll_search || true
    LAST_SEARCH_POLL="$NOW_SEC"
  fi

  touch "$WATCHER_ALIVE_FILE" 2>/dev/null || true
  sleep "$POLL_INTERVAL"
done
