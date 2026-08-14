#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

printf '%s\n' '{"locations":[{"id":1,"name":"nbg1","available":true,"recommended":true}]}' |
  server_type_available_in_location nbg1
printf '%s\n' '{"locations":[{"location":{"name":"hel1"},"available":true,"recommended":false}]}' |
  server_type_available_in_location hel1
if printf '%s\n' '{"locations":[{"id":1,"name":"fsn1","available":false}]}' |
  server_type_available_in_location fsn1; then
  die 'Unavailable server-type fixture unexpectedly passed.'
fi

for fixture in '24h 86400' '30m 1800' '1h 3600'; do
  read -r duration expected <<< "$fixture"
  actual=$(duration_to_seconds "$duration")
  [[ "$actual" == "$expected" ]] || die "Duration $duration produced $actual seconds; expected $expected."
done

for invalid in 0h 24 foo; do
  if duration_to_seconds "$invalid" >/dev/null; then
    die "Invalid duration $invalid unexpectedly passed."
  fi
done

printf 'Qualification static tests passed.\n'
