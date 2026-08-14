#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 10 'CI telemetry and observation lifecycle cleanup'
dotnet test "$REPO_ROOT/Deda.sln" --configuration Release --no-build --filter 'FullyQualifiedName~ServiceLifecycleRemoval_EvictsCachedObservation' > "$SCENARIO_DIR/lifecycle-cleanup-tests.txt" 2>&1 || fail_scenario 'CI lifecycle cache eviction test failed'
set_state '{"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
wait_replicas github-runner 1
old_service=$(service github-runner)
wait_until 'CI telemetry for managed GitHub runner' 45 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS 'http://$(service deda):8080/metrics' | grep -F 'service=\"$old_service\"' >/dev/null" || fail_scenario 'GitHub CI telemetry was not emitted'
before=$(request_count)
docker service rm "$old_service" >/dev/null
wait_until 'GitHub runner service deletion' 60 bash -c "! docker service inspect '$old_service' >/dev/null 2>&1" || fail_scenario 'GitHub runner service was not deleted'
wait_until 'stale GitHub CI telemetry removal' 60 bash -c "! docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS 'http://$(service deda):8080/metrics' | grep -F 'service=\"$old_service\"' >/dev/null" || fail_scenario 'stale GitHub CI telemetry remained after service deletion'
docker stack deploy -c "$SCRIPT_DIR/stack/stack.yml" "$DEDA_QUAL_STACK" >/dev/null
wait_until 'recreated GitHub runner service' 60 bash -c "docker service inspect '$old_service' >/dev/null 2>&1" || fail_scenario 'GitHub runner service was not recreated'
wait_for_endpoint_observation_after "$before" '/actions/' 'fresh GitHub provider observation after service recreation'
wait_replicas github-runner 1
set_state '{"github":{"runs":[],"jobs":[]}}'; wait_replicas github-runner 0
finish_scenario PASS 'deleted-service telemetry was removed and recreated service fetched a fresh provider observation'
