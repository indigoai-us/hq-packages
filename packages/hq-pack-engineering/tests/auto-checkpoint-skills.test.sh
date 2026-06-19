#!/usr/bin/env bash
# Regression: /prd and /run-project (hq-pack-engineering) must auto-checkpoint at
# the end of the command (Item 2). Instruction skills -> structural contract:
# each SKILL.md carries the AUTO-CHECKPOINT-ON-COMPLETION marker AND a real
# lightweight auto-checkpoint thread write under workspace/threads/.
set -euo pipefail
PACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
MARKER="AUTO-CHECKPOINT-ON-COMPLETION"
for skill in prd run-project; do
  f="$PACK/skills/$skill/SKILL.md"
  [ -f "$f" ] || fail "missing skill file: $f"
  grep -q "$MARKER" "$f" || fail "$skill: missing $MARKER final-step marker"
  grep -q 'type: "auto-checkpoint"' "$f" || fail "$skill: marker present but no auto-checkpoint thread instruction"
  grep -q 'workspace/threads/' "$f" || fail "$skill: no workspace/threads/ checkpoint path"
done
echo "auto-checkpoint-skills: ok (prd + run-project auto-checkpoint on completion)"
