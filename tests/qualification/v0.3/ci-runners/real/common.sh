#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QUAL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
source "$QUAL_ROOT/common.sh"

confirm_real() {
  [[ ${1:-} == --confirm-real-provider-tests ]] || die 'Real-provider qualification requires --confirm-real-provider-tests; credentials alone are never authorization.'
}
require_env() { [[ -n ${!1:-} ]] || die "$1 is required"; }
require_secret_file() { [[ -f ${!1:-} && -r ${!1} ]] || die "$1 must name a readable secret file"; }
secret() { tr -d '\r\n' < "$1"; }
real_result_dir() { printf '%s/real-%s' "$(result_root)" "$1"; }
begin_real() { mkdir -p "$(real_result_dir "$1")"; }
write_real() {
  local provider=$1 status=$2 detail=$3 file
  file="$(real_result_dir "$provider")/result.json"
  jq -n --arg provider "$provider" --arg status "$status" --arg at "$(utc_now)" --arg detail "$detail" '{provider:$provider,status:$status,at:$at,detail:$detail}' > "$file"
}
safe_json() {
  # Keep only provider identifiers, timestamps, and job conclusions. This is
  # intentionally narrower than a raw API response, which could contain URLs
  # or user-supplied metadata inappropriate for release evidence.
  jq -c "$1"
}
poll_for_completion() {
  local description=$1 timeout=$2 check=$3
  local end=$((SECONDS + timeout))
  until eval "$check"; do
    (( SECONDS < end )) || die "Timed out waiting for $description after ${timeout}s"
    sleep 5
  done
}
wait_real() {
  local description=$1 timeout=$2; shift 2
  wait_until "$description" "$timeout" "$@" || die "Timed out waiting for $description"
}
