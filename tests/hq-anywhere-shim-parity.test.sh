#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
plugin="$root/plugins/hq-anywhere/scripts/hq/hqd-hook-shim.sh"
codex="$root/packages/hq-pack-hq-anywhere/hooks/codex-hook-shim.sh"
plugin_flags="$root/plugins/hq-anywhere/scripts/hq/hqd-hook-flag-cache-lib.sh"
codex_flags="$root/packages/hq-pack-hq-anywhere/hooks/hqd-hook-flag-cache-lib.sh"
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

helper_index=0
for helper in "$plugin_flags" "$codex_flags"; do
  helper_index=$((helper_index + 1))
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$helper" >"$tmp/helper-$helper_index.flag-lines"
done
if ! cmp -s "$tmp/helper-1.flag-lines" "$tmp/helper-2.flag-lines"; then
  echo 'FAIL plugin and Codex hqd flag helpers diverge in behavior-bearing lines' >&2
  diff -u "$tmp/helper-1.flag-lines" "$tmp/helper-2.flag-lines" || true
  exit 1
fi
echo 'PASS plugin and Codex hqd flag helpers have identical behavior-bearing lines'
