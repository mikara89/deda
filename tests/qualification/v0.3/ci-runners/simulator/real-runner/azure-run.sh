#!/bin/sh
set -eu

duration=${SIMULATED_JOB_SECONDS:-45}
job=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo task)
: > /tmp/deda-azure-agent.busy
printf 'job=%s provider=azure event=started at=%s\n' "$job" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

trap 'printf "job=%s provider=azure event=cancelled at=%s\n" "$job" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; rm -f /tmp/deda-azure-agent.busy; exit 99' TERM INT
sleep "$duration"
rm -f /tmp/deda-azure-agent.busy
printf 'job=%s provider=azure event=completed at=%s\n' "$job" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
