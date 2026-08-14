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
  set_state "$state"; wait_replicas "$service_name" 5; wait_running_tasks "$service_name" 5
  set_state "$clear"; wait_replicas "$service_name" 0; wait_running_tasks "$service_name" 0
  docker service logs --raw "$(service "$service_name")" > "$SCENARIO_DIR/$provider-swarm-drain.log" 2>&1 || fail_scenario "could not collect $provider drain log"
  case "$provider" in
    github)
      grep -Fq 'preserving the active ephemeral job' "$SCENARIO_DIR/$provider-swarm-drain.log" || fail_scenario 'GitHub busy-hook protection did not engage'
      grep -Fq 'runner exited during drain' "$SCENARIO_DIR/$provider-swarm-drain.log" || fail_scenario 'GitHub runner did not finish during drain'
      ;;
    azure)
      grep -Fq 'one-job agent exited during drain' "$SCENARIO_DIR/$provider-swarm-drain.log" || fail_scenario 'Azure one-job agent did not finish during drain'
      ;;
    gitlab)
      grep -Fq 'completed-after-drain' "$SCENARIO_DIR/$provider-swarm-drain.log" || fail_scenario 'GitLab runner did not complete after SIGQUIT drain'
      ;;
  esac
done
if grep -R -F 'cancelled' "$SCENARIO_DIR" >/dev/null; then
  fail_scenario 'an active CI job was cancelled'
fi
finish_scenario PASS 'five wrapper iterations and real PR10 wrappers in Swarm 5→0 drains passed for GitHub busy hook, Azure --once, and GitLab SIGQUIT'
