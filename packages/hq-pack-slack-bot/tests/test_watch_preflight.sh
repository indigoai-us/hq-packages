#!/usr/bin/env bash
# Regression coverage for first-run identity + model-credential preflight.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$ROOT/scripts/watch.sh"
TMP="$(mktemp -d)"
BIN="$TMP/bin"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BIN"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1" needle="$2"
  [[ "$text" == *"$needle"* ]] || fail "missing '$needle' in: $text"
}

cat > "$BIN/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = "secrets" ] || exit 64
shift
scope=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --company) scope="company:$2"; shift 2 ;;
    --personal) scope="personal"; shift ;;
    list|get|exec) command="$1"; shift; break ;;
    *) shift ;;
  esac
done

case "$command" in
  list)
    printf 'NAME  ACCESS\n'
    case "${HQ_TEST_LIST:-one}" in
      one) printf 'prs_alice/HQ_SLACK_BOT_TOKEN_BOT_ACME  read\n' ;;
      ambiguous)
        printf 'prs_alice/HQ_SLACK_BOT_TOKEN_BOT_ACME  read\n'
        printf 'prs_bob/HQ_SLACK_BOT_TOKEN_BOT_ACME  read\n' ;;
      none) : ;;
      *) exit 64 ;;
    esac
    ;;
  get)
    secret="${*: -1}"
    case "$secret" in
      */HQ_SLACK_BOT_TOKEN_BOT_ACME) printf '  Value: mock-bot-token\n' ;;
      *) exit 1 ;;
    esac
    ;;
  exec)
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
    [ "${1:-}" = "--" ] || exit 64
    shift
    if [ "${HQ_TEST_MODEL:-present}" = "missing" ]; then
      exit 1
    fi
    printf '%s\n' "$scope:$*" >> "$HQ_TEST_EXEC_LOG"
    export ANTHROPIC_API_KEY=mock-model-key
    exec "$@"
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$BIN/hq"

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *auth.test*) printf '%s\n' '{"ok":true,"user_id":"U123"}' ;;
  *users.conversations*)
    if [ "${HQ_TEST_SLACK:-ok}" = "fail" ]; then
      printf '%s\n' '{"ok":false,"error":"missing_scope"}'
    else
      printf '%s\n' '{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}'
    fi
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/curl"

run_check() {
  local home="$1"
  shift
  mkdir -p "$home"
  HOME="$home" PATH="$BIN:$PATH" HQ_TEST_EXEC_LOG="$TMP/exec.log" "$@" \
    bash "$WATCH" bot -c acme -w acme --check
}

# A first-run machine has no cache. Resolve the sole exact token namespace
# from the selected company vault instead of demanding an ambient cache.
cacheless_out="$(run_check "$TMP/cacheless" env HQ_TEST_LIST=one 2>&1)" || fail "cacheless preflight failed: $cacheless_out"
assert_contains "$cacheless_out" 'person_uid:   prs_alice (source: vault:prs_alice/HQ_SLACK_BOT_TOKEN_BOT_ACME)'
assert_contains "$cacheless_out" 'model:        ANTHROPIC_API_KEY (loadable via scoped hq secrets exec)'
grep -q 'company:acme:sh -c' "$TMP/exec.log" \
  || fail 'model credential was not validated through scoped hq secrets exec'

# Matching more than one namespace must fail rather than choosing an owner.
if ambiguous_out="$(run_check "$TMP/ambiguous" env HQ_TEST_LIST=ambiguous 2>&1)"; then
  fail "ambiguous personUid resolution unexpectedly succeeded: $ambiguous_out"
fi
assert_contains "$ambiguous_out" 'FATAL: ambiguous HQ personUid for company:acme/acme'
assert_contains "$ambiguous_out" 'pass -u <prs_personUid>'

# The worker model key is a required preflight dependency, not host state.
mkdir -p "$TMP/model-missing/.hq/secrets-cache/prs_cached"
if model_out="$(run_check "$TMP/model-missing" env HQ_TEST_MODEL=missing 2>&1)"; then
  fail "missing model credential unexpectedly succeeded: $model_out"
fi
assert_contains "$model_out" 'FATAL: ANTHROPIC_API_KEY not loadable from company:acme vault for workers'

# Do not scrub the injected model credential; workers must receive it through
# the scope-bound hq secrets exec wrapper, never from the host environment.
grep -F 'nohup hq secrets "${HQ_SCOPE_ARGS[@]}" exec --only "$MODEL_SECRET" --' "$WATCH" >/dev/null \
  || fail 'worker dispatch does not inject the scoped model credential'
if grep -A24 'unset CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST' "$WATCH" | grep -q 'ANTHROPIC_API_KEY'; then
  fail 'worker dispatch still unsets ANTHROPIC_API_KEY'
fi

# Slack connectivity remains part of preflight and must fail loudly.
mkdir -p "$TMP/slack-failure/.hq/secrets-cache/prs_cached"
if slack_out="$(run_check "$TMP/slack-failure" env HQ_TEST_SLACK=fail 2>&1)"; then
  fail "Slack preflight failure unexpectedly succeeded: $slack_out"
fi
assert_contains "$slack_out" 'FATAL: users.conversations failed:'

echo 'PASS: watch first-run preflight'
