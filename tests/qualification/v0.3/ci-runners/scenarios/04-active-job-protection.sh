#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 04 'Active job protection and GitHub dispatch-race contracts'

# The real runner wrappers are exercised with five deterministic busy jobs per
# provider. They hold their child job through Swarm's termination signal, then
# clean up only after it completes. Keeping this outside the provider simulator
# avoids pretending that an API response alone proves runner signal behavior.
for iteration in $(seq 1 5); do
  bash "$REPO_ROOT/tests/ci-runners/lifecycle-tests.sh" > "$SCENARIO_DIR/lifecycle-$iteration.log" 2>&1 || fail_scenario "runner lifecycle iteration $iteration failed"
done
for provider in github azure gitlab; do
  service_name="$provider-runner"
  case "$provider" in
    github) state='{"github":{"runs":[{"id":1,"status":"in_progress"}],"jobs":[{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]}]}}'; clear='{"github":{"runs":[],"jobs":[]}}' ;;
    azure) state='{"azure":{"jobs":[{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["deda","Agent.OS -equals Linux"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null}]}}'; clear='{"azure":{"jobs":[]}}' ;;
    gitlab) state='{"gitlab":{"jobs":[{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]}]}}'; clear='{"gitlab":{"jobs":[]}}' ;;
  esac
  for drain_run in $(seq 1 3); do
    drain_started_at=$(utc_now)
    set_state "$state"; wait_replicas "$service_name" 5; wait_running_tasks "$service_name" 5
    started_jobs=0
    for _ in $(seq 1 90); do
      started_jobs=$(docker service logs --since "$drain_started_at" --raw "$(service "$service_name")" 2>/dev/null | grep -c "provider=$provider event=started" || true)
      (( started_jobs >= 5 )) && break
      sleep 1
    done
    (( started_jobs >= 5 )) || fail_scenario "$provider drain run $drain_run did not start all five active jobs before downscale"
    log_file="$SCENARIO_DIR/$provider-swarm-drain-$drain_run.log"
    set_state "$clear"; wait_replicas "$service_name" 0
    sleep 5
    docker service logs --since "$drain_started_at" --raw "$(service "$service_name")" > "$log_file" 2>&1 \
      || fail_scenario "could not collect $provider drain run $drain_run log"
    wait_running_tasks "$service_name" 0
    case "$provider" in
      github)
        if ! grep -Fq 'preserving the active ephemeral job' "$log_file"; then
          cat "$log_file" >&2 || true
          fail_scenario "GitHub busy-hook protection did not engage on drain run $drain_run"
        fi
        grep -Fq 'runner exited during drain' "$log_file" || fail_scenario "GitHub runner did not finish during drain run $drain_run"
        ;;
      azure)
        grep -Fq 'one-job agent exited during drain' "$log_file" || fail_scenario "Azure one-job agent did not finish during drain run $drain_run"
        ;;
      gitlab)
        grep -Fq 'completed-after-drain' "$log_file" || fail_scenario "GitLab runner did not complete after SIGQUIT drain run $drain_run"
        ;;
    esac
  done
done
if grep -R -F 'cancelled' "$SCENARIO_DIR" >/dev/null; then
  fail_scenario 'an active CI job was cancelled'
fi
finish_scenario PASS 'five wrapper iterations and three real PR10 wrapper Swarm 5→0 drains per provider passed for GitHub busy hook, Azure --once, and GitLab SIGQUIT'
