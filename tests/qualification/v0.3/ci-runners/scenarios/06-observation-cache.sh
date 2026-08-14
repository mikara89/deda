#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 06 'Observation cache and config invalidation'

# Cache scope is a controller process. Temporarily use one DEDA replica so the
# simulator counter has one unambiguous observer.
docker service scale "$(service deda)=1" >/dev/null
wait_until 'one DEDA replica for cache measurement' 60 bash -c "[[ \"\$(docker service ps '$(service deda)' --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true)\" == 1 ]]" || fail_scenario 'could not isolate one controller replica'
set_state '{"reset":true,"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
github_baseline=$(provider_request_count '/actions/')
docker service update --label-add com.deda.autoscale.trigger.refreshSeconds=15 "$(service github-runner)" >/dev/null
wait_for_endpoint_observation_after "$github_baseline" '/actions/' 'first GitHub observation after config change'
initial=$(provider_request_count '/actions/'); sleep 6; within=$(provider_request_count '/actions/')
[[ "$within" == "$initial" ]] || fail_scenario "cache fetched again inside refresh window ($initial → $within)"
sleep 11; after_expiry=$(provider_request_count '/actions/')
(( after_expiry > within )) || fail_scenario 'cache did not refresh after expiry'
docker service update --label-add com.deda.autoscale.trigger.refreshSeconds=1 "$(service github-runner)" >/dev/null
wait_for_endpoint_observation_after "$after_expiry" '/actions/' 'new GitHub observation after configuration invalidation'
docker service scale "$(service deda)=2" >/dev/null
finish_scenario PASS 'GitHub-specific observation was retained within refreshSeconds; expiry and label change fetched fresh state'
