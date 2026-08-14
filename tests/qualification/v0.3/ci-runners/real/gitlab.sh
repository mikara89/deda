#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
confirm_real "${1:-}"
for key in GITLAB_QUAL_URL GITLAB_QUAL_PROJECT GITLAB_QUAL_REF GITLAB_QUAL_TAGS GITLAB_QUAL_QUEUE_TOKEN_FILE GITLAB_QUAL_RUNNER_TOKEN_FILE; do require_env "$key"; done
require_secret_file GITLAB_QUAL_QUEUE_TOKEN_FILE; require_secret_file GITLAB_QUAL_RUNNER_TOKEN_FILE
export_real_candidate_images
init_run
begin_real gitlab
count=${GITLAB_QUAL_JOB_COUNT:-3}; timeout=${GITLAB_QUAL_TIMEOUT_SECONDS:-1800}; [[ "$count" =~ ^[1-9][0-9]*$ ]] || die 'GITLAB_QUAL_JOB_COUNT must be a positive integer'
stack=${REAL_GITLAB_STACK:-deda-real-gitlab}
service_name=$(real_service "$stack" gitlab-runner)
tmpdir=$(mktemp -d)
timeline="$(real_result_dir gitlab)/swarm-scale-timeline.ndjson"
namesfile="$(real_result_dir gitlab)/swarm-runner-names.txt"
trap 'teardown_real_stack "$tmpdir" "$stack" "${stack}-gitlab-queue-reader" "${stack}-gitlab-runner-auth"' EXIT
deploy_gitlab_stack "$tmpdir"
write_real_candidate gitlab
wait_real_desired "$service_name" 0 'initial GitLab runner service at zero'
record_scale "$timeline" "$service_name" gitlab
token=$(secret "$GITLAB_QUAL_QUEUE_TOKEN_FILE"); project=$(printf '%s' "$GITLAB_QUAL_PROJECT" | sed 's|/|%2F|g')
base="${GITLAB_QUAL_URL%/}/api/v4/projects/$project"; pipeline_ids=()
for _ in $(seq 1 "$count"); do response=$(curl --fail --silent --show-error -H "PRIVATE-TOKEN: $token" -X POST --data-urlencode "ref=$GITLAB_QUAL_REF" "$base/pipeline"); printf '%s\n' "$response" | jq '{id,status,web_url,created_at,updated_at}' >> "$(real_result_dir gitlab)/pipelines.ndjson"; pipeline_ids+=("$(printf '%s' "$response" | jq -r .id)"); done
wait_real_desired_positive "$service_name" 'GitLab runner service scaled up for queued pipelines'
wait_real_running_positive "$service_name" 'GitLab runner tasks started for queued pipelines'
capture_gitlab_runner_names "$service_name" > "$namesfile"
record_scale "$timeline" "$service_name" gitlab
end=$((SECONDS + timeout))
for id in "${pipeline_ids[@]}"; do
  file="$(real_result_dir gitlab)/pipeline-$id.json"
  while :; do
    pipeline=$(curl --fail --silent --show-error -H "PRIVATE-TOKEN: $token" "$base/pipelines/$id")
    jobs=$(curl --fail --silent --show-error -H "PRIVATE-TOKEN: $token" "$base/pipelines/$id/jobs?per_page=100")
    jq -n --argjson pipeline "$pipeline" --argjson jobs "$jobs" '{pipeline:{id:$pipeline.id,status:$pipeline.status,created_at:$pipeline.created_at,updated_at:$pipeline.updated_at},jobs:[$jobs[]?|{id,status,started_at,finished_at,runner:(.runner|{id,description,name})}]}' > "$file"
    record_scale "$timeline" "$service_name" gitlab
    [[ $(jq -r .pipeline.status "$file") =~ ^(success|failed|canceled|skipped)$ ]] && break
    (( SECONDS < end )) || { write_real gitlab FAIL "Timed out waiting for pipeline $id."; exit 1; }; sleep 5
  done
  jq -e '.pipeline.status == "success" and ([.jobs[] | select(.status != "success")] | length == 0)' "$file" >/dev/null || { write_real gitlab FAIL "Pipeline $id did not succeed."; exit 1; }
done
unset token
assert_gitlab_runner_attribution "$(real_result_dir gitlab)" "$namesfile"
wait_real_desired "$service_name" 0 'GitLab runner service scaled back to zero'
wait_real_running_zero "$service_name" 'GitLab runner tasks drained to zero'
record_scale "$timeline" "$service_name" gitlab
assert_scale_timeline "$timeline" "$service_name"
capture_real_swarm_evidence gitlab "$stack" "$service_name"
write_real gitlab PASS 'All queued pipelines and jobs completed successfully and DEDA/Swarm completed 0→N→active→0.'
printf 'GitLab qualification passed provider-side and DEDA/Swarm scale evidence checks.\n'
