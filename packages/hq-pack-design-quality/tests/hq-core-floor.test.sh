#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
pack_root=${HQ_PACK_ROOT:-$repo_root}

node - "$pack_root" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const root = process.argv[2];
const manifestPath = path.join(root, 'packages/hq-pack-design-quality/package.yaml');
const manifest = fs.readFileSync(manifestPath, 'utf8');
const match = manifest.match(/^\s*hqCore:\s*['"]?>?=?\s*([0-9]+\.[0-9]+\.[0-9]+)['"]?\s*$/m);
if (!match) throw new Error(`missing requires.hqCore in ${manifestPath}`);

const required = [15, 0, 179];
const actual = match[1].split('.').map(Number);
const comparison = actual.findIndex((part, index) => part !== required[index]);
if (comparison >= 0 && actual[comparison] < required[comparison]) {
  throw new Error(`requires.hqCore ${match[1]} is below 15.0.179 for hq core scan-packages`);
}
console.log(`hq-core floor ${match[1]} satisfies hq core scan-packages`);
NODE
