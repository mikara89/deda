#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 10 'CI telemetry and observation lifecycle cleanup'

dump_recreation_evidence() {
  local dest=$1
  mkdir -p "$dest"
  printf 'old_service=%s\nold_service_id=%s\nnew_service_id=%s\n' \
    "${old_service:-}" "${old_service_id:-}" "${new_service_id:-}" > "$dest/service-identity.txt"
  docker service inspect "$old_service" > "$dest/github-runner-inspect.json" 2>&1 || true
  docker service ls > "$dest/docker-service-ls.txt" 2>&1 || true
  docker service logs --tail 400 "$(service deda)" > "$dest/deda-logs.txt" 2>&1 || true
  docker run --rm --network "${DEDA_QUAL_STACK}_control" curlimages/curl:8.10.1 -fsS "http://$(service deda):8080/metrics" > "$dest/deda-metrics.txt" 2>&1 || true
  grep -E 'deda_ci_|service="' "$dest/deda-metrics.txt" > "$dest/deda-ci-metrics.txt" 2>&1 || true
  {
    printf 'old_id_in_metrics=%s\n' "$(grep -F "$old_service_id" "$dest/deda-metrics.txt" >/dev/null && echo yes || echo no)"
    printf 'new_id_in_metrics=%s\n' "$(grep -F "$new_service_id" "$dest/deda-metrics.txt" >/dev/null && echo yes || echo no)"
    printf 'service_name_in_metrics=%s\n' "$(grep -F "service=\"$old_service\"" "$dest/deda-metrics.txt" >/dev/null && echo yes || echo no)"
  } > "$dest/telemetry-identity.txt"
  simulator_get /__admin/requests > "$dest/simulator-requests.json" 2>&1 || true
  jq -r '{count,endpoints:[.requests[]?.endpoint]}' "$dest/simulator-requests.json" > "$dest/simulator-request-summary.json" 2>&1 || true
}

dotnet test "$REPO_ROOT/Deda.sln" --configuration Release --no-build --filter 'FullyQualifiedName~ServiceLifecycleRemoval_EvictsCachedObservation' > "$SCENARIO_DIR/lifecycle-cleanup-tests.txt" 2>&1 || fail_scenario 'CI lifecycle cache eviction test failed'
set_state '{"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
wait_replicas github-runner 1
old_service=$(service github-runner)
old_service_id=$(docker service inspect "$old_service" --format '{{.ID}}')
[[ -n "$old_service_id" ]] || fail_scenario 'could not read the original GitHub runner service ID'
wait_until 'CI telemetry for managed GitHub runner' 45 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS 'http://$(service deda):8080/metrics' | grep -F 'service=\"$old_service\"' >/dev/null" || fail_scenario 'GitHub CI telemetry was not emitted'
docker service rm "$old_service" >/dev/null
wait_until 'GitHub runner service deletion' 60 bash -c "! docker service inspect '$old_service' >/dev/null 2>&1" || fail_scenario 'GitHub runner service was not deleted'
wait_until 'stale GitHub CI telemetry removal' 60 bash -c "! docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS 'http://$(service deda):8080/metrics' | grep -F 'service=\"$old_service\"' >/dev/null" || fail_scenario 'stale GitHub CI telemetry remained after service deletion'
docker stack deploy -c "$SCRIPT_DIR/stack/stack.yml" "$DEDA_QUAL_STACK" >/dev/null
wait_until 'recreated GitHub runner service' 60 bash -c "docker service inspect '$old_service' >/dev/null 2>&1" || fail_scenario 'GitHub runner service was not recreated'
new_service_id=$(docker service inspect "$old_service" --format '{{.ID}}')
[[ -n "$new_service_id" && "$old_service_id" != "$new_service_id" ]] || fail_scenario "recreated GitHub runner reused service ID ${old_service_id:-empty}"
wait_until 'provider simulator health after stack redeploy' 90 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/healthz' >/dev/null" || fail_scenario 'simulator did not become healthy after stack redeploy'
wait_until 'DEDA readiness after stack redeploy' 90 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS 'http://$(service deda):8080/health/ready' >/dev/null" || fail_scenario 'DEDA did not become ready after stack redeploy'
set_state '{"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
before=$(latest_request_at)
dump_recreation_evidence "$SCENARIO_DIR/after-redeploy"
if ! wait_until 'fresh GitHub provider observation after service recreation' 45 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -e --arg since '$before' --arg fragment '/actions/' 'any(.requests[]?; (.endpoint | contains(\$fragment)) and .at > \$since)' >/dev/null"; then
  dump_recreation_evidence "$SCENARIO_DIR/after-observation-timeout"
  fail_scenario 'timed out waiting for fresh GitHub provider observation after service recreation'
fi
wait_replicas github-runner 1
set_state '{"github":{"runs":[],"jobs":[]}}'; wait_replicas github-runner 0
finish_scenario PASS 'deleted-service telemetry was removed and recreated service fetched a fresh provider observation'
