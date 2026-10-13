#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/native-cli-floor.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

has_core_command() {
  local package="$1"
  grep -R -E -q --include='*.md' --include='*.sh' \
    'hq core (hq-session|scan-packages|generate-workers-registry)' "$package"
}

minimum_hq_core() {
  local package="$1"
  if grep -R -E -q --include='*.md' --include='*.sh' \
      'hq core hq-session (add|remove) company|hq core hq-session get company_slugs' "$package"; then
    printf '16.0.4'
  elif has_core_command "$package"; then
    printf '15.0.179'
  fi
}

declared_hq_core() {
  awk '
    /^requires:/ { in_requires=1; next }
    in_requires && /^[^[:space:]]/ { exit }
    in_requires && /^[[:space:]]+hqCore:/ { print $2; exit }
  ' "$1/package.yaml" | tr -d "\047\"" | sed 's/^>=//'
}

floor_is_sufficient() {
  local package="$1" minimum actual
  minimum="$(minimum_hq_core "$package")"
  [ -n "$minimum" ] || return 0
  actual="$(declared_hq_core "$package")"
  [ -n "$actual" ] || return 1
  awk -v actual="$actual" -v minimum="$minimum" 'BEGIN {
    split(actual, a, /[.]/); split(minimum, m, /[.]/);
    for (i=1; i<=3; i++) {
      if (a[i] > m[i]) exit 0;
      if (a[i] < m[i]) exit 1;
    }
    exit 0;
  }'
}

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$*"; }

# Prove this guard catches an under-declared direct CLI requirement.
mkdir -p "$WORK/too-low/scripts" "$WORK/at-floor/scripts"
cat > "$WORK/too-low/package.yaml" <<'YAML'
requires:
  hqCore: '>=15.0.178'
YAML
cat > "$WORK/at-floor/package.yaml" <<'YAML'
requires:
  hqCore: '>=15.0.179'
YAML
printf '%s\n' 'hq core scan-packages' > "$WORK/too-low/scripts/run.sh"
cp "$WORK/too-low/scripts/run.sh" "$WORK/at-floor/scripts/run.sh"
if floor_is_sufficient "$WORK/too-low"; then
  fail 'accepted hqCore 15.0.178 for hq core scan-packages'
fi
pass 'rejects a synthetic package below the derived CLI floor'
floor_is_sufficient "$WORK/at-floor" || fail 'rejected the derived hqCore floor'
pass 'accepts a synthetic package at the derived CLI floor'

for package in "$ROOT"/packages/hq-pack-*; do
  [ -d "$package" ] || continue
  if has_core_command "$package"; then
    floor_is_sufficient "$package" || fail "${package##*/} declares hqCore below $(minimum_hq_core "$package")"
    pass "${package##*/} declares hqCore >= $(minimum_hq_core "$package")"
  fi
done
