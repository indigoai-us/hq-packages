#!/usr/bin/env bash
set -euo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PACK_DIR/scripts/client-workspace.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/companies/agency/clients/client"
printf 'engagement\n' > "$ROOT/companies/agency/clients/client/engagement.md"
out="$(bash "$SCRIPT" --firm agency --client client --mode company --root "$ROOT" 2>&1)"

grep -Fq 'hq core hq-session add company client' <<< "$out"
grep -Fq 'hq core hq-session remove company client' <<< "$out"
if grep -Eq 'hq-session\.sh|core/scripts/hq-session' <<< "$out"; then
  printf 'FAIL: output still calls the hq-session forwarder\n' >&2
  exit 1
fi

printf 'PASS: company-mode instructions call hq core hq-session\n'
