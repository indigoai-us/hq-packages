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
for (const file of ['.claude-plugin/plugin.json', 'hooks/hooks.json', '.mcp.json']) {
  if (!fs.existsSync(path.join(root, 'plugins/hq-anywhere', file))) throw new Error(`Claude plugin is missing ${file}`);
}
for (const file of ['hooks/codex-hooks.json', 'mcp/hq-anywhere.json']) {
  if (!fs.existsSync(path.join(root, 'packages/hq-pack-hq-anywhere', file))) throw new Error(`Codex pack is missing ${file}`);
}
console.log('PASS hq-anywhere marketplace and pack layout');
NODE
