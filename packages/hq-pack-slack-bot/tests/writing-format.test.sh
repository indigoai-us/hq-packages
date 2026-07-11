#!/usr/bin/env bash
# Pins the Slack channel-writing-formats contract in the mention-worker
# system prompt (aligned with hq-pro src/agents/channel-writing-formats.ts).
# Agents must write like a sharp human: mrkdwn only, outcome-first, ~600-char
# main-channel cap, no variable/secret/path inventories, depth via thread or
# canvas, structure via the slack-ui Block Kit toolkit.
set -euo pipefail

PROMPT="$(cd "$(dirname "$0")/.." && pwd)/workers/slack-mention-worker/system-prompt.md"
[ -f "$PROMPT" ] || { echo "FAIL: missing $PROMPT"; exit 1; }

fail=0
require() {
  if ! grep -qF "$1" "$PROMPT"; then
    echo "FAIL: system-prompt.md missing: $1"
    fail=1
  fi
}

require "Writing format (Slack)"
require "mrkdwn, NOT standard Markdown"
require "1-3 plain conversational sentences"
require "600 characters"
require "NEVER dump inventories"
require "thread reply, a canvas report"
require "Block Kit toolkit"
require "sharp, thoughtful human teammate"

[ "$fail" -eq 0 ] && echo "PASS: writing-format contract present"
exit "$fail"
