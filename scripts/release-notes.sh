#!/bin/bash
# Prints Markdown release notes for the commits since a tag (all commits when none is given),
# grouped by conventional-commit type. Commit bodies are kept as sub-items.
#   scripts/release-notes.sh v0.1.4
set -euo pipefail
cd "$(dirname "$0")/.."

RANGE="${1:+$1..}HEAD"
declare -a FEAT=() FIX=() OTHER=()
while IFS= read -r -d $'\x1e' entry; do
  subject="${entry%%$'\x1f'*}"
  body="${entry#*$'\x1f'}"
  subject="${subject#$'\n'}"
  [ -z "$subject" ] && continue
  case "$subject" in
    *"[skip release]"*|"Merge "*) continue ;;
  esac
  # Strip the "type(scope): " prefix for display.
  text="$(sed -E 's/^[a-z]+(\([^)]*\))?!?: //' <<<"$subject")"
  item="- $text"
  details="$(grep -E '^[[:space:]]*[-*] ' <<<"$body" | sed -E 's/^[[:space:]]*[-*] /  - /' || true)"
  [ -n "$details" ] && item+=$'\n'"$details"
  case "$subject" in
    feat*) FEAT+=("$item") ;;
    fix*) FIX+=("$item") ;;
    *) OTHER+=("$item") ;;
  esac
done < <(git log --reverse --format='%s%x1f%b%x1e' "$RANGE")

section() {
  local title="$1"; shift
  [ $# -eq 0 ] && return
  printf '### %s\n\n' "$title"
  printf '%s\n' "$@"
  printf '\n'
}
section "新功能" ${FEAT[@]+"${FEAT[@]}"}
section "修复" ${FIX[@]+"${FIX[@]}"}
section "其他改动" ${OTHER[@]+"${OTHER[@]}"}
