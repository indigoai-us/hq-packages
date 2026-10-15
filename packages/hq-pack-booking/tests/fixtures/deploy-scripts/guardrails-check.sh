#!/usr/bin/env bash
# Test stand-in for the /deploy skill's guardrails-check.sh (used only when the
# real skill is not available). Same contract: <out-dir> [api-dir], run from the
# project root; db/migrations from the root are added; > 100 files fails.
set -u
OUT="$1" API="${2:-}"
[ -d "$OUT" ] || { echo '{"pass":false,"reason":"missing_output_dir"}'; exit 0; }
count=$(find "$OUT" -type f | wc -l | tr -d ' ')
[ -n "$API" ] && count=$((count + $(find "$API" -type f | wc -l | tr -d ' ')))
[ -d ./db/migrations ] && count=$((count + $(find ./db/migrations -type f -name '*.sql' | wc -l | tr -d ' ')))
[ "$count" -le 100 ] || { printf '{"pass":false,"reason":"file_count_exceeded:%s"}\n' "$count"; exit 0; }
tarball="$(mktemp)"
args=(-czf "$tarball" -C "$OUT" .)
[ -n "$API" ] && args+=(-C "$(dirname "$API")" "$(basename "$API")")
[ -d ./db/migrations ] && args+=(-C "$PWD" db/migrations)
tar "${args[@]}" 2>/dev/null || { echo '{"pass":false,"reason":"tar_create_failed"}'; exit 0; }
size=$(wc -c <"$tarball" | tr -d ' ')
printf '{"pass":true,"reason":null,"tarball_path":"%s","size_bytes":%d,"sha256":"-","file_count":%d}\n' "$tarball" "$size" "$count"
