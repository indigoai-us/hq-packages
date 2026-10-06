#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1/core" ]]; then
  echo "usage: scripts/sync-hq-anywhere-from-core-staging.sh <hq-core-staging-checkout>" >&2
  exit 2
fi

core_root=$(cd "$1" && pwd -P)
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
for builder in build-claude-plugin.sh build-codex-pack.sh; do
  if [[ ! -x "$core_root/core/scripts/$builder" ]]; then
    echo "error: missing executable builder: $core_root/core/scripts/$builder" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

bash "$core_root/core/scripts/build-claude-plugin.sh" "$tmp/claude-plugin"
bash "$core_root/core/scripts/build-codex-pack.sh" "$tmp/codex-pack"

[[ -f "$tmp/claude-plugin/.claude-plugin/plugin.json" ]] || { echo 'error: Claude builder omitted plugin manifest' >&2; exit 1; }
[[ -f "$tmp/codex-pack/package.yaml" ]] || { echo 'error: Codex builder omitted package.yaml' >&2; exit 1; }

mkdir -p "$repo_root/plugins" "$repo_root/packages"
rm -rf "$repo_root/plugins/hq-anywhere" "$repo_root/packages/hq-pack-hq-anywhere"
mv "$tmp/claude-plugin" "$repo_root/plugins/hq-anywhere"
mv "$tmp/codex-pack" "$repo_root/packages/hq-pack-hq-anywhere"
echo 'Synced HQ Anywhere Claude plugin and Codex pack from hq-core-staging builders.'
