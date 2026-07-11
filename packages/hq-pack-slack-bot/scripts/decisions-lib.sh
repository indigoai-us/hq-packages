#!/usr/bin/env bash
# decisions-lib.sh — pure sourceable helpers for Slack decision state.
#
# bash 3.2 compatible. Uses jq for JSON. No set -e (caller controls error
# mode). No side effects at source time — only defines functions.
#
# Pending files live under a state dir as {decision_id}.json (see
# slack-ui.sh ask / resolve). Shape includes:
#   decision_id, bot, channel, thread_ts, question,
#   options:[{value,label}], recommended, fallback, expires_at (epoch secs),
#   message_ts, and after answer: resolved, action, value, user, answered_at.

# decisions_pending_files <state_dir>
# Print paths of *.json files where .resolved is not true.
# Missing/empty dir → print nothing, return 0.
decisions_pending_files() {
  local state_dir="$1"
  local f
  [ -n "$state_dir" ] || return 0
  [ -d "$state_dir" ] || return 0
  # shellcheck disable=SC2231
  for f in "$state_dir"/*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.resolved // false' "$f" 2>/dev/null || echo false)" != "true" ]; then
      printf '%s\n' "$f"
    fi
  done
  return 0
}

# decision_field <file> <jq_filter>
# jq -r the filter against the file (raw string output).
decision_field() {
  local file="$1" filter="$2"
  jq -r "$filter" "$file"
}

# decision_match_option <file> <free_text>
# Trim + lowercase free_text; exact-match against each option's value and
# label (also trimmed+lowercased). On match print the option VALUE and
# return 0; else return 1. No substring matching.
decision_match_option() {
  local file="$1" free_text="$2"
  local needle line value label v_norm l_norm
  needle="$(printf '%s' "$free_text" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | tr '[:upper:]' '[:lower:]')"
  [ -n "$needle" ] || return 1

  while IFS= read -r line || [ -n "${line:-}" ]; do
    [ -z "${line:-}" ] && continue
    value="${line%%	*}"
    label="${line#*	}"
    v_norm="$(printf '%s' "$value" \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      | tr '[:upper:]' '[:lower:]')"
    l_norm="$(printf '%s' "$label" \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      | tr '[:upper:]' '[:lower:]')"
    if [ "$needle" = "$v_norm" ] || [ "$needle" = "$l_norm" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < <(jq -r '.options[]? | "\(.value)\t\(.label)"' "$file" 2>/dev/null)

  return 1
}

# decision_is_expired <file> [now_epoch]
# Return 0 iff not resolved and now (default date +%s) > expires_at.
decision_is_expired() {
  local file="$1"
  local now="${2:-}"
  local resolved expires
  if [ -z "$now" ]; then
    now="$(date +%s)"
  fi
  resolved="$(jq -r '.resolved // false' "$file" 2>/dev/null || echo false)"
  if [ "$resolved" = "true" ]; then
    return 1
  fi
  expires="$(jq -r '.expires_at // 0' "$file" 2>/dev/null || echo 0)"
  case "$expires" in
    ''|*[!0-9]*) expires=0 ;;
  esac
  [ "$now" -gt "$expires" ]
}

# decision_mark_resolved <file> <action> <value> <user> <answered_at>
# Idempotent first-answer-wins: if .resolved==true return 1 unchanged;
# else atomically rewrite adding resolved:true + fields; return 0.
decision_mark_resolved() {
  local file="$1" action="$2" value="$3" user="$4" answered_at="$5"
  local resolved tmp
  if [ ! -f "$file" ]; then
    return 1
  fi
  resolved="$(jq -r '.resolved // false' "$file" 2>/dev/null || echo false)"
  if [ "$resolved" = "true" ]; then
    return 1
  fi
  tmp="${file}.tmp.$$"
  if ! jq \
    --arg action "$action" \
    --arg value "$value" \
    --arg user "$user" \
    --arg answered_at "$answered_at" \
    '. + {
      resolved: true,
      action: $action,
      value: $value,
      user: $user,
      answered_at: $answered_at
    }' "$file" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
  return 0
}

# decisions_poll_url <api_base> <bot>
# Print "{api_base}/v1/slack/decisions?bot={bot}" (omit query when bot empty).
decisions_poll_url() {
  local api_base="$1" bot="${2:-}"
  # Trim trailing slash on base for clean join.
  api_base="${api_base%/}"
  if [ -n "$bot" ]; then
    printf '%s/v1/slack/decisions?bot=%s\n' "$api_base" "$bot"
  else
    printf '%s/v1/slack/decisions\n' "$api_base"
  fi
}

# decision_event_seen <seen_dir> <decision_id>
# Return 0 iff a marker file for decision_id exists under seen_dir.
decision_event_seen() {
  local seen_dir="$1" decision_id="$2"
  [ -n "$decision_id" ] || return 1
  [ -e "${seen_dir}/${decision_id}" ]
}

# decision_event_mark_seen <seen_dir> <decision_id>
# mkdir -p seen_dir and touch the marker file.
decision_event_mark_seen() {
  local seen_dir="$1" decision_id="$2"
  [ -n "$decision_id" ] || return 1
  mkdir -p "$seen_dir"
  touch "${seen_dir}/${decision_id}"
}

# decision_dispatch <pending_file> <cmd...>
# Export DECISION_* from the pending file, then run "<cmd...> <pending_file>".
# Return the command's exit code.
decision_dispatch() {
  local pending_file="$1"
  shift
  local answer_value answer_label
  export DECISION_ID
  export DECISION_QUESTION
  export DECISION_ANSWER_VALUE
  export DECISION_ANSWER_LABEL
  export DECISION_USER
  export DECISION_CHANNEL
  export DECISION_THREAD_TS

  DECISION_ID="$(jq -r '.decision_id // empty' "$pending_file" 2>/dev/null || true)"
  DECISION_QUESTION="$(jq -r '.question // empty' "$pending_file" 2>/dev/null || true)"
  DECISION_ANSWER_VALUE="$(jq -r '.value // empty' "$pending_file" 2>/dev/null || true)"
  DECISION_USER="$(jq -r '.user // empty' "$pending_file" 2>/dev/null || true)"
  DECISION_CHANNEL="$(jq -r '.channel // empty' "$pending_file" 2>/dev/null || true)"
  DECISION_THREAD_TS="$(jq -r '.thread_ts // empty' "$pending_file" 2>/dev/null || true)"

  answer_value="$DECISION_ANSWER_VALUE"
  answer_label=""
  if [ -n "$answer_value" ]; then
    answer_label="$(jq -r --arg v "$answer_value" \
      '(.options // [])[] | select(.value == $v) | .label' \
      "$pending_file" 2>/dev/null | head -1)"
  fi
  DECISION_ANSWER_LABEL="${answer_label:-}"

  "$@" "$pending_file"
}
