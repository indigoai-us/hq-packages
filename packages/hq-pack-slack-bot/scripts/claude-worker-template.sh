#!/usr/bin/env bash
# claude-worker-template.sh — Resolve a worker template bundled with this
# package and hand off to claude-worker.sh (sibling script). Pack-vendored
# variant of personal/tools/claude-worker-template.sh — paths point at the
# package's own scripts/ + workers/ tree so the pack runs without
# depending on HQ_ROOT/personal/.
#
# Template layout (resolved relative to this script):
#   <pack>/workers/{name}/system-prompt.md
#                       /schema.json    (optional)
#                       /settings.json  (optional)
#                       /meta.yaml      (optional; provider: claude|codex)
#
# Resolved system-prompt.md is variable-substituted ({{KEY}}), then passed to
# claude-worker.sh as --append-system-prompt. Optional schema.json becomes
# --json-schema @<path>, which is what makes the Stop hook actually enforce
# the final-message envelope. Optional settings.json becomes -s <json>.
#
# Usage:
#   claude-worker-template.sh -t slack-mention-worker -n "mention:<ts>" \
#     --var THREAD_TS=<ts> --var CHANNEL=<id> "<initial prompt>"
set -euo pipefail

TEMPLATE=""
NAME=""
TIMEOUT=""
declare -a TEMPLATE_VARS=()
declare -a PASSTHROUGH=()

usage() {
  cat <<EOF
Usage: $(basename "$0") -t TEMPLATE -n NAME [options] [prompt]

Required:
  -t, --template NAME    Worker template name (folder under HQ/personal/workers/)
  -n, --name TITLE       Session name shown in Remote Control UI.

Options:
  --var KEY=VALUE        Template variable substitution. Repeatable.
                         PERSONAL_ROOT is set automatically.
      --timeout SECS     Forwarded to claude-worker.sh as -t
  -h, --help             Show this help

Any remaining flags (-J, --json-schema, -s, etc.) are forwarded to
claude-worker.sh unchanged. Prompt may be passed as an argument or piped.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--template) TEMPLATE="$2"; shift 2 ;;
    -n|--name)     NAME="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --var)         TEMPLATE_VARS+=("$2"); shift 2 ;;
    -h|--help)     usage ;;
    --)            shift; PASSTHROUGH+=("$@"); break ;;
    -*)            PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    *)             break ;;
  esac
done

if [[ -z "$TEMPLATE" ]]; then
  echo "Error: -t/--template is required." >&2
  exit 1
fi
if [[ -z "$NAME" ]]; then
  echo "Error: -n/--name is required (distinguishes simultaneous sessions in Remote Control)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# PACKAGE_ROOT = the pack directory (one up from scripts/). Templates live
# at $PACKAGE_ROOT/workers/<name>/, vendored alongside this script.
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# PERSONAL_ROOT kept as a substituted var name for backward-compat with
# any templates that still reference {{PERSONAL_ROOT}} (none in this
# pack today; harmless if absent).
PERSONAL_ROOT="$PACKAGE_ROOT"

TEMPLATE_DIR="$PACKAGE_ROOT/workers/$TEMPLATE"
TEMPLATE_FILE="$TEMPLATE_DIR/system-prompt.md"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Error: template not found: $TEMPLATE_FILE" >&2
  exit 1
fi

# ── Collect prompt (remaining args + stdin) ───────────────────────────────────
# IMPORTANT for callers: when composing multi-line prompts in shell, use
# `printf` or a heredoc (`<<EOF`), NEVER the splice form
# `prompt="$header"$'\n\n'"$body"`. The splice form interacts badly with bash
# 3.2 (macOS default) when iterating arrays whose values include the literal
# `$(...)` text — the last iteration of a for-loop silently produces empty
# variable expansions, which means a worker spawn gets an empty name and
# falls through to fresh-spawn mode under `--resume` (now hard-rejected).
# Use heredoc inside a `cat <<EOF ... EOF` block, or pipe via stdin instead.
PROMPT="${*:-}"
if [[ -z "$PROMPT" && ! -t 0 ]]; then
  PROMPT="$(cat)"
fi
if [[ -z "$PROMPT" ]]; then
  echo "Error: no prompt. Pass as arg or pipe via stdin." >&2
  exit 1
fi

# ── Resolve system prompt + vars ─────────────────────────────────────────────
SYSTEM_PROMPT="$(cat "$TEMPLATE_FILE")"
SYSTEM_PROMPT="${SYSTEM_PROMPT//\{\{PERSONAL_ROOT\}\}/$PERSONAL_ROOT}"
for kv in ${TEMPLATE_VARS[@]+"${TEMPLATE_VARS[@]}"}; do
  key="${kv%%=*}"
  value="${kv#*=}"
  SYSTEM_PROMPT="${SYSTEM_PROMPT//\{\{$key\}\}/$value}"
done

UNRESOLVED="$(printf '%s' "$SYSTEM_PROMPT" | grep -oE '\{\{[A-Z_]+\}\}' | sort -u || true)"
if [[ -n "$UNRESOLVED" ]]; then
  echo "Error: template '$TEMPLATE' has unresolved placeholders:" >&2
  echo "$UNRESOLVED" | sed 's/^/  /' >&2
  echo "Pass them via --var, e.g. --var THREAD_TS=1778634985.234479" >&2
  exit 1
fi

# ── Provider resolution (meta.yaml `provider:`; default claude) ──────────────
PROVIDER="claude"
if [[ -f "$TEMPLATE_DIR/meta.yaml" ]]; then
  P=$(awk -F: '/^[[:space:]]*provider:[[:space:]]*/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$TEMPLATE_DIR/meta.yaml")
  [[ -n "$P" ]] && PROVIDER="$P"
fi

case "$PROVIDER" in
  claude)
    # claude-worker.sh is vendored next to this script (pack's scripts/).
    WORKER="$SCRIPT_DIR/claude-worker.sh"
    if [[ ! -x "$WORKER" ]]; then
      echo "Error: $WORKER not found or not executable." >&2
      exit 1
    fi
    WORKER_CMD=("$WORKER" --append-system-prompt "$SYSTEM_PROMPT")
    WORKER_CMD+=(-n "$NAME")
    [[ -n "$TIMEOUT" ]] && WORKER_CMD+=(-t "$TIMEOUT")
    if [[ -f "$TEMPLATE_DIR/settings.json" ]]; then
      WORKER_CMD+=(-s "$(cat "$TEMPLATE_DIR/settings.json")")
    fi
    if [[ -f "$TEMPLATE_DIR/schema.json" ]]; then
      WORKER_CMD+=(--json-schema "@$TEMPLATE_DIR/schema.json")
    fi
    WORKER_CMD+=(${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"})
    WORKER_CMD+=("$PROMPT")
    ;;
  *)
    echo "Error: provider '$PROVIDER' not supported in personal/ runner. Only 'claude' for now." >&2
    exit 1
    ;;
esac

exec "${WORKER_CMD[@]}"
