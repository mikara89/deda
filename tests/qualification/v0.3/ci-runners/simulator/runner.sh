#!/bin/sh
set -eu
duration=${SIMULATED_JOB_SECONDS:-12}
provider=${SIMULATED_PROVIDER:-unknown}
job="${HOSTNAME:-task}"
printf 'job=%s provider=%s event=started at=%s\n' "$job" "$provider" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sleep "$duration" & child=$!
drain() {
  printf 'job=%s provider=%s event=drain-signal signal=%s at=%s\n' "$job" "$provider" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  wait "$child"
  printf 'job=%s provider=%s event=completed-after-drain at=%s\n' "$job" "$provider" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
}
trap 'drain TERM' TERM
trap 'drain QUIT' QUIT
wait "$child"
printf 'job=%s provider=%s event=completed at=%s\n' "$job" "$provider" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
