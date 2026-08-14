#!/usr/bin/env bash
# Shared helpers for deterministic v0.3 CI-runner qualification. No helper logs
# request headers, Docker secrets, or provider tokens.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
RESULTS_ROOT="$REPO_ROOT/tests/qualification/results"
: "${DEDA_QUAL_STACK:=deda-v03-qual}"
: "${QUAL_SECRET_PREFIX:=${DEDA_QUAL_STACK}-secrets}"
: "${DEDA_IMAGE:=deda:qualification}"
: "${CI_SIMULATOR_IMAGE:=deda-ci-provider-simulator:qualification}"
: "${CI_RUNNER_SIMULATOR_IMAGE:=deda-ci-runner-lifecycle-simulator:qualification}"
[[ "$DEDA_QUAL_STACK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo 'invalid DEDA_QUAL_STACK' >&2; exit 1; }
export DEDA_QUAL_STACK QUAL_SECRET_PREFIX DEDA_IMAGE CI_SIMULATOR_IMAGE CI_RUNNER_SIMULATOR_IMAGE

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '[v0.3 qualification] %s\n' "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
service() { printf '%s_%s' "$DEDA_QUAL_STACK" "$1"; }
result_root() { printf '%s/%s/v0.3-ci' "$RESULTS_ROOT" "$RUN_ID"; }
scenario_root() { printf '%s/scenario-%s' "$(result_root)" "$1"; }

init_run() {
  RUN_ID=${RUN_ID:-"$(date -u +%Y%m%d-%H%M%S)-v03"}
  export RUN_ID
  mkdir -p "$(result_root)"
  printf '%s\n' "$DEDA_IMAGE" > "$(result_root)/candidate-image.txt"
  { docker version --format '{{.Server.Version}}' 2>/dev/null || true; uname -a; } > "$(result_root)/environment.txt"
}

begin_scenario() {
  local id=$1 name=$2 dir
  dir=$(scenario_root "$id"); mkdir -p "$dir"
  SCENARIO_ID=$id SCENARIO_NAME=$name SCENARIO_STARTED=$(utc_now) SCENARIO_DIR=$dir
  export SCENARIO_ID SCENARIO_NAME SCENARIO_STARTED SCENARIO_DIR
}

finish_scenario() {
  local status=$1; shift
  local message=$*
  jq -n --arg scenario "$SCENARIO_NAME" --arg status "$status" --arg startedAt "$SCENARIO_STARTED" \
    --arg finishedAt "$(utc_now)" --arg message "$message" \
    '{scenario:$scenario,status:$status,startedAt:$startedAt,finishedAt:$finishedAt,durationSeconds:((($finishedAt|fromdateiso8601)-($startedAt|fromdateiso8601))),assertions:[$message],diagnostics:[]}' > "$SCENARIO_DIR/result.json"
}

capture_diagnostics() {
  local dir=${1:-"$SCENARIO_DIR"}
  mkdir -p "$dir"
  docker node ls > "$dir/docker-node-ls.txt" 2>&1 || true
  docker service ls > "$dir/docker-service-ls.txt" 2>&1 || true
  docker service ps --no-trunc "$(service deda)" > "$dir/deda-service-ps.txt" 2>&1 || true
  docker service inspect "$(service deda)" > "$dir/deda-service-inspect.json" 2>&1 || true
  docker service logs --tail 300 "$(service deda)" > "$dir/deda-logs.txt" 2>&1 || true
  docker service logs --tail 300 "$(service simulator)" > "$dir/simulator-logs.txt" 2>&1 || true
  for runner in github-runner azure-runner gitlab-runner invalid-github-runner; do
    docker service ps --no-trunc "$(service "$runner")" > "$dir/$runner-service-ps.txt" 2>&1 || true
    docker service inspect "$(service "$runner")" > "$dir/$runner-service-inspect.json" 2>&1 || true
    docker service logs --tail 300 "$(service "$runner")" > "$dir/$runner-logs.txt" 2>&1 || true
  done
  docker run --rm --network "${DEDA_QUAL_STACK}_control" curlimages/curl:8.10.1 -fsS "http://$(service deda):8080/metrics" > "$dir/deda-metrics.txt" 2>&1 || true
  simulator_get /__admin/state > "$dir/simulator-state.json" 2>&1 || true
  redis_leader > "$dir/redis-leadership.txt" 2>&1 || true
}

fail_scenario() { capture_diagnostics; finish_scenario FAIL "$*"; die "Scenario $SCENARIO_ID failed: $*"; }

wait_until() {
  local description=$1 timeout=$2; shift 2
  local end=$((SECONDS + timeout))
  until "$@"; do
    (( SECONDS < end )) || return 1
    sleep 1
  done
  note "observed: $description"
}

replicas() { docker service inspect "$(service "$1")" --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null; }
running_tasks() { docker service ps "$(service "$1")" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running' || true; }
wait_replicas() {
  local name=$1 expected=$2
  wait_until "$(service "$name") desired replicas=$expected" 90 bash -c "[[ \"\$(docker service inspect '$(service "$name")' --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || true)\" == '$expected' ]" || fail_scenario "timed out waiting for $(service "$name") desired replicas=$expected"
}
wait_running_tasks() {
  local name=$1 expected=$2
  wait_until "$(service "$name") running tasks=$expected" 90 bash -c "[[ \"\$(docker service ps '$(service "$name")' --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running' || true)\" == '$expected' ]" || fail_scenario "timed out waiting for $(service "$name") running tasks=$expected"
}

simulator_url() { printf 'http://%s:8081' "$(service simulator)"; }
simulator_get() { docker run --rm --network "${DEDA_QUAL_STACK}_control" curlimages/curl:8.10.1 -fsS "$(simulator_url)$1"; }
simulator_put() { docker run --rm -i --network "${DEDA_QUAL_STACK}_control" curlimages/curl:8.10.1 -fsS -X POST -H 'content-type: application/json' --data-binary @- "$(simulator_url)/__admin/state"; }
set_state() { printf '%s' "$1" | simulator_put >/dev/null; }
request_count() { simulator_get /__admin/requests | jq -r .count; }
wait_for_provider_request_after() {
  local baseline=$1 description=$2
  wait_until "$description" 45 bash -c "count=\$(docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -r .count); (( count > $baseline ))" || fail_scenario "timed out waiting for $description"
}
wait_for_endpoint_observation_after() {
  local baseline=$1 endpoint_fragment=$2 description=$3
  wait_until "$description" 45 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -e --argjson baseline '$baseline' --arg fragment '$endpoint_fragment' 'any(.requests[\$baseline:][]?; .endpoint | contains(\$fragment))' >/dev/null" || fail_scenario "timed out waiting for $description"
}
wait_for_all_provider_observations_after() {
  local baseline=$1 description=$2
  wait_until "$description" 60 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -e --argjson baseline '$baseline' '[.requests[\$baseline:][].endpoint] as \$paths | ([\$paths[] | contains(\"/actions/\")] | any) and ([\$paths[] | contains(\"/_apis/\")] | any) and ([\$paths[] | contains(\"/api/v4/\")] | any)' >/dev/null" || fail_scenario "timed out waiting for $description"
}
redis_leader() { docker run --rm --network "${DEDA_QUAL_STACK}_control" redis:7-alpine redis-cli -h "$(service redis)" --raw GET deda-v03-qualification:leader 2>/dev/null || true; }

prepare_stack() {
  require docker; require jq
  docker info >/dev/null || die 'Docker daemon is unavailable.'
  if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active; then docker swarm init >/dev/null; fi
  if ! docker image inspect "$DEDA_IMAGE" >/dev/null 2>&1; then
    note "building local DEDA qualification image"
    docker build -f "$REPO_ROOT/src/Deda.Host/Dockerfile" -t "$DEDA_IMAGE" "$REPO_ROOT"
  fi
  if ! docker image inspect "$CI_SIMULATOR_IMAGE" >/dev/null 2>&1; then
    docker build -t "$CI_SIMULATOR_IMAGE" "$SCRIPT_DIR/simulator"
  fi
  if ! docker image inspect "$CI_RUNNER_SIMULATOR_IMAGE" >/dev/null 2>&1; then
    docker build -f "$SCRIPT_DIR/simulator/runner.Dockerfile" -t "$CI_RUNNER_SIMULATOR_IMAGE" "$SCRIPT_DIR/simulator"
  fi
  local stack_dir="$SCRIPT_DIR/stack"
  sed -e "s/__GITHUB_SERVICE__/$(service github-runner)/g" -e "s/__AZURE_SERVICE__/$(service azure-runner)/g" -e "s/__GITLAB_SERVICE__/$(service gitlab-runner)/g" \
    "$stack_dir/credential-policy.json.tpl" > "$stack_dir/credential-policy.json"
  for name in github_queue azure_queue gitlab_queue; do
    if ! docker secret inspect "${QUAL_SECRET_PREFIX}_${name}" >/dev/null 2>&1; then printf 'simulated-token' | docker secret create "${QUAL_SECRET_PREFIX}_${name}" - >/dev/null; fi
  done
  docker stack deploy --prune -c "$stack_dir/stack.yml" "$DEDA_QUAL_STACK" >/dev/null
  wait_until 'provider simulator health' 90 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/healthz' >/dev/null" || die 'simulator did not become healthy'
  wait_until 'DEDA readiness' 90 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS 'http://$(service deda):8080/health/ready' >/dev/null" || die 'DEDA did not become ready'
}

ensure_runner_images() {
  if ! docker image inspect deda-github-runner:ci >/dev/null 2>&1; then
    docker build --build-arg RUNNER_SHA256_AMD64=048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271 -t deda-github-runner:ci "$REPO_ROOT/examples/ci-runners/github-actions"
  fi
  if ! docker image inspect deda-azure-runner:ci >/dev/null 2>&1; then
    docker build --build-arg AGENT_SHA256_AMD64=828220fc662131f8d6bd427c8d8b9bffae064a9b1532b7e448d58766276b31fa -t deda-azure-runner:ci "$REPO_ROOT/examples/ci-runners/azure-pipelines"
  fi
  if ! docker image inspect deda-gitlab-runner:ci >/dev/null 2>&1; then
    docker build -t deda-gitlab-runner:ci "$REPO_ROOT/examples/ci-runners/gitlab"
  fi
}

cleanup_stack() {
  docker stack rm "$DEDA_QUAL_STACK" >/dev/null 2>&1 || true
  wait_until "stack $DEDA_QUAL_STACK removal" 90 bash -c "! docker stack ls --format '{{.Name}}' | grep -Fxq '$DEDA_QUAL_STACK'" || note "stack removal did not finish before cleanup"
  for name in github_queue azure_queue gitlab_queue; do docker secret rm "${QUAL_SECRET_PREFIX}_${name}" >/dev/null 2>&1 || true; done
  rm -f "$SCRIPT_DIR/stack/credential-policy.json"
}
