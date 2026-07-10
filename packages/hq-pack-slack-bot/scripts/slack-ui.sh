#!/usr/bin/env bash
# slack-ui.sh — Slack Block Kit helper for structured status messages.
#
# Package: hq-pack-slack-bot
# Deps: bash, jq, curl (python3 ok)
#
# Subcommands:
#   post   Build (and optionally send) a chat.postMessage Block Kit payload.
#
# Never string-interpolates into JSON — all payloads are built with jq.
# Compatible with bash 3.2+ (macOS /bin/bash).

set -euo pipefail

# Slack hard limits (produce payloads that will not 400)
HEADER_MAX=150
SECTION_TEXT_MAX=3000
MAX_FIELDS=4
MAX_BLOCKS=50
CONTINUED_PREFIX="(continued) "

usage_post() {
  cat <<'EOF'
Usage: slack-ui.sh post [options]

Build a valid Slack Block Kit chat.postMessage payload from typed inputs.
With --dry-run, print the JSON payload(s) to stdout and do not call Slack.
Without --dry-run, POST to chat.postMessage using $SLACK_BOT_TOKEN or
$HQ_SLACK_BOT_TOKEN.

Options:
  --title <text>          Header block (plain_text). Truncated to 150 chars.
  --body <text>           Section block (mrkdwn). Auto-splits at 3000 chars;
                          subsequent section chunks are prefixed with
                          "(continued) ".
  --field "Label|Value"   Repeatable. Max 4 pairs. Rendered as one section
                          block with a fields array of mrkdwn "*Label*\nValue"
                          items. Errors clearly if more than 4 are given.
  --context <text>        Repeatable. Rendered as one context block with
                          mrkdwn elements (one element per --context).
  --channel <id>          Target channel id (required when sending).
  --thread <ts>           Optional thread_ts (post as a thread reply).
  --text-only             Plain-text fallback mode: emit/send only a top-level
                          text payload (no blocks). Text is composed from
                          title, body, fields, and context.
  --dry-run               Print final chat.postMessage JSON payload(s) to
                          stdout; do not call the Slack API. When the payload
                          must be split into multiple messages (>50 blocks),
                          prints one JSON object per line.
  -h, --help              Show this help.

Limits / multi-message behavior:
  - Header text is truncated to 150 characters (Slack header plain_text limit).
  - Any mrkdwn section text longer than 3000 characters is split into multiple
    section blocks; each subsequent chunk is prefixed with "(continued) ".
  - If total blocks would exceed 50, the payload is split into multiple
    chat.postMessage bodies. Subsequent messages reuse channel/thread_ts and
    mark their first block with "(continued)".
  - Top-level text is always set to a plain-text fallback summary (notification
    text / accessibility).
  - On send, the bot token is read from $SLACK_BOT_TOKEN or $HQ_SLACK_BOT_TOKEN.

Examples:
  # Dry-run structured status
  bash scripts/slack-ui.sh post \
    --title "Deploy complete" \
    --body "web-front preview is live." \
    --field "Env|preview" \
    --field "SHA|abc1234" \
    --context "triggered by @alice" \
    --channel C01234567 \
    --thread 1710000000.000100 \
    --dry-run

  # Plain-text only
  bash scripts/slack-ui.sh post \
    --title "Ping" \
    --body "still here" \
    --channel C01234567 \
    --text-only \
    --dry-run
EOF
}

usage() {
  cat <<'EOF'
Usage: slack-ui.sh <command> [options]

Commands:
  post    Build/send a structured Block Kit status message (chat.postMessage)

Run `slack-ui.sh post --help` for post flags and limit behavior.
EOF
}

die() {
  printf 'slack-ui.sh: %s\n' "$*" >&2
  exit 1
}

# Truncate a string to at most $2 characters.
truncate_str() {
  local s="$1"
  local max="$2"
  if [ "${#s}" -le "$max" ]; then
    printf '%s' "$s"
  else
    printf '%s' "${s:0:$max}"
  fi
}

# Split body into section texts each <= SECTION_TEXT_MAX.
# First chunk is raw; subsequent chunks are prefixed with CONTINUED_PREFIX.
# Emits one JSON-encoded string per line (via jq).
split_section_texts() {
  local body="$1"
  local prefix="$CONTINUED_PREFIX"
  local prefix_len=${#prefix}
  local max=$SECTION_TEXT_MAX
  local first=1
  local take chunk room

  if [ -z "$body" ]; then
    return 0
  fi

  while [ "${#body}" -gt 0 ]; do
    if [ "$first" -eq 1 ]; then
      take=$max
      if [ "${#body}" -lt "$take" ]; then
        take=${#body}
      fi
      chunk="${body:0:$take}"
      body="${body:$take}"
      first=0
    else
      room=$((max - prefix_len))
      if [ "$room" -lt 1 ]; then
        die "internal: CONTINUED_PREFIX longer than SECTION_TEXT_MAX"
      fi
      take=$room
      if [ "${#body}" -lt "$take" ]; then
        take=${#body}
      fi
      chunk="${prefix}${body:0:$take}"
      body="${body:$take}"
    fi
    jq -nc --arg t "$chunk" '$t'
  done
}

# Build plain-text fallback from title/body + field/context files (one entry per line).
# Field lines are still "Label|Value". Context lines are raw text.
# Args: title body fields_file contexts_file
build_plain_text() {
  local title="$1" body="$2" fields_file="$3" contexts_file="$4"
  local out="" f label value c

  if [ -n "$title" ]; then
    out="$title"
  fi
  if [ -n "$body" ]; then
    if [ -n "$out" ]; then
      out="${out}

${body}"
    else
      out="$body"
    fi
  fi
  if [ -f "$fields_file" ]; then
    while IFS= read -r f || [ -n "${f:-}" ]; do
      [ -z "${f:-}" ] && continue
      label="${f%%|*}"
      value="${f#*|}"
      if [ -n "$out" ]; then
        out="${out}
${label}: ${value}"
      else
        out="${label}: ${value}"
      fi
    done <"$fields_file"
  fi
  if [ -f "$contexts_file" ]; then
    while IFS= read -r c || [ -n "${c:-}" ]; do
      [ -z "${c:-}" ] && continue
      if [ -n "$out" ]; then
        out="${out}
${c}"
      else
        out="$c"
      fi
    done <"$contexts_file"
  fi
  printf '%s' "$out"
}

mark_continued_block() {
  local blk="$1"
  local typ
  typ="$(printf '%s' "$blk" | jq -r '.type')"
  case "$typ" in
    header)
      printf '%s' "$blk" | jq -c --arg p "$CONTINUED_PREFIX" --argjson max "$HEADER_MAX" '
        ($p + .text.text) as $t
        | .text.text = (if ($t | length) > $max then $t[0:$max] else $t end)
      '
      ;;
    section)
      if printf '%s' "$blk" | jq -e '.text.text' >/dev/null 2>&1; then
        printf '%s' "$blk" | jq -c --arg p "$CONTINUED_PREFIX" --argjson max "$SECTION_TEXT_MAX" '
          if (.text.text | startswith($p)) then .
          else
            ($p + .text.text) as $t
            | .text.text = (if ($t | length) > $max then $t[0:$max] else $t end)
          end
        '
      else
        # fields-only section — attach a small mrkdwn text marker
        printf '%s' "$blk" | jq -c --arg p "$CONTINUED_PREFIX" \
          '. + {text:{type:"mrkdwn", text:($p | rtrimstr(" "))}}'
      fi
      ;;
    context)
      printf '%s' "$blk" | jq -c --arg p "$CONTINUED_PREFIX" '
        .elements = ([{type:"mrkdwn", text:($p | rtrimstr(" "))}] + .elements)
      '
      ;;
    *)
      printf '%s' "$blk"
      ;;
  esac
}

# Assemble one chat.postMessage payload JSON from a blocks ndjson file slice.
# Args: channel thread fallback msg_idx blocks_ndjson_file
assemble_payload_from_file() {
  local channel="$1" thread="$2" fallback="$3" msg_idx="$4" blocks_file="$5"
  local blocks_json="[]"
  local i=0 line marked

  while IFS= read -r line || [ -n "${line:-}" ]; do
    [ -z "${line:-}" ] && continue
    if [ "$msg_idx" -gt 0 ] && [ "$i" -eq 0 ]; then
      marked="$(mark_continued_block "$line")"
      blocks_json="$(jq -nc --argjson acc "$blocks_json" --argjson blk "$marked" '$acc + [$blk]')"
    else
      blocks_json="$(jq -nc --argjson acc "$blocks_json" --argjson blk "$line" '$acc + [$blk]')"
    fi
    i=$((i + 1))
  done <"$blocks_file"

  local text="$fallback"
  if [ "$msg_idx" -gt 0 ]; then
    text="${CONTINUED_PREFIX}${fallback}"
    text="$(truncate_str "$text" 3000)"
  fi

  jq -nc \
    --arg text "$text" \
    --arg channel "$channel" \
    --arg thread "$thread" \
    --argjson blocks "$blocks_json" \
    '
      {text: $text, blocks: $blocks}
      + (if $channel != "" then {channel: $channel} else {} end)
      + (if $thread != "" then {thread_ts: $thread} else {} end)
    '
}

send_payload() {
  local payload="$1"
  local token="${SLACK_BOT_TOKEN:-}"
  if [ -z "$token" ]; then
    token="${HQ_SLACK_BOT_TOKEN:-}"
  fi
  [ -n "$token" ] || die "no token: set SLACK_BOT_TOKEN or HQ_SLACK_BOT_TOKEN"

  local resp ok err
  resp="$(curl -fsS -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$payload")" || die "curl chat.postMessage failed"

  ok="$(printf '%s' "$resp" | jq -r '.ok // false')"
  if [ "$ok" != "true" ]; then
    err="$(printf '%s' "$resp" | jq -r '.error // "unknown_error"')"
    die "chat.postMessage failed: $err"
  fi
  printf '%s' "$resp" | jq -c '{ok:true, ts:(.ts // null), channel:(.channel // null)}'
}

cmd_post() {
  local title="" body="" channel="" thread="" text_only=0 dry_run=0
  local field_count=0 context_count=0
  local tmpdir fields_file contexts_file
  local f label value

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/slack-ui.XXXXXX")"
  fields_file="$tmpdir/fields.txt"
  contexts_file="$tmpdir/contexts.txt"
  : >"$fields_file"
  : >"$contexts_file"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmpdir"' EXIT

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage_post
        trap - EXIT
        rm -rf "$tmpdir"
        return 0
        ;;
      --title)
        [ $# -ge 2 ] || die "--title requires an argument"
        title="$2"
        shift 2
        ;;
      --body)
        [ $# -ge 2 ] || die "--body requires an argument"
        body="$2"
        shift 2
        ;;
      --field)
        [ $# -ge 2 ] || die "--field requires an argument"
        field_count=$((field_count + 1))
        if [ "$field_count" -gt "$MAX_FIELDS" ]; then
          die "too many --field values: ${field_count} (max ${MAX_FIELDS})"
        fi
        f="$2"
        case "$f" in
          *"|"*) ;;
          *) die "--field must be \"Label|Value\" (missing |): $f" ;;
        esac
        printf '%s\n' "$f" >>"$fields_file"
        shift 2
        ;;
      --context)
        [ $# -ge 2 ] || die "--context requires an argument"
        context_count=$((context_count + 1))
        printf '%s\n' "$2" >>"$contexts_file"
        shift 2
        ;;
      --channel)
        [ $# -ge 2 ] || die "--channel requires an argument"
        channel="$2"
        shift 2
        ;;
      --thread)
        [ $# -ge 2 ] || die "--thread requires an argument"
        thread="$2"
        shift 2
        ;;
      --text-only)
        text_only=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1 (try --help)"
        ;;
      *)
        die "unexpected argument: $1 (try --help)"
        ;;
    esac
  done

  if [ "$dry_run" -eq 0 ]; then
    [ -n "$channel" ] || die "--channel is required when sending (omit only with --dry-run)"
  fi

  local fallback
  fallback="$(build_plain_text "$title" "$body" "$fields_file" "$contexts_file")"
  if [ -z "$fallback" ]; then
    fallback="(empty message)"
  fi
  fallback="$(truncate_str "$fallback" 3000)"

  # --- plain-text-only path ---
  if [ "$text_only" -eq 1 ]; then
    local payload
    payload="$(jq -nc \
      --arg text "$fallback" \
      --arg channel "$channel" \
      --arg thread "$thread" \
      '
        {text: $text}
        + (if $channel != "" then {channel: $channel} else {} end)
        + (if $thread != "" then {thread_ts: $thread} else {} end)
      ')"

    if [ "$dry_run" -eq 1 ]; then
      printf '%s\n' "$payload"
      trap - EXIT
      rm -rf "$tmpdir"
      return 0
    fi
    send_payload "$payload"
    trap - EXIT
    rm -rf "$tmpdir"
    return 0
  fi

  # --- Block Kit path ---
  local header_text=""
  if [ -n "$title" ]; then
    header_text="$(truncate_str "$title" "$HEADER_MAX")"
  fi

  local blocks_file="$tmpdir/blocks.ndjson"
  : >"$blocks_file"

  if [ -n "$header_text" ]; then
    jq -nc --arg t "$header_text" \
      '{type:"header", text:{type:"plain_text", text:$t, emoji:true}}' \
      >>"$blocks_file"
  fi

  if [ -n "$body" ]; then
    local chunk_json
    while IFS= read -r chunk_json; do
      jq -nc --argjson t "$chunk_json" \
        '{type:"section", text:{type:"mrkdwn", text:$t}}' \
        >>"$blocks_file"
    done < <(split_section_texts "$body")
  fi

  if [ "$field_count" -gt 0 ]; then
    local fields_json="[]"
    while IFS= read -r f || [ -n "${f:-}" ]; do
      [ -z "${f:-}" ] && continue
      label="${f%%|*}"
      value="${f#*|}"
      fields_json="$(jq -nc \
        --argjson acc "$fields_json" \
        --arg label "$label" \
        --arg value "$value" \
        '$acc + [{type:"mrkdwn", text:("*" + $label + "*\n" + $value)}]')"
    done <"$fields_file"
    jq -nc --argjson fields "$fields_json" \
      '{type:"section", fields:$fields}' \
      >>"$blocks_file"
  fi

  if [ "$context_count" -gt 0 ]; then
    local elements_json="[]"
    local c
    while IFS= read -r c || [ -n "${c:-}" ]; do
      [ -z "${c:-}" ] && continue
      elements_json="$(jq -nc \
        --argjson acc "$elements_json" \
        --arg t "$c" \
        '$acc + [{type:"mrkdwn", text:$t}]')"
    done <"$contexts_file"
    jq -nc --argjson elements "$elements_json" \
      '{type:"context", elements:$elements}' \
      >>"$blocks_file"
  fi

  local block_count
  block_count="$(wc -l <"$blocks_file" | tr -d '[:space:]')"
  if [ -z "$block_count" ] || [ "$block_count" = "0" ]; then
    jq -nc '{type:"section", text:{type:"mrkdwn", text:"(empty message)"}}' \
      >>"$blocks_file"
    block_count=1
  fi

  # Split into groups of <= MAX_BLOCKS; write each group to a slice file and assemble
  local msg_idx=0
  local in_group=0
  local slice_file payload
  slice_file="$tmpdir/slice.ndjson"
  : >"$slice_file"

  while IFS= read -r line || [ -n "${line:-}" ]; do
    [ -z "${line:-}" ] && continue
    printf '%s\n' "$line" >>"$slice_file"
    in_group=$((in_group + 1))
    if [ "$in_group" -ge "$MAX_BLOCKS" ]; then
      payload="$(assemble_payload_from_file "$channel" "$thread" "$fallback" "$msg_idx" "$slice_file")"
      if [ "$dry_run" -eq 1 ]; then
        printf '%s\n' "$payload"
      else
        send_payload "$payload"
      fi
      : >"$slice_file"
      in_group=0
      msg_idx=$((msg_idx + 1))
    fi
  done <"$blocks_file"

  if [ "$in_group" -gt 0 ]; then
    payload="$(assemble_payload_from_file "$channel" "$thread" "$fallback" "$msg_idx" "$slice_file")"
    if [ "$dry_run" -eq 1 ]; then
      printf '%s\n' "$payload"
    else
      send_payload "$payload"
    fi
  fi

  trap - EXIT
  rm -rf "$tmpdir"
}

main() {
  if [ $# -eq 0 ]; then
    usage
    exit 1
  fi
  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    post)
      shift
      cmd_post "$@"
      ;;
    *)
      die "unknown command: $1 (try --help)"
      ;;
  esac
}

main "$@"
