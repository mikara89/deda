#!/bin/sh
set -eu

duration=${SIMULATED_JOB_SECONDS:-30}
job=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo task)
printf 'job=%s provider=github event=started at=%s\n' "$job" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -n "${ACTIONS_RUNNER_HOOK_JOB_STARTED:-}" ]; then
  "$ACTIONS_RUNNER_HOOK_JOB_STARTED"
fi

trap 'printf "job=%s provider=github event=cancelled at=%s\n" "$job" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; exit 99' TERM INT
sleep "$duration"

if [ -n "${ACTIONS_RUNNER_HOOK_JOB_COMPLETED:-}" ]; then
  "$ACTIONS_RUNNER_HOOK_JOB_COMPLETED"
fi
printf 'job=%s provider=github event=completed at=%s\n' "$job" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
