#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIMS=(
  "$HERE/../plugins/hq-anywhere/scripts/hq/hqd-hook-shim.sh"
  "$HERE/../packages/hq-pack-hq-anywhere/hooks/codex-hook-shim.sh"
)
if [ -n "${HQD_TEST_SHIM:-}" ]; then SHIMS=("$HQD_TEST_SHIM"); fi
if [ -z "${HQD_TEST_SHIM:-}" ]; then
  for shim in "${SHIMS[@]}"; do HQD_TEST_SHIM="$shim" bash "$0" || exit $?; done
  exit 0
fi
SHIM_DIR="$(cd "$(dirname "$HQD_TEST_SHIM")" && pwd)"
FLAG_SCRIPT="$SHIM_DIR/hq-anywhere-runtime-flag.cjs"
source "$HERE/hq-anywhere-flag-fixture.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
hq_anywhere_flag_fixture "$TMP/cli"
flag() { env -u HQ_FLAG_HQ_ANYWHERE_RUNTIME HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG="$1" node "$FLAG_SCRIPT"; }
missing_endpoint() { env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_FLAG_HQ_ANYWHERE_RUNTIME HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" node "$FLAG_SCRIPT"; }
missing_uid() { env -u HQ_COMPANY_UID -u HQ_FLAG_HQ_ANYWHERE_RUNTIME HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_TEST_FLAG=true node "$FLAG_SCRIPT"; }
override() { env -u HQ_TEST_FLAG HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_FLAG_HQ_ANYWHERE_RUNTIME="$1" node "$FLAG_SCRIPT"; }
count=0
failed=0
assert_value() {
  local name="$1" expected="$2" actual
  shift 2
  if ! actual="$("$@" 2>"$TMP/stderr")"; then
    printf 'FAIL %s: command failed\n' "$name"
    failed=$((failed + 1))
  elif [ "$actual" != "$expected" ]; then
    printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  else
    printf 'PASS %s: %s\n' "$name" "$actual"
  fi
  count=$((count + 1))
}
assert_value 'missing endpoint defaults on' true missing_endpoint
assert_value 'missing company UID defaults on' true missing_uid
assert_value 'row true stays on' true flag true
assert_value 'row false stays off' false flag false
assert_value 'row absent defaults on' true flag absent
assert_value 'archived row defaults on' true flag archived
assert_value 'reader throw defaults on' true flag unreadable
grep -q 'using default-on behavior' "$TMP/stderr"
assert_value 'cached explicit false survives a read failure' false flag stale-false
assert_value 'cached explicit false survives a thrown read' false flag stale-false-throw
assert_value 'reader timeout defaults on' true flag timeout
assert_value 'local override false stays off' false override false
assert_value 'local override zero stays off' false override 0
printf 'Assertions: %s; failures: %s\n' "$count" "$failed"
[ "$failed" -eq 0 ]
