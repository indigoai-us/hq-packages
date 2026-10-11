#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
plugin="$root/plugins/hq-anywhere/scripts/hq/hqd-hook-shim.sh"
codex="$root/packages/hq-pack-hq-anywhere/hooks/codex-hook-shim.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for shim in "$plugin" "$codex"; do
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$shim" >"$tmp/$(basename "$(dirname "$shim")").lines"
done
if ! cmp -s "$tmp/hq.lines" "$tmp/hooks.lines"; then
  echo 'FAIL plugin and Codex hqd shims diverge in behavior-bearing lines' >&2
  diff -u "$tmp/hq.lines" "$tmp/hooks.lines" || true
  exit 1
fi
echo 'PASS plugin and Codex hqd shims have identical behavior-bearing lines'
