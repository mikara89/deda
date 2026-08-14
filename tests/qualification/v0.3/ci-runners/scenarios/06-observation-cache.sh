#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 06 'Observation cache and config invalidation'

# Cache scope is a controller process. Temporarily use one DEDA replica so the
# simulator counter has one unambiguous observer.
docker service scale "$(service deda)=1" >/dev/null
wait_until 'one DEDA replica for cache measurement' 60 bash -c "[[ \"\$(docker service ps '$(service deda)' --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true)\" == 1 ]]" || fail_scenario 'could not isolate one controller replica'
set_state '{"reset":true,"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
docker service update --label-add com.deda.autoscale.trigger.refreshSeconds=15 "$(service github-runner)" >/dev/null
wait_until 'first GitHub observation after config change' 45 bash -c "[[ \"\$(docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -r .count)\" -ge 2 ]]" || fail_scenario 'initial provider observation did not occur'
initial=$(request_count); sleep 6; within=$(request_count)
[[ "$within" == "$initial" ]] || fail_scenario "cache fetched again inside refresh window ($initial → $within)"
sleep 11; after_expiry=$(request_count)
(( after_expiry > within )) || fail_scenario 'cache did not refresh after expiry'
docker service update --label-add com.deda.autoscale.trigger.refreshSeconds=1 "$(service github-runner)" >/dev/null
wait_until 'new observation after configuration invalidation' 45 bash -c "[[ \"\$(docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -r .count)\" -gt $after_expiry ]]" || fail_scenario 'configuration change did not invalidate cached observation'
docker service scale "$(service deda)=2" >/dev/null
finish_scenario PASS 'one observation was retained within refreshSeconds; expiry and label change fetched fresh state'
