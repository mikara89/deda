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
: "${GITHUB_RUNNER_IMAGE:=$CI_RUNNER_SIMULATOR_IMAGE}"
: "${AZURE_RUNNER_IMAGE:=$CI_RUNNER_SIMULATOR_IMAGE}"
: "${GITLAB_RUNNER_IMAGE:=$CI_RUNNER_SIMULATOR_IMAGE}"
: "${GITHUB_RUNNER_QUALIFICATION_IMAGE:=deda-github-runner-qualification:ci}"
: "${AZURE_RUNNER_QUALIFICATION_IMAGE:=deda-azure-runner-qualification:ci}"
: "${GITLAB_RUNNER_QUALIFICATION_IMAGE:=deda-gitlab-runner-qualification:ci}"
: "${GITHUB_RUNNER_CANDIDATE_IMAGE:=deda-github-runner:ci}"
: "${AZURE_RUNNER_CANDIDATE_IMAGE:=deda-azure-runner:ci}"
: "${GITLAB_RUNNER_CANDIDATE_IMAGE:=deda-gitlab-runner:ci}"
[[ "$DEDA_QUAL_STACK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo 'invalid DEDA_QUAL_STACK' >&2; exit 1; }
export DEDA_QUAL_STACK QUAL_SECRET_PREFIX DEDA_IMAGE CI_SIMULATOR_IMAGE CI_RUNNER_SIMULATOR_IMAGE GITHUB_RUNNER_IMAGE AZURE_RUNNER_IMAGE GITLAB_RUNNER_IMAGE
export GITHUB_RUNNER_QUALIFICATION_IMAGE AZURE_RUNNER_QUALIFICATION_IMAGE GITLAB_RUNNER_QUALIFICATION_IMAGE
export GITHUB_RUNNER_CANDIDATE_IMAGE AZURE_RUNNER_CANDIDATE_IMAGE GITLAB_RUNNER_CANDIDATE_IMAGE

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
image_digest() { docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true; }
image_label() { docker image inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null || true; }
reference_digest() {
  case "$1" in
    *@sha256:*) printf '%s\n' "${1##*@}" ;;
    *) printf '\n' ;;
  esac
}
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
  capture_diagnostics_to "${SCENARIO_DIR:?SCENARIO_DIR is not set}"
}

capture_diagnostics_to() {
  local dir=$1
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
running_task_containers() {
  local task container
  while IFS= read -r task; do
    container=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task" 2>/dev/null || true)
    [[ -n "$container" ]] && printf '%s\n' "$container"
  done < <(docker service ps --no-trunc "$(service "$1")" --filter desired-state=running --format '{{.ID}}')
}
snapshot_container_logs() {
  local dest=$1 container
  shift
  : > "$dest"
  for container in "$@"; do
    [[ -n "$container" ]] || continue
    docker logs "$container" >> "$dest" 2>/dev/null || true
  done
}
count_log_matches() { grep -c -- "$2" "$1" 2>/dev/null || true; }
follow_container_logs() {
  local since=$1 dest=$2 pidfile=$3 container
  shift 3
  : > "$pidfile"
  for container in "$@"; do
    [[ -n "$container" ]] || continue
    docker logs -f --since "$since" "$container" >> "$dest" 2>&1 &
    printf '%s\n' "$!" >> "$pidfile"
  done
}
stop_followed_logs() {
  local pidfile=$1 pid
  [[ -f "$pidfile" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done < "$pidfile"
  rm -f "$pidfile"
}
wait_replicas() {
  local name=$1 expected=$2
  wait_until "$(service "$name") desired replicas=$expected" 90 bash -c "[[ \"\$(docker service inspect '$(service "$name")' --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || true)\" == '$expected' ]]" || fail_scenario "timed out waiting for $(service "$name") desired replicas=$expected"
}
wait_running_tasks() {
  local name=$1 expected=$2
  wait_until "$(service "$name") running tasks=$expected" 180 bash -c "[[ \"\$(docker service ps '$(service "$name")' --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running' || true)\" == '$expected' ]]" || fail_scenario "timed out waiting for $(service "$name") running tasks=$expected"
}

simulator_url() { printf 'http://%s:8081' "$(service simulator)"; }
simulator_get() { docker run --rm --network "${DEDA_QUAL_STACK}_control" curlimages/curl:8.10.1 -fsS "$(simulator_url)$1"; }
simulator_put() { docker run --rm -i --network "${DEDA_QUAL_STACK}_control" curlimages/curl:8.10.1 -fsS -X POST -H 'content-type: application/json' --data-binary @- "$(simulator_url)/__admin/state"; }
set_state() { printf '%s' "$1" | simulator_put >/dev/null; }
request_count() { simulator_get /__admin/requests | jq -r .count; }
request_total() { simulator_get /__admin/requests | jq -r '.total // .count'; }
latest_request_at() { simulator_get /__admin/requests | jq -r '.requests[-1].at // "1970-01-01T00:00:00Z"'; }
provider_request_count() {
  local fragment=$1
  simulator_get /__admin/requests | jq -r --arg fragment "$fragment" '[.requests[] | select(.endpoint | contains($fragment))] | length'
}
github_observations() {
  docker run --rm --network "${DEDA_QUAL_STACK}_control" curlimages/curl:8.10.1 -fsS "http://$(service deda):8080/metrics" \
    | sed -n 's/^deda_ci_observations_total{.*provider="github-actions".*} \([0-9][0-9]*\).*/\1/p' \
    | tail -n 1
}
github_observation_greater_than() {
  local expected=$1 value
  value=$(github_observations)
  [[ -n "$value" && "$value" =~ ^[0-9]+$ && "$value" -gt "$expected" ]]
}
wait_for_provider_request_after() {
  local baseline=$1 description=$2
  wait_until "$description" 45 bash -c "total=\$(docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -r '.total // .count'); (( total > $baseline ))" || fail_scenario "timed out waiting for $description"
}
wait_for_endpoint_observation_after() {
  local since=$1 endpoint_fragment=$2 description=$3
  wait_until "$description" 45 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -e --arg since '$since' --arg fragment '$endpoint_fragment' 'any(.requests[]?; (.endpoint | contains(\$fragment)) and .at > \$since)' >/dev/null" || fail_scenario "timed out waiting for $description"
}
wait_for_all_provider_observations_after() {
  local since=$1 description=$2
  wait_until "$description" 60 bash -c "docker run --rm --network '${DEDA_QUAL_STACK}_control' curlimages/curl:8.10.1 -fsS '$(simulator_url)/__admin/requests' | jq -e --arg since '$since' '[.requests[] | select(.at > \$since) | .endpoint] as \$paths | ([\$paths[] | contains(\"/actions/\")] | any) and ([\$paths[] | contains(\"/_apis/\")] | any) and ([\$paths[] | contains(\"/api/v4/\")] | any)' >/dev/null" || fail_scenario "timed out waiting for $description"
}
redis_leader() { docker run --rm --network "${DEDA_QUAL_STACK}_control" redis:7-alpine redis-cli -h "$(service redis)" --raw GET deda-v03-qualification:leader 2>/dev/null || true; }

deda_leader_task() {
  local owner=$1 task container host
  while IFS= read -r task; do
    container=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task" 2>/dev/null || true)
    [[ -n "$container" ]] || continue
    host=$(docker inspect --format '{{.Config.Hostname}}' "$container" 2>/dev/null || true)
    if [[ "$owner" == "$host"* ]]; then
      printf '%s\n' "$container"
      return 0
    fi
  done < <(docker service ps --no-trunc "$(service deda)" --filter desired-state=running --format '{{.ID}}')
  return 1
}

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
  for name in github_queue azure_queue gitlab_queue github_runner azure_runner gitlab_runner; do
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

build_runner_qualification_overlay() {
  local dockerfile=$1 base=$2 tag=$3
  local base_digest
  base_digest=$(image_digest "$base")
  [[ -n "$base_digest" ]] || die "candidate base image '$base' is not present locally"
  docker build -f "$SCRIPT_DIR/simulator/real-runner/$dockerfile" \
    --build-arg BASE_IMAGE="$base" \
    --label "deda.qualification.candidateBaseImage=$base" \
    --label "deda.qualification.candidateBaseDigest=$base_digest" \
    -t "$tag" "$SCRIPT_DIR/simulator/real-runner" >/dev/null
  [[ "$(image_label "$tag" deda.qualification.candidateBaseDigest)" == "$base_digest" ]] \
    || die "qualification overlay $tag is not bound to candidate $base"
}

write_overlay_identity() {
  local dest=$1
  jq -n \
    --arg githubCandidateBaseImage "$GITHUB_RUNNER_CANDIDATE_IMAGE" \
    --arg githubCandidateBaseDigest "$(image_digest "$GITHUB_RUNNER_CANDIDATE_IMAGE")" \
    --arg githubQualificationOverlayImage "$GITHUB_RUNNER_QUALIFICATION_IMAGE" \
    --arg githubQualificationOverlayImageId "$(image_digest "$GITHUB_RUNNER_QUALIFICATION_IMAGE")" \
    --arg githubOverlayLabeledBase "$(image_label "$GITHUB_RUNNER_QUALIFICATION_IMAGE" deda.qualification.candidateBaseImage)" \
    --arg githubOverlayLabeledDigest "$(image_label "$GITHUB_RUNNER_QUALIFICATION_IMAGE" deda.qualification.candidateBaseDigest)" \
    --arg azureCandidateBaseImage "$AZURE_RUNNER_CANDIDATE_IMAGE" \
    --arg azureCandidateBaseDigest "$(image_digest "$AZURE_RUNNER_CANDIDATE_IMAGE")" \
    --arg azureQualificationOverlayImage "$AZURE_RUNNER_QUALIFICATION_IMAGE" \
    --arg azureQualificationOverlayImageId "$(image_digest "$AZURE_RUNNER_QUALIFICATION_IMAGE")" \
    --arg azureOverlayLabeledBase "$(image_label "$AZURE_RUNNER_QUALIFICATION_IMAGE" deda.qualification.candidateBaseImage)" \
    --arg azureOverlayLabeledDigest "$(image_label "$AZURE_RUNNER_QUALIFICATION_IMAGE" deda.qualification.candidateBaseDigest)" \
    --arg gitlabCandidateBaseImage "$GITLAB_RUNNER_CANDIDATE_IMAGE" \
    --arg gitlabCandidateBaseDigest "$(image_digest "$GITLAB_RUNNER_CANDIDATE_IMAGE")" \
    --arg gitlabQualificationOverlayImage "$GITLAB_RUNNER_QUALIFICATION_IMAGE" \
    --arg gitlabQualificationOverlayImageId "$(image_digest "$GITLAB_RUNNER_QUALIFICATION_IMAGE")" \
    --arg gitlabOverlayLabeledBase "$(image_label "$GITLAB_RUNNER_QUALIFICATION_IMAGE" deda.qualification.candidateBaseImage)" \
    --arg gitlabOverlayLabeledDigest "$(image_label "$GITLAB_RUNNER_QUALIFICATION_IMAGE" deda.qualification.candidateBaseDigest)" \
    '{github:{candidateBaseImage:$githubCandidateBaseImage,candidateBaseDigest:$githubCandidateBaseDigest,qualificationOverlayImage:$githubQualificationOverlayImage,qualificationOverlayImageId:$githubQualificationOverlayImageId,labeledBaseImage:$githubOverlayLabeledBase,labeledBaseDigest:$githubOverlayLabeledDigest},azure:{candidateBaseImage:$azureCandidateBaseImage,candidateBaseDigest:$azureCandidateBaseDigest,qualificationOverlayImage:$azureQualificationOverlayImage,qualificationOverlayImageId:$azureQualificationOverlayImageId,labeledBaseImage:$azureOverlayLabeledBase,labeledBaseDigest:$azureOverlayLabeledDigest},gitlab:{candidateBaseImage:$gitlabCandidateBaseImage,candidateBaseDigest:$gitlabCandidateBaseDigest,qualificationOverlayImage:$gitlabQualificationOverlayImage,qualificationOverlayImageId:$gitlabQualificationOverlayImageId,labeledBaseImage:$gitlabOverlayLabeledBase,labeledBaseDigest:$gitlabOverlayLabeledDigest}}' > "$dest"
}

ensure_runner_qualification_images() {
  local github_base=${GITHUB_RUNNER_CANDIDATE_IMAGE} azure_base=${AZURE_RUNNER_CANDIDATE_IMAGE} gitlab_base=${GITLAB_RUNNER_CANDIDATE_IMAGE}
  if [[ "$github_base" == "deda-github-runner:ci" || "$azure_base" == "deda-azure-runner:ci" || "$gitlab_base" == "deda-gitlab-runner:ci" ]]; then
    ensure_runner_images
  fi
  build_runner_qualification_overlay github.Dockerfile "$github_base" "$GITHUB_RUNNER_QUALIFICATION_IMAGE"
  build_runner_qualification_overlay azure.Dockerfile "$azure_base" "$AZURE_RUNNER_QUALIFICATION_IMAGE"
  build_runner_qualification_overlay gitlab.Dockerfile "$gitlab_base" "$GITLAB_RUNNER_QUALIFICATION_IMAGE"
  if [[ -n ${RUN_ID:-} ]]; then
    write_overlay_identity "$(result_root)/overlay-identity.json"
  fi
}

cleanup_stack() {
  docker stack rm "$DEDA_QUAL_STACK" >/dev/null 2>&1 || true
  wait_until "stack $DEDA_QUAL_STACK removal" 90 bash -c "! docker stack ls --format '{{.Name}}' | grep -Fxq '$DEDA_QUAL_STACK'" || note "stack removal did not finish before cleanup"
  for name in github_queue azure_queue gitlab_queue github_runner azure_runner gitlab_runner; do docker secret rm "${QUAL_SECRET_PREFIX}_${name}" >/dev/null 2>&1 || true; done
  rm -f "$SCRIPT_DIR/stack/credential-policy.json"
}
