#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
confirm_real "${1:-}"
for key in AZURE_QUAL_ORGANIZATION_URL AZURE_QUAL_PROJECT AZURE_QUAL_PIPELINE_ID AZURE_QUAL_POOL AZURE_QUAL_QUEUE_TOKEN_FILE AZURE_QUAL_AGENT_TOKEN_FILE; do require_env "$key"; done
require_secret_file AZURE_QUAL_QUEUE_TOKEN_FILE; require_secret_file AZURE_QUAL_AGENT_TOKEN_FILE
export_real_candidate_images
init_run
begin_real azure-pipelines
count=${AZURE_QUAL_JOB_COUNT:-3}; timeout=${AZURE_QUAL_TIMEOUT_SECONDS:-1800}; [[ "$count" =~ ^[1-9][0-9]*$ ]] || die 'AZURE_QUAL_JOB_COUNT must be a positive integer'
stack=${REAL_AZURE_STACK:-deda-real-azure}
service_name=$(real_service "$stack" azure-runner)
tmpdir=$(mktemp -d)
timeline="$(real_result_dir azure-pipelines)/swarm-scale-timeline.ndjson"
hostfile="$(real_result_dir azure-pipelines)/swarm-runner-hostnames.txt"
agents_file="$(real_result_dir azure-pipelines)/agent-names.txt"
trap 'teardown_real_stack "$tmpdir" "$stack" "${stack}-ado-queue-reader" "${stack}-ado-agent-registration"' EXIT
deploy_azure_stack "$tmpdir"
write_real_candidate azure-pipelines
wait_real_desired "$service_name" 0 'initial Azure runner service at zero'
record_scale "$timeline" "$service_name" azure-pipelines
token=$(secret "$AZURE_QUAL_QUEUE_TOKEN_FILE"); base="${AZURE_QUAL_ORGANIZATION_URL%/}/$AZURE_QUAL_PROJECT/_apis/pipelines/$AZURE_QUAL_PIPELINE_ID/runs"; queue_url="$base?api-version=7.1"
run_ids=()
for _ in $(seq 1 "$count"); do response=$(curl --fail --silent --show-error -u ":$token" -H 'content-type: application/json' -X POST "$queue_url" -d '{}'); printf '%s\n' "$response" | jq '{id,state,result,createdDate,finishedDate}' >> "$(real_result_dir azure-pipelines)/runs.ndjson"; run_ids+=("$(printf '%s' "$response" | jq -r .id)"); done
wait_real_desired_positive "$service_name" 'Azure runner service scaled up for queued pipeline runs'
wait_real_running_positive "$service_name" 'Azure runner tasks started for queued pipeline runs'
capture_real_runner_hostnames "$service_name" > "$hostfile"
record_scale "$timeline" "$service_name" azure-pipelines
end=$((SECONDS + timeout))
timeline_base="${AZURE_QUAL_ORGANIZATION_URL%/}/$AZURE_QUAL_PROJECT/_apis/build/builds"
for id in "${run_ids[@]}"; do
  file="$(real_result_dir azure-pipelines)/run-$id.json"
  while :; do
    curl --fail --silent --show-error -u ":$token" "$base/$id?api-version=7.1" | jq '{id,state,result,createdDate,finishedDate}' > "$file"
    curl --fail --silent --show-error -u ":$token" "$timeline_base/$id/timeline?api-version=7.1" | jq -r '.records[]?.workerName // ""' | grep -F 'deda-ado-' >> "$agents_file" || true
    capture_real_runner_hostnames "$service_name" >> "$hostfile"
    sort -u "$hostfile" -o "$hostfile"
    record_scale "$timeline" "$service_name" azure-pipelines
    [[ $(jq -r .state "$file") == completed ]] && break
    (( SECONDS < end )) || { write_real azure-pipelines FAIL "Timed out waiting for run $id."; exit 1; }
    sleep 5
  done
  [[ $(jq -r .result "$file") == succeeded ]] || { write_real azure-pipelines FAIL "Run $id did not succeed."; exit 1; }
done
unset token
assert_azure_agent_attribution "$(real_result_dir azure-pipelines)" "$hostfile"
wait_real_desired "$service_name" 0 'Azure runner service scaled back to zero'
wait_real_running_zero "$service_name" 'Azure runner tasks drained to zero'
record_scale "$timeline" "$service_name" azure-pipelines
assert_scale_timeline "$timeline" "$service_name"
capture_real_swarm_evidence azure-pipelines "$stack" "$service_name"
write_real azure-pipelines PASS 'All queued pipeline runs completed successfully and DEDA/Swarm completed 0→N→active→0.'
printf 'Azure qualification passed provider-side and DEDA/Swarm scale evidence checks.\n'
