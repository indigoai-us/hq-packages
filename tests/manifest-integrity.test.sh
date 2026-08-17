#!/usr/bin/env bash
# Release-metadata integrity, enforced BEFORE merge.
#
# Why this exists
# ---------------
# release.yml already asserts both of these invariants, but it only runs on push
# to main — after the bad metadata has landed. Over the 30 days to 2026-08-17
# that workflow failed on 10 of 17 pushes, and 5 of those were this exact
# version-parity guard firing on a merge that had already happened:
#
#   package.json version '1.6.0' does not match package.yaml version '1.8.0'
#   package.json version '1.5.1' does not match package.yaml version '1.6.0'
#
# Nothing was ever wrong with the guard; it was simply the last line of defence
# instead of the first, so every mismatch became a red release run and a
# follow-up commit. Running the same assertions in the required `shell-tests`
# check means the PR that introduces a mismatch cannot merge.
#
# The release-time guards are deliberately KEPT as defence in depth. This is an
# earlier copy of them, not a replacement — a direct push to main, or an edit
# that bypasses the check, still gets stopped before publishing.
#
# Run locally: bash tests/manifest-integrity.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Must match `expected_repo` in .github/workflows/release.yml. npm trusted
# publishing matches the repository URL, so a wrong value here fails at publish
# time with an opaque permission error rather than an obvious one.
EXPECTED_REPO='https://github.com/indigoai-us/hq-packages.git'

failures=0
checked=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

shopt -s nullglob
for package_json in packages/*/package.json; do
  package_dir="$(dirname "$package_json")"

  # python3 rather than node: this job installs no toolchain, and python3 is
  # present on every runner. Emits `private<TAB>version<TAB>repo_url`.
  fields="$(python3 - "$package_json" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    pkg = json.load(fh)

repo = pkg.get("repository")
if isinstance(repo, str):
    url = repo
elif isinstance(repo, dict):
    url = repo.get("url") or ""
else:
    url = ""

print(
    "\t".join(
        [
            "true" if pkg.get("private") is True else "false",
            str(pkg.get("version") or ""),
            url,
        ]
    )
)
PY
  )" || { fail "$package_json is not valid JSON"; continue; }

  IFS=$'\t' read -r is_private version repo_url <<<"$fields"

  if [ "$is_private" = "true" ]; then
    echo "skip: $package_dir (private)"
    continue
  fi

  checked=$((checked + 1))

  if [ -z "$version" ]; then
    fail "$package_json has no version"
    continue
  fi

  # A publishable pack MUST have package.yaml. packages/README.md states that
  # "Each pack declares package.yaml at its root" and that the installer
  # "Validates package.yaml against the schema", so a pack without one is
  # unusable once published.
  #
  # release.yml only checks the version WHEN the file happens to exist
  # (`if [[ -f "$package_manifest" ]]`). That is a hole rather than a
  # deliberate allowance: adding a publishable package with no package.yaml, or
  # deleting an existing manifest, skips the version check entirely and lets an
  # unusable pack publish green. Requiring it here closes that at the PR, and
  # costs nothing today — all seven current publishable packs have one.
  package_manifest="$package_dir/package.yaml"
  if [ ! -f "$package_manifest" ]; then
    fail "$package_dir is publishable but has no package.yaml (required root manifest; the installer validates it)"
    continue
  fi

  # Same parser as release.yml uses, so the two cannot disagree about what the
  # manifest version is.
  manifest_version="$(sed -n 's/^version:[[:space:]]*//p' "$package_manifest")"
  if [ -z "$manifest_version" ]; then
    fail "$package_manifest has no version: line (package.json is '$version')"
  elif [ "$manifest_version" != "$version" ]; then
    fail "$package_json version '$version' does not match $package_manifest version '$manifest_version'"
  fi

  if [ "$repo_url" != "$EXPECTED_REPO" ]; then
    fail "$package_json repository.url must be '$EXPECTED_REPO' for npm trusted publishing (got '${repo_url:-missing}')"
  fi
done

if [ "$checked" -eq 0 ]; then
  fail "no publishable packages found under packages/*/package.json — the glob is wrong or the layout moved"
fi

if [ "$failures" -ne 0 ]; then
  printf '\nmanifest integrity FAILED (%s problem(s)) across %s publishable package(s)\n' \
    "$failures" "$checked" >&2
  exit 1
fi

printf 'manifest integrity passed: %s publishable package(s) consistent\n' "$checked"
