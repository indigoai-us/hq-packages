#!/usr/bin/env bash
# End-to-end install check for hq-pack-booking. Needs the real `hq` CLI.
#
# Builds a throwaway HQ root, installs this pack into it from its local path with
# `hq install`, runs `hq core scan-packages`, and checks that:
#   - .claude/skills/booking resolves to the pack's skill
#   - the knowledge and launcher are wired
#   - the installed launcher validates an example config for a bound company
# Nothing outside the throwaway root is touched.
#
# Usage: bash tests/e2e-install.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pack="$(cd "$here/.." && pwd)"
command -v hq >/dev/null 2>&1 || { echo "FAIL the hq CLI is required" >&2; exit 1; }

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/companies/acme" "$root/core/packages" "$root/core/scripts" "$root/.claude/skills"
printf 'companies:\n  acme:\n    name: Acme\n' >"$root/companies/manifest.yaml"
hq_version="$(hq core version 2>/dev/null | head -1 | tr -d '[:space:]')"
printf 'hqVersion: "%s"\n' "${hq_version:-15.0.179}" >"$root/core/core.yaml"

failures=0
check() { if eval "$2"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); fi; }

install_log="$(cd "$root" && hq install "$pack" --allow-unsigned 2>&1)"
install_rc=$?
check "hq install from the local path exits 0" '[ "$install_rc" -eq 0 ]'
[ "$install_rc" -eq 0 ] || printf '%s\n' "$install_log" | tail -20 >&2
check "pack landed in core/packages" '[ -f "$root/core/packages/hq-pack-booking/package.yaml" ]'

scan_log="$(hq core --hq-root "$root" scan-packages 2>&1)"
scan_rc=$?
check "scan-packages exits 0" '[ "$scan_rc" -eq 0 ]'
[ "$scan_rc" -eq 0 ] || printf '%s\n' "$scan_log" | tail -20 >&2

skill="$root/.claude/skills/booking"
check "/booking skill is discoverable" '[ -f "$skill/SKILL.md" ]'
check "/booking resolves to the pack skill" '[ "$(cd "$skill" && pwd -P)" = "$(cd "$root/core/packages/hq-pack-booking/skills/booking" && pwd -P)" ]'
check "booking knowledge is wired" '[ -e "$root/core/knowledge/booking" ] || [ -e "$root/core/knowledge/public/booking" ]'

launcher="$root/core/packages/hq-pack-booking/scripts/hq-booking.sh"
[ -e "$root/core/scripts/hq-booking.sh" ] && launcher="$root/core/scripts/hq-booking.sh"
mkdir -p "$root/companies/acme/booking"
cp "$pack/knowledge/booking/examples/solo-consultant.yaml" "$root/companies/acme/booking/booking.yaml"
bin="$(mktemp -d)"
cat >"$bin/hq" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "core hq-session get company_slug" ] && { printf acme; exit 0; }
exit 9
EOF
chmod +x "$bin/hq"
validate_out="$(cd "$root" && PATH="$bin:$PATH" bash "$launcher" validate 2>&1)"
validate_rc=$?
rm -rf "$bin"
check "installed launcher validates the company's booking.yaml" '[ "$validate_rc" -eq 0 ]'
[ "$validate_rc" -eq 0 ] || printf '%s\n' "$validate_out" >&2

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "e2e install passed" || echo "e2e install: $failures failed")"
[ "$failures" -eq 0 ]
