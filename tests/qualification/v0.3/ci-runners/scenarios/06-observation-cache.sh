#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 06 'Observation cache and config invalidation'

# Cache scope is a controller process. Temporarily use one DEDA replica so the
# simulator counter has one unambiguous observer.
docker service scale "$(service deda)=1" >/dev/null
wait_until 'one DEDA replica for cache measurement' 60 bash -c "[[ \"\$(docker service ps '$(service deda)' --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true)\" == 1 ]]" || fail_scenario 'could not isolate one controller replica'
set_state '{"reset":true,"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
update_ephemeral_service --label-add com.deda.autoscale.trigger.refreshSeconds=15 "$(service github-runner)" >/dev/null
baseline=$(github_observations)
[[ -n "$baseline" ]] || baseline=0
wait_until 'first GitHub observation after config change' 45 github_observation_greater_than "$baseline"
initial=$(github_observations); sleep 6; within=$(github_observations)
[[ "$within" == "$initial" ]] || fail_scenario "GitHub cache fetched again inside refresh window ($initial → $within)"
sleep 11; after_expiry=$(github_observations)
(( after_expiry > within )) || fail_scenario 'GitHub cache did not refresh after expiry'
before_invalidation=$(github_observations)
update_ephemeral_service --label-add com.deda.autoscale.trigger.refreshSeconds=1 "$(service github-runner)" >/dev/null
wait_until 'new GitHub observation after configuration invalidation' 45 github_observation_greater_than "$before_invalidation"
docker service scale "$(service deda)=2" >/dev/null
finish_scenario PASS 'GitHub-specific observation was retained within refreshSeconds; expiry and label change fetched fresh state'
