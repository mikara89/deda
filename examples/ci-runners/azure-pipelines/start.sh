#!/usr/bin/env bash
set -Eeuo pipefail

agent_home=${AZP_AGENT_HOME:-/azp/agent}
token_file=${AZP_TOKEN_FILE:-/run/secrets/ado-agent-registration}
agent_name=${AZP_AGENT_NAME:-deda-ado-${HOSTNAME}}
cleanup_retries=${AZP_CLEANUP_RETRIES:-20}
cleanup_delay=${AZP_CLEANUP_DELAY_SECONDS:-15}
configured=false
agent_pid=
draining=false

log() { printf '%s azure-agent: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
require_secret() { test -r "$token_file" && test -s "$token_file" || { log "registration secret is missing or empty"; exit 1; }; }
cleanup() {
  local attempt=1
  test "$configured" = true || return 0
  log "removing Azure Pipelines agent registration"
  while ! "$agent_home/config.sh" remove --unattended --auth PAT --token "$(<"$token_file")" >/dev/null 2>&1; do
    if (( attempt >= cleanup_retries )); then log "agent removal did not complete before the cleanup bound"; return 0; fi
    log "agent is busy or cleanup API is unavailable; retrying (${attempt}/${cleanup_retries})"
    attempt=$((attempt + 1)); sleep "$cleanup_delay"
  done
}
drain() {
  draining=true
  log "shutdown requested; waiting for the agent's one-job run to finish before cleanup"
  # Do not signal run.sh: Azure's supported remove operation fails while a job is active,
  # so retries provide a bounded, non-interrupting drain within Swarm's stop grace period.
  cleanup
}
wait_for_agent() {
  local status
  while true; do
    wait "$agent_pid" && return 0
    status=$?
    # TERM can interrupt bash's wait while the one-job agent is still finishing.
    if "$draining" && { test "$status" -eq 143 || test "$status" -eq 130; }; then
      # drain() has already waited for supported removal; do not turn a normal
      # Swarm shutdown signal into a failed task merely because wait was interrupted.
      return 0
    fi
    return "$status"
  done
}
trap drain TERM INT
trap cleanup EXIT

: "${AZP_URL:?AZP_URL is required}"
: "${AZP_POOL:?AZP_POOL is required}"
require_secret
"$agent_home/config.sh" --unattended --url "$AZP_URL" --auth PAT --token "$(<"$token_file")" --pool "$AZP_POOL" --agent "$agent_name" --work "${AZP_WORK:-_work}" --replace --acceptTeeEula
configured=true
"$agent_home/run.sh" --once & agent_pid=$!
wait_for_agent || exit=$?
agent_pid=
if "$draining"; then log "one-job agent exited during drain"; fi
exit "${exit:-0}"
