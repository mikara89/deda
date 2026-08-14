#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=09; start_scenario "$id" 'Direct Docker socket smoke'; dir=$(scenario_dir "$id"); direct="${QUAL_STACK}-direct-deda"; worker="${QUAL_STACK}-direct-worker"
main_services=("${QUAL_STACK}_basic-worker" "${QUAL_STACK}_zero-worker" "${QUAL_STACK}_rabbit-worker")
isolated=0
cleanup() {
  manager_exec "docker service rm '$direct' '$worker' >/dev/null 2>&1 || true" || true
  if [[ "$isolated" == 1 ]]; then
    for service in "${main_services[@]}"; do manager_exec "docker service update --label-add com.deda.autoscale.enabled=true '$service'" >/dev/null 2>&1 || true; done
    manager_exec "docker service scale '${QUAL_STACK}_deda=2'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
isolated=1
for service in "${main_services[@]}"; do manager_exec "docker service update --label-add com.deda.autoscale.enabled=false '$service'" >/dev/null; done
manager_exec "docker service scale '${QUAL_STACK}_deda=0'" > "$dir/main-ha-pause.txt"; wait_service_running "${QUAL_STACK}_deda" 0
manager_exec "docker service create --name '$worker' --network '$(network_name)' --replicas 1 --label com.deda.autoscale.enabled=true --label com.deda.autoscale.min=1 --label com.deda.autoscale.max=3 --label com.deda.autoscale.targetPerReplica=10 --label com.deda.autoscale.cooldownSeconds=0 --label com.deda.autoscale.scaleDownDelaySeconds=0 --label com.deda.autoscale.trigger.type=prometheus --label com.deda.autoscale.trigger.url=http://prometheus:9090 --label 'com.deda.autoscale.trigger.query=vector(30)' alpine:3.22 sleep infinity" >/dev/null
manager_exec "docker service create --name '$direct' --network '$(network_name)' --user 0:0 --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock --env DOCKER_HOST=unix:///var/run/docker.sock --env DEDA_POLL_SECONDS=2 --env DEDA_HTTP_PORT=8080 '$DEDA_IMAGE'" > "$dir/direct-service.txt"
wait_service_running "$direct" 1; network_curl "http://$direct:8080/health/ready" > "$dir/direct-readiness.txt" || fail_scenario "$id" 'Direct-socket DEDA did not become ready.'; wait_replicas "$worker" 3
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(10)' '$worker'" >/dev/null; wait_replicas "$worker" 1
manager_exec "docker service rm '$direct' '$worker'" >/dev/null
for service in "${main_services[@]}"; do manager_exec "docker service update --label-add com.deda.autoscale.enabled=true '$service'" >/dev/null; done
manager_exec "docker service scale '${QUAL_STACK}_deda=2'" > "$dir/main-ha-restore.txt"; wait_service_running "${QUAL_STACK}_deda" 2
wait_for 'main HA DEDA readiness after direct-mode isolation' 90 2 network_curl --output /dev/null 'http://deda:8080/health/ready'
isolated=0
capture_cluster "$dir"; finish_scenario "$id" PASS 'HA controllers were paused and autoscaled services disabled while the isolated direct-socket controller scaled its worker up and down; HA readiness recovered afterward.'
