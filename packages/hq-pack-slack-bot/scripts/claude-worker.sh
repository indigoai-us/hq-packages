#!/usr/bin/env bash
# claude-worker.sh — Spawn claude in --remote-control mode so AskUserQuestion
# surfaces to claude.ai/code + mobile. The prompt is passed as a positional
# argv (not piped on stdin) and claude runs inside a real pty via
# claude-pty-spawn.py — both conditions are required for AskUserQuestion to
# reach the Remote Control UI. A Stop hook captures the final assistant
# message and touches a "done" sentinel; the wrapper then SIGTERMs the pty
# spawner (which forwards to claude) so the session disappears from the UI.
#
# Pack-vendored copy: this file ships inside hq-pack-slack-bot/scripts/
# so the pack runs without depending on personal/tools/. The sibling
# claude-pty-spawn.py is resolved first; the legacy companies/ghq path
# is kept as a back-compat fallback only.
#
# Usage:
#   claude-worker.sh -n "Plan" "Your prompt here"
#   echo "Your prompt" | claude-worker.sh -n "Plan"
#   claude-worker.sh -n "Plan" -t 900 "Plan the migration"
set -euo pipefail

NAME=""
TIMEOUT=10800
EXTRA_SETTINGS=""
JSON_SCHEMA=""
RESULT_JSON=false
APPEND_SYSTEM_PROMPT=""
RESUME_ID=""
CONTINUE_LAST=false
FORK_SESSION=false

usage() {
  cat <<EOF
Usage: $(basename "$0") -n NAME [options] [prompt]
       $(basename "$0") --resume AGENT_ID [options] [prompt]
       $(basename "$0") --continue-last [options] [prompt]

Required (fresh runs):
  -n, --name TITLE       Session name shown in Remote Control UI. Required so
                         simultaneous sessions are distinguishable at a glance.
                         Optional on --resume / --continue-last (inherits from
                         the prior run's meta.yaml).

Options:
  -t, --timeout SECS     Emit a "still running" warning after this many seconds
                         (default: 10800 = 3h). Never hard-kills the pty — the
                         worker runs until its Stop hook fires, Remote Control
                         drops, or the pty is killed externally.
  -s, --settings JSON    Extra settings JSON, deep-merged over the base hook config
      --append-system-prompt TEXT
                         Forwarded to claude as --append-system-prompt.
      --json-schema SPEC JSON Schema for structured output validation.
                         Pass an inline JSON string, or @path/to/schema.json to
                         load from a file. Forwarded to claude as --json-schema.
  -J, --result-json      Post-process result.txt through extract-json.sh to
                         strip markdown fences and guarantee valid JSON.
                         Combines naturally with --json-schema.
      --resume AGENT_ID  Resume a prior run by its agent run id (the AGENT_DIR
                         basename, e.g. 20260423_170410_hesb). The prior run's
                         transcript JSONL is rehydrated; the new prompt is sent
                         as the next turn. result.txt is appended (separated by
                         ---RESUME---) so prior envelopes are preserved.
                         Refused for status ∈ {rc-failed, settings-error} —
                         those failed before any JSONL was written.
      --continue-last    Resume the most recent run in this repo whose status
                         is one of stream-idle-timeout, rc-mid-session-drop,
                         exited-early, or completed. Mutually exclusive with
                         --resume.
      --fork-session     When resuming, create a new session id instead of
                         reusing the original. Forwarded to claude. Useful for
                         trying an alternative approach without trampling the
                         original transcript.
  -h, --help             Show this help

Prompt may be passed as an argument or piped on stdin.
Open claude.ai/code or the Claude mobile app to answer any AskUserQuestion
calls the session makes — the session is registered under the name above.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)        NAME="$2"; shift 2 ;;
    -t|--timeout)     TIMEOUT="$2"; shift 2 ;;
    -s|--settings)    EXTRA_SETTINGS="$2"; shift 2 ;;
    --append-system-prompt) APPEND_SYSTEM_PROMPT="$2"; shift 2 ;;
    --json-schema)    JSON_SCHEMA="$2"; shift 2 ;;
    -J|--result-json) RESULT_JSON=true; shift ;;
    --resume)
      # Hard fail on empty value. Falling through to fresh-spawn mode when
      # the caller passed an empty string is a footgun — we've seen bash 3.2
      # array-iteration bugs and shell-eval edge cases silently produce
      # `--resume ""`, which the old code accepted and rerouted into minting
      # a brand-new agent dir named `liveops:` (empty) that then retry-looped
      # as a phantom. Refuse it loudly instead.
      if [[ -z "${2:-}" ]]; then
        echo "Error: --resume requires a non-empty AGENT_ID. Got empty string." >&2
        echo "  If you intended a fresh spawn, omit --resume entirely. If you" >&2
        echo "  intended to resume, your caller's variable expansion is broken." >&2
        exit 1
      fi
      RESUME_ID="$2"; shift 2 ;;
    --continue-last)  CONTINUE_LAST=true; shift ;;
    --fork-session)   FORK_SESSION=true; shift ;;
    -h|--help)        usage ;;
    --)               shift; break ;;
    -*)               echo "Unknown option: $1" >&2; exit 1 ;;
    *)                break ;;
  esac
done

if [[ -n "$RESUME_ID" && "$CONTINUE_LAST" == true ]]; then
  echo "Error: --resume and --continue-last are mutually exclusive." >&2
  exit 1
fi
if [[ "$FORK_SESSION" == true && -z "$RESUME_ID" && "$CONTINUE_LAST" != true ]]; then
  echo "Error: --fork-session requires --resume or --continue-last." >&2
  exit 1
fi

# -n check is deferred until after resume-mode resolution: in resume mode the
# name can be inherited from the prior run's meta.yaml.
if [[ -z "$NAME" && -z "$RESUME_ID" && "$CONTINUE_LAST" != true ]]; then
  echo "Error: -n/--name is required. Pick a label that makes this session distinguishable from other simultaneous sessions (e.g. 'planner: brage', 'recruiter-audit: code-worker')." >&2
  exit 1
fi

# Resolve --json-schema: @path loads a file; otherwise treat as inline JSON
if [[ -n "$JSON_SCHEMA" && "${JSON_SCHEMA:0:1}" == "@" ]]; then
  SCHEMA_PATH="${JSON_SCHEMA:1}"
  if [[ ! -f "$SCHEMA_PATH" ]]; then
    echo "Error: --json-schema file not found: $SCHEMA_PATH" >&2
    exit 1
  fi
  JSON_SCHEMA="$(jq -c . "$SCHEMA_PATH")"
elif [[ -n "$JSON_SCHEMA" ]]; then
  JSON_SCHEMA="$(printf '%s' "$JSON_SCHEMA" | jq -c . 2>/dev/null || true)"
  if [[ -z "$JSON_SCHEMA" ]]; then
    echo "Error: --json-schema is not valid JSON." >&2
    exit 1
  fi
fi

# Collect prompt from args + stdin
PROMPT="${*:-}"
if [[ ! -t 0 ]]; then
  STDIN_CONTENT="$(cat)"
  if [[ -n "$PROMPT" ]]; then
    PROMPT="$PROMPT"$'\n\n'"$STDIN_CONTENT"
  else
    PROMPT="$STDIN_CONTENT"
  fi
fi
if [[ -z "$PROMPT" ]]; then
  echo "Error: no prompt. Pass as arg or pipe via stdin." >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ── Resume resolution ────────────────────────────────────────────────────────
# When --resume or --continue-last is set, reuse the prior AGENT_DIR rather
# than minting a new one. The prior run's transcript JSONL is rehydrated by
# claude itself via --resume <SID>; we look up <SID> from transcript.path.
# Statuses rc-failed and settings-error are refused — those failed before any
# JSONL was written, so there is nothing to rehydrate.
RESUME_SID=""
RESUME_MODE=false
if [[ "$CONTINUE_LAST" == true ]]; then
  RUNS_DIR="$REPO_ROOT/workspace/workers/runs"
  if [[ ! -d "$RUNS_DIR" ]]; then
    echo "Error: --continue-last: no $RUNS_DIR directory exists." >&2
    exit 1
  fi
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    s=$(tr -d '[:space:]' < "$RUNS_DIR/$d/status" 2>/dev/null || true)
    case "$s" in
      stream-idle-timeout|rc-mid-session-drop|exited-early|completed)
        RESUME_ID="$d"; break ;;
    esac
  done < <(ls -t "$RUNS_DIR" 2>/dev/null)
  if [[ -z "$RESUME_ID" ]]; then
    echo "Error: --continue-last: no resumable run found in $RUNS_DIR (need status ∈ {stream-idle-timeout, rc-mid-session-drop, exited-early, completed})." >&2
    exit 1
  fi
  echo "--continue-last: resuming $RESUME_ID" >&2
fi

if [[ -n "$RESUME_ID" ]]; then
  RESUME_MODE=true
  AGENT_ID="$RESUME_ID"
  AGENT_DIR="$REPO_ROOT/workspace/workers/runs/$AGENT_ID"
  if [[ ! -d "$AGENT_DIR" ]]; then
    echo "Error: --resume: agent dir not found: $AGENT_DIR" >&2
    exit 1
  fi
  PRIOR_STATUS=$(tr -d '[:space:]' < "$AGENT_DIR/status" 2>/dev/null || true)
  case "$PRIOR_STATUS" in
    rc-failed|settings-error)
      echo "Error: --resume: prior run status '$PRIOR_STATUS' has no JSONL to rehydrate. Re-spawn fresh instead." >&2
      exit 1
      ;;
  esac
  # Resolve session id from transcript.path (basename sans .jsonl).
  if [[ -f "$AGENT_DIR/transcript.path" ]]; then
    PRIOR_TRANSCRIPT=$(cat "$AGENT_DIR/transcript.path")
    if [[ -f "$PRIOR_TRANSCRIPT" ]]; then
      RESUME_SID=$(basename "$PRIOR_TRANSCRIPT" .jsonl)
    fi
  fi
  if [[ -z "$RESUME_SID" ]]; then
    echo "Error: --resume: cannot resolve session id for $RESUME_ID. transcript.path missing or its target was deleted." >&2
    exit 1
  fi
  # Inherit name from meta.yaml if not supplied.
  if [[ -z "$NAME" && -f "$AGENT_DIR/meta.yaml" ]]; then
    NAME=$(awk -F '"' '/^name: "/ { print $2; exit }' "$AGENT_DIR/meta.yaml")
  fi
  if [[ -z "$NAME" ]]; then
    echo "Error: --resume: -n NAME not provided and prior meta.yaml has no usable name field." >&2
    exit 1
  fi
  # Clear sentinels from the prior attempt so the wait loop and salvage path
  # behave correctly. result.txt is preserved (Stop hook will append on resume).
  rm -f "$AGENT_DIR/done" "$AGENT_DIR/timeout" "$AGENT_DIR/warning-timeout" 2>/dev/null || true
  : > "$AGENT_DIR/status"
  # pty.log must be truncated: the wait loop's stream_idle_dropped/rc_dropped
  # detectors tail the last 8KB and would re-trigger instantly on the prior
  # run's failure tail. stdout/stderr logs go with it for cleanliness.
  : > "$AGENT_DIR/pty.log" 2>/dev/null || true
  : > "$AGENT_DIR/stdout.log" 2>/dev/null || true
  : > "$AGENT_DIR/stderr.log" 2>/dev/null || true
  # Mark this dir as a resume target so the Stop hook + salvage block append
  # rather than overwrite result.txt. The sentinel is removed at the end of
  # this run so a subsequent fresh run reusing the dir would not pick it up.
  touch "$AGENT_DIR/.resume-mode"
else
  AGENT_ID="$(date +%Y%m%d_%H%M%S)_$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4 || true)"
  AGENT_DIR="$REPO_ROOT/workspace/workers/runs/$AGENT_ID"
fi
mkdir -p "$AGENT_DIR"

START_TS_EPOCH=$(date +%s)
START_TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── meta.yaml writer ─────────────────────────────────────────────────────────
# Called twice per run:
#   write_meta_yaml initial  — right after AGENT_DIR is created, so in-flight
#                              runs are inspectable (status: running) and the
#                              file always exists even if a SIGKILL skips the
#                              EXIT trap.
#   write_meta_yaml          — via EXIT trap; overwrites with terminal status,
#                              ended_at, duration, and token usage.
# Token counts come from the Claude Code JSONL transcript (path saved by the
# Stop hook in transcript.path). Assistant content blocks are each emitted as
# their own transcript row with identical `message.usage`, so we dedupe by
# `message.id` before summing — otherwise totals double-count by block-count.
write_meta_yaml() {
  local mode="${1:-final}"
  if [[ "$mode" == "final" ]]; then
    [[ -n "${_META_WRITTEN:-}" ]] && return 0
    _META_WRITTEN=1
  fi
  set +e

  # YAML-escape for double-quoted scalars (backslash + double-quote)
  local n="$NAME";     n="${n//\\/\\\\}";     n="${n//\"/\\\"}"
  local a="$AGENT_ID"; a="${a//\\/\\\\}";     a="${a//\"/\\\"}"

  if [[ "$mode" == "initial" ]]; then
    {
      printf 'agent_id: "%s"\n' "$a"
      printf 'name: "%s"\n' "$n"
      printf 'status: running\n'
      printf 'started_at: "%s"\n' "$START_TS_ISO"
    } > "$AGENT_DIR/meta.yaml" 2>/dev/null
    return 0
  fi

  local end_epoch end_iso duration status transcript usage_block
  end_epoch=$(date +%s)
  end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  duration=$(( end_epoch - START_TS_EPOCH ))
  status="unknown"
  [[ -f "$AGENT_DIR/status" ]] && status=$(tr -d '\n' < "$AGENT_DIR/status")

  transcript=""
  [[ -f "$AGENT_DIR/transcript.path" ]] && transcript=$(cat "$AGENT_DIR/transcript.path")

  if [[ -n "$transcript" && -f "$transcript" ]]; then
    usage_block=$(jq -rs '
      [.[] | select(.type == "assistant") | .message]
      | group_by(.id) | map(.[0])
      | {
          input:  (map(.usage.input_tokens // 0)                | add // 0),
          output: (map(.usage.output_tokens // 0)               | add // 0),
          ccit:   (map(.usage.cache_creation_input_tokens // 0) | add // 0),
          crit:   (map(.usage.cache_read_input_tokens // 0)     | add // 0),
          n:      length,
          models: (map(.model) | unique)
        }
      | "usage:\n  input_tokens: \(.input)\n  output_tokens: \(.output)\n  cache_creation_input_tokens: \(.ccit)\n  cache_read_input_tokens: \(.crit)\n  total_tokens: \(.input + .output + .ccit + .crit)\n  message_count: \(.n)\nmodels:\n" + (if (.models | length) == 0 then "  []" else (.models | map("  - \(.)") | join("\n")) end)
    ' "$transcript" 2>/dev/null)
    [[ -z "$usage_block" ]] && usage_block=$'usage: null  # transcript parse failed\nmodels: []'
  else
    usage_block=$'usage: null  # transcript not captured\nmodels: []'
  fi

  {
    printf 'agent_id: "%s"\n' "$a"
    printf 'name: "%s"\n' "$n"
    printf 'status: %s\n' "$status"
    printf 'started_at: "%s"\n' "$START_TS_ISO"
    printf 'ended_at: "%s"\n' "$end_iso"
    printf 'duration_seconds: %d\n' "$duration"
    printf '%s\n' "$usage_block"
  } > "$AGENT_DIR/meta.yaml" 2>/dev/null
}
trap write_meta_yaml EXIT
write_meta_yaml initial

if [[ "$RESUME_MODE" == true ]]; then
  printf '\n\n---RESUME---\n\n%s' "$PROMPT" >> "$AGENT_DIR/prompt.txt"
else
  printf '%s' "$PROMPT" > "$AGENT_DIR/prompt.txt"
fi

# Pack-vendored variant: claude-pty-spawn.py is shipped as a sibling of
# this script. Resolve sibling-first; legacy companies/ghq path kept as a
# back-compat fallback for callers that haven't vendored the helper.
PTY_SPAWN="$(cd "$(dirname "$0")" && pwd)/claude-pty-spawn.py"
if [[ ! -x "$PTY_SPAWN" ]]; then
  ALT_PTY_SPAWN="$REPO_ROOT/companies/ghq/tools/workers/v1/claude-pty-spawn.py"
  if [[ -x "$ALT_PTY_SPAWN" ]]; then
    PTY_SPAWN="$ALT_PTY_SPAWN"
  fi
fi
if [[ ! -x "$PTY_SPAWN" ]]; then
  echo "Error: claude-pty-spawn.py not found or not executable next to this script." >&2
  exit 1
fi

# ── Stop hook ────────────────────────────────────────────────────────────────
# Fires when Claude's turn ends. Reads the JSONL transcript, extracts the last
# assistant text message to result.txt, then — if this Stop represents the
# worker's final turn — touches "done" so the wrapper knows it's safe to
# SIGTERM the claude process.
#
# Background-subscribe tools like Monitor end the agent's turn while the
# worker is still alive; their events arrive as fresh user messages that wake
# subsequent turns. An unconditional touch-done would kill the worker before
# any Monitor event could land. When the run was launched with --json-schema,
# the contract is "the final assistant message is a schema-valid JSON
# envelope" — so we gate done on whether the last assistant text contains a
# JSON object with the required top-level keys (status + summary). Models
# routinely wrap the envelope in markdown fences or prepend a chat preamble
# even under --json-schema, so the check tolerates fences and prose around
# the JSON (matches the same shape extract-json.sh handles for result.txt).
# Intermediate turns (e.g. "I armed Monitor and am watching") have no such
# envelope and the wrapper keeps waiting. Stream-idle / RC-drop / hard-timeout
# remain the backstops for genuine hangs.
HAS_SCHEMA=$([[ -n "$JSON_SCHEMA" ]] && echo true || echo false)
ENVELOPE_CHECK="$AGENT_DIR/is-final-envelope.py"
cat > "$ENVELOPE_CHECK" <<'PYCHECK'
#!/usr/bin/env python3
# Exit 0 if stdin contains a JSON object with both "status" and "summary"
# top-level keys (raw, fenced, or embedded in prose). Exit 1 otherwise.
import json, sys
text = sys.stdin.read().strip()
def envelope(obj):
    return isinstance(obj, dict) and "status" in obj and "summary" in obj
try:
    if envelope(json.loads(text)):
        sys.exit(0)
except Exception:
    pass
opens = [i for i, c in enumerate(text) if c == "{"]
closes = [i for i, c in enumerate(text) if c == "}"]
for s in reversed(opens):
    for e in reversed(closes):
        if e <= s:
            continue
        try:
            if envelope(json.loads(text[s:e+1])):
                sys.exit(0)
        except Exception:
            continue
sys.exit(1)
PYCHECK
chmod +x "$ENVELOPE_CHECK"
STOP_HOOK="$AGENT_DIR/stop-hook.sh"
cat > "$STOP_HOOK" <<HOOK
#!/usr/bin/env bash
set -u
AGENT_DIR="$AGENT_DIR"
HAS_SCHEMA=$HAS_SCHEMA
payload="\$(cat)"
transcript="\$(printf '%s' "\$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
if [[ -n "\$transcript" && -f "\$transcript" ]]; then
  printf '%s\n' "\$transcript" > "\$AGENT_DIR/transcript.path"
  if [[ -f "\$AGENT_DIR/.resume-mode" ]]; then
    {
      printf '\n\n---RESUME---\n\n'
      jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | .[-1] // empty' \
        "\$transcript" 2>/dev/null
    } >> "\$AGENT_DIR/result.txt" || true
  else
    jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | .[-1] // empty' \
      "\$transcript" > "\$AGENT_DIR/result.txt" 2>/dev/null || true
  fi
fi
final=true
if [[ "\$HAS_SCHEMA" == true && -n "\$transcript" && -f "\$transcript" ]]; then
  last_text=\$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | .[-1] // empty' "\$transcript" 2>/dev/null || printf '')
  if ! printf '%s' "\$last_text" | "\$AGENT_DIR/is-final-envelope.py" >/dev/null 2>&1; then
    final=false
  fi
fi
if [[ "\$final" == true ]]; then
  touch "\$AGENT_DIR/done"
fi
exit 0
HOOK
chmod +x "$STOP_HOOK"

# ── Settings file ────────────────────────────────────────────────────────────
SETTINGS_FILE="$AGENT_DIR/settings.json"
BASE_SETTINGS=$(cat <<JSON
{
  "hooks": {
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "$STOP_HOOK" } ] }
    ]
  }
}
JSON
)
if [[ -n "$EXTRA_SETTINGS" ]]; then
  printf '%s\n%s' "$BASE_SETTINGS" "$EXTRA_SETTINGS" \
    | jq -s '.[0] * .[1]' > "$SETTINGS_FILE"
else
  printf '%s' "$BASE_SETTINGS" > "$SETTINGS_FILE"
fi

# ── Pre-flight: every settings JSON Claude will read must parse ──────────────
# A malformed settings file makes Claude pop a blocking "Settings Error /
# Invalid or malformed JSON" prompt at startup. The worker has no way to answer
# it (no interactive stdin), so the pty hangs until TIMEOUT (hours). Fail fast
# instead, pointing at every broken file so the user can fix in one pass.
INVALID_SETTINGS_FILES=()
for s in \
  "$SETTINGS_FILE" \
  "$REPO_ROOT/.claude/settings.json" \
  "$REPO_ROOT/.claude/settings.local.json" \
  "$HOME/.claude/settings.json" \
  "$HOME/.claude/settings.local.json"
do
  [[ -f "$s" ]] || continue
  if ! jq empty "$s" >/dev/null 2>&1; then
    INVALID_SETTINGS_FILES+=("$s")
  fi
done
if (( ${#INVALID_SETTINGS_FILES[@]} > 0 )); then
  {
    echo "Error: malformed JSON in settings file(s) — fix before running a worker:"
    for f in "${INVALID_SETTINGS_FILES[@]}"; do
      echo "  $f"
      jq empty "$f" 2>&1 | sed 's/^/    /' || true
    done
  } >&2
  printf 'settings-error\n' > "$AGENT_DIR/status"
  touch "$AGENT_DIR/done"
  exit 125
fi

# ── Launch claude in a pty with the prompt as positional argv ────────────────
# stdin-pipe mode synchronously rejects AskUserQuestion with
# is_error:"Answer questions?" in ~2ms. Positional argv + pty surfaces the
# question to the Remote Control UI.
unset CLAUDECODE

CLAUDE_CMD=(
  claude
  --remote-control
  --name "$NAME"
  --settings "$SETTINGS_FILE"
  --dangerously-skip-permissions
  --allow-dangerously-skip-permissions
  --permission-mode bypassPermissions
  # Keep HQ-root file access alive even if the Bash-tool cwd later drifts into a
  # sub-repo/worktree: --add-dir adds HQ root to the file-access roots so HQ
  # knowledge/policy/skill-file READS keep resolving. (Slash-command/skill search
  # paths still load from the LAUNCH cwd at boot — drift-prevention in the worker
  # prompts stays the primary guard; this is belt-and-suspenders.)
  --add-dir "$REPO_ROOT"
)
if [[ -n "$APPEND_SYSTEM_PROMPT" ]]; then
  CLAUDE_CMD+=(--append-system-prompt "$APPEND_SYSTEM_PROMPT")
fi
if [[ -n "$JSON_SCHEMA" ]]; then
  CLAUDE_CMD+=(--json-schema "$JSON_SCHEMA")
fi
if [[ -n "$RESUME_SID" ]]; then
  CLAUDE_CMD+=(--resume "$RESUME_SID")
fi
if [[ "$FORK_SESSION" == true ]]; then
  CLAUDE_CMD+=(--fork-session)
fi
# `--` terminates option processing so variadic flags like --disallowedTools
# and values starting with `--` in $PROMPT can't swallow each other.
CLAUDE_CMD+=(-- "$PROMPT")

# ── Retry loop for Remote Control connection failures ───────────────────────
# When RC fails at boot ("Remote Control failed to connect: Session creation
# failed"), the worker can't receive AskUserQuestion answers and hangs forever.
# Detect within the first 20s of boot and retry up to 3 times.
MAX_RC_ATTEMPTS=3
RC_HEALTH_WINDOW=20  # seconds to watch for RC-failure signatures in pty.log
RC_ATTEMPT=1
RC_GAVE_UP=false

while (( RC_ATTEMPT <= MAX_RC_ATTEMPTS )); do
  # Reset sentinels from any previous attempt
  rm -f "$AGENT_DIR/done" "$AGENT_DIR/timeout" 2>/dev/null || true

  # ── Boot-env diagnostic snapshot ──────────────────────────────────────────
  # Capture the exact environment the grandchild will see right before the
  # `claude` exec. Per-attempt file so retries don't clobber each other.
  # Lets us diff a failing watch.sh-driven spawn vs a successful manual one
  # to find the differentiating session-attribute / fd / env leak. Token-like
  # values are redacted so the log itself doesn't become a credential.
  BOOT_ENV_LOG="$AGENT_DIR/boot-env.attempt-${RC_ATTEMPT}.log"
  {
    echo "=== timestamp ==="; date -u +%FT%TZ
    echo "=== shell ==="; echo "pid=$$ ppid=$PPID shell=$BASH_VERSION"
    echo "=== cwd ==="; pwd -P
    echo "=== tty ==="; tty 2>&1 || true
    echo "=== id ==="; id
    echo "=== ulimit -a ==="; ulimit -a
    echo "=== umask ==="; umask
    echo "=== process tree up to launchd ==="
    p=$$; depth=0
    while [[ "$p" != "1" && "$p" != "0" && "$depth" -lt 20 ]]; do
      ps -o pid,ppid,user,sess,tt,stat,etime,comm -p "$p" 2>/dev/null | tail -n +2
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      [[ -z "$p" ]] && break
      depth=$((depth + 1))
    done
    echo "=== PATH ==="; echo "$PATH"
    echo "=== which claude ==="; command -v claude || echo "(not on PATH)"
    echo "=== full env (CLAUDE/ANTHROPIC/API/SESSION/TERM/PATH/SSH/LANG/LC/HOME/USER/SHELL/TMPDIR/XPC) ==="
    env | grep -E '^(CLAUDE|ANTHROPIC|API|SESSION|TERM|PATH|SSH|LANG|LC_|HOME|USER|SHELL|TMPDIR|XPC|LAUNCH|SECURITY|AWS|AI_AGENT|BAGGAGE)' \
      | sed -E 's/(API_KEY|TOKEN|SECRET|PASSWORD|AUTH|CREDENTIALS?)=.+/\1=<redacted>/i' \
      | sort
    echo "=== full env keys only (everything else, no values) ==="
    env | awk -F= '{print $1}' | sort -u
    echo "=== open fds for THIS shell ==="
    if command -v lsof >/dev/null 2>&1; then
      lsof -p $$ 2>/dev/null | awk 'NR<=30'
    else
      ls -la /dev/fd 2>/dev/null
    fi
    echo "=== keychain reachability test ==="
    if security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
      echo "OK: keychain readable"
    else
      echo "FAIL: keychain not readable (exit $?)"
    fi
    echo "=== claude --version (auth-free smoke) ==="
    claude --version 2>&1 || echo "(exit $?)"
    echo "=== CLAUDE_CMD (about to exec) ==="
    # Mask the prompt body (last arg after --) to keep log small/safe
    printf '%s\n' "${CLAUDE_CMD[@]}" | awk -v cap=200 '
      /^--/ && body { print substr(body, 1, cap) " ... [truncated]"; body=""; print; next }
      seenDD { body=$0; next }
      $0=="--" { seenDD=1; print; next }
      { print }
    '
    echo "=== invocation hint ==="
    # Best-effort: who started this script (helps spot Monitor-tool wrapper vs Bash-tool vs Terminal)
    ps -o pid,ppid,command -p $PPID 2>/dev/null
    echo "=== /end ==="
  } > "$BOOT_ENV_LOG" 2>&1

  "$PTY_SPAWN" "$AGENT_DIR/pty.log" "${CLAUDE_CMD[@]}" \
    > "$AGENT_DIR/stdout.log" 2> "$AGENT_DIR/stderr.log" &
  PID=$!

  if [[ "$RC_ATTEMPT" -eq 1 ]]; then
    cat >&2 <<INFO
Agent:   $AGENT_ID
Dir:     $AGENT_DIR
PID:     $PID
Name:    $NAME
Open:    claude.ai/code (or mobile app) and pick "$NAME" to answer any questions
Logs:    tail -f $AGENT_DIR/pty.log
INFO
  else
    echo "Remote Control retry attempt $RC_ATTEMPT/$MAX_RC_ATTEMPTS (PID: $PID)" >&2
  fi

  # Health check: watch pty.log for RC-failure and settings-error signatures.
  # RC failures are transient (retried below). Settings errors mean Claude is
  # blocked on an interactive "Invalid or malformed JSON" prompt — the pty has
  # no way to answer it, so retrying can't help. Fail fast on that signature.
  RC_FAILED=false
  SETTINGS_FAILED=false
  HEALTH_ELAPSED=0
  while (( HEALTH_ELAPSED < RC_HEALTH_WINDOW )); do
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    if grep -qE 'Settings Error|Invalid or malformed JSON' "$AGENT_DIR/pty.log" 2>/dev/null; then
      SETTINGS_FAILED=true
      break
    fi
    if grep -qE 'Remote Control failed to connect|Remote Control failed · /remote-control' "$AGENT_DIR/pty.log" 2>/dev/null; then
      RC_FAILED=true
      break
    fi
    sleep 1
    HEALTH_ELAPSED=$((HEALTH_ELAPSED + 1))
  done

  if [[ "$SETTINGS_FAILED" == true ]]; then
    echo "Settings error: Claude blocked on 'Invalid or malformed JSON' prompt — killing." >&2
    echo "  pty.log: $AGENT_DIR/pty.log" >&2
    kill -TERM "$PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    printf 'settings-error\n' > "$AGENT_DIR/status"
    touch "$AGENT_DIR/done"
    exit 125
  fi

  if [[ "$RC_FAILED" != true ]]; then
    # RC is up (or the pty died for a non-RC reason — main loop handles it)
    break
  fi

  echo "Remote Control connection failed on attempt $RC_ATTEMPT/$MAX_RC_ATTEMPTS — killing and retrying." >&2
  kill -TERM "$PID" 2>/dev/null || true
  sleep 2
  kill -KILL "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true

  # Archive the failed attempt's logs for debugging
  mv "$AGENT_DIR/pty.log" "$AGENT_DIR/pty.log.rc-failed-attempt-$RC_ATTEMPT" 2>/dev/null || true
  : > "$AGENT_DIR/stdout.log"
  : > "$AGENT_DIR/stderr.log"

  RC_ATTEMPT=$((RC_ATTEMPT + 1))
  if (( RC_ATTEMPT <= MAX_RC_ATTEMPTS )); then
    sleep 3  # brief backoff before next attempt
  else
    RC_GAVE_UP=true
  fi
done

if [[ "$RC_GAVE_UP" == true ]]; then
  cat >&2 <<ERR
Remote Control failed $MAX_RC_ATTEMPTS times in a row — giving up.
  agent: $AGENT_ID
  dir:   $AGENT_DIR
  name:  $NAME
Inspect: $AGENT_DIR/pty.log.rc-failed-attempt-*
ERR
  printf 'rc-failed\n' > "$AGENT_DIR/status"
  touch "$AGENT_DIR/done"   # signal terminal state to the manager's Monitor
  exit 126
fi

# ── Wait for Stop hook to drop the done sentinel ────────────────────────────
# Mid-session "Remote Control disconnected / Transport closed (code 4091)" is
# terminal — the CLI will not reconnect (claude-code#32982). pty.log interleaves
# the banner with ANSI cursor-forward escapes, so spaced phrases like
# "Transport closed" never match; grep on contiguous word tokens instead. See
# companies/ghq/knowledge/core/workers/docs/remote-control-disconnect-handling.md.
# Strip ANSI CSI sequences (cursor-forwards interleaved by the TUI when it
# wraps long error lines) so contiguous-phrase matches still work. Replace
# each escape with a single space rather than deleting it: the TUI emits CSI
# sequences where it would have rendered a space, so deletion glues words
# together ("Streamidletimeout") and breaks the phrase greps below.
strip_csi() {
  sed 's/\x1b\[[0-9;]*[A-Za-z]/ /g'
}

RC_DROP_PATTERN='disconnected|4091\)|1002\)|1006\)'
rc_dropped() {
  tail -c 8192 "$AGENT_DIR/pty.log" 2>/dev/null | strip_csi | grep -qE "$RC_DROP_PATTERN"
}

# Stream idle timeout — Claude Code CLI client-side watchdog firing when no
# SSE byte arrives for >CLAUDE_STREAM_IDLE_TIMEOUT_MS (default 90s) on an
# otherwise healthy stream. The Stop hook does NOT fire (no message_stop
# event), so result.txt stays empty even when work landed on disk. Detect so
# we can mark a distinct terminal status and salvage the transcript below.
# Match BEFORE rc_dropped: both can co-occur but stream-idle is the proximate
# cause (the RC drop may follow as a consequence of the stream dying).
# See: companies/ghq/knowledge/core/workers/docs/stream-idle-timeout-recovery.md
STREAM_IDLE_PATTERN='Stream idle timeout|partial response received'
stream_idle_dropped() {
  tail -c 8192 "$AGENT_DIR/pty.log" 2>/dev/null | strip_csi | grep -qE "$STREAM_IDLE_PATTERN"
}

WARNED=false
ELAPSED=0
while [[ ! -f "$AGENT_DIR/done" ]]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    if stream_idle_dropped; then
      echo "(pty spawner exited after stream idle timeout)" >&2
      printf 'stream-idle-timeout\n' > "$AGENT_DIR/status"
    elif rc_dropped; then
      echo "(pty spawner exited after mid-session Remote Control drop)" >&2
      printf 'rc-mid-session-drop\n' > "$AGENT_DIR/status"
    else
      echo "(pty spawner exited before Stop hook fired)" >&2
      printf 'exited-early\n' > "$AGENT_DIR/status"
    fi
    touch "$AGENT_DIR/done"
    break
  fi
  if stream_idle_dropped; then
    echo "Stream idle timeout — Stop hook will not fire; terminating worker." >&2
    kill -TERM "$PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    printf 'stream-idle-timeout\n' > "$AGENT_DIR/status"
    touch "$AGENT_DIR/done"
    break
  fi
  if rc_dropped; then
    echo "Remote Control dropped mid-session — terminating worker." >&2
    kill -TERM "$PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    printf 'rc-mid-session-drop\n' > "$AGENT_DIR/status"
    touch "$AGENT_DIR/done"
    break
  fi
  if (( ELAPSED >= TIMEOUT )) && [[ "$WARNED" != true ]]; then
    WARNED=true
    touch "$AGENT_DIR/warning-timeout"
    cat >&2 <<WARN
warning: claude-worker still running after ${TIMEOUT}s — Stop hook has not fired. Continuing to wait (no hard kill).
  agent: $AGENT_ID
  dir:   $AGENT_DIR
  name:  $NAME
WARN
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# ── Terminate the session so it disappears from the Remote Control UI ───────
if kill -0 "$PID" 2>/dev/null; then
  kill -TERM "$PID" 2>/dev/null || true
  sleep 2
  kill -KILL "$PID" 2>/dev/null || true
fi
wait "$PID" 2>/dev/null || true

if [[ -f "$AGENT_DIR/done" && ! -s "$AGENT_DIR/status" ]]; then
  printf 'completed\n' > "$AGENT_DIR/status"
fi

# ── Transcript salvage when Stop hook did not fire ───────────────────────────
# On stream-idle-timeout (and exited-early without an RC drop), the Stop hook
# never received a message_stop event, so transcript.path was not written and
# result.txt is empty. We can still recover the last assistant text block from
# the JSONL transcript: Claude Code writes it per-block as the turn unfolds,
# so any assistant text that made it to the wire is on disk. Find the JSONL
# under ~/.claude/projects/<encoded-cwd>/ whose first record has
# `customTitle == $NAME` (the field set by `claude --name`); mtime alone is
# not selective enough when many workers run concurrently in the same repo.
# Best-effort: silently skip if anything fails (a missing salvage is no worse
# than today's empty result.txt).
# See: companies/ghq/knowledge/core/workers/docs/stream-idle-timeout-recovery.md §5.
if [[ ! -s "$AGENT_DIR/result.txt" && -s "$AGENT_DIR/status" ]]; then
  CURRENT_STATUS=$(tr -d '\n' < "$AGENT_DIR/status")
  case "$CURRENT_STATUS" in
    stream-idle-timeout|exited-early)
      ENCODED_CWD="${REPO_ROOT//\//-}"
      PROJ_DIR="$HOME/.claude/projects/$ENCODED_CWD"
      if [[ -d "$PROJ_DIR" ]]; then
        # Collect JSONLs touched after this run started, sort newest-first,
        # then pick the first one whose first record's customTitle matches
        # our session NAME. The mtime filter is a coarse window; the
        # customTitle match is the precise key.
        SALVAGE_CANDIDATES=()
        while IFS= read -r -d '' f; do
          SALVAGE_CANDIDATES+=("$f")
        done < <(find "$PROJ_DIR" -maxdepth 1 -name '*.jsonl' -type f \
                 -newermt "@$START_TS_EPOCH" -print0 2>/dev/null)
        TRANSCRIPT_CANDIDATE=""
        if (( ${#SALVAGE_CANDIDATES[@]} > 0 )); then
          while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            if head -1 "$f" 2>/dev/null \
               | jq -e --arg n "$NAME" 'select(.customTitle == $n)' >/dev/null 2>&1; then
              TRANSCRIPT_CANDIDATE="$f"
              break
            fi
          done < <(ls -t "${SALVAGE_CANDIDATES[@]}" 2>/dev/null)
        fi
        if [[ -n "$TRANSCRIPT_CANDIDATE" && -f "$TRANSCRIPT_CANDIDATE" ]]; then
          printf '%s\n' "$TRANSCRIPT_CANDIDATE" > "$AGENT_DIR/transcript.path"
          if [[ "$RESUME_MODE" == true ]]; then
            {
              printf '\n\n---RESUME---\n\n'
              jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | .[-1] // empty' \
                "$TRANSCRIPT_CANDIDATE" 2>/dev/null
            } >> "$AGENT_DIR/result.txt" || true
          else
            jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | .[-1] // empty' \
              "$TRANSCRIPT_CANDIDATE" > "$AGENT_DIR/result.txt" 2>/dev/null || true
          fi
          if [[ -s "$AGENT_DIR/result.txt" ]]; then
            echo "Salvaged last assistant text from transcript ($CURRENT_STATUS, customTitle=$NAME): $TRANSCRIPT_CANDIDATE" >&2
          fi
        fi
      fi
      ;;
  esac
fi

# ── Optional JSON post-processing ────────────────────────────────────────────
# -J strips markdown fences and normalizes verdict fields via extract-json.sh.
# Safe to combine with --json-schema: the schema constrains what the model
# emits, and extract-json.sh cleans up any wrappers that slip through.
if [[ "$RESULT_JSON" == true && -s "$AGENT_DIR/result.txt" ]]; then
  EXTRACT="$REPO_ROOT/companies/ghq/tools/archive/dev-team/extract-json.sh"
  if [[ -x "$EXTRACT" ]]; then
    CLEAN_JSON="$(cat "$AGENT_DIR/result.txt" | "$EXTRACT" 2>/dev/null || echo '{}')"
    printf '%s' "$CLEAN_JSON" > "$AGENT_DIR/result.txt"
  else
    echo "Warning: $EXTRACT not found; skipping JSON cleanup." >&2
  fi
fi

# Drop the resume-mode sentinel so this dir does not behave as a resume target
# on any future invocation that happens to pass --resume against it again
# (the next resume re-creates the sentinel itself).
rm -f "$AGENT_DIR/.resume-mode" 2>/dev/null || true

# ── Resume hint ──────────────────────────────────────────────────────────────
# Print a copy-pasteable resume command to stderr so /manager (or an operator)
# knows how to resume this run if a follow-up turn is needed. Skipped only for
# statuses that have no JSONL on disk to rehydrate from.
FINAL_STATUS=$(tr -d '[:space:]' < "$AGENT_DIR/status" 2>/dev/null || true)
case "$FINAL_STATUS" in
  rc-failed|settings-error)
    : # not resumable — no JSONL was written before the failure.
    ;;
  *)
    cat >&2 <<HINT
To resume this run:
  $0 --resume $AGENT_ID "<follow-up prompt>"
HINT
    ;;
esac

# ── Emit result ──────────────────────────────────────────────────────────────
if [[ -s "$AGENT_DIR/result.txt" ]]; then
  cat "$AGENT_DIR/result.txt"
  exit 0
else
  echo "(no result captured — inspect $AGENT_DIR/{pty,stdout,stderr}.log)" >&2
  exit 1
fi
