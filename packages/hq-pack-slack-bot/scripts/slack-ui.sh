#!/usr/bin/env bash
# slack-ui.sh — Slack Block Kit helper for structured status messages.
#
# Package: hq-pack-slack-bot
# Deps: bash, jq, curl (python3 ok)
#
# Subcommands:
#   post     Build (and optionally send) a chat.postMessage Block Kit payload.
#   report   Create/edit a Slack canvas report and post an in-thread TL;DR + link.
#   ask      Register a decision + post interactive buttons / multi-select.
#   resolve  Update a decision message (answered or timed-out) and mark state.
#
# Never string-interpolates into JSON — all payloads are built with jq.
# Compatible with bash 3.2+ (macOS /bin/bash).

set -euo pipefail

# Slack hard limits (produce payloads that will not 400)
HEADER_MAX=150
SECTION_TEXT_MAX=3000
# Human-in-the-loop timeout sentinel: an ask with expiry >= this renders
# "stays open" copy instead of a countdown (and defaults apply when --timeout
# is omitted). 30 days, matching the decisions-store registration TTL.
HITL_TIMEOUT_SENTINEL=2592000
MAX_FIELDS=4
MAX_BLOCKS=50
CONTINUED_PREFIX="(continued) "
DRYRUN_CANVAS_ID="F_DRYRUN_CANVAS"

# canvases.create / canvases.edit errors that mean "canvas unavailable" → fallback
is_canvas_unavailable_error() {
  case "$1" in
    missing_scope|not_allowed_token_type|canvas_disabled|feature_not_enabled|paid_teams_only|method_not_supported_for_channel_type|unknown_method)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bot_token() {
  local token="${SLACK_BOT_TOKEN:-}"
  if [ -z "$token" ]; then
    token="${HQ_SLACK_BOT_TOKEN:-}"
  fi
  printf '%s' "$token"
}

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

usage_report() {
  cat <<'EOF'
Usage: slack-ui.sh report [options]

Create or update a Slack canvas from a markdown file, then post a short
TL;DR + canvas link in the target channel/thread (chat.postMessage).

Create mode (default):
  canvases.create with {title, document_content:{type:"markdown", markdown}}
  then chat.postMessage with TL;DR + link to https://slack.com/canvas/<id>

Living / update mode (--update <canvas-id>):
  canvases.edit with replace document_content, then the same TL;DR message.

When canvas support is unavailable (--force-fallback, or live API errors such
as missing_scope / canvas_disabled / paid_teams_only / …), automatically
falls back to a deploy-and-link style chat.postMessage (exit 0) and says so
on stderr.

Options:
  --file <path>             Markdown file to put in the canvas (required).
  --title <text>            Canvas title (required).
  --tldr <text>             Short TL;DR shown in the in-thread preview (required).
  --channel <id>            Target channel id (required).
  --thread <ts>             Optional thread_ts (post as a thread reply).
  --update <canvas-id>      Edit an existing canvas instead of creating one.
  --fallback-url <url>      Optional URL used in deploy-and-link fallback mode.
  --force-fallback          Skip canvas APIs; emit deploy-and-link message only.
  --dry-run                 Print API request JSON lines to stdout; do not call
                            Slack. Create mode uses canvas_id F_DRYRUN_CANVAS
                            in the message link. With --force-fallback, only the
                            chat.postMessage line is printed (plus stderr notice).
  -h, --help                Show this help.

Dry-run output (create/update, not force-fallback):
  Line 1: {"api":"canvases.create"|"canvases.edit","payload":{...}}
  Line 2: {"api":"chat.postMessage","payload":{...}}

Examples:
  bash scripts/slack-ui.sh report \
    --file /tmp/report.md \
    --title "Incident write-up" \
    --tldr "Root cause was a bad deploy; mitigated." \
    --channel C01234567 \
    --thread 1710000000.000100 \
    --dry-run

  bash scripts/slack-ui.sh report \
    --file /tmp/report.md \
    --title "Incident write-up" \
    --tldr "Updated with postmortem notes." \
    --channel C01234567 \
    --update F0123CANVAS \
    --dry-run
EOF
}

usage_ask() {
  cat <<'EOF'
Usage: slack-ui.sh ask [options]

Register a pending decision and post an interactive Block Kit message
(buttons for ≤3 options, or multi_static_select when --multi / >3 options).

With --dry-run, print two JSON lines (hq.decisions.register then
chat.postMessage) and still write a local pending state file. Without
--dry-run, POST registration to $HQ_API_BASE/v1/slack/decisions, then
chat.postMessage via the bot token.

Options:
  --question <text>       Decision question (required). Header + section body.
  --option "value|Label"  Repeatable. At least 2 required. Buttons when ≤3
                          and --multi is not set; multi_static_select otherwise.
  --recommend <value>     Option value styled primary (buttons mode only).
  --abort <value>         Option value styled danger (buttons mode only).
  --fallback <value>      Optional. Must equal one --option value (timeout
                          path). Default: the --recommend value, else the
                          first --option value. With the default timeout the
                          fallback is registration metadata only — it never
                          fires on its own.
  --timeout <secs>        Optional positive integer. Decision expiry window.
                          Default: 2592000 (30 days) — human-in-the-loop, the
                          question stays open until answered and the message
                          renders "Stays open until answered" instead of a
                          countdown. Explicit shorter values are for
                          machine-to-machine flows only.
  --bot <app-id>          Optional bot / app id stored in registration.
  --field "Label|Value"   Repeatable. Max 4. Same fields section as post.
  --context <text>        Repeatable. Context block elements (plus timeout line).
  --channel <id>          Target channel (required unless --dry-run).
  --thread <ts>           Optional thread_ts.
  --multi                 Force multi_static_select even with ≤3 options.
  --decision-id <id>      Override auto-minted 26-char uppercase decision id.
  --state-dir <dir>       Pending file dir (default:
                          ${HQ_DECISIONS_DIR:-$HOME/.hq/slack-decisions}).
  --dry-run               Print register + postMessage JSON lines; write
                          pending file with message_ts DRYRUN_TS.
  -h, --help              Show this help.

Notes:
  - More than 3 options without --multi is an error (never >3 buttons).
  - action_id form: hqd:{decision_id}:{value} (buttons) or
    hqd:{decision_id}:submit (multi_static_select).
  - Live mode requires HQ_API_BASE; auth header uses HQ_API_TOKEN.

Examples:
  bash scripts/slack-ui.sh ask \
    --question "Ship to prod?" \
    --option "yes|Yes, ship" \
    --option "no|No, hold" \
    --option "later|Defer" \
    --recommend yes \
    --abort no \
    --fallback later \
    --timeout 300 \
    --channel C01234567 \
    --dry-run
EOF
}

usage_resolve() {
  cat <<'EOF'
Usage: slack-ui.sh resolve [options]

Update a decision message (chat.update) after answer or timeout, strip
actions blocks, and rewrite the local pending state file if present.

With --dry-run, print one JSON line {"api":"chat.update","payload":{...}}.
Without --dry-run, POST chat.update with the bot token.

Options:
  --decision-id <id>      Decision id (required).
  --channel <id>          Channel of the original message (required).
  --ts <ts>               Message ts to update (required).
  --question <text>       Optional question text prefixed onto the section.
  --answer-label <text>   Display label of the chosen option (required unless
                          --timed-out).
  --answer-value <val>    Value stored as action/value in the pending file.
  --user <uid>            Slack user id who answered (required unless --timed-out).
  --answered-at <ISO8601> Timestamp (default: UTC now).
  --timed-out             Timeout path; mutually exclusive with --user.
  --fallback-label <text> Required with --timed-out.
  --state-dir <dir>       Pending file dir (default:
                          ${HQ_DECISIONS_DIR:-$HOME/.hq/slack-decisions}).
  --dry-run               Print chat.update JSON line; do not call Slack.
  -h, --help              Show this help.

Examples:
  bash scripts/slack-ui.sh resolve \
    --decision-id TESTDECISION0000000000000001 \
    --channel C01234567 \
    --ts 1710000000.000100 \
    --question "Ship to prod?" \
    --answer-label "Yes, ship" \
    --answer-value yes \
    --user U0123 \
    --dry-run

  bash scripts/slack-ui.sh resolve \
    --decision-id TESTDECISION0000000000000001 \
    --channel C01234567 \
    --ts 1710000000.000100 \
    --timed-out \
    --fallback-label "Defer" \
    --dry-run
EOF
}

usage() {
  cat <<'EOF'
Usage: slack-ui.sh <command> [options]

Commands:
  post      Build/send a structured Block Kit status message (chat.postMessage)
  report    Create/edit a Slack canvas report + in-thread TL;DR preview
  ask       Register a decision + post interactive buttons / multi-select
  resolve   Update a decision message after answer or timeout

Run `slack-ui.sh <command> --help` for flags (post, report, ask, resolve).
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
  local token
  token="$(bot_token)"
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

# POST canvases.create or canvases.edit. Prints raw Slack JSON response to stdout.
# Does not die on ok:false (caller decides fallback vs hard error).
send_canvas_api() {
  local method="$1"
  local payload="$2"
  local token
  token="$(bot_token)"
  [ -n "$token" ] || die "no token: set SLACK_BOT_TOKEN or HQ_SLACK_BOT_TOKEN"

  local resp
  resp="$(curl -fsS -X POST "https://slack.com/api/${method}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$payload")" || die "curl ${method} failed"
  printf '%s' "$resp"
}

# Build chat.postMessage payload for a successful canvas report preview.
# Args: channel thread tldr canvas_id
build_report_canvas_message() {
  local channel="$1" thread="$2" tldr="$3" canvas_id="$4"
  local canvas_url link_md text

  canvas_url="https://slack.com/canvas/${canvas_id}"
  link_md="<${canvas_url}|Open canvas report>"
  text="$(printf '%s\n%s' "$tldr" "$canvas_url")"
  text="$(truncate_str "$text" 3000)"

  jq -nc \
    --arg text "$text" \
    --arg tldr "$tldr" \
    --arg link_md "$link_md" \
    --arg channel "$channel" \
    --arg thread "$thread" \
    '
      {
        text: $text,
        blocks: [
          {type: "section", text: {type: "mrkdwn", text: $tldr}},
          {type: "section", text: {type: "mrkdwn", text: $link_md}},
          {type: "context", elements: [{type: "mrkdwn", text: "Canvas report"}]}
        ]
      }
      + (if $channel != "" then {channel: $channel} else {} end)
      + (if $thread != "" then {thread_ts: $thread} else {} end)
    '
}

# Build chat.postMessage payload for deploy-and-link fallback.
# Args: channel thread tldr fallback_url (may be empty)
build_report_fallback_message() {
  local channel="$1" thread="$2" tldr="$3" fallback_url="$4"
  local link_section text

  if [ -n "$fallback_url" ]; then
    link_section="Full report: <${fallback_url}|view report>"
    text="$(printf '%s\nFull report: %s' "$tldr" "$fallback_url")"
  else
    link_section="Full report should be shipped via the /deploy skill (canvas unavailable)."
    text="$(printf '%s\n%s' "$tldr" "$link_section")"
  fi
  text="$(truncate_str "$text" 3000)"

  jq -nc \
    --arg text "$text" \
    --arg tldr "$tldr" \
    --arg link_section "$link_section" \
    --arg channel "$channel" \
    --arg thread "$thread" \
    '
      {
        text: $text,
        blocks: [
          {type: "section", text: {type: "mrkdwn", text: $tldr}},
          {type: "section", text: {type: "mrkdwn", text: $link_section}},
          {type: "context", elements: [{type: "mrkdwn", text: "Deploy-and-link fallback (canvas unavailable)"}]}
        ]
      }
      + (if $channel != "" then {channel: $channel} else {} end)
      + (if $thread != "" then {thread_ts: $thread} else {} end)
    '
}

# Emit fallback notice + message (dry-run print or live send). Exit 0.
report_fallback() {
  local reason="$1" channel="$2" thread="$3" tldr="$4" fallback_url="$5" dry_run="$6"
  local msg envelope

  printf 'slack-ui.sh report: canvas unavailable (%s); falling back to deploy-and-link\n' \
    "$reason" >&2

  msg="$(build_report_fallback_message "$channel" "$thread" "$tldr" "$fallback_url")"

  if [ "$dry_run" -eq 1 ]; then
    envelope="$(jq -nc --argjson payload "$msg" '{api:"chat.postMessage", payload:$payload}')"
    printf '%s\n' "$envelope"
  else
    send_payload "$msg"
  fi
  return 0
}

cmd_report() {
  local file="" title="" tldr="" channel="" thread=""
  local update_id="" fallback_url=""
  local dry_run=0 force_fallback=0
  local canvas_payload canvas_api canvas_id msg envelope resp ok err

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage_report
        return 0
        ;;
      --file)
        [ $# -ge 2 ] || die "--file requires an argument"
        file="$2"
        shift 2
        ;;
      --title)
        [ $# -ge 2 ] || die "--title requires an argument"
        title="$2"
        shift 2
        ;;
      --tldr)
        [ $# -ge 2 ] || die "--tldr requires an argument"
        tldr="$2"
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
      --update)
        [ $# -ge 2 ] || die "--update requires an argument"
        update_id="$2"
        shift 2
        ;;
      --fallback-url)
        [ $# -ge 2 ] || die "--fallback-url requires an argument"
        fallback_url="$2"
        shift 2
        ;;
      --force-fallback)
        force_fallback=1
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

  [ -n "$file" ] || die "--file is required"
  [ -f "$file" ] || die "--file not readable: $file"
  [ -r "$file" ] || die "--file not readable: $file"
  [ -n "$title" ] || die "--title is required"
  [ -n "$tldr" ] || die "--tldr is required"
  [ -n "$channel" ] || die "--channel is required"

  # Force fallback: skip canvas entirely (used by tests + operator override).
  if [ "$force_fallback" -eq 1 ]; then
    report_fallback "force-fallback" "$channel" "$thread" "$tldr" "$fallback_url" "$dry_run"
    return 0
  fi

  # Read markdown via jq --rawfile so contents stay JSON-safe (no string-interp).
  if [ -n "$update_id" ]; then
    canvas_api="canvases.edit"
    canvas_payload="$(jq -nc \
      --arg canvas_id "$update_id" \
      --rawfile md "$file" \
      '{
        canvas_id: $canvas_id,
        changes: [{
          operation: "replace",
          document_content: {type: "markdown", markdown: $md}
        }]
      }')"
    canvas_id="$update_id"
  else
    canvas_api="canvases.create"
    canvas_payload="$(jq -nc \
      --arg title "$title" \
      --rawfile md "$file" \
      '{
        title: $title,
        document_content: {type: "markdown", markdown: $md}
      }')"
    canvas_id=""
  fi

  if [ "$dry_run" -eq 1 ]; then
    if [ -z "$canvas_id" ]; then
      canvas_id="$DRYRUN_CANVAS_ID"
    fi
    envelope="$(jq -nc --arg api "$canvas_api" --argjson payload "$canvas_payload" \
      '{api:$api, payload:$payload}')"
    printf '%s\n' "$envelope"
    msg="$(build_report_canvas_message "$channel" "$thread" "$tldr" "$canvas_id")"
    envelope="$(jq -nc --argjson payload "$msg" '{api:"chat.postMessage", payload:$payload}')"
    printf '%s\n' "$envelope"
    return 0
  fi

  # Live canvas call
  resp="$(send_canvas_api "$canvas_api" "$canvas_payload")"
  ok="$(printf '%s' "$resp" | jq -r '.ok // false')"
  if [ "$ok" != "true" ]; then
    err="$(printf '%s' "$resp" | jq -r '.error // "unknown_error"')"
    if is_canvas_unavailable_error "$err"; then
      report_fallback "$err" "$channel" "$thread" "$tldr" "$fallback_url" "$dry_run"
      return 0
    fi
    die "${canvas_api} failed: $err"
  fi

  if [ -z "$canvas_id" ]; then
    canvas_id="$(printf '%s' "$resp" | jq -r '.canvas_id // empty')"
    [ -n "$canvas_id" ] || die "canvases.create ok but no canvas_id in response"
  fi

  msg="$(build_report_canvas_message "$channel" "$thread" "$tldr" "$canvas_id")"
  send_payload "$msg"
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

# Mint a 26-char uppercase alphanumeric decision id (time + random, no colons).
mint_decision_id() {
  python3 -c '
import time, random, string
alphabet = string.ascii_uppercase + string.digits
seed = f"{time.time_ns():x}{random.getrandbits(64):016x}"
rng = random.Random(seed)
print("".join(rng.choice(alphabet) for _ in range(26)))
'
}

# POST chat.update. Mirrors send_payload auth/error handling.
send_chat_update() {
  local payload="$1"
  local token
  token="$(bot_token)"
  [ -n "$token" ] || die "no token: set SLACK_BOT_TOKEN or HQ_SLACK_BOT_TOKEN"

  local resp ok err
  resp="$(curl -fsS -X POST "https://slack.com/api/chat.update" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$payload")" || die "curl chat.update failed"

  ok="$(printf '%s' "$resp" | jq -r '.ok // false')"
  if [ "$ok" != "true" ]; then
    err="$(printf '%s' "$resp" | jq -r '.error // "unknown_error"')"
    die "chat.update failed: $err"
  fi
  printf '%s' "$resp" | jq -c '{ok:true, ts:(.ts // null), channel:(.channel // null)}'
}

# Atomically rewrite pending state file merging extra keys (jq-built).
# Args: path existing_json_or_empty merge_json
write_pending_file() {
  local path="$1" base_json="$2" merge_json="$3"
  local dir tmp
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  tmp="${path}.tmp.$$"
  if [ -n "$base_json" ]; then
    jq -nc --argjson base "$base_json" --argjson extra "$merge_json" \
      '$base + $extra' >"$tmp"
  else
    printf '%s\n' "$merge_json" >"$tmp"
  fi
  mv -f "$tmp" "$path"
}

cmd_ask() {
  local question="" recommend="" abort="" fallback="" timeout="" bot=""
  local channel="" thread="" decision_id="" state_dir=""
  local multi=0 dry_run=0
  local field_count=0 context_count=0 option_count=0
  local tmpdir fields_file contexts_file options_file
  local f label value

  state_dir="${HQ_DECISIONS_DIR:-$HOME/.hq/slack-decisions}"

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/slack-ui-ask.XXXXXX")"
  fields_file="$tmpdir/fields.txt"
  contexts_file="$tmpdir/contexts.txt"
  options_file="$tmpdir/options.txt"
  : >"$fields_file"
  : >"$contexts_file"
  : >"$options_file"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmpdir"' EXIT

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage_ask
        trap - EXIT
        rm -rf "$tmpdir"
        return 0
        ;;
      --question)
        [ $# -ge 2 ] || die "--question requires an argument"
        question="$2"
        shift 2
        ;;
      --option)
        [ $# -ge 2 ] || die "--option requires an argument"
        f="$2"
        case "$f" in
          *"|"*) ;;
          *) die "--option must be \"value|Label\" (missing |): $f" ;;
        esac
        value="${f%%|*}"
        label="${f#*|}"
        [ -n "$value" ] || die "--option value is empty: $f"
        [ -n "$label" ] || die "--option label is empty: $f"
        printf '%s\n' "$f" >>"$options_file"
        option_count=$((option_count + 1))
        shift 2
        ;;
      --recommend)
        [ $# -ge 2 ] || die "--recommend requires an argument"
        recommend="$2"
        shift 2
        ;;
      --abort)
        [ $# -ge 2 ] || die "--abort requires an argument"
        abort="$2"
        shift 2
        ;;
      --fallback)
        [ $# -ge 2 ] || die "--fallback requires an argument"
        fallback="$2"
        shift 2
        ;;
      --timeout)
        [ $# -ge 2 ] || die "--timeout requires an argument"
        timeout="$2"
        shift 2
        ;;
      --bot)
        [ $# -ge 2 ] || die "--bot requires an argument"
        bot="$2"
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
      --multi)
        multi=1
        shift
        ;;
      --decision-id)
        [ $# -ge 2 ] || die "--decision-id requires an argument"
        decision_id="$2"
        shift 2
        ;;
      --state-dir)
        [ $# -ge 2 ] || die "--state-dir requires an argument"
        state_dir="$2"
        shift 2
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

  # HITL env enforcement (agent boxes; the hq-pro watcher exports
  # HQ_SLACK_UI_HITL=1 into every dispatch run env): caller-supplied
  # --timeout/--fallback are ignored even when the wrapper shim is BYPASSED
  # and this lib is invoked directly — observed live 2026-08-08: Grok called
  # the lib path itself with --timeout 120, sailing past the wrapper's strip
  # and rendering countdown copy. The question also gains the requester's
  # mention when it carries none (HQ_SLACK_REQUESTER, same run env). Non-agent
  # pack consumers (env unset) keep full flag control.
  if [ "${HQ_SLACK_UI_HITL:-}" = "1" ]; then
    if [ -n "$timeout" ] || [ -n "$fallback" ]; then
      echo "slack-ui ask: --timeout/--fallback are managed by the runtime (human-in-the-loop: the question stays open until answered) — ignoring." >&2
      timeout=""
      fallback=""
    fi
    case "$question" in
      "") : ;;
      *"<@"*) : ;;
      *)
        if [ -n "${HQ_SLACK_REQUESTER:-}" ]; then
          question="<@${HQ_SLACK_REQUESTER}> ${question}"
        fi
        ;;
    esac
  fi

  [ -n "$question" ] || die "--question is required"
  [ "$option_count" -ge 2 ] || die "at least 2 --option values are required (got ${option_count})"
  # Human-in-the-loop defaults (agent-voice wave 1): a decision with no
  # explicit expiry stays open until a person answers — 30-day registration
  # TTL, no countdown copy, no self-firing fallback. The registered fallback
  # is still required by the decisions API, so default it to the recommended
  # option (else the first option); with the sentinel timeout it is inert
  # metadata.
  if [ -z "$fallback" ]; then
    if [ -n "$recommend" ]; then
      fallback="$recommend"
    else
      fallback="$(head -n 1 "$options_file" 2>/dev/null | cut -d'|' -f1)"
    fi
  fi
  [ -n "$fallback" ] || die "--fallback could not be defaulted (no options?)"
  [ -n "$timeout" ] || timeout="$HITL_TIMEOUT_SENTINEL"
  case "$timeout" in
    ''|*[!0-9]*) die "--timeout must be a positive integer" ;;
  esac
  if [ "$timeout" -le 0 ]; then
    die "--timeout must be a positive integer"
  fi
  if [ "$dry_run" -eq 0 ]; then
    [ -n "$channel" ] || die "--channel is required when sending (omit only with --dry-run)"
  fi

  if [ "$option_count" -gt 3 ] && [ "$multi" -eq 0 ]; then
    die "more than 3 options requires --multi (never emit >3 buttons)"
  fi

  # Validate fallback is one of the option values; resolve its label.
  local fallback_label="" found_fallback=0
  local opt_value opt_label
  while IFS= read -r f || [ -n "${f:-}" ]; do
    [ -z "${f:-}" ] && continue
    opt_value="${f%%|*}"
    opt_label="${f#*|}"
    if [ "$opt_value" = "$fallback" ]; then
      found_fallback=1
      fallback_label="$opt_label"
    fi
  done <"$options_file"
  [ "$found_fallback" -eq 1 ] || die "--fallback value is not among --option values: $fallback"

  if [ -z "$decision_id" ]; then
    decision_id="$(mint_decision_id)"
    [ -n "$decision_id" ] || die "failed to mint decision id"
  fi

  local now_s expires_at
  now_s="$(date +%s)"
  expires_at=$((now_s + timeout))

  # Build options JSON array [{value,label}, ...]
  local options_json="[]"
  while IFS= read -r f || [ -n "${f:-}" ]; do
    [ -z "${f:-}" ] && continue
    opt_value="${f%%|*}"
    opt_label="${f#*|}"
    options_json="$(jq -nc \
      --argjson acc "$options_json" \
      --arg value "$opt_value" \
      --arg label "$opt_label" \
      '$acc + [{value: $value, label: $label}]')"
  done <"$options_file"

  # Registration payload
  local reg_payload
  reg_payload="$(jq -nc \
    --arg decision_id "$decision_id" \
    --arg bot "$bot" \
    --arg channel "$channel" \
    --arg thread_ts "$thread" \
    --arg question "$question" \
    --argjson options "$options_json" \
    --arg recommended "$recommend" \
    --arg fallback "$fallback" \
    --argjson expires_at "$expires_at" \
    '{
      decision_id: $decision_id,
      bot: $bot,
      channel: $channel,
      thread_ts: $thread_ts,
      question: $question,
      options: $options,
      recommended: $recommended,
      fallback: $fallback,
      expires_at: $expires_at
    }')"

  # --- Build Block Kit message ---
  local header_text
  header_text="$(truncate_str "Decision needed: ${question}" "$HEADER_MAX")"

  local blocks_json="[]"
  blocks_json="$(jq -nc \
    --argjson acc "$blocks_json" \
    --arg t "$header_text" \
    '$acc + [{type:"header", text:{type:"plain_text", text:$t, emoji:true}}]')"

  blocks_json="$(jq -nc \
    --argjson acc "$blocks_json" \
    --arg q "$question" \
    '$acc + [{type:"section", text:{type:"mrkdwn", text:$q}}]')"

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
    blocks_json="$(jq -nc \
      --argjson acc "$blocks_json" \
      --argjson fields "$fields_json" \
      '$acc + [{type:"section", fields:$fields}]')"
  fi

  # Actions block: multi_static_select or buttons
  local use_multi=0
  if [ "$multi" -eq 1 ] || [ "$option_count" -gt 3 ]; then
    use_multi=1
  fi

  if [ "$use_multi" -eq 1 ]; then
    local select_options="[]"
    while IFS= read -r f || [ -n "${f:-}" ]; do
      [ -z "${f:-}" ] && continue
      opt_value="${f%%|*}"
      opt_label="${f#*|}"
      select_options="$(jq -nc \
        --argjson acc "$select_options" \
        --arg value "$opt_value" \
        --arg label "$opt_label" \
        '$acc + [{text:{type:"plain_text", text:$label}, value:$value}]')"
    done <"$options_file"

    blocks_json="$(jq -nc \
      --argjson acc "$blocks_json" \
      --arg decision_id "$decision_id" \
      --argjson options "$select_options" \
      '
        $acc + [{
          type: "actions",
          elements: [{
            type: "multi_static_select",
            action_id: ("hqd:" + $decision_id + ":submit"),
            options: $options,
            confirm: {
              title: {type: "plain_text", text: "Confirm selection"},
              text: {type: "mrkdwn", text: "Apply this selection?"},
              confirm: {type: "plain_text", text: "Confirm"},
              deny: {type: "plain_text", text: "Cancel"}
            }
          }]
        }]
      ')"
  else
    local elements_json="[]"
    while IFS= read -r f || [ -n "${f:-}" ]; do
      [ -z "${f:-}" ] && continue
      opt_value="${f%%|*}"
      opt_label="${f#*|}"
      elements_json="$(jq -nc \
        --argjson acc "$elements_json" \
        --arg decision_id "$decision_id" \
        --arg value "$opt_value" \
        --arg label "$opt_label" \
        --arg recommend "$recommend" \
        --arg abort "$abort" \
        '
          $acc + [
            {
              type: "button",
              action_id: ("hqd:" + $decision_id + ":" + $value),
              value: $value,
              text: {type: "plain_text", text: $label}
            }
            + (if $recommend != "" and $value == $recommend then {style: "primary"} else {} end)
            + (if $abort != "" and $value == $abort then {style: "danger"} else {} end)
          ]
        ')"
    done <"$options_file"

    blocks_json="$(jq -nc \
      --argjson acc "$blocks_json" \
      --argjson elements "$elements_json" \
      '$acc + [{type:"actions", elements:$elements}]')"
  fi

  # Context block: --context texts + timeout/fallback line
  local elements_ctx="[]"
  local c
  if [ -f "$contexts_file" ]; then
    while IFS= read -r c || [ -n "${c:-}" ]; do
      [ -z "${c:-}" ] && continue
      elements_ctx="$(jq -nc \
        --argjson acc "$elements_ctx" \
        --arg t "$c" \
        '$acc + [{type:"mrkdwn", text:$t}]')"
    done <"$contexts_file"
  fi
  local timeout_line
  if [ "$timeout" -ge "$HITL_TIMEOUT_SENTINEL" ]; then
    # Human-in-the-loop ask: no countdown, no fallback promise — the question
    # stays live and a late tap wakes the agent (decision→inbox bridge).
    timeout_line="Stays open until answered — a late tap wakes the agent."
  else
    timeout_line="Times out in ${timeout}s → fallback: ${fallback_label}"
  fi
  elements_ctx="$(jq -nc \
    --argjson acc "$elements_ctx" \
    --arg t "$timeout_line" \
    '$acc + [{type:"mrkdwn", text:$t}]')"

  blocks_json="$(jq -nc \
    --argjson acc "$blocks_json" \
    --argjson elements "$elements_ctx" \
    '$acc + [{type:"context", elements:$elements}]')"

  local fallback_text
  fallback_text="$(truncate_str "Decision needed: ${question}" 3000)"

  local msg_payload
  msg_payload="$(jq -nc \
    --arg text "$fallback_text" \
    --arg channel "$channel" \
    --arg thread "$thread" \
    --argjson blocks "$blocks_json" \
    '
      {text: $text, blocks: $blocks}
      + (if $channel != "" then {channel: $channel} else {} end)
      + (if $thread != "" then {thread_ts: $thread} else {} end)
    ')"

  local message_ts=""
  local envelope

  if [ "$dry_run" -eq 1 ]; then
    envelope="$(jq -nc --argjson payload "$reg_payload" \
      '{api:"hq.decisions.register", payload:$payload}')"
    printf '%s\n' "$envelope"
    envelope="$(jq -nc --argjson payload "$msg_payload" \
      '{api:"chat.postMessage", payload:$payload}')"
    printf '%s\n' "$envelope"
    message_ts="DRYRUN_TS"
  else
    [ -n "${HQ_API_BASE:-}" ] || die "HQ_API_BASE is required for live ask (or pass --dry-run)"

    local reg_resp
    reg_resp="$(curl -fsS -X POST "${HQ_API_BASE}/v1/slack/decisions" \
      -H "Authorization: Bearer ${HQ_API_TOKEN:-}" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data "$reg_payload")" || die "curl hq.decisions.register failed"

    local send_resp
    send_resp="$(send_payload "$msg_payload")"
    message_ts="$(printf '%s' "$send_resp" | jq -r '.ts // empty')"
    [ -n "$message_ts" ] || die "chat.postMessage ok but no ts in response"
  fi

  # Write pending file: registration + message_ts
  local pending_path pending_json
  pending_path="${state_dir}/${decision_id}.json"
  pending_json="$(jq -nc \
    --argjson reg "$reg_payload" \
    --arg message_ts "$message_ts" \
    '$reg + {message_ts: $message_ts}')"
  write_pending_file "$pending_path" "" "$pending_json"

  trap - EXIT
  rm -rf "$tmpdir"
}

cmd_resolve() {
  local decision_id="" channel="" ts="" question="" answer_label="" answer_value=""
  local user="" answered_at="" fallback_label="" state_dir=""
  local timed_out=0 dry_run=0

  state_dir="${HQ_DECISIONS_DIR:-$HOME/.hq/slack-decisions}"

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage_resolve
        return 0
        ;;
      --decision-id)
        [ $# -ge 2 ] || die "--decision-id requires an argument"
        decision_id="$2"
        shift 2
        ;;
      --channel)
        [ $# -ge 2 ] || die "--channel requires an argument"
        channel="$2"
        shift 2
        ;;
      --ts)
        [ $# -ge 2 ] || die "--ts requires an argument"
        ts="$2"
        shift 2
        ;;
      --question)
        [ $# -ge 2 ] || die "--question requires an argument"
        question="$2"
        shift 2
        ;;
      --answer-label)
        [ $# -ge 2 ] || die "--answer-label requires an argument"
        answer_label="$2"
        shift 2
        ;;
      --answer-value)
        [ $# -ge 2 ] || die "--answer-value requires an argument"
        answer_value="$2"
        shift 2
        ;;
      --user)
        [ $# -ge 2 ] || die "--user requires an argument"
        user="$2"
        shift 2
        ;;
      --answered-at)
        [ $# -ge 2 ] || die "--answered-at requires an argument"
        answered_at="$2"
        shift 2
        ;;
      --timed-out)
        timed_out=1
        shift
        ;;
      --fallback-label)
        [ $# -ge 2 ] || die "--fallback-label requires an argument"
        fallback_label="$2"
        shift 2
        ;;
      --state-dir)
        [ $# -ge 2 ] || die "--state-dir requires an argument"
        state_dir="$2"
        shift 2
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

  [ -n "$decision_id" ] || die "--decision-id is required"
  [ -n "$channel" ] || die "--channel is required"
  [ -n "$ts" ] || die "--ts is required"

  if [ "$timed_out" -eq 1 ] && [ -n "$user" ]; then
    die "--timed-out and --user are mutually exclusive"
  fi

  if [ "$timed_out" -eq 1 ]; then
    [ -n "$fallback_label" ] || die "--fallback-label is required with --timed-out"
  else
    [ -n "$user" ] || die "--user is required (or pass --timed-out)"
    [ -n "$answer_label" ] || die "--answer-label is required (or pass --timed-out)"
  fi

  if [ -z "$answered_at" ]; then
    answered_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi

  local section_text context_text fallback_text

  if [ "$timed_out" -eq 1 ]; then
    section_text="⏳ Decision timed out — fallback applied: *${fallback_label}*"
    if [ -n "$question" ]; then
      section_text="$(printf '%s\n%s' "$question" "$section_text")"
    fi
    context_text="No answer before the deadline; declared fallback fired at ${answered_at}"
    fallback_text="Decision timed out — fallback applied: ${fallback_label}"
  else
    section_text="✅ Decision resolved: *${answer_label}*"
    if [ -n "$question" ]; then
      section_text="$(printf '%s\n%s' "$question" "$section_text")"
    fi
    context_text="Answered by <@${user}> at ${answered_at}"
    fallback_text="Decision resolved: ${answer_label}"
  fi

  local update_payload
  update_payload="$(jq -nc \
    --arg channel "$channel" \
    --arg ts "$ts" \
    --arg text "$fallback_text" \
    --arg section "$section_text" \
    --arg context "$context_text" \
    '{
      channel: $channel,
      ts: $ts,
      text: $text,
      blocks: [
        {type: "section", text: {type: "mrkdwn", text: $section}},
        {type: "context", elements: [{type: "mrkdwn", text: $context}]}
      ]
    }')"

  # Rewrite pending file if present
  local pending_path
  pending_path="${state_dir}/${decision_id}.json"
  if [ -f "$pending_path" ]; then
    local existing merge_json action_val value_val
    existing="$(cat "$pending_path")"
    if [ "$timed_out" -eq 1 ]; then
      action_val="timeout"
      value_val="${answer_value:-}"
    else
      action_val="${answer_value:-}"
      value_val="${answer_value:-}"
    fi
    merge_json="$(jq -nc \
      --arg action "$action_val" \
      --arg value "$value_val" \
      --arg user "$user" \
      --arg answered_at "$answered_at" \
      '{
        resolved: true,
        action: $action,
        value: $value,
        user: $user,
        answered_at: $answered_at
      }')"
    write_pending_file "$pending_path" "$existing" "$merge_json"
  fi

  if [ "$dry_run" -eq 1 ]; then
    jq -nc --argjson payload "$update_payload" '{api:"chat.update", payload:$payload}'
  else
    send_chat_update "$update_payload"
  fi
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
    report)
      shift
      cmd_report "$@"
      ;;
    ask)
      shift
      cmd_ask "$@"
      ;;
    resolve)
      shift
      cmd_resolve "$@"
      ;;
    *)
      die "unknown command: $1 (try --help)"
      ;;
  esac
}

main "$@"
