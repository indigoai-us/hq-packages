#!/usr/bin/env bash
# CI entry: run the pack's existing shell tests from packages/*/tests/*.test.sh
set -euo pipefail
PACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shopt -s nullglob
found=0
for t in "$PACK"/scripts/__tests__/*.test.sh; do
  found=1
  echo "::group::$(basename "$t")"
  bash "$t"
  echo "::endgroup::"
done
test "$found" -eq 1
test -f "$PACK/package.yaml"
test -f "$PACK/package.json"
test -f "$PACK/skills/work-mesh/SKILL.md"
test -x "$PACK/scripts/apply.sh"
grep -q 'version: 0.2.0' "$PACK/package.yaml"
test ! -f "$PACK/scripts/install-listen.sh"
test ! -f "$PACK/hooks/SessionStart/60-work-mesh-bin.sh"
echo "pack-shell.test: ok"
