#!/usr/bin/env bash
set -Eeuo pipefail

runner_home=${RUNNER_HOME:-/opt/actions-runner}
token_file=${GITHUB_RUNNER_ADMIN_TOKEN_FILE:-/run/secrets/github-runner-admin}
api_url=${GITHUB_API_URL:-https://api.github.com}
scope=${GITHUB_RUNNER_SCOPE:-org}
owner=${GITHUB_OWNER:?GITHUB_OWNER is required}
repository=${GITHUB_REPOSITORY:-}
labels=${GITHUB_RUNNER_LABELS:-self-hosted,linux,deda}
runner_name=${GITHUB_RUNNER_NAME:-deda-gh-${HOSTNAME}}
cleanup_retries=${GITHUB_CLEANUP_RETRIES:-3}
cleanup_delay=${GITHUB_CLEANUP_DELAY_SECONDS:-5}
runner_pid=
configured=false
draining=false

log() { printf '%s github-runner: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
require_secret() { test -r "$token_file" && test -s "$token_file" || { log "registration secret is missing or empty"; exit 1; }; }
api() { curl --fail --silent --show-error --location --retry 3 --retry-all-errors --proto '=https' --tlsv1.2 -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $(<"$token_file")" -H 'X-GitHub-Api-Version: 2022-11-28' "$@"; }
token_endpoint() {
  case "$scope" in
    org) printf '%s/orgs/%s/actions/runners/registration-token' "$api_url" "$owner" ;;
    repo) test -n "$repository" || { log "GITHUB_REPOSITORY is required for repo scope"; exit 1; }; printf '%s/repos/%s/actions/runners/registration-token' "$api_url" "$repository" ;;
    *) log "GITHUB_RUNNER_SCOPE must be org or repo"; exit 1 ;;
  esac
}
remove_endpoint() {
  case "$scope" in org) printf '%s/orgs/%s/actions/runners/remove-token' "$api_url" "$owner" ;; repo) printf '%s/repos/%s/actions/runners/remove-token' "$api_url" "$repository" ;; esac
}
cleanup() {
  local remove_token attempt=1
  test "$configured" = true || return 0
  log "removing runner registration"
  while ! remove_token=$(api -X POST "$(remove_endpoint)" | jq -er '.token'); do
    if (( attempt >= cleanup_retries )); then log "could not obtain removal token within the cleanup bound; ephemeral runner will be removed by GitHub"; return 0; fi
    log "removal-token API unavailable; retrying (${attempt}/${cleanup_retries})"
    attempt=$((attempt + 1)); sleep "$cleanup_delay"
  done
  "$runner_home/config.sh" remove --unattended --token "$remove_token" >/dev/null 2>&1 || log "runner was already removed or provider cleanup was unavailable"
}
drain() {
  draining=true
  log "shutdown requested; asking runner to stop after its current work"
  test -n "$runner_pid" && kill -TERM "$runner_pid" 2>/dev/null || true
}
wait_for_runner() {
  local status
  while true; do
    wait "$runner_pid" && return 0
    status=$?
    # A trapped TERM interrupts bash's wait before the runner process is reaped.
    # Keep waiting during drain so an active job is not abandoned by the wrapper.
    if "$draining" && { test "$status" -eq 143 || test "$status" -eq 130; } && kill -0 "$runner_pid" 2>/dev/null; then continue; fi
    return "$status"
  done
}
trap drain TERM INT
trap cleanup EXIT

require_secret
registration_token=$(api -X POST "$(token_endpoint)" | jq -er '.token') || { log "could not obtain registration token"; exit 1; }
"$runner_home/config.sh" --unattended --url "https://github.com/${repository:-$owner}" --token "$registration_token" --name "$runner_name" --labels "$labels" --ephemeral --disableupdate --replace
unset registration_token
configured=true
"$runner_home/run.sh" & runner_pid=$!
wait_for_runner || exit=$?
runner_pid=
if "$draining"; then log "runner exited during drain"; fi
exit "${exit:-0}"
