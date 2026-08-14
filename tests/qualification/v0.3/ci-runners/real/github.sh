#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
confirm_real "${1:-}"
for key in GITHUB_QUAL_OWNER GITHUB_QUAL_REPOSITORY GITHUB_QUAL_WORKFLOW GITHUB_QUAL_QUEUE_TOKEN_FILE GITHUB_QUAL_RUNNER_ADMIN_TOKEN_FILE; do require_env "$key"; done
require_secret_file GITHUB_QUAL_QUEUE_TOKEN_FILE; require_secret_file GITHUB_QUAL_RUNNER_ADMIN_TOKEN_FILE
init_run
begin_real github
api=${GITHUB_QUAL_API_URL:-https://api.github.com}; ref=${GITHUB_QUAL_REF:-main}; count=${GITHUB_QUAL_JOB_COUNT:-3}; timeout=${GITHUB_QUAL_TIMEOUT_SECONDS:-1800}
[[ "$count" =~ ^[1-9][0-9]*$ ]] || die 'GITHUB_QUAL_JOB_COUNT must be a positive integer'
stack=${REAL_GITHUB_STACK:-deda-real-github}
service_name=$(real_service "$stack" github-runner)
tmpdir=$(mktemp -d)
timeline="$(real_result_dir github)/swarm-scale-timeline.ndjson"
trap 'teardown_real_stack "$tmpdir" "$stack" "${stack}-github-queue-reader" "${stack}-github-runner-admin"' EXIT
deploy_github_stack "$tmpdir"
wait_real_desired "$service_name" 0 'initial GitHub runner service at zero'
record_scale "$timeline" "$service_name" github
token=$(secret "$GITHUB_QUAL_QUEUE_TOKEN_FILE")
dispatch_body=$(jq -n --arg ref "$ref" '{ref:$ref}')
list_runs() { curl --fail --silent --show-error -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$api/repos/$GITHUB_QUAL_OWNER/$GITHUB_QUAL_REPOSITORY/actions/workflows/$GITHUB_QUAL_WORKFLOW/runs?event=workflow_dispatch&per_page=100"; }
before=$(list_runs | jq -r '.workflow_runs[]?.id')
for _ in $(seq 1 "$count"); do
  curl --fail --silent --show-error -X POST -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api/repos/$GITHUB_QUAL_OWNER/$GITHUB_QUAL_REPOSITORY/actions/workflows/$GITHUB_QUAL_WORKFLOW/dispatches" -d "$dispatch_body" >/dev/null
done
run_ids=()
end=$((SECONDS + timeout))
while (( ${#run_ids[@]} < count )); do
  mapfile -t run_ids < <(list_runs | jq -r --arg before "$before" '.workflow_runs[]? | select((.id|tostring) as $id | ($before | split("\n") | index($id) | not)) | .id' | head -n "$count")
  (( ${#run_ids[@]} >= count )) && break
  (( SECONDS < end )) || { write_real github FAIL 'Timed out discovering dispatched workflow runs.'; exit 1; }
  sleep 5
done
wait_real_desired_positive "$service_name" 'GitHub runner service scaled up for dispatched jobs'
wait_real_running_positive "$service_name" 'GitHub runner tasks started for dispatched jobs'
record_scale "$timeline" "$service_name" github
for id in "${run_ids[@]}"; do
  run_file="$(real_result_dir github)/run-$id.json"
  while :; do
    run=$(curl --fail --silent --show-error -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$api/repos/$GITHUB_QUAL_OWNER/$GITHUB_QUAL_REPOSITORY/actions/runs/$id")
    jobs=$(curl --fail --silent --show-error -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$api/repos/$GITHUB_QUAL_OWNER/$GITHUB_QUAL_REPOSITORY/actions/runs/$id/jobs?per_page=100")
    jq -n --argjson run "$run" --argjson jobs "$jobs" '{run:{id:$run.id,status:$run.status,conclusion:$run.conclusion,created_at:$run.created_at,updated_at:$run.updated_at},jobs:[$jobs.jobs[]?|{id,status,conclusion,started_at,completed_at,runner_name}]}' > "$run_file"
    record_scale "$timeline" "$service_name" github
    [[ $(jq -r .run.status "$run_file") == completed ]] && break
    (( SECONDS < end )) || { write_real github FAIL "Timed out waiting for workflow run $id."; exit 1; }
    sleep 5
  done
  jq -e '.run.conclusion == "success" and ([.jobs[] | select(.status != "completed" or .conclusion != "success")] | length == 0) and ([.jobs[] | select((.runner_name // "") == "")] | length == 0)' "$run_file" >/dev/null || { write_real github FAIL "Workflow run $id did not complete successfully on a named DEDA runner."; exit 1; }
done
unset token
unset dispatch_body
wait_real_desired "$service_name" 0 'GitHub runner service scaled back to zero'
wait_real_running_zero "$service_name" 'GitHub runner tasks drained to zero'
record_scale "$timeline" "$service_name" github
assert_scale_timeline "$timeline" "$service_name"
capture_real_swarm_evidence github "$stack" "$service_name"
jq -n --argjson ids "$(printf '%s\n' "${run_ids[@]}" | jq -R . | jq -s .)" '{workflowRunIds:$ids}' > "$(real_result_dir github)/run-ids.json"
write_real github PASS 'All dispatched workflow runs and jobs completed successfully on DEDA-managed Swarm runner tasks; 0→N→active→0 scale evidence was captured.'
printf 'GitHub qualification passed provider-side and DEDA/Swarm scale evidence checks.\n'
