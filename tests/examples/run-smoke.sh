#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ACTIVE_STACKS=()
POLICY_CONTAINER=""
POLICY_FILE=""

remove_stack() {
  local stack=$1
  docker stack rm "$stack" >/dev/null 2>&1 || true

  for _ in $(seq 1 60); do
    if [[ -z "$(docker service ls --filter "label=com.docker.stack.namespace=$stack" --quiet)" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "Timed out removing stack $stack" >&2
  return 1
}

cleanup() {
  if [[ -n "$POLICY_CONTAINER" ]]; then
    docker rm --force "$POLICY_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$POLICY_FILE" ]]; then
    rm -f "$POLICY_FILE"
  fi
  for stack in "${ACTIVE_STACKS[@]}"; do
    remove_stack "$stack" || true
  done
  docker swarm leave --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_http() {
  local url=$1
  local host_header=${2:-}

  for _ in $(seq 1 120); do
    if [[ -n "$host_header" ]]; then
      if curl --fail --silent --header "Host: $host_header" "$url" >/dev/null; then return 0; fi
    elif curl --fail --silent "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "Timed out waiting for $url" >&2
  curl --verbose --header "Host: ${host_header:-127.0.0.1}" "$url" >&2 || true
  docker service ls >&2 || true
  if [[ "${#ACTIVE_STACKS[@]}" -gt 0 ]]; then
    stack=${ACTIVE_STACKS[$((${#ACTIVE_STACKS[@]} - 1))]}
    docker service logs --tail 200 "${stack}_deda" >&2 || true
  fi
  return 1
}

wait_replicas() {
  local service=$1
  local expected=$2

  for _ in $(seq 1 120); do
    actual=$(docker service inspect "$service" --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || true)
    if [[ "$actual" == "$expected" ]]; then return 0; fi
    sleep 1
  done

  echo "Timed out waiting for $service desired replicas=$expected (actual=${actual:-missing})" >&2
  docker service inspect "$service" --pretty >&2 || true
  docker service logs --tail 200 "${service%_*}_deda" >&2 || true
  return 1
}

wait_running() {
  local service=$1
  local expected=$2

  for _ in $(seq 1 120); do
    running=$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running' || true)
    if [[ "$running" == "$expected" ]]; then return 0; fi
    sleep 1
  done

  echo "Timed out waiting for $service running tasks=$expected (actual=${running:-0})" >&2
  docker service ps --no-trunc "$service" >&2 || true
  docker service logs --tail 200 "$service" >&2 || true
  return 1
}

deploy_stack() {
  local directory=$1
  local stack=$2
  ACTIVE_STACKS+=("$stack")
  (
    cd "$REPO_ROOT/examples/$directory"
    DEDA_IMAGE=deda:examples docker stack deploy --resolve-image never -c stack.yml "$stack"
  )
}

docker swarm init

# The image is the NativeAOT host. Exercise the operator credential-policy
# startup path against the actual published binary, not only unit-test code.
POLICY_FILE=$(mktemp)
printf '%s' '{"orders":{"secret":"orders-rabbitmq","allowedHosts":["rabbitmq.internal"],"allowedServices":["worker"]}}' > "$POLICY_FILE"
POLICY_CONTAINER=$(docker run --detach --rm \
  --publish 18081:18081 \
  --env DEDA_HTTP_PORT=18081 \
  --env DEDA_CREDENTIAL_POLICY_FILE=/run/deda/credential-policy.json \
  --volume "$POLICY_FILE:/run/deda/credential-policy.json:ro" \
  deda:examples)
wait_http http://127.0.0.1:18081/health/live
docker rm --force "$POLICY_CONTAINER" >/dev/null
POLICY_CONTAINER=""
rm -f "$POLICY_FILE"
POLICY_FILE=""

deploy_stack http-trigger deda-http
wait_http http://127.0.0.1:8081/health/ready
wait_replicas deda-http_worker 3
wait_running deda-http_worker 3
remove_stack deda-http
ACTIVE_STACKS=()

deploy_stack scale-to-zero deda-zero
wait_http http://127.0.0.1:8082/health/ready
wait_replicas deda-zero_worker 0
remove_stack deda-zero
ACTIVE_STACKS=()

deploy_stack prometheus-trigger deda-prometheus
wait_http http://127.0.0.1:8080/health/ready
wait_http http://127.0.0.1:9090/-/ready
wait_http http://127.0.0.1/ demo.local
wait_running deda-prometheus_deda 1
wait_running deda-prometheus_prometheus 1
wait_running deda-prometheus_demo-http 1

echo "HTTP trigger, scale-to-zero, and Prometheus example smoke tests passed."
