#!/usr/bin/env bash
set -euo pipefail
# Runs on manager-1 under systemd. It contains no Hetzner credential.
RUN_ID=${1:?RUN_ID required}; DURATION_SECONDS=${2:?duration seconds required}; STACK=${3:-deda-qual}; SERVICE_COUNT=${4:-20}
root="/var/lib/deda-qualification/$RUN_ID/soak"; mkdir -p "$root"; started=$(date -u +%s); status=PASS; reason=''; redis_stopped=0
metric=deda_qual_soak_metric; network="${STACK}_control"; consecutive_readiness_failures=0; cycle=0
stats_service="${STACK}-soak-node-stats"; stale_metric_check=NOT_RUN; recovery_checks=0
declare -a soak_services=()

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$root/driver.log"; }
network_curl() { docker run --rm --network "$network" curlimages/curl:8.10.1 --silent --show-error "$@"; }
lease_owner() { docker run --rm --network "$network" redis:7-alpine redis-cli -h redis GET deda-qualification:leader 2>/dev/null | tr -d '\r'; }
set_metric() { printf '%s %s\n' "$metric" "$1" | docker run --rm -i --network "$network" curlimages/curl:8.10.1 --fail --silent --show-error --data-binary @- http://pushgateway:9091/metrics/job/deda-soak >/dev/null; }
wait_deda() { local attempt running; for ((attempt=1; attempt<=90; attempt++)); do running=$(docker service ps "${STACK}_deda" --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true); [[ "$running" == 2 ]] && return 0; sleep 2; done; return 1; }

sample() {
  local expected=$1 http_status owner service actual mismatches=0
  local -a local_deda=()
  http_status=$(network_curl --output /dev/null --write-out '%{http_code}' http://deda:8080/health/ready 2>/dev/null || true)
  owner=$(lease_owner || true)
  {
    printf '\n=== %s readiness=%s lease_owner=%s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${http_status:-unreachable}" "${owner:-none}"
    docker node ls
    docker service ls
    docker service ps "${STACK}_deda" --no-trunc
    docker service ps "${STACK}_basic-worker" --no-trunc
    mapfile -t local_deda < <(docker ps --filter "label=com.docker.swarm.service.name=${STACK}_deda" --format '{{.ID}}')
    ((${#local_deda[@]} == 0)) || docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' "${local_deda[@]}" 2>/dev/null || true
  } >> "$root/samples.txt"
  printf '# sample %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$root/deda-metrics.txt"
  network_curl http://deda:8080/metrics >> "$root/deda-metrics.txt" 2>/dev/null || true
  printf '\n' >> "$root/deda-metrics.txt"
  if [[ "$http_status" == 200 ]]; then consecutive_readiness_failures=0; else consecutive_readiness_failures=$((consecutive_readiness_failures + 1)); fi
  if (( consecutive_readiness_failures >= 3 )); then reason='DEDA readiness failed for three consecutive samples'; return 1; fi
  if [[ -z "$owner" ]]; then reason='No Redis lease owner during a normal soak sample'; return 1; fi
  actual=$(docker service inspect "${STACK}_basic-worker" --format '{{.Spec.Mode.Replicated.Replicas}}')
  if [[ "$actual" != "$expected" ]]; then printf '%s expected=%s actual=%s\n' "${STACK}_basic-worker" "$expected" "$actual" >> "$root/recovery-failures.txt"; mismatches=$((mismatches + 1)); fi
  for service in "${soak_services[@]}"; do
    actual=$(docker service inspect "$service" --format '{{.Spec.Mode.Replicated.Replicas}}')
    if [[ "$actual" != "$expected" ]]; then printf '%s expected=%s actual=%s\n' "$service" "$expected" "$actual" >> "$root/recovery-failures.txt"; mismatches=$((mismatches + 1)); fi
  done
  recovery_checks=$((recovery_checks + 1))
  if (( mismatches > 0 )); then reason="$mismatches soak services failed to reach replicas=$expected"; return 1; fi
}

force_current_leader() {
  local owner task container_id node_id constraint=''
  owner=$(lease_owner); [[ -n "$owner" ]] || { reason='No Redis lease owner before leader disturbance'; return 1; }
  while read -r task; do
    [[ -n "$task" ]] || continue
    read -r container_id node_id < <(docker inspect "$task" --format '{{.Status.ContainerStatus.ContainerID}} {{.NodeID}}')
    if [[ "$owner" == "${container_id:0:12}"* ]]; then constraint="node.id!=$node_id"; break; fi
  done < <(docker service ps "${STACK}_deda" --filter desired-state=running --format '{{.ID}}')
  [[ -n "$constraint" ]] || { reason="Could not map lease owner $owner to a running DEDA task"; return 1; }
  log "forcing-current-leader owner=$owner constraint=$constraint"
  docker service update --constraint-add "$constraint" "${STACK}_deda" >/dev/null
  wait_deda
  docker service update --constraint-rm "$constraint" "${STACK}_deda" >/dev/null
}

disturb() {
  case $1 in
    0) force_current_leader;;
    1) redis_stopped=1; docker service scale "${STACK}_redis=0" >/dev/null; sleep 15; docker service scale "${STACK}_redis=1" >/dev/null; redis_stopped=0;;
    2) docker service update --force "${STACK}_rabbitmq" >/dev/null;;
    3) docker service update --force "${STACK}_prometheus" >/dev/null;;
    4) docker service update --label-add "deda.qual.soak.external=$(date -u +%s)" "${STACK}_basic-worker" >/dev/null;;
  esac
}

finalize() {
  local rc=$? ended probe metrics memory_signal=PASS
  trap - EXIT
  if (( rc != 0 )); then status=FAIL; [[ -n "$reason" ]] || reason="driver exited with status $rc"; fi
  if [[ "$redis_stopped" == 1 ]]; then docker service scale "${STACK}_redis=1" >/dev/null 2>&1 || true; fi
  docker service logs --timestamps "${STACK}_deda" > "$root/deda-service.log" 2>&1 || true
  docker service logs --raw "$stats_service" > "$root/node-stats.log" 2>&1 || true
  if [[ $(grep -c ' node=' "$root/node-stats.log" 2>/dev/null || true) -lt 10 ]]; then
    memory_signal=NOT_ENOUGH_DATA
  elif ! awk '
    function kib(v, n) { n=v+0; if (v ~ /GiB$/) return n*1048576; if (v ~ /MiB$/) return n*1024; if (v ~ /KiB$/) return n; if (v ~ /GB$/) return n*1000000; if (v ~ /MB$/) return n*1000; return n/1024 }
    NF >= 6 && $2 ~ /^node=/ { node=$2; sub(/^node=/,"",node); value=kib($5); if (node in last) { if (value >= last[node]) streak[node]++; else { streak[node]=0; base[node]=value } } else base[node]=value; last[node]=value; if (streak[node] >= 10 && value > base[node]*1.5) bad=1 }
    END { exit bad }
  ' "$root/node-stats.log"; then memory_signal=FAIL; status=FAIL; reason='Sustained monotonic DEDA memory growth exceeded 50 percent'; fi
  if (( rc == 0 && ${#soak_services[@]} > 0 )); then
    probe=${soak_services[${#soak_services[@]}-1]}
    docker service rm "$probe" >/dev/null 2>&1 || true
    sleep 10
    metrics=$(network_curl http://deda:8080/metrics 2>/dev/null || true)
    if grep -Fq "service=\"$probe\"" <<< "$metrics"; then status=FAIL; reason="Deleted service metrics remained for $probe"; stale_metric_check=FAIL; else stale_metric_check=PASS; fi
  fi
  for service in "${soak_services[@]}"; do docker service rm "$service" >/dev/null 2>&1 || true; done
  docker service rm "$stats_service" >/dev/null 2>&1 || true
  ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg status "$status" --arg reason "$reason" --arg started "$(date -u -d "@$started" +%Y-%m-%dT%H:%M:%SZ)" --arg ended "$ended" --arg stale "$stale_metric_check" --arg memory "$memory_signal" --argjson duration "$DURATION_SECONDS" --argjson services "$SERVICE_COUNT" --argjson recovery_checks "$recovery_checks" \
    '{status:$status,reason:$reason,started:$started,ended:$ended,duration_seconds:$duration,service_count:$services,analysis:{stale_deleted_service_metrics:$stale,sustained_memory_growth:$memory,recovery_checks:$recovery_checks,node_stats:"node-stats.log",metrics:"deda-metrics.txt"}}' > "$root/result.json"
  log "completed status=$status reason=${reason:-none}"
  exit "$rc"
}
trap 'status=FAIL; reason="driver command failed at line $LINENO"' ERR
trap finalize EXIT

log "creating $SERVICE_COUNT soak services"
docker service rm "$stats_service" >/dev/null 2>&1 || true
docker service create --quiet --mode global --name "$stats_service" --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --env "TARGET_SERVICE=${STACK}_deda" docker:27.5.1-cli sh -ec \
  'node=$(hostname); while true; do ids=$(docker ps --filter "label=com.docker.swarm.service.name=$TARGET_SERVICE" --format "{{.ID}}"); if [ -n "$ids" ]; then docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" $ids | while IFS= read -r stat; do printf "%s node=%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$node" "$stat"; done; fi; sleep 60; done' >/dev/null
for i in $(seq 1 "$SERVICE_COUNT"); do
  service=$(printf '%s-soak-%02d' "$STACK" "$i"); soak_services+=("$service")
  docker service rm "$service" >/dev/null 2>&1 || true
  docker service create --quiet --name "$service" --network "$network" --replicas 1 \
    --label com.deda.autoscale.enabled=true --label com.deda.autoscale.min=1 --label com.deda.autoscale.max=3 \
    --label com.deda.autoscale.targetPerReplica=10 --label com.deda.autoscale.cooldownSeconds=0 \
    --label com.deda.autoscale.scaleDownDelaySeconds=0 --label com.deda.autoscale.trigger.type=prometheus \
    --label com.deda.autoscale.trigger.url=http://prometheus:9090 --label "com.deda.autoscale.trigger.query=$metric" \
    alpine:3.22 sleep infinity >/dev/null
done
docker service update --label-add "com.deda.autoscale.trigger.query=$metric" "${STACK}_basic-worker" >/dev/null

phase=0
while (( $(date -u +%s) - started < DURATION_SECONDS )); do
  case $phase in 0) value=10; label=low;; 1) value=30; label=high;; 2) value=20; label=medium;; 3) value=0; label=zero;; *) value=10; label=recovery;; esac
  expected=$(((value + 9) / 10)); (( expected < 1 )) && expected=1
  log "phase=$label metric=$value expected_replicas=$expected cycle=$cycle"; set_metric "$value"; sleep 90; sample "$expected"
  if (( phase == 4 )); then log "recoverable-disturbance=$((cycle % 5))"; disturb $((cycle % 5)); cycle=$((cycle + 1)); fi
  phase=$(((phase + 1) % 5))
done
