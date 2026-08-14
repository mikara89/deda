#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QUAL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
source "$QUAL_ROOT/common.sh"
REAL_ACTIVE_STACK=""

confirm_real() {
  [[ ${1:-} == --confirm-real-provider-tests ]] || die 'Real-provider qualification requires --confirm-real-provider-tests; credentials alone are never authorization.'
}
require_env() { [[ -n ${!1:-} ]] || die "$1 is required"; }
require_secret_file() { [[ -f ${!1:-} && -r ${!1} ]] || die "$1 must name a readable secret file"; }
secret() { tr -d '\r\n' < "$1"; }
require_digest_image() {
  local name=$1 value=${!1:-}
  [[ -n "$value" ]] || die "$name is required and must be digest-pinned"
  [[ "$value" == *@sha256:* ]] || die "$name must use an immutable digest reference (image@sha256:...), got: $value"
}
export_real_candidate_images() {
  require_digest_image REAL_DEDA_IMAGE
  require_digest_image GITHUB_QUAL_RUNNER_IMAGE
  require_digest_image AZURE_QUAL_RUNNER_IMAGE
  require_digest_image GITLAB_QUAL_RUNNER_IMAGE
  export DEDA_IMAGE="$REAL_DEDA_IMAGE"
  export GITHUB_RUNNER_IMAGE="$GITHUB_QUAL_RUNNER_IMAGE"
  export AZURE_RUNNER_IMAGE="$AZURE_QUAL_RUNNER_IMAGE"
  export GITLAB_RUNNER_IMAGE="$GITLAB_QUAL_RUNNER_IMAGE"
}
image_digest() {
  docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true
}
reference_digest() {
  printf '%s\n' "${1##*@}"
}
write_real_candidate() {
  local provider=$1 file
  file="$(real_result_dir "$provider")/candidate.json"
  jq -n --arg provider "$provider" --arg collectedAt "$(utc_now)" --arg candidateCommit "$(git rev-parse HEAD)" \
    --arg dedaImage "$DEDA_IMAGE" --arg dedaReferenceDigest "$(reference_digest "$DEDA_IMAGE")" --arg dedaDigest "$(image_digest "$DEDA_IMAGE")" \
    --arg githubRunnerImage "$GITHUB_RUNNER_IMAGE" --arg githubRunnerReferenceDigest "$(reference_digest "$GITHUB_RUNNER_IMAGE")" --arg githubRunnerLocalImageId "$(image_digest "$GITHUB_RUNNER_IMAGE")" \
    --arg azureRunnerImage "$AZURE_RUNNER_IMAGE" --arg azureRunnerReferenceDigest "$(reference_digest "$AZURE_RUNNER_IMAGE")" --arg azureRunnerLocalImageId "$(image_digest "$AZURE_RUNNER_IMAGE")" \
    --arg gitlabRunnerImage "$GITLAB_RUNNER_IMAGE" --arg gitlabRunnerReferenceDigest "$(reference_digest "$GITLAB_RUNNER_IMAGE")" --arg gitlabRunnerLocalImageId "$(image_digest "$GITLAB_RUNNER_IMAGE")" \
    '{provider:$provider,collectedAt:$collectedAt,candidateCommit:$candidateCommit,dedaImage:$dedaImage,dedaReferenceDigest:$dedaReferenceDigest,dedaDigest:$dedaDigest,githubRunnerImage:$githubRunnerImage,githubRunnerReferenceDigest:$githubRunnerReferenceDigest,githubRunnerLocalImageId:$githubRunnerLocalImageId,azureRunnerImage:$azureRunnerImage,azureRunnerReferenceDigest:$azureRunnerReferenceDigest,azureRunnerLocalImageId:$azureRunnerLocalImageId,gitlabRunnerImage:$gitlabRunnerImage,gitlabRunnerReferenceDigest:$gitlabRunnerReferenceDigest,gitlabRunnerLocalImageId:$gitlabRunnerLocalImageId,containsSecrets:false}' > "$file"
}
real_result_dir() { printf '%s/real-%s' "$(result_root)" "$1"; }
begin_real() { mkdir -p "$(real_result_dir "$1")"; }
write_real() {
  local provider=$1 status=$2 detail=$3 file
  file="$(real_result_dir "$provider")/result.json"
  jq -n --arg provider "$provider" --arg status "$status" --arg at "$(utc_now)" --arg detail "$detail" '{provider:$provider,status:$status,at:$at,detail:$detail}' > "$file"
}
wait_real() {
  local description=$1 timeout=$2; shift 2
  wait_until "$description" "$timeout" "$@" || die "Timed out waiting for $description"
}

require_docker_swarm() {
  require docker
  docker info >/dev/null || die 'Docker daemon is unavailable.'
  if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active; then
    docker swarm init >/dev/null
  fi
}

host_from_url() {
  local url=$1
  local host=${url#*://}
  host=${host%%/*}
  host=${host%%:*}
  printf '%s\n' "$host"
}

real_service() { printf '%s_%s' "$1" "$2"; }
run_suffix() { printf '%s' "$RUN_ID" | sed 's/[^a-zA-Z0-9_-]/-/g'; }
real_stack_name() { printf 'deda-real-%s-%s' "$1" "$(run_suffix)"; }
real_desired() { docker service inspect "$1" --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || true; }
real_running() { docker service ps "$1" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running' || true; }
deda_ci_metric_value() {
  local metric=$1 service_name=$2
  docker run --rm --network "${REAL_ACTIVE_STACK}_deda_net" curlimages/curl:8.10.1 -fsS "http://$(real_service "$REAL_ACTIVE_STACK" deda):8080/metrics" 2>/dev/null \
    | grep -F "$metric" \
    | grep -F "service=\"$service_name\"" \
    | sed -n 's/.*} \([0-9][0-9]*\).*/\1/p' \
    | tail -n 1
}
create_real_secret() {
  local name=$1 file=$2
  if docker secret inspect "$name" >/dev/null 2>&1; then die "Docker secret '$name' already exists; refusing to replace an unrelated resource"; fi
  docker secret create "$name" "$file" >/dev/null
}

ensure_real_stack_available() {
  local stack=$1
  if docker stack ls --format '{{.Name}}' | grep -Fxq "$stack"; then
    die "Docker stack '$stack' already exists; refusing to reuse an unrelated stack"
  fi
}

record_scale() {
  local file=$1 service_name=$2 provider=$3 desired running required queued active
  desired=$(real_desired "$service_name")
  running=$(real_running "$service_name")
  required=$(deda_ci_metric_value deda_ci_required_capacity "$service_name")
  queued=$(deda_ci_metric_value deda_ci_jobs_queued "$service_name")
  active=$(deda_ci_metric_value deda_ci_jobs_active "$service_name")
  jq -n --arg at "$(utc_now)" --arg provider "$provider" --arg service "$service_name" \
    --arg desired "$desired" --arg running "$running" --arg required "$required" --arg queued "$queued" --arg active "$active" \
    '{at:$at,provider:$provider,service:$service,desiredReplicas:(if $desired == "" then 0 else ($desired|tonumber) end),runningTasks:(if $running == "" then 0 else ($running|tonumber) end),requiredCapacity:(if $required == "" then 0 else ($required|tonumber) end),queuedJobs:(if $queued == "" then 0 else ($queued|tonumber) end),activeJobs:(if $active == "" then 0 else ($active|tonumber) end)}' >> "$file"
}

wait_real_desired() {
  local service_name=$1 expected=$2 description=$3
  wait_real "$description" 600 bash -c "[[ \"\$(docker service inspect '$service_name' --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || true)\" == '$expected' ]]" || die "Timed out waiting for $service_name desired replicas=$expected"
}

wait_real_desired_positive() {
  local service_name=$1 description=$2
  wait_real "$description" 600 bash -c "[[ \"\$(docker service inspect '$service_name' --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || true)\" -gt 0 ]]" || die "Timed out waiting for $service_name desired replicas to become positive"
}

wait_real_running_positive() {
  local service_name=$1 description=$2
  wait_real "$description" 600 bash -c "[[ \"\$(docker service ps '$service_name' --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running' || true)\" -gt 0 ]]" || die "Timed out waiting for $service_name to run a task"
}

wait_real_running_zero() {
  local service_name=$1 description=$2
  wait_real "$description" 900 bash -c "[[ \"\$(docker service ps '$service_name' --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running' || true)\" -eq 0 ]]" || die "Timed out waiting for $service_name to reach zero running tasks"
}

assert_scale_timeline() {
  local file=$1 service_name=$2
  jq -se --arg service "$service_name" '
    [.[] | select(.service == $service)] as $rows
    | ($rows | length > 0)
      and ([$rows[] | select(.desiredReplicas > 0)] | length > 0)
      and ([$rows[] | select(.runningTasks > 0)] | length > 0)
      and ([$rows[] | select(.desiredReplicas == 0)] | length > 0)
      and ([$rows[] | select(.runningTasks == 0)] | length > 0)
      and ([$rows[] | select(.requiredCapacity > 0)] | length > 0)
      and ([$rows[] | select(.requiredCapacity > 0 and .desiredReplicas < .requiredCapacity)] | length == 0)
  ' "$file" >/dev/null || die "$service_name did not produce a complete 0→N→active→0 Swarm scale timeline"
}

capture_real_swarm_evidence() {
  local provider=$1 stack=$2 runner_service=$3 dir deda_service
  dir=$(real_result_dir "$provider")
  deda_service=$(real_service "$stack" deda)
  docker node ls > "$dir/docker-node-ls.txt" 2>&1 || true
  docker service ls > "$dir/docker-service-ls.txt" 2>&1 || true
  docker service ps --no-trunc "$deda_service" > "$dir/deda-service-ps.txt" 2>&1 || true
  docker service inspect "$deda_service" > "$dir/deda-service-inspect.json" 2>&1 || true
  docker service ps --no-trunc "$runner_service" > "$dir/runner-service-ps.txt" 2>&1 || true
  docker service inspect "$runner_service" > "$dir/runner-service-inspect.json" 2>&1 || true
  docker service logs --tail 500 "$deda_service" > "$dir/deda-logs.txt" 2>&1 || true
  docker service logs --tail 500 "$runner_service" > "$dir/runner-logs.txt" 2>&1 || true
  docker run --rm --network "${stack}_deda_net" curlimages/curl:8.10.1 -fsS "http://$deda_service:8080/metrics" > "$dir/deda-metrics.txt" 2>&1 || true
}

capture_real_runner_hostnames() {
  local service_name=$1 task container host
  while IFS= read -r task; do
    container=$(docker inspect --format '{{.Status.ContainerStatus.ContainerID}}' "$task" 2>/dev/null || true)
    [[ -n "$container" ]] || continue
    host=$(docker inspect --format '{{.Config.Hostname}}' "$container" 2>/dev/null || true)
    [[ -n "$host" ]] && printf '%s\n' "$host"
  done < <(docker service ps --no-trunc "$service_name" --filter desired-state=running --format '{{.ID}}')
}

capture_gitlab_runner_names() {
  local service_name=$1 host
  while IFS= read -r host; do
    [[ -n "$host" ]] && printf 'deda-gitlab-%s\n' "$host"
  done < <(capture_real_runner_hostnames "$service_name")
}

assert_github_runner_attribution() {
  local dir=$1 hostfile=$2 name host
  [[ -s "$hostfile" ]] || die 'No running GitHub qualification task hostnames were captured'
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    host=${name#deda-gh-}
    [[ "$host" != "$name" ]] || die "GitHub runner name '$name' does not use the DEDA runner naming scheme"
    grep -Fxq "$host" "$hostfile" || die "GitHub runner '$name' was not created by the qualification Swarm service"
  done < <(jq -r '.jobs[]?.runner_name // ""' "$dir"/run-*.json | sort -u)
}

assert_azure_agent_attribution() {
  local dir=$1 hostfile=$2 expected_jobs=$3 agent host unique_agents
  [[ -s "$hostfile" ]] || die 'No running Azure qualification task hostnames were captured'
  [[ -s "$dir/agent-names.txt" ]] || die 'No Azure pipeline agent identities were captured'
  unique_agents=$(sort -u "$dir/agent-names.txt" | grep -c '^deda-ado-')
  (( unique_agents >= expected_jobs )) || die "Azure qualification captured only $unique_agents DEDA agent identities for $expected_jobs expected jobs"
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    host=${agent#deda-ado-}
    [[ "$host" != "$agent" ]] || die "Azure agent name '$agent' does not use the DEDA agent naming scheme"
    grep -Fxq "$host" "$hostfile" || die "Azure agent '$agent' was not created by the qualification Swarm service"
  done < <(sort -u "$dir/agent-names.txt")
}

assert_gitlab_runner_attribution() {
  local dir=$1 namesfile=$2 name
  [[ -s "$namesfile" ]] || die 'No running GitLab qualification runner names were captured'
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -Fxq "$name" "$namesfile" || die "GitLab runner '$name' was not created by the qualification Swarm service"
  done < <(jq -r '.jobs[]? | (.runner.name // .runner.description // "")' "$dir"/pipeline-*.json | sort -u)
}

teardown_real_stack() {
  local tmpdir=$1 stack=$2
  shift 2
  docker stack rm "$stack" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    docker stack ls --format '{{.Name}}' | grep -Fxq "$stack" || break
    sleep 1
  done
  for secret_name in "$@"; do docker secret rm "$secret_name" >/dev/null 2>&1 || true; done
  rm -rf "$tmpdir"
}

deploy_github_stack() {
  local tmpdir=$1 stack=${REAL_GITHUB_STACK:-$(real_stack_name github)} compose policy api api_host labels repositories
  require_docker_swarm
  ensure_real_stack_available "$stack"
  REAL_ACTIVE_STACK="$stack"
  compose="$tmpdir/stack.yml"; policy="$tmpdir/policy.json"
  api=${GITHUB_QUAL_API_URL:-https://api.github.com}
  api_host=$(host_from_url "$api")
  labels=${GITHUB_QUAL_LABELS:-self-hosted,linux,deda}
  repositories=${GITHUB_QUAL_REPOSITORY}
  sed -e "s|example-org|$GITHUB_QUAL_OWNER|g" \
    -e "s|api,web|$repositories|g" \
    -e "s|self-hosted,linux,deda|$labels|g" \
    -e "s|github-queue-reader|${stack}-github-queue-reader|g" \
    -e "s|github-runner-admin|${stack}-github-runner-admin|g" \
    -e "s|file: ./credential-policy.example.json|file: $policy|g" \
    "$REPO_ROOT/examples/ci-runners/github-actions/stack.yml" > "$compose"
  sed -e "s|api.github.com|$api_host|g" \
    -e "s|github-queue-reader|${stack}-github-queue-reader|g" \
    -e "s|ci-github_github-runner|${stack}_github-runner|g" \
    "$REPO_ROOT/examples/ci-runners/github-actions/credential-policy.example.json" > "$policy"
  create_real_secret "${stack}-github-queue-reader" "$GITHUB_QUAL_QUEUE_TOKEN_FILE"
  create_real_secret "${stack}-github-runner-admin" "$GITHUB_QUAL_RUNNER_ADMIN_TOKEN_FILE"
  export GITHUB_RUNNER_IMAGE="$GITHUB_QUAL_RUNNER_IMAGE"
  export DEDA_IMAGE="$REAL_DEDA_IMAGE"
  docker stack deploy --prune -c "$compose" "$stack" >/dev/null
  docker service update --label-add "com.deda.autoscale.trigger.apiUrl=$api" "$(real_service "$stack" github-runner)" >/dev/null
  if [[ "$api" != "https://api.github.com" ]]; then
    docker service update --env-add "GITHUB_API_URL=$api" "$(real_service "$stack" github-runner)" >/dev/null
  fi
  wait_real "$stack DEDA readiness" 180 bash -c "docker run --rm --network '${stack}_deda_net' curlimages/curl:8.10.1 -fsS 'http://$(real_service "$stack" deda):8080/health/ready' >/dev/null" || die 'real GitHub qualification DEDA did not become ready'
}

deploy_azure_stack() {
  local tmpdir=$1 stack=${REAL_AZURE_STACK:-$(real_stack_name azure)} compose policy api_host org_url pool demands
  require_docker_swarm
  ensure_real_stack_available "$stack"
  REAL_ACTIVE_STACK="$stack"
  compose="$tmpdir/stack.yml"; policy="$tmpdir/policy.json"
  org_url=${AZURE_QUAL_ORGANIZATION_URL%/}
  api_host=$(host_from_url "$org_url")
  pool=${AZURE_QUAL_POOL}
  demands=${AZURE_QUAL_DEMANDS:-Agent.OS=Linux,deda}
  sed -e "s|https://dev.azure.com/example-org|$org_url|g" \
    -e "s|deda-swarm|$pool|g" \
    -e "s|Agent.OS=Linux,deda|$demands|g" \
    -e "s|ado-queue-reader|${stack}-ado-queue-reader|g" \
    -e "s|ado-agent-registration|${stack}-ado-agent-registration|g" \
    -e "s|file: ./credential-policy.example.json|file: $policy|g" \
    "$REPO_ROOT/examples/ci-runners/azure-pipelines/stack.yml" > "$compose"
  sed -e "s|dev.azure.com|$api_host|g" \
    -e "s|ado-queue-reader|${stack}-ado-queue-reader|g" \
    -e "s|ci-azure_azure-runner|${stack}_azure-runner|g" \
    "$REPO_ROOT/examples/ci-runners/azure-pipelines/credential-policy.example.json" > "$policy"
  create_real_secret "${stack}-ado-queue-reader" "$AZURE_QUAL_QUEUE_TOKEN_FILE"
  create_real_secret "${stack}-ado-agent-registration" "$AZURE_QUAL_AGENT_TOKEN_FILE"
  export AZURE_RUNNER_IMAGE="$AZURE_QUAL_RUNNER_IMAGE"
  export DEDA_IMAGE="$REAL_DEDA_IMAGE"
  docker stack deploy --prune -c "$compose" "$stack" >/dev/null
  wait_real "$stack DEDA readiness" 180 bash -c "docker run --rm --network '${stack}_deda_net' curlimages/curl:8.10.1 -fsS 'http://$(real_service "$stack" deda):8080/health/ready' >/dev/null" || die 'real Azure qualification DEDA did not become ready'
}

deploy_gitlab_stack() {
  local tmpdir=$1 stack=${REAL_GITLAB_STACK:-$(real_stack_name gitlab)} compose policy api_host url projects tags run_untagged
  require_docker_swarm
  ensure_real_stack_available "$stack"
  REAL_ACTIVE_STACK="$stack"
  compose="$tmpdir/stack.yml"; policy="$tmpdir/policy.json"
  url=${GITLAB_QUAL_URL%/}
  api_host=$(host_from_url "$url")
  projects=${GITLAB_QUAL_PROJECT}
  tags=${GITLAB_QUAL_TAGS:-linux,deda}
  run_untagged=${GITLAB_QUAL_RUN_UNTAGGED:-false}
  sed -e "s|https://gitlab.com|$url|g" \
    -e "s|example-group/api,example-group/web|$projects|g" \
    -e "s|linux,deda|$tags|g" \
    -e "s|com.deda.autoscale.trigger.runUntagged: \"false\"|com.deda.autoscale.trigger.runUntagged: \"$run_untagged\"|" \
    -e "s|gitlab-queue-reader|${stack}-gitlab-queue-reader|g" \
    -e "s|gitlab-runner-auth|${stack}-gitlab-runner-auth|g" \
    -e "s|file: ./credential-policy.example.json|file: $policy|g" \
    "$REPO_ROOT/examples/ci-runners/gitlab/stack.yml" > "$compose"
  sed -e "s|gitlab.com|$api_host|g" \
    -e "s|gitlab-queue-reader|${stack}-gitlab-queue-reader|g" \
    -e "s|ci-gitlab_gitlab-runner|${stack}_gitlab-runner|g" \
    "$REPO_ROOT/examples/ci-runners/gitlab/credential-policy.example.json" > "$policy"
  create_real_secret "${stack}-gitlab-queue-reader" "$GITLAB_QUAL_QUEUE_TOKEN_FILE"
  create_real_secret "${stack}-gitlab-runner-auth" "$GITLAB_QUAL_RUNNER_TOKEN_FILE"
  export GITLAB_RUNNER_IMAGE="$GITLAB_QUAL_RUNNER_IMAGE"
  export DEDA_IMAGE="$REAL_DEDA_IMAGE"
  docker stack deploy --prune -c "$compose" "$stack" >/dev/null
  wait_real "$stack DEDA readiness" 180 bash -c "docker run --rm --network '${stack}_deda_net' curlimages/curl:8.10.1 -fsS 'http://$(real_service "$stack" deda):8080/health/ready' >/dev/null" || die 'real GitLab qualification DEDA did not become ready'
}
