#!/usr/bin/env bash
set -euo pipefail

DEDA_PID=""

cleanup() {
  if [[ -n "$DEDA_PID" ]]; then
    kill "$DEDA_PID" 2>/dev/null || true
    wait "$DEDA_PID" 2>/dev/null || true
  fi
  docker service rm \
    deda-e2e-prom-worker \
    deda-e2e-rabbit-worker \
    deda-e2e-contract \
    deda-e2e-global \
    deda-e2e-prometheus \
    deda-e2e-rabbitmq 2>/dev/null || true
  docker swarm leave --force 2>/dev/null || true
}
trap cleanup EXIT

wait_http() {
  local url="$1"
  local auth="${2:-}"
  for _ in $(seq 1 90); do
    if [[ -n "$auth" ]]; then
      if curl --fail --silent --user "$auth" "$url" >/dev/null; then return 0; fi
    elif curl --fail --silent "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for $url" >&2
  return 1
}

wait_replicas() {
  local service="$1"
  local expected="$2"
  for _ in $(seq 1 90); do
    actual=$(docker service inspect "$service" --format '{{.Spec.Mode.Replicated.Replicas}}')
    if [[ "$actual" == "$expected" ]]; then return 0; fi
    sleep 1
  done
  echo "Timed out waiting for $service desired replicas=$expected (actual=$actual)" >&2
  docker service inspect "$service" --pretty >&2 || true
  tail -200 /tmp/deda-e2e.log >&2 || true
  return 1
}

docker swarm init

docker service create --quiet \
  --name deda-e2e-prometheus \
  --publish published=9090,target=9090 \
  prom/prometheus:v3.5.0

docker service create --quiet \
  --name deda-e2e-rabbitmq \
  --env RABBITMQ_DEFAULT_USER=admin \
  --env RABBITMQ_DEFAULT_PASS=admin \
  --publish published=15672,target=15672 \
  rabbitmq:4.1-management

docker service create --quiet \
  --name deda-e2e-contract \
  --replicas 1 \
  --label com.deda.test=contract \
  alpine:3.22 sleep 3600

docker service create --quiet \
  --name deda-e2e-global \
  --mode global \
  alpine:3.22 sleep 3600

wait_http http://127.0.0.1:9090/-/ready
wait_http http://127.0.0.1:15672/api/overview admin:admin

curl --fail --silent --user admin:admin \
  --request PUT \
  --header 'content-type: application/json' \
  --data '{"durable":false,"auto_delete":false,"arguments":{}}' \
  http://127.0.0.1:15672/api/queues/%2F/orders >/dev/null

docker service create --quiet \
  --name deda-e2e-prom-worker \
  --replicas 1 \
  --label com.deda.autoscale.enabled=true \
  --label com.deda.autoscale.min=1 \
  --label com.deda.autoscale.max=10 \
  --label com.deda.autoscale.targetPerReplica=10 \
  --label com.deda.autoscale.cooldownSeconds=0 \
  --label com.deda.autoscale.scaleDownDelaySeconds=0 \
  --label com.deda.autoscale.stepUp=0 \
  --label com.deda.autoscale.stepDown=0 \
  --label com.deda.autoscale.trigger.type=prometheus \
  --label com.deda.autoscale.trigger.url=http://127.0.0.1:9090 \
  --label 'com.deda.autoscale.trigger.query=vector(100)' \
  alpine:3.22 sleep 3600

docker service create --quiet \
  --name deda-e2e-rabbit-worker \
  --replicas 1 \
  --label com.deda.autoscale.enabled=true \
  --label com.deda.autoscale.min=1 \
  --label com.deda.autoscale.max=10 \
  --label com.deda.autoscale.targetPerReplica=10 \
  --label com.deda.autoscale.cooldownSeconds=0 \
  --label com.deda.autoscale.scaleDownDelaySeconds=0 \
  --label com.deda.autoscale.stepUp=0 \
  --label com.deda.autoscale.stepDown=0 \
  --label com.deda.autoscale.trigger.type=rabbitmq \
  --label com.deda.autoscale.trigger.url=http://127.0.0.1:15672 \
  --label com.deda.autoscale.trigger.queue=orders \
  --label com.deda.autoscale.trigger.metric=messages_ready \
  alpine:3.22 sleep 3600

DEDA_SWARM_TESTS=1 \
DEDA_SWARM_REPLICATED_SERVICE=deda-e2e-contract \
DEDA_SWARM_GLOBAL_SERVICE=deda-e2e-global \
dotnet test tests/Deda.Swarm.Tests/Deda.Swarm.Tests.csproj \
  --configuration Release --no-build --no-restore

DEDA_POLL_SECONDS=1 \
DEDA_MAX_RECONCILE_BACKOFF_SECONDS=5 \
DEDA_HTTP_PORT=18080 \
RABBITMQ_USER=admin \
RABBITMQ_PASS=admin \
dotnet run --project src/Deda.Host/Deda.Host.csproj \
  --configuration Release --no-build > /tmp/deda-e2e.log 2>&1 &
DEDA_PID=$!

wait_http http://127.0.0.1:18080/health/ready
wait_replicas deda-e2e-prom-worker 10

for index in $(seq 1 50); do
  curl --fail --silent --user admin:admin \
    --header 'content-type: application/json' \
    --data "{\"properties\":{},\"routing_key\":\"orders\",\"payload\":\"message-$index\",\"payload_encoding\":\"string\"}" \
    http://127.0.0.1:15672/api/exchanges/%2F/amq.default/publish >/dev/null
done
wait_replicas deda-e2e-rabbit-worker 5

docker service update --quiet \
  --label-rm com.deda.autoscale.trigger.query \
  --label-add 'com.deda.autoscale.trigger.query=vector(0)' \
  deda-e2e-prom-worker
curl --fail --silent --user admin:admin --request DELETE \
  http://127.0.0.1:15672/api/queues/%2F/orders/contents >/dev/null

wait_replicas deda-e2e-prom-worker 1
wait_replicas deda-e2e-rabbit-worker 1

echo "Real Swarm contract and RabbitMQ/Prometheus scaling scenarios passed."
