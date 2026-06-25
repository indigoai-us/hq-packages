#!/usr/bin/env bash
# Regression: every worker.yaml shipped by hq-pack-gstack MUST carry a non-empty
# worker-level `description:` field. Without it, HQ's generate-workers-registry.sh
# quarantines the worker ("missing required field(s): description") on every
# registry regeneration and excludes it from registry.yaml.
#
# Real incident (feedback_7e9f86f8 / feedback_95f58261): the published pack
# shipped gstack-team and gstack-sprint worker.yaml WITHOUT this field, so both
# workers were quarantined for every user and no core upgrade could fix it.
set -euo pipefail

PACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKERS_DIR="$PACK/workers"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$WORKERS_DIR" ] || fail "no workers/ directory at $WORKERS_DIR"

# Extract the worker-level description (direct child of the top-level `worker:`
# mapping). Prefer yq; fall back to a grep that matches the 2-space-indented
# `description:` line (the per-skill descriptions are nested deeper, so a
# single leading 2-space indent uniquely identifies the worker-level field).
worker_description() {
  local file="$1"
  if command -v yq >/dev/null 2>&1; then
    yq -r '.worker.description // ""' "$file" 2>/dev/null
  else
    # First `^  description:` line == worker-level field; strip key, quotes, ws.
    grep -m1 -E '^  description:[[:space:]]*' "$file" 2>/dev/null \
      | sed -E 's/^  description:[[:space:]]*//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' \
      | sed -E 's/[[:space:]]+$//'
  fi
}

count=0
while IFS= read -r -d '' wy; do
  count=$((count + 1))
  desc="$(worker_description "$wy")"
  rel="${wy#"$PACK"/}"
  case "$desc" in
    ""|null|"~") fail "$rel: missing/empty worker-level description (would be quarantined on registry regen)" ;;
  esac
done < <(find "$WORKERS_DIR" -type f -name worker.yaml -print0)

[ "$count" -gt 0 ] || fail "no worker.yaml files found under $WORKERS_DIR"

echo "worker-descriptions: ok ($count worker.yaml file(s) checked, all carry a worker-level description)"
