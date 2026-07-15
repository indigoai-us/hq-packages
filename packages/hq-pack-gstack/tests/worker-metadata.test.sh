#!/usr/bin/env bash
# Regression: worker IDs contribute to one global registry namespace. A duplicate
# ID causes registry generation to abort, so every contributed worker must have a
# globally unique ID and all registry-required metadata fields.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKERS_DIR="$ROOT/packages"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Return a direct child of the top-level `worker:` mapping. This avoids matching
# similarly named fields in nested configuration blocks without requiring yq.
worker_field() {
  local file="$1" field="$2"

  awk -v field="$field" '
    $0 == "worker:" { in_worker = 1; next }
    in_worker && /^[^[:space:]]/ { exit }
    in_worker && $0 ~ ("^  " field ":[[:space:]]*") {
      sub("^  " field ":[[:space:]]*", "")
      sub(/[[:space:]]+#.*/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 ~ /^".*"$/) {
        sub(/^"/, "")
        sub(/"$/, "")
      } else if ($0 ~ /^\047.*\047$/) {
        sub(/^\047/, "")
        sub(/\047$/, "")
      }
      print
      exit
    }
  ' "$file"
}

declare -A worker_files=()
count=0
while IFS= read -r -d '' worker; do
  count=$((count + 1))
  rel="${worker#"$ROOT"/}"

  for field in id type description; do
    value="$(worker_field "$worker" "$field")"
    case "$value" in
      ""|null|"~") fail "$rel: missing/empty worker.$field" ;;
    esac
  done

  id="$(worker_field "$worker" id)"
  if [[ -n "${worker_files[$id]+set}" ]]; then
    fail "duplicate worker.id '$id' in $rel and ${worker_files[$id]}"
  fi
  worker_files["$id"]="$rel"
done < <(find "$WORKERS_DIR" -type f -name worker.yaml -print0)

[ "$count" -gt 0 ] || fail "no worker.yaml files found under packages/"

echo "worker-metadata: ok ($count worker.yaml file(s) checked; ids unique; id/type/description present)"
