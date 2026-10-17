#!/usr/bin/env bash
# Runs in the shell suite on every platform; the macOS build checks behavior.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sources="$here/../app/Sources"
if grep -nE '@(SwiftUI\.)?(State|Entry|Animatable|AnimatableIgnored)([^[:alnum:]_]|$)|#Preview[ (]' "$sources"/*.swift; then
  echo "Use CaptureState for state; CLT does not ship SwiftUIMacros/PreviewsMacros." >&2
  exit 1
fi
# Keep Apple's DynamicProperty and binding behavior, rather than a custom wrapper.
grep -Fxq 'typealias CaptureState<Value> = SwiftUI.State<Value>' "$sources/CaptureState.swift"
echo "ok: Capture uses the SwiftUI State property wrapper without the State macro"
