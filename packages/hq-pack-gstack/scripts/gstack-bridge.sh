#!/usr/bin/env bash
# gstack-bridge.sh — Materialize gstack skills into HQ with g- prefix
#
# Usage:
#   scripts/gstack-bridge.sh install   # Create g-* skills in .claude/skills/
#   scripts/gstack-bridge.sh remove    # Remove bridge-owned g-* skills
#   scripts/gstack-bridge.sh status    # Show bridge state
#   scripts/gstack-bridge.sh update    # git pull gstack + re-install

set -euo pipefail

resolve_physical_script() {
  local source="${BASH_SOURCE[0]}" directory
  while [[ -L "${source}" ]]; do
    directory="$(cd -P "$(dirname "${source}")" && pwd)"
    source="$(readlink "${source}")"
    [[ "${source}" == /* ]] || source="${directory}/${source}"
  done
  printf '%s\n' "${source}"
}

find_hq_root() {
  local candidate="$1"
  while [[ "${candidate}" != / ]]; do
    if [[ -f "${candidate}/core/core.yaml" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    candidate="$(dirname "${candidate}")"
  done
  return 1
}

SCRIPT_PATH="$(resolve_physical_script)"
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_PATH}")" && pwd)"
if [[ -n "${HQ_ROOT:-}" ]]; then
  HQ_ROOT="$(cd "${HQ_ROOT}" && pwd)"
else
  HQ_ROOT="$(find_hq_root "${SCRIPT_DIR}")" || {
    echo "ERROR: could not find HQ root (expected core/core.yaml); set HQ_ROOT to override" >&2
    exit 1
  }
fi
GSTACK_DIR="${HQ_ROOT}/repos/public/gstack"
HQ_SKILLS_DIR="${HQ_ROOT}/.claude/skills"

# Directories in gstack that are NOT skills (no SKILL.md)
INFRA_DIRS=("agents" "bin" "docs" "scripts" "supabase" "test")

# Skills to explicitly skip even though they have SKILL.md
SKIP_SKILLS=("browse")  # 58MB Playwright binary; HQ has agent-browser

usage() {
  cat <<'EOF'
gstack-bridge — Materialize gstack skills into HQ with g- prefix

Usage:
  scripts/gstack-bridge.sh install   Create g-* skills in .claude/skills/
  scripts/gstack-bridge.sh remove    Remove bridge-owned g-* skills
  scripts/gstack-bridge.sh status    Show bridge state
  scripts/gstack-bridge.sh update    git pull gstack + re-install
EOF
}

is_skipped() {
  local name="$1"
  for skip in "${SKIP_SKILLS[@]}"; do
    [[ "$name" == "$skip" ]] && return 0
  done
  for infra in "${INFRA_DIRS[@]}"; do
    [[ "$name" == "$infra" ]] && return 0
  done
  return 1
}

frontmatter_name() {
  local value
  value="$(awk '
    NR == 1 { in_frontmatter = ($0 == "---"); next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && $0 ~ /^name:[[:space:]]*/ {
      sub(/^name:[[:space:]]*/, "")
      sub(/[[:space:]]+#.*/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      exit
    }
  ' "$1")"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s\n' "${value}"
}

rewrite_skill_name() {
  local skill_file="$1" skill_name="$2" temp_file
  temp_file="$(mktemp "${skill_file}.XXXXXX")"

  if [[ "$(head -n 1 "${skill_file}")" == "---" ]]; then
    awk -v skill_name="${skill_name}" '
      NR == 1 { in_frontmatter = 1; print; next }
      in_frontmatter && $0 == "---" {
        if (!replaced) print "name: " skill_name
        in_frontmatter = 0
        print
        next
      }
      in_frontmatter && $0 ~ /^name:[[:space:]]*/ {
        if (!replaced) print "name: " skill_name
        replaced = 1
        next
      }
      { print }
    ' "${skill_file}" > "${temp_file}"
  else
    {
      printf '%s\n' '---' "name: ${skill_name}" '---'
      cat "${skill_file}"
    } > "${temp_file}"
  fi

  mv "${temp_file}" "${skill_file}"
}

resolved_link_target() {
  local link="$1" target directory
  target="$(readlink "${link}")" || return 1
  if [[ "${target}" != /* ]]; then
    directory="$(cd -P "$(dirname "${link}")" && pwd)"
    target="${directory}/${target}"
  fi
  directory="$(cd -P "$(dirname "${target}")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "${directory}" "$(basename "${target}")"
}

is_bridge_install() {
  local target="$1" source
  if [[ -L "${target}" ]]; then
    source="$(resolved_link_target "${target}" 2>/dev/null || true)"
  elif [[ -f "${target}/.hq-gstack-bridge-source" ]]; then
    source="$(<"${target}/.hq-gstack-bridge-source")"
  else
    return 1
  fi
  [[ "${source}" == "${GSTACK_DIR}/"* ]]
}

registered_name_conflict() {
  local required_name="$1" ignored_target="$2" skill_file skill_dir existing_name
  for skill_file in "${HQ_SKILLS_DIR}"/*/SKILL.md; do
    [[ -f "${skill_file}" ]] || continue
    skill_dir="$(dirname "${skill_file}")"
    [[ "${skill_dir}" == "${ignored_target}" ]] && continue
    existing_name="$(frontmatter_name "${skill_file}")"
    if [[ "${existing_name}" == "${required_name}" ]]; then
      echo "ERROR: registered skill name '${required_name}' is already provided by ${skill_dir}" >&2
      return 0
    fi
  done
  return 1
}

install_bridge() {
  if [[ ! -d "${GSTACK_DIR}" ]]; then
    echo "ERROR: gstack not cloned. Run:" >&2
    echo "  git clone https://github.com/garrytan/gstack repos/public/gstack" >&2
    exit 1
  fi

  mkdir -p "${HQ_SKILLS_DIR}"

  local skill_dir name source target

  # Validate every target before changing any existing bridge installation.
  for skill_dir in "${GSTACK_DIR}"/*/; do
    [[ -d "${skill_dir}" ]] || continue
    name="$(basename "${skill_dir}")"
    is_skipped "${name}" && continue
    [[ -f "${skill_dir}SKILL.md" ]] || continue

    target="${HQ_SKILLS_DIR}/g-${name}"
    if registered_name_conflict "g-${name}" "${target}"; then
      exit 1
    fi
    if [[ -e "${target}" || -L "${target}" ]] && ! is_bridge_install "${target}"; then
      echo "BLOCKED  g-${name}: target exists but is not owned by gstack-bridge" >&2
      exit 1
    fi
  done

  local installed=0 skipped=0 updated=0

  for skill_dir in "${GSTACK_DIR}"/*/; do
    [[ -d "${skill_dir}" ]] || continue
    local name
    name="$(basename "${skill_dir}")"

    # Skip non-skill directories
    if is_skipped "${name}"; then
      ((skipped++)) || true
      continue
    fi

    # Skip dirs without SKILL.md
    if [[ ! -f "${skill_dir}SKILL.md" ]]; then
      ((skipped++)) || true
      continue
    fi

    local target="${HQ_SKILLS_DIR}/g-${name}"
    local source="${skill_dir%/}"

    if [[ -e "${target}" || -L "${target}" ]]; then
      if [[ -L "${target}" ]]; then
        rm "${target}"
      else
        rm -rf "${target}"
      fi
      ((updated++)) || true
    fi

    cp -R "${source}" "${target}"
    rewrite_skill_name "${target}/SKILL.md" "g-${name}"
    printf '%s\n' "${source}" > "${target}/.hq-gstack-bridge-source"
    echo "INSTALLED  g-${name}"
    ((installed++)) || true
  done

  echo ""
  echo "Done: ${installed} installed, ${updated} updated, ${skipped} skipped"
}

remove_bridge() {
  local removed=0
  local target
  for target in "${HQ_SKILLS_DIR}"/g-*; do
    [[ -e "${target}" || -L "${target}" ]] || continue
    if is_bridge_install "${target}"; then
      rm -rf "${target}"
      echo "REMOVED  $(basename "${target}")"
      ((removed++)) || true
    fi
  done
  echo "${removed} bridge skills removed"
}

status_bridge() {
  local count=0
  echo "gstack skills in .claude/skills/:"
  echo ""
  local target
  for target in "${HQ_SKILLS_DIR}"/g-*; do
    [[ -e "${target}" || -L "${target}" ]] || continue
    if is_bridge_install "${target}"; then
      local name
      name="$(basename "${target}")"
      local valid="OK"
      [[ -f "${target}/SKILL.md" ]] || valid="BROKEN"
      printf "  %-30s %s\n" "${name}" "${valid}"
      ((count++)) || true
    fi
  done
  echo ""
  echo "Total: ${count} installed"
  echo "Skipped: browse (use /agent-browser)"
  echo ""
  echo "gstack version: $(cat "${GSTACK_DIR}/VERSION" 2>/dev/null || echo "unknown")"
}

update_bridge() {
  if [[ ! -d "${GSTACK_DIR}" ]]; then
    echo "ERROR: gstack not cloned. Run install first." >&2
    exit 1
  fi

  echo "Pulling gstack..."
  (cd "${GSTACK_DIR}" && git pull)
  echo ""
  echo "Re-installing..."
  install_bridge
}

case "${1:-}" in
  install) install_bridge ;;
  remove)  remove_bridge ;;
  status)  status_bridge ;;
  update)  update_bridge ;;
  *)       usage; exit 1 ;;
esac
