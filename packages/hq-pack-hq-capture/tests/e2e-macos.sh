#!/usr/bin/env bash
# macOS end-to-end checks against the real HQ desktop app (macOS 26 or later). Not part of the
# any-OS suite.
#
# 1. Recordings made with the standalone HQ Capture still work with the bundled one: for each
#    package given, /record-process `run describe` (the HQ Capture inside the HQ desktop app)
#    returns the same description as the standalone app's own --describe. Read-only: the package
#    is cloned into a temporary HQ first. No window and no permission.
#      HQ_CAPTURE_E2E_PACKAGES  .hqrec packages made by the standalone app, separated by ':'
#      HQ_CAPTURE_STANDALONE    the standalone app (default:
#                               ~/Library/Application Support/HQ Capture/HQ Capture.app)
#      HQ_DESKTOP_APP           the HQ desktop app (default: the installed one)
# 2. With HQ_CAPTURE_E2E_LIVE=1 only: start asks the HQ desktop app to open the recorder for a
#    temporary company, which opens a real window (or HQ's permission window first), then stop
#    closes it. Nothing is recorded.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "e2e-macos.sh needs macOS" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$here/../scripts/hq-record-process.sh"

tmp="$(mktemp -d)"
trap 'HQ_ROOT="$tmp/hq" bash "$R" stop >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/hq" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "core hq-session get company_slug" ] && cat "$HQ_E2E_COMPANY_FILE"
EOF
chmod +x "$tmp/bin/hq"
export PATH="$tmp/bin:$PATH" HQ_ROOT="$tmp/hq" HQ_E2E_COMPANY_FILE="$tmp/company"

field() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2"; }
expect() { [ "$2" = "$3" ] || { echo "FAIL: $1: expected $3, got $2" >&2; exit 1; }; echo "ok: $1"; }

doc="$(bash "$R" doctor)" || { echo "FAIL: doctor: $doc" >&2; exit 1; }
echo "ok: doctor finds $(field "$doc" hq_capture_detail)"

standalone="${HQ_CAPTURE_STANDALONE:-$HOME/Library/Application Support/HQ Capture/HQ Capture.app}"
standalone_exe="$standalone/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$standalone/Contents/Info.plist")"
echo "standalone HQ Capture $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$standalone/Contents/Info.plist")"

IFS=: read -r -a packages <<<"${HQ_CAPTURE_E2E_PACKAGES:-}"
[ "${#packages[@]}" -gt 0 ] && [ -n "${packages[0]}" ] || { echo "Set HQ_CAPTURE_E2E_PACKAGES" >&2; exit 2; }
for given in "${packages[@]}"; do
  company="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["company"])' "$given/manifest.json")"
  mkdir -p "$tmp/hq/companies/$company/recordings"
  printf 'companies:\n  %s:\n    name: E2E\n' "$company" >"$tmp/hq/companies/manifest.yaml"
  printf '%s' "$company" >"$tmp/company"
  copy="$tmp/hq/companies/$company/recordings/$(basename "$given")"
  rm -rf "$copy"
  cp -cR "$given" "$copy" 2>/dev/null || cp -R "$given" "$copy"
  bundled="$(bash "$R" run describe "$copy" --json)"
  reference="$("$standalone_exe" --describe "$copy" --json)"
  expect "$(basename "$given"): the bundled app describes it as the standalone app does" "$bundled" "$reference"
done

if [ "${HQ_CAPTURE_E2E_LIVE:-}" = 1 ]; then
  mkdir -p "$tmp/hq/companies/e2e-capture/recordings"
  printf 'companies:\n  e2e-capture:\n    name: E2E\n' >"$tmp/hq/companies/manifest.yaml"
  printf 'e2e-capture' >"$tmp/company"
  out="$(bash "$R" start)"
  state="$(field "$out" state)"
  case "$state" in
    awaiting-start|waiting-permission) echo "ok: start through the HQ desktop app: $state" ;;
    *) echo "FAIL: start: $out" >&2; exit 1 ;;
  esac
  if [ "$state" = awaiting-start ]; then
    expect "no recording written on open" "$(ls -A "$tmp/hq/companies/e2e-capture/recordings" | wc -l | tr -d ' ')" "0"
    expect "stop closes the recorder" "$(field "$(bash "$R" stop)" state)" "closed"
  fi
fi
echo "e2e-macos: passed"
