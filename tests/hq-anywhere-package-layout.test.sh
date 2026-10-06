#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

node - "$repo_root" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const marketplace = JSON.parse(fs.readFileSync(path.join(root, '.claude-plugin/marketplace.json'), 'utf8'));
if (marketplace.name !== 'hq-packages') throw new Error('marketplace name must be hq-packages');
const plugin = marketplace.plugins?.find((entry) => entry.name === 'hq');
if (!plugin || plugin.source !== './plugins/hq-anywhere') throw new Error('marketplace must source the HQ plugin from plugins/hq-anywhere');
const codexManifest = fs.readFileSync(path.join(root, 'packages/hq-pack-hq-anywhere/package.yaml'), 'utf8');
if (!/^name:\s*hq-anywhere\s*$/m.test(codexManifest)) throw new Error('Codex package must preserve the hq-anywhere alias name');
const codexPack = path.join(root, 'packages/hq-pack-hq-anywhere');
const hooksSection = codexManifest.match(/^  hooks:\r?\n((?:    - [^\r\n]+\r?\n)+)/mu)?.[1];
if (!hooksSection) throw new Error('Codex pack manifest must declare its hook payloads');
const declaredHooks = hooksSection.split(/\r?\n/u).map(line => line.trim().replace(/^-\s+/u, '')).filter(Boolean);
for (const hook of declaredHooks) {
  const payload = path.join(codexPack, 'hooks', `${hook}.sh`);
  if (!fs.existsSync(payload)) throw new Error(`contributes.hooks declares "${hook}" but payload file missing: hooks/${hook}.sh`);
}
const codexHooks = JSON.parse(fs.readFileSync(path.join(codexPack, 'hooks/codex-hooks.json'), 'utf8')).hooks;
for (const [event, groups] of Object.entries(codexHooks)) {
  for (const group of groups) for (const entry of group.hooks) {
    if (entry.command !== 'hooks/codex.sh') throw new Error(`${event} must run the declared hooks/codex.sh entry point`);
    if (!fs.existsSync(path.resolve(codexPack, entry.command))) throw new Error(`${event} Codex hook target is missing: ${entry.command}`);
  }
}
const codexEntry = fs.readFileSync(path.join(codexPack, 'hooks/codex.sh'), 'utf8');
if (!/exec \/bin\/sh "\$hook_dir\/codex-hook-shim\.sh" --runtime codex/u.test(codexEntry)) {
  throw new Error('Codex hook entry point must forward to the flag-aware shared shim with runtime codex');
}
for (const file of ['.claude-plugin/plugin.json', 'hooks/hooks.json', '.mcp.json']) {
  if (!fs.existsSync(path.join(root, 'plugins/hq-anywhere', file))) throw new Error(`Claude plugin is missing ${file}`);
}
for (const file of ['hooks/codex-hooks.json', 'mcp/hq-anywhere.json']) {
  if (!fs.existsSync(path.join(codexPack, file))) throw new Error(`Codex pack is missing ${file}`);
}
console.log('PASS hq-anywhere marketplace and pack layout');
NODE

codex_hook_home=$(mktemp -d)
trap 'rm -rf "$codex_hook_home"' EXIT
printf '%s\n' '{"hook_event_name":"SessionStart","cwd":"/tmp/foreign-repo"}' |
  env -i "PATH=$PATH" "HOME=$codex_hook_home" /bin/sh "$repo_root/packages/hq-pack-hq-anywhere/hooks/codex.sh" >"$codex_hook_home/stdout" 2>"$codex_hook_home/stderr"
test ! -s "$codex_hook_home/stdout"
test ! -s "$codex_hook_home/stderr"
