#!/bin/sh
set -eu

config_file=${GITLAB_RUNNER_CONFIG:-/etc/deda-gitlab-runner/config.toml}
token_file=${GITLAB_RUNNER_TOKEN_FILE:-/run/secrets/gitlab-runner-auth}
runner_name=${GITLAB_RUNNER_NAME:-deda-gitlab-${HOSTNAME:-unknown}}
cleanup_retries=${GITLAB_CLEANUP_RETRIES:-3}
cleanup_delay=${GITLAB_CLEANUP_DELAY_SECONDS:-5}
runner_pid=
registered=false
draining=false

log() { printf '%s gitlab-runner: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
require_secret() { test -r "$token_file" && test -s "$token_file" || { log "runner authentication secret is missing or empty"; exit 1; }; }
cleanup() {
  attempt=1
  test "$registered" = true || return 0
  log "removing GitLab runner manager"
  # With a glrt-* authentication token this removes the manager, not the reusable runner.
  while ! gitlab-runner unregister --config "$config_file" --url "$CI_SERVER_URL" --token "$(cat "$token_file")" >/dev/null 2>&1; do
    if [ "$attempt" -ge "$cleanup_retries" ]; then log "runner-manager cleanup was unavailable within the cleanup bound; remove stale managers through GitLab if necessary"; return 0; fi
    log "runner-manager cleanup unavailable; retrying (${attempt}/${cleanup_retries})"
    attempt=$((attempt + 1)); sleep "$cleanup_delay"
  done
}
drain() {
  draining=true
  log "SIGQUIT requested; runner will stop accepting jobs and wait for its active job"
  test -n "$runner_pid" && kill -QUIT "$runner_pid" 2>/dev/null || true
}
trap drain QUIT
trap drain TERM INT
trap cleanup EXIT

: "${CI_SERVER_URL:?CI_SERVER_URL is required}"
require_secret
mkdir -p "$(dirname "$config_file")"
# This task-local file also leaves .runner_system_id task-local; no identity is baked
# into the image or shared by replicas. Registration appends its runner entry.
printf 'concurrent = 1\ncheck_interval = 0\n' > "$config_file"
chmod 600 "$config_file"
gitlab-runner register --non-interactive --config "$config_file" --url "$CI_SERVER_URL" --token "$(cat "$token_file")" --name "$runner_name" --executor shell
registered=true
chmod 600 "$config_file"
gitlab-runner run --config "$config_file" --user ci-job --working-directory /home/ci-job & runner_pid=$!
while true; do
  if wait "$runner_pid"; then break; fi
  exit=$?
  if [ "$draining" = true ] && kill -0 "$runner_pid" 2>/dev/null; then continue; fi
  exit "$exit"
done
runner_pid=
exit "${exit:-0}"
