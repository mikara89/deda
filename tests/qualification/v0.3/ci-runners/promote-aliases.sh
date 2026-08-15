#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

plan_aliases() {
  local v_existing=${1:-} plain_existing=${2:-} want=$3
  check_one() {
    local existing=${1:-}
    [[ -z "$existing" ]] && return 2
    [[ "$existing" == "$want" ]] && return 0
    return 1
  }
  local v_state plain_state
  check_one "$v_existing"; v_state=$?
  check_one "$plain_existing"; plain_state=$?
  if (( v_state == 1 || plain_state == 1 )); then
    printf 'FAIL\n'
    return 1
  fi
  if (( v_state == 2 || plain_state == 2 )); then
    printf 'CREATE\n'
    return 0
  fi
  printf 'OK\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 3 ]] || die 'usage: promote-aliases.sh <v-tag-digest-or-empty> <plain-tag-digest-or-empty> <wanted-digest>'
  plan_aliases "$1" "$2" "$3"
fi
